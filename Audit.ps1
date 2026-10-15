# Only installation and the elevated event worker load this file.
function Initialize-AuditNative {
    if ('VmnetSync.AuditNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
namespace VmnetSync {
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
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegOpenKeyEx(IntPtr root, string name, uint options, uint rights, out IntPtr key);
        [DllImport("advapi32.dll")] static extern int RegGetKeySecurity(IntPtr key, uint sections, byte[] descriptor, ref uint length);
        [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr descriptor, out bool present, out IntPtr sacl, out bool defaulted);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string name, int type, uint sections, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
        static readonly Guid FileSystem = new Guid("0cce921d-69ae-11d9-bed3-505054503030");
        static readonly Guid Registry = new Guid("0cce921e-69ae-11d9-bed3-505054503030");
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
        static uint QueryFlags(Guid id) {
            IntPtr data;
            if (!AuditQuerySystemPolicy(ref id, 1, out data)) throw new Win32Exception();
            try { return ((Policy)Marshal.PtrToStructure(data, typeof(Policy))).Flags; }
            finally { AuditFree(data); }
        }
        static void UpdateFlags(Guid id, uint flags) {
            // AuditSetSystemPolicy treats zero as "leave unchanged". NONE (4)
            // explicitly restores an originally disabled audit subcategory.
            var value = new Policy { Subcategory=id, Flags=(flags & 3) == 0 ? 4u : (flags & 3) };
            if (!AuditSetSystemPolicy(ref value, 1)) throw new Win32Exception();
        }
        public static uint GetFlags() { return QueryFlags(FileSystem); }
        public static void SetFlags(uint flags) { UpdateFlags(FileSystem, flags); }
        public static uint GetRegistryFlags() { return QueryFlags(Registry); }
        public static void SetRegistryFlags(uint flags) { UpdateFlags(Registry, flags); }
        public static RegistrySecurity ReadRegistryAudit(string subkey) {
            IntPtr key;
            int error = RegOpenKeyEx(new IntPtr(unchecked((int)0x80000002)), subkey, 0, 0x01020000, out key);
            if (error != 0) throw new Win32Exception(error);
            try {
                uint size = 0;
                error = RegGetKeySecurity(key, 8, null, ref size);
                if (error != 122 && error != 0) throw new Win32Exception(error);
                var buffer = new byte[size];
                error = RegGetKeySecurity(key, 8, buffer, ref size);
                if (error != 0) throw new Win32Exception(error);
                var security = new RegistrySecurity();
                security.SetSecurityDescriptorBinaryForm(buffer, AccessControlSections.Audit);
                return security;
            } finally { RegCloseKey(key); }
        }
        public static void WriteRegistryAudit(string subkey, RegistrySecurity security) {
            // Unlike RegSetKeySecurity, SetNamedSecurityInfo propagates inherited
            // audit ACEs to existing children as well as future subkeys.
            var descriptor = security.GetSecurityDescriptorBinaryForm();
            var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
            try {
                bool present, defaulted; IntPtr sacl;
                if (!GetSecurityDescriptorSacl(pinned.AddrOfPinnedObject(), out present, out sacl, out defaulted)) throw new Win32Exception();
                uint error = SetNamedSecurityInfo("MACHINE\\" + subkey, 4, 8, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, present ? sacl : IntPtr.Zero);
                if (error != 0) throw new Win32Exception((int)error);
            } finally { pinned.Free(); }
        }
    }
}
'@
    [VmnetSync.AuditNative]::EnablePrivilege()
}

function Get-ConfigAuditTargets([string]$Directory, [string]$RegistryRoot = (Get-VMnetRegistryRoot)) {
    # Audit only directory entry creation/deletion, not every descendant.
    # This catches atomic replacement; the worker reattaches the file SACL afterward.
    [pscustomobject]@{ Path = $Directory; Rights = [Security.AccessControl.FileSystemRights]'WriteData,DeleteSubdirectoriesAndFiles' }
    foreach ($name in @('vmnetnat.conf', 'vmnetdhcp.conf')) {
        [pscustomobject]@{ Path = (Join-Path $Directory $name); Rights = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete' }
    }
    [pscustomobject]@{ Path=$RegistryRoot; Kind='Registry'; Rights=[Security.AccessControl.RegistryRights]::SetValue }
}

function New-ConfigAuditRule($Target) {
    $sid = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    if ($Target.PSObject.Properties['Kind'] -and $Target.Kind -eq 'Registry') {
        return [Security.AccessControl.RegistryAuditRule]::new($sid, $Target.Rights,
            [Security.AccessControl.InheritanceFlags]::ContainerInherit, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AuditFlags]::Success)
    }
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
    })) {
        $value = if ($existing -is [Security.AccessControl.RegistryAuditRule]) { [int]$existing.RegistryRights } else { [int]$existing.FileSystemRights }
        $rights = $rights -bor $value
    }
    return $rights
}

