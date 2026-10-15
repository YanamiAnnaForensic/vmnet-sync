#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Install', 'Uninstall', 'Status')][string]$Action = 'Status', [switch]$NoPause)
$ErrorActionPreference = 'Stop'
# Always use 64-bit Windows PowerShell, including when opened by a 32-bit shell.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Action
    if ($NoPause) { $arguments += ' -NoPause' }
    $child = Start-Process -FilePath "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Wait -PassThru
    exit $child.ExitCode
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and ($Action -ne 'Status' -or -not $NoPause)) {
    try {
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Action
        if ($NoPause) { $arguments += ' -NoPause' }
        $child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
        exit $child.ExitCode
    } catch {
        Write-Host 'Administrator approval was cancelled or unavailable. No installation was performed.' -ForegroundColor Yellow
        if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
        exit 1
    }
}
$exitCode = 0
try {
    switch ($Action) {
        'Install' {
            & "$PSScriptRoot\Install.ps1"
            $message = "Installation complete. Only VMware network-configuration writes trigger the worker.`nNo boot, logon, timer or resident worker."
        }
        'Uninstall' {
            $installed = Join-Path $env:ProgramFiles 'VmnetSync\Uninstall.ps1'
            if (Test-Path -LiteralPath $installed) { & $installed }
            elseif (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'VmnetSync\installation.json')) { throw 'Installation is incomplete. Run Install.cmd to recover before uninstalling.' }
            else { Write-Output 'VMnet Sync is not installed.' }
            $message = 'Uninstall complete. The automatic task is removed. Network addresses were not changed.'
        }
        'Status' {
            if ($NoPause) { & "$PSScriptRoot\Status.ps1"; $message = '' }
            else {
                $report = & "$PSScriptRoot\Status.ps1" -Json | ConvertFrom-Json
                $message = "Installed: $($report.Installed)`nVersion: $($report.Version)`nTask: $($report.TaskState)`nRunning workers: $($report.RunningInstances)`nEvent only: $($report.EventOnly)"
                if ($null -ne $report.LastResult) { $message += "`n`nLast check: $($report.LastResult.Status)" }
                else { $message += "`n`nNo result yet; waiting for the first configuration change." }
                if ($report.TaskInspectionError) { $message += "`n`n$($report.TaskInspectionError)" }
                $message += "`n`nReady means waiting for an event, not a resident worker."
            }
        }
    }
    if (-not $NoPause) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message, 'VMnet Sync', 'OK', 'Information')
    }
} catch {
    $exitCode = 1
    $message = $_.Exception.Message
    Write-Host $message -ForegroundColor Red
    if (-not $NoPause) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message, 'VMnet Sync - action failed', 'OK', 'Error')
    }
}
exit $exitCode
