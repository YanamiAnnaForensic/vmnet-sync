#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid VERSION.' }
$rootFiles = @('Install.cmd','Uninstall.cmd','Status.cmd','Launcher.ps1','Install.ps1','Uninstall.ps1','Status.ps1',
    'Core.ps1','Sync.ps1','Audit.ps1','Setup.Common.ps1','VERSION','README.md','README.en.md','LICENSE','CHANGELOG.md')
$runtimeFiles = $rootFiles + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'docs') -File | ForEach-Object { 'docs/' + $_.Name })
$sourceFiles = $runtimeFiles + @('Build.ps1','Test.ps1','Test-Worker.ps1','Test-Setup.ps1','Test-Package.ps1','.gitignore','.gitattributes',
    '.github/workflows/ci.yml','.github/workflows/release.yml','.github/ISSUE_TEMPLATE/bug_report.md')
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $output)) { [void](New-Item -ItemType Directory -Path $output) }
function Write-ReleaseZip([string]$Name, [string[]]$Files) {
    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file) -PathType Leaf)) { throw "Missing release file: $file" }
    }
    $path = Join-Path $output $Name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in ($Files | Sort-Object -Unique)) {
            $entryName = "vmnet8-sync-$version/" + $file.Replace('\','/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2026, 10, 15, 0, 0, 0, [TimeSpan]::Zero)
            $stream = $entry.Open()
            try {
                $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $file))
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    return $path
}
$packages = @(
    Write-ReleaseZip "vmnet8-sync-$version-windows-x64.zip" $runtimeFiles
    Write-ReleaseZip "vmnet8-sync-$version-source.zip" $sourceFiles
)
$checksums = @($packages | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($_) })
[IO.File]::WriteAllLines((Join-Path $output 'SHA256SUMS.txt'), $checksums, [Text.Encoding]::ASCII)
$packages | ForEach-Object { Get-Item -LiteralPath $_ | Select-Object Name,Length }
Write-Output "Packages and SHA256SUMS.txt written to $output"