function Get-ConfigAuditAcl($Target) {
    if (-not $Target.PSObject.Properties['Kind'] -or $Target.Kind -ne 'Registry') { return Get-Acl -LiteralPath $Target.Path -Audit }
    # Windows PowerShell's registry provider does not reliably open a handle
    # with ACCESS_SYSTEM_SECURITY for Get-Acl -Audit. Open that right explicitly.
    $subkey=$Target.Path -replace '^HKLM:\\', ''
    return [VmnetSync.AuditNative]::ReadRegistryAudit($subkey)
}

function Set-ConfigAuditAcl($Target, $Acl) {
    if (-not $Target.PSObject.Properties['Kind'] -or $Target.Kind -ne 'Registry') { Set-Acl -LiteralPath $Target.Path -AclObject $Acl; return }
    $subkey=$Target.Path -replace '^HKLM:\\', ''
    [VmnetSync.AuditNative]::WriteRegistryAudit($subkey, $Acl)
}

function Restore-ConfigAudit([string]$Directory) {
    Initialize-AuditNative
    foreach ($target in @(Get-ConfigAuditTargets $Directory)) {
        if (-not (Test-Path -LiteralPath $target.Path)) { continue }
        $acl = Get-ConfigAuditAcl $target
        $rule = New-ConfigAuditRule $target
        if (((Get-ExistingAuditRights $acl $rule) -band [int]$target.Rights) -ne [int]$target.Rights) {
            $acl.AddAuditRule($rule)
            Set-ConfigAuditAcl $target $acl
        }
    }
}

function Remove-AddedConfigAudit($Entry, [string]$Directory) {
    if ($Entry.AddedRights -eq 0 -or -not (Test-Path -LiteralPath $Entry.Path)) { return }
    $target = @(Get-ConfigAuditTargets $Directory | Where-Object { $_.Path -ieq $Entry.Path })[0]
    if ($target.PSObject.Properties['Kind'] -and $target.Kind -eq 'Registry') { $target.Rights=[Security.AccessControl.RegistryRights]$Entry.AddedRights }
    else { $target.Rights=[Security.AccessControl.FileSystemRights]$Entry.AddedRights }
    $acl = Get-ConfigAuditAcl $target
    [void]$acl.RemoveAuditRule((New-ConfigAuditRule $target))
    Set-ConfigAuditAcl $target $acl
}

function New-SyncTaskXml([string]$Directory, [string]$Worker, [string[]]$EditorExecutables) {
    $targets = @(Get-ConfigAuditTargets $Directory)
    $clauses = @($targets | Where-Object { $_.Path -ne $Directory -and -not $_.PSObject.Properties['Kind'] } | ForEach-Object {
        if ($_.Path.Contains("'")) { throw 'An apostrophe in the configuration path is unsupported.' }
        "Data[@Name='ObjectName']='$([Security.SecurityElement]::Escape($_.Path))'"
    })
    # Directory-entry events cover atomic file replacement. Limit these to VMware
    # editors so DHCP lease-file rotation does not launch unnecessary workers.
    $editors = @($EditorExecutables | ForEach-Object {
        if ($_.Contains("'")) { throw 'An apostrophe in the editor path is unsupported.' }
        "Data[@Name='ProcessName']='$([Security.SecurityElement]::Escape($_))'"
    })
    if ($editors.Count -eq 0) { throw 'At least one VMware editor executable is required.' }
    if ($Directory.Contains("'")) { throw 'An apostrophe in the configuration path is unsupported.' }
    $clauses += "(Data[@Name='ObjectName']='$([Security.SecurityElement]::Escape($Directory))' and (" + ($editors -join ' or ') + '))'
    # Existing broad SACLs can audit reads too. Restrict to write/append/delete/
    # delete-child access; otherwise our own reads could trigger an endless loop.
    $selects = "<Select Path='Security'>*[System[EventID=4663] and EventData[(" + ($clauses -join ' or ') + ") and band(Data[@Name='AccessMask'],65606)]]</Select>"
    $registry = @($targets | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Registry' })[0]
    $keyName = $registry.Path -replace '^HKLM:', '\REGISTRY\MACHINE'
    if ($keyName.Contains("'")) { throw 'An apostrophe in the registry path is unsupported.' }
    # Separate selects keep each XPath within Windows Event Log's expression limit.
    # 4657 is a value modification event; registry reads never match.
    foreach ($number in 0..19) {
        $names = @('','\Adapter','\DHCP','\NAT') | ForEach-Object {
            "Data[@Name='ObjectName']='$( [Security.SecurityElement]::Escape("$keyName\vmnet$number$_") )'"
        }
        $selects += "<Select Path='Security'>*[System[EventID=4657] and EventData[" + ($names -join ' or ') + ']]</Select>'
    }
    $query = "<QueryList><Query Id='0' Path='Security'>$selects</Query></QueryList>"
    $subscription = [Security.SecurityElement]::Escape($query)
    $command = [Security.SecurityElement]::Escape("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
    $arguments = [Security.SecurityElement]::Escape('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Worker + '" -Mode Repair -EventMode')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Synchronize changed DHCP-managed VMware host adapters after network configuration writes. No resident worker.</Description></RegistrationInfo>
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
