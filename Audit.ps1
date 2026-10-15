# Only installation and the elevated event worker load this file.
function Initialize-AuditNative {
    if ('Vmnet8Sync.AuditNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace Vmnet8Sync {
    public static class AuditNative {
        [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Luid; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)] struct Policy { public Guid Subcategory; public uint Flags; public Guid Category; }
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref Privileges value, uint length, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AuditQuerySystemPolicy(ref Guid id, uint count, out IntPtr data);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AuditSetSystemPolicy(ref Policy data, uint count);
        [DllImport("advapi32.dll")] static extern void AuditFree(IntPtr data);
        static readonly Guid FileSystem = new Guid("0cce921d-69ae-11d9-bed3-505054503030");
        public static void EnablePrivilege() {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new Win32Exception();
            try {
                var value = new Privileges { Count=1, Attributes=2 };
                if (!LookupPrivilegeValue(null, "SeSecurityPrivilege", out value.Luid)) throw new Win32Exception();
                if (!AdjustTokenPrivileges(token, false, ref value, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
                int error = Marshal.GetLastWin32Error();
                if (error != 0) throw new Win32Exception(error);
            } finally { CloseHandle(token); }
        }
        public static uint GetFlags() {
            Guid id = FileSystem; IntPtr data;
            if (!AuditQuerySystemPolicy(ref id, 1, out data)) throw new Win32Exception();
            try { return ((Policy)Marshal.PtrToStructure(data, typeof(Policy))).Flags; }
            finally { AuditFree(data); }
        }
        public static void SetFlags(uint flags) {
            var value = new Policy { Subcategory=FileSystem, Flags=flags };
            if (!AuditSetSystemPolicy(ref value, 1)) throw new Win32Exception();
        }
    }
}
'@
    [Vmnet8Sync.AuditNative]::EnablePrivilege()
}

function Get-ConfigAuditTargets([string]$Directory) {
    # Audit only directory entry creation/deletion, not every descendant.
    # This catches atomic replacement; the worker reattaches the file SACL afterward.
    [pscustomobject]@{ Path = $Directory; Rights = [Security.AccessControl.FileSystemRights]'WriteData,DeleteSubdirectoriesAndFiles' }
    foreach ($name in @('vmnetnat.conf', 'vmnetdhcp.conf')) {
        [pscustomobject]@{ Path = (Join-Path $Directory $name); Rights = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete' }
    }
}

function New-ConfigAuditRule($Target) {
    $sid = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    return [Security.AccessControl.FileSystemAuditRule]::new($sid, $Target.Rights,
        [Security.AccessControl.InheritanceFlags]::None, [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AuditFlags]::Success)
}

function Get-ExistingAuditRights($Acl, $Rule) {
    $rights = 0
    foreach ($existing in @($Acl.GetAuditRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference.Value -eq $Rule.IdentityReference.Value -and
        $_.InheritanceFlags -eq $Rule.InheritanceFlags -and
        $_.PropagationFlags -eq $Rule.PropagationFlags -and
        ($_.AuditFlags -band [Security.AccessControl.AuditFlags]::Success)
    })) { $rights = $rights -bor [int]$existing.FileSystemRights }
    return $rights
}

function Restore-ConfigAudit([string]$Directory) {
    Initialize-AuditNative
    foreach ($target in @(Get-ConfigAuditTargets $Directory)) {
        if (-not (Test-Path -LiteralPath $target.Path)) { continue }
        $acl = Get-Acl -LiteralPath $target.Path -Audit
        $rule = New-ConfigAuditRule $target
        if (((Get-ExistingAuditRights $acl $rule) -band [int]$rule.FileSystemRights) -ne [int]$rule.FileSystemRights) {
            $acl.AddAuditRule($rule)
            Set-Acl -LiteralPath $target.Path -AclObject $acl
        }
    }
}

function New-SyncTaskXml([string]$Directory, [string]$Worker, [string[]]$EditorExecutables) {
    $clauses = @(Get-ConfigAuditTargets $Directory | Where-Object { $_.Path -ne $Directory } | ForEach-Object {
        if ($_.Path.Contains("'")) { throw 'An apostrophe in the configuration path is unsupported.' }
        "Data[@Name='ObjectName']='$($_.Path)'"
    })
    # Directory-entry events cover atomic file replacement. Limit these to VMware
    # editors so DHCP lease-file rotation does not launch unnecessary workers.
    $editors = @($EditorExecutables | ForEach-Object {
        if ($_.Contains("'")) { throw 'An apostrophe in the editor path is unsupported.' }
        "Data[@Name='ProcessName']='$_'"
    })
    if ($editors.Count -eq 0) { throw 'At least one VMware editor executable is required.' }
    if ($Directory.Contains("'")) { throw 'An apostrophe in the configuration path is unsupported.' }
    $clauses += "(Data[@Name='ObjectName']='$Directory' and (" + ($editors -join ' or ') + '))'
    # Existing broad SACLs can audit reads too. Restrict to write/append/delete/
    # delete-child access; otherwise our own reads could trigger an endless loop.
    $query = "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[System[EventID=4663] and EventData[(" + ($clauses -join ' or ') + ") and band(Data[@Name='AccessMask'],65606)]]</Select></Query></QueryList>"
    $subscription = [Security.SecurityElement]::Escape($query)
    $command = [Security.SecurityElement]::Escape("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
    $arguments = [Security.SecurityElement]::Escape('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Worker + '" -Mode Repair -EventMode')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Repair DHCP-managed VMnet8 after VMware network configuration writes. No resident worker.</Description></RegistrationInfo>
  <Triggers>
    <EventTrigger><Enabled>true</Enabled><Subscription>$subscription</Subscription><Delay>PT3S</Delay></EventTrigger>
  </Triggers>
  <Principals><Principal id="System"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>false</AllowStartOnDemand><WakeToRun>false</WakeToRun>
    <Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT2M</ExecutionTimeLimit><Priority>7</Priority>
  </Settings>
  <Actions Context="System"><Exec><Command>$command</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
}
