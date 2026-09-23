# Create a full snapshot of this folder (including node_modules and config.cmd)
# so the whole thing can be restored by unzipping. ASCII-only on purpose.
$ErrorActionPreference = 'Stop'
# The progress bar makes Compress-Archive far slower and floods the console.
$ProgressPreference = 'SilentlyContinue'

# $PSScriptRoot is the reliable way to locate the script folder.
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { throw 'Cannot determine the script folder.' }

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path $versionFile) { (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() } else { '0.0.0' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$snapshotDir = Join-Path $root 'snapshots'
New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null

$base = 'webrdp-v{0}-{1}' -f $version, $stamp
$zip = Join-Path $snapshotDir ($base + '.zip')
$tgz = Join-Path $snapshotDir ($base + '.tar.gz')
$staging = Join-Path $env:TEMP ('webrdp-snapshot-' + $stamp)
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    Get-ChildItem -LiteralPath $root -Force |
        Where-Object { $_.Name -notin @('snapshots', '.git') } |
        Copy-Item -Destination $staging -Recurse -Force

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -CompressionLevel Optimal -Force

    # A second archive for Linux: zip entries created by Compress-Archive use
    # backslash separators, which Linux unzip turns into odd literal filenames.
    # tar.gz keeps forward slashes, so use it when copying to the Debian server.
    $tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tarCmd) { $tarCmd = Get-Command tar -ErrorAction SilentlyContinue }
    if ($tarCmd) {
        Push-Location $staging
        try { & $tarCmd.Source -czf $tgz . } finally { Pop-Location }
    } else {
        Write-Host '  (tar not found - skipped tar.gz; use git or scp for Linux transfers)'
    }
}
finally {
    try { if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } } catch { }
}

Write-Host ''
Write-Host '  Snapshot created'
Write-Host '  ----------------'
Write-Host ('  version : v{0}' -f $version)
Write-Host ('  zip     : {0}  ({1:N1} MB)  - restore on Windows' -f (Split-Path -Leaf $zip), ((Get-Item -LiteralPath $zip).Length / 1MB))
if (Test-Path -LiteralPath $tgz) {
    Write-Host ('  tar.gz  : {0}  ({1:N1} MB)  - use this for Linux' -f (Split-Path -Leaf $tgz), ((Get-Item -LiteralPath $tgz).Length / 1MB))
}
Write-Host ''
Write-Host '  To roll back on Windows: close the gateway, rename the current folder'
Write-Host '  aside, then unzip the .zip and start it again.'
Write-Host '  To deploy on Debian: copy the project (git clone / scp / the .tar.gz),'
Write-Host '  then run: sudo bash deploy/debian/install.sh'
Write-Host ''
