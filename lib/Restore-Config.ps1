#Requires -Version 5.1
<#
.SYNOPSIS
  Puts one app's settings back from a WinPrestige backup.

.DESCRIPTION
  WinPrestige copies this script into every folder under Configs\. It reads restore.json
  next to it, closes the app, copies the saved files back to where they came from,
  imports any saved registry keys, and fixes paths inside config files if your
  Windows user folder has a different name than before.

  Install the app first, then run this (or Restore-Config.cmd next to it).
  Use -TestRun to see what would happen without changing anything.
#>
[CmdletBinding()]
param([switch]$TestRun)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Get-Content -LiteralPath (Join-Path $here 'restore.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-DownloadsFolder {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Expand-Target {
    param([string]$Path, [string]$InstallDir)
    $map = [ordered]@{
        '%LOCALAPPDATA%' = $env:LOCALAPPDATA
        '%APPDATA%' = $env:APPDATA
        '%DOCUMENTS%' = [Environment]::GetFolderPath('MyDocuments')
        '%DESKTOP%' = [Environment]::GetFolderPath('Desktop')
        '%PICTURES%' = [Environment]::GetFolderPath('MyPictures')
        '%VIDEOS%' = [Environment]::GetFolderPath('MyVideos')
        '%MUSIC%' = [Environment]::GetFolderPath('MyMusic')
        '%DOWNLOADS%' = (Get-DownloadsFolder)
        '%USERPROFILE%' = $env:USERPROFILE
        '%PROGRAMDATA%' = $env:ProgramData
        '%PROGRAMFILES(X86)%' = ${env:ProgramFiles(x86)}
        '%PROGRAMFILES%' = $env:ProgramFiles
        '%WINDIR%' = $env:windir
    }
    $p = $Path
    if ($InstallDir) { $p = $p.Replace('%INSTALLDIR%', $InstallDir.TrimEnd('\')) }
    foreach ($k in $map.Keys) { if ($map[$k]) { $p = $p.Replace($k, ([string]$map[$k]).TrimEnd('\')) } }
    return $p
}

function Find-InstallDir {
    # Where the freshly installed app lives now, from its uninstall entry.
    if ($spec.app) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        foreach ($e in (Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)) {
            if ($e.DisplayName -and $e.DisplayName -match $spec.app -and $e.InstallLocation) {
                $loc = ([string]$e.InstallLocation).Trim('"').TrimEnd('\')
                if (Test-Path -LiteralPath $loc) { return $loc }
            }
        }
    }
    foreach ($f in @($spec.installDirFallback)) {
        if (-not $f) { continue }
        $p = Expand-Target $f
        if (Test-Path -LiteralPath $p) { return $p.TrimEnd('\') }
    }
    if ($spec.installDir) { return ([string]$spec.installDir).TrimEnd('\') }
    return $null
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsAdmin = (@($spec.items | Where-Object { $_.target -match '^%(PROGRAMFILES|PROGRAMFILES\(X86\)|PROGRAMDATA|WINDIR|INSTALLDIR)%' }).Count -gt 0) -or
              (@($spec.registry | Where-Object { $_.key -like 'HKLM*' }).Count -gt 0)
if ($needsAdmin -and -not $isAdmin -and -not $TestRun) {
    # Protected folder: re-run elevated from a local copy (an admin window may not be signed in to the NAS).
    Write-Host "$($spec.name) settings go into a protected folder, so Windows will ask for administrator rights."
    $tmp = Join-Path $env:TEMP ('WinPrestige-restore-' + ($spec.id -replace '[^\w.-]', '_'))
    & robocopy.exe $here $tmp /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp\Restore-Config.ps1`""
    return
}

Write-Host "Restoring $($spec.name) settings"

$needsInstallDir = @($spec.items | Where-Object { $_.target -like '*%INSTALLDIR%*' }).Count -gt 0
$installDir = $null
if ($needsInstallDir) {
    $installDir = Find-InstallDir
    if (-not $installDir) { throw "Couldn't find where $($spec.name) is installed. Install it first, then run this again." }
}

# Close the app so it can't overwrite the restored files when it exits.
foreach ($name in @($spec.processes)) {
    if (-not $name) { continue }
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { continue }
    if ($TestRun) { Write-Host "  would close $name"; continue }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

$copied = 0
foreach ($item in @($spec.items)) {
    $src = Join-Path $here $item.stored
    $dst = Expand-Target $item.target $installDir
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "Missing from backup: $($item.stored)"; continue }
    if ($TestRun) { Write-Host "  would copy $($item.stored) -> $dst"; continue }
    if ($item.type -eq 'file') {
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    } else {
        & robocopy.exe $src $dst /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { Write-Warning "Some files could not be copied to $dst (robocopy code $LASTEXITCODE)." }
    }
    $copied++
}

foreach ($reg in @($spec.registry)) {
    if (-not $reg) { continue }
    $file = Join-Path $here $reg.stored
    if ($TestRun) { Write-Host "  would import registry key $($reg.key)"; continue }
    & reg.exe import $file 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not import $($reg.key)." }
}

# Config files store absolute paths. If the user folder or Documents moved, point them at the new place.
$pairs = @()
if ($spec.userProfile -and $spec.userProfile -ne $env:USERPROFILE) { $pairs += , @($spec.userProfile, $env:USERPROFILE) }
$docsNow = [Environment]::GetFolderPath('MyDocuments')
if ($spec.documents -and $spec.documents -ne $docsNow) { $pairs += , @($spec.documents, $docsNow) }
if ($pairs.Count -and @($spec.rewrite).Count) {
    # Longest first so a OneDrive Documents path is handled before the bare profile path.
    $pairs = @($pairs | Sort-Object { $_[0].Length } -Descending)
    foreach ($pattern in @($spec.rewrite)) {
        $glob = Expand-Target $pattern $installDir
        foreach ($f in @(Get-ChildItem -Path $glob -File -ErrorAction SilentlyContinue)) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $orig = $text
            foreach ($pair in $pairs) {
                $old = $pair[0].TrimEnd('\'); $new = $pair[1].TrimEnd('\')
                foreach ($form in @(@($old, $new), @($old.Replace('\', '/'), $new.Replace('\', '/')), @($old.Replace('\', '\\'), $new.Replace('\', '\\')))) {
                    $text = [regex]::Replace($text, [regex]::Escape($form[0]), $form[1].Replace('$', '$$'), 'IgnoreCase')
                }
            }
            if ($text -ne $orig) {
                if ($TestRun) { Write-Host "  would update paths in $($f.Name)"; continue }
                [IO.File]::WriteAllText($f.FullName, $text, (New-Object Text.UTF8Encoding $false))
                Write-Host "  updated paths in $($f.Name)"
            }
        }
    }
}

if ($TestRun) { Write-Host "Test run finished for $($spec.name)." }
else { Write-Host "Restored $copied items for $($spec.name)." }
