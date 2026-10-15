#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
$output = [IO.Path]::GetFullPath($OutputDirectory)
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vmnet8-package-tests-' + [Guid]::NewGuid().ToString('N'))
$unpack = Join-Path $scratch ('package ' + [char]0x4e2d + ' & spaces')
[void](New-Item -ItemType Directory -Path $unpack)
try {
    $checksums = [IO.File]::ReadAllLines((Join-Path $output 'SHA256SUMS.txt'))
    if ($checksums.Count -ne 2) { throw 'Expected two package checksums.' }
    foreach ($line in $checksums) {
        if ($line -notmatch '^([0-9a-f]{64})  (vmnet8-sync-[\d.]+-(?:source|windows-x64)\.zip)$') { throw 'Invalid checksum entry.' }
        if ((Get-FileHash -LiteralPath (Join-Path $output $Matches[2]) -Algorithm SHA256).Hash -ine $Matches[1]) { throw 'Package checksum mismatch.' }
    }
    foreach ($kind in @('windows-x64','source')) {
        $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $output "vmnet8-sync-$version-$kind.zip"))
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
            if (@($names | Sort-Object -Unique).Count -ne $names.Count) { throw 'Duplicate ZIP entry.' }
            foreach ($name in $names) {
                if (-not $name.StartsWith("vmnet8-sync-$version/") -or $name.Contains('..') -or $name.Contains('\')) { throw "Unsafe ZIP entry: $name" }
                if ($name -match '/(?:installation\.json|baseline\.json|last-result\.json|before-repair\.json|task\.xml|\.git/|[^/]*\.log)$') { throw "Private/runtime file in package: $name" }
            }
            foreach ($required in @('Install.cmd','Uninstall.cmd','Status.cmd','Launcher.ps1','Install.ps1','Uninstall.ps1','Status.ps1','Core.ps1','Sync.ps1','Audit.ps1','Setup.Common.ps1','VERSION','LICENSE','README.md')) {
                if ("vmnet8-sync-$version/$required" -notin $names) { throw "Missing package file: $required" }
            }
            if ($kind -eq 'source' -and "vmnet8-sync-$version/.github/workflows/ci.yml" -notin $names) { throw 'Source archive lost hidden .github files.' }
            if ($kind -eq 'source' -and "vmnet8-sync-$version/Test-MultiNetwork.ps1" -notin $names) { throw 'Source archive lost multi-network tests.' }
            if ($kind -eq 'source' -and "vmnet8-sync-$version/Test-Integration.ps1" -notin $names) { throw 'Source archive lost optional integration tests.' }
        } finally { $archive.Dispose() }
    }
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $output "vmnet8-sync-$version-source.zip"),$unpack)
    $root = Join-Path $unpack "vmnet8-sync-$version"
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.ps1') {
        $errors=$null; $tokens=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count -gt 0) { throw "Packaged script cannot be parsed: $($file.Name)" }
    }
    # Read-only launch from an extracted Unicode/space/& path. No UAC and no worker.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Launcher.ps1') + '" -Action Status -NoPause'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { $process.Kill(); $process.WaitForExit(); throw 'Packaged status launcher did not exit.' }
        if ($process.ExitCode -ne 0) { throw "Packaged status failed: $($stderr.Result)" }
        if (-not $stdout.Result.Contains('VMnet8 Sync')) { throw 'Packaged status produced no report.' }
    } finally { $process.Dispose() }
    Write-Output 'PASS package checksums, archive contents, hidden source files, script parsing and read-only launch from a Unicode path'
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'vmnet8-package-tests-*') { throw 'Unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
