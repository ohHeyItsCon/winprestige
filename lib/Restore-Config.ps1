#Requires -Version 5.1
<#
.SYNOPSIS
  Puts one app's settings back from a WinPrestige backup.

.DESCRIPTION
  WinPrestige copies this script into every folder under Configs\. It reads restore.json
  next to it, closes the app (and pauses its background service), copies the saved files
  back to where they came from, imports any saved registry keys, checks that every file
  landed, and fixes paths inside config files if your Windows user folder has a different
  name than before.

  Install the app first, then run this (or Restore-Config.cmd next to it).
  Use -TestRun to see what would happen without changing anything.
  WinPrestige itself runs its own (newest) copy with -Folder pointing at the backup's
  config folder, so older backups get the latest fixes.
#>
[CmdletBinding()]
param([switch]$TestRun, [switch]$Pause, [string]$Folder)

$ErrorActionPreference = 'Stop'
trap {
    # -Pause is set when this re-runs in its own administrator window; keep it open so the error can be read.
    if ($Pause) {
        Write-Host ("Couldn't finish: " + $_.Exception.Message) -ForegroundColor Red
        [void](Read-Host 'Press Enter to close')
    }
    throw $_
}
$here = $(if ($Folder) { $Folder.TrimEnd('\') } else { Split-Path -Parent $MyInvocation.MyCommand.Path })
$spec = Get-Content -LiteralPath (Join-Path $here 'restore.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Backups made before 1.2.1 don't list background services. WinPrestige's own copy of this
# script sits next to data\profiles.json, so it can look them up there.
if (-not $spec.PSObject.Properties['services']) {
    $profilesFile = Join-Path $PSScriptRoot '..\data\profiles.json'
    if (Test-Path -LiteralPath $profilesFile) {
        $profiles = Get-Content -LiteralPath $profilesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prof in $profiles) {
            if ($prof.id -ne $spec.id) { continue }
            $spec | Add-Member -NotePropertyName services -NotePropertyValue @($prof.services | Where-Object { $_ }) -Force
            $spec | Add-Member -NotePropertyName processes -NotePropertyValue @(@($spec.processes) + @($prof.processes) | Where-Object { $_ } | Select-Object -Unique) -Force
            break
        }
    }
}

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

function Format-Count {
    param([int]$Count, [string]$Word, [string]$Plural)
    if (-not $Plural) { $Plural = $Word + 's' }
    if ($Count -eq 1) { return "1 $Word" }
    return "$Count $Plural"
}

function Test-Landed {
    # Every file in the backup copy should now exist at the target with the same size.
    param([string]$Source, [string]$Target, [string]$Type)
    $result = @{ Files = 0; Bad = (New-Object System.Collections.Generic.List[string]) }
    if ($Type -eq 'file') {
        $result.Files = 1
        $dst = New-Object IO.FileInfo $Target
        if (-not $dst.Exists -or $dst.Length -ne (New-Object IO.FileInfo $Source).Length) { $result.Bad.Add((Split-Path -Leaf $Target)) }
        return $result
    }
    $base = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
    $leaf = Split-Path -Leaf $Target
    foreach ($f in [IO.Directory]::EnumerateFiles($base, '*', [IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($base.Length + 1)
        try {
            $dst = New-Object IO.FileInfo ([IO.Path]::Combine($Target, $rel))
            $result.Files++
            if (-not $dst.Exists -or $dst.Length -ne (New-Object IO.FileInfo $f).Length) { $result.Bad.Add("$leaf\$rel") }
        } catch {
            # Paths too long for PowerShell to check; robocopy copies them fine, so don't count them either way.
        }
    }
    return $result
}

$runningServices = @(foreach ($s in @($spec.services)) {
        if (-not $s) { continue }
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { $svc }
    })

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsAdmin = (@($spec.items | Where-Object { $_.target -match '^%(PROGRAMFILES|PROGRAMFILES\(X86\)|PROGRAMDATA|WINDIR|INSTALLDIR)%' }).Count -gt 0) -or
              (@($spec.registry | Where-Object { $_.key -like 'HKLM*' }).Count -gt 0) -or
              ($runningServices.Count -gt 0)
if ($needsAdmin -and -not $isAdmin -and -not $TestRun) {
    # Protected folder or a background service: re-run elevated from a local copy (an admin window may not be signed in to the NAS).
    Write-Host "$($spec.name) needs administrator rights to restore, so Windows will ask."
    $tmp = Join-Path $env:TEMP ('WinPrestige-restore-' + ($spec.id -replace '[^\w.-]', '_'))
    & robocopy.exe $here $tmp /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $tmp 'Restore-Config.ps1') -Force
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp\Restore-Config.ps1`" -Pause"
    Write-Host 'Finished. The result was shown in the administrator window.'
    return
}

Write-Host "Restoring $($spec.name) settings"

$needsInstallDir = @($spec.items | Where-Object { $_.target -like '*%INSTALLDIR%*' }).Count -gt 0
$installDir = $null
if ($needsInstallDir) {
    $installDir = Find-InstallDir
    if (-not $installDir) { throw "Couldn't find where $($spec.name) is installed. Install it first, then run this again." }
}

# Pause background services first so they can't relaunch the app or write over the files mid-copy.
$stopped = @()
foreach ($svc in $runningServices) {
    if ($TestRun) { Write-Host "  would pause background service: $($svc.DisplayName)"; continue }
    try {
        Stop-Service -Name $svc.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue
        $stopped += $svc
        Write-Host "  paused background service: $($svc.DisplayName)"
    } catch {
        Write-Warning "Couldn't pause background service $($svc.DisplayName) ($($_.Exception.Message)). Restoring anyway."
    }
}

$summary = $null
try {
    # Close the app so it can't overwrite the restored files when it exits.
    foreach ($name in @($spec.processes)) {
        if (-not $name) { continue }
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        if ($TestRun) { Write-Host "  would close $name"; continue }
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    $copied = @()
    $notInBackup = @()
    foreach ($item in @($spec.items)) {
        $src = Join-Path $here $item.stored
        $dst = Expand-Target $item.target $installDir
        if (-not (Test-Path -LiteralPath $src)) { Write-Warning "Missing from backup: $($item.stored)"; $notInBackup += (Split-Path -Leaf $item.target); continue }
        if ($TestRun) { Write-Host "  would copy $($item.stored) -> $dst"; continue }
        if ($item.type -eq 'file') {
            $parent = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        } else {
            & robocopy.exe $src $dst /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-Warning "Some files could not be copied to $dst (robocopy code $LASTEXITCODE)." }
        }
        $copied += @{ Source = $src; Target = $dst; Type = $item.type }
    }

    $regs = @($spec.registry | Where-Object { $_ })
    foreach ($reg in $regs) {
        $file = Join-Path $here $reg.stored
        if ($TestRun) { Write-Host "  would import registry key $($reg.key)"; continue }
        # reg.exe prints its success message on stderr, which 'Stop' would turn into an error.
        $ErrorActionPreference = 'Continue'
        $null = & reg.exe import $file 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { Write-Warning "Could not import $($reg.key)." }
    }

    if (-not $TestRun) {
        # Check before paths are rewritten below, since that changes file sizes on purpose.
        try {
            $fileCount = 0
            $bad = New-Object System.Collections.Generic.List[string]
            foreach ($c in $copied) {
                $r = Test-Landed $c.Source $c.Target $c.Type
                $fileCount += $r.Files
                foreach ($b in $r.Bad) { $bad.Add($b) }
            }
            $badRegs = @(foreach ($reg in $regs) {
                    $key = ([string]$reg.key) -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
                    if (-not (Test-Path -LiteralPath ('Registry::' + $key))) { $reg.key }
                })

            $issues = @()
            if ($bad.Count) { $issues += "$($bad.Count) of $(Format-Count $fileCount 'file') didn't land" }
            if ($notInBackup.Count) { $issues += (Format-Count $notInBackup.Count 'item') + ' missing from the backup' }
            if ($badRegs.Count) { $issues += (Format-Count $badRegs.Count 'registry key' 'registry keys') + ' not imported' }
            if ($issues.Count) {
                foreach ($b in ($bad | Select-Object -First 5)) { Write-Host "  didn't land: $b" }
                if ($bad.Count -gt 5) { Write-Host "  ...and $($bad.Count - 5) more" }
                foreach ($k in $badRegs) { Write-Host "  not imported: $k" }
                $first = @($bad.ToArray()) + @($notInBackup) + @($badRegs) | Select-Object -First 1
                $summary = "Check $($spec.name): $($issues -join ', ') (first: $first)."
            } else {
                $parts = @()
                if ($fileCount) { $parts += Format-Count $fileCount 'file' }
                if ($regs.Count) { $parts += Format-Count $regs.Count 'registry key' 'registry keys' }
                if ($parts.Count) { $summary = "Restored $($spec.name): $($parts -join ' and ') checked and in place." }
                else { $summary = "Restored $($spec.name)." }
            }
        } catch {
            $summary = "Restored $($spec.name), but couldn't check the files ($($_.Exception.Message))."
        }
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
} finally {
    foreach ($svc in $stopped) {
        try {
            Start-Service -Name $svc.Name -ErrorAction Stop -WarningAction SilentlyContinue
            Write-Host "  restarted background service: $($svc.DisplayName)"
        } catch {
            Write-Warning "Couldn't restart background service $($svc.DisplayName). Restarting the PC will bring it back."
        }
    }
}

if ($TestRun) { Write-Host "Test run finished for $($spec.name)." }
else { Write-Host $summary }
if ($Pause) { [void](Read-Host 'Press Enter to close') }
