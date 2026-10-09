#Requires -Version 5.1
<#
  WinPrestige core: app inventory, winget lookups and downloads, config backups,
  extras, the HTML report and the restore engine.

  There is no UI code in here, so the window and its background runspaces can
  both dot-source this file. Progress goes out through Send-WPMessage, which
  queues messages for the window (or prints them when run from a console).
#>

$script:WP = @{ Queue = $null; Sync = $null; CurrentProcess = $null }

function Initialize-WP {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Sync
    )
    $script:WP.Root = $Root
    $script:WP.Version = '1.2.1'
    $script:WP.StateDir = Join-Path $env:LOCALAPPDATA 'WinPrestige'
    if (-not (Test-Path -LiteralPath $script:WP.StateDir)) {
        New-Item -ItemType Directory -Path $script:WP.StateDir -Force | Out-Null
    }
    $script:WP.Rules = Read-WPJson (Join-Path $Root 'data\rules.json')
    $script:WP.Profiles = @(Read-WPJson (Join-Path $Root 'data\profiles.json'))
    $script:WP.Winget = Get-WPWingetPath
    if ($Sync) {
        $script:WP.Sync = $Sync
        $script:WP.Queue = $Sync.Queue
    }
}

#region Messaging -------------------------------------------------------------

function Send-WPMessage {
    param([string]$Type, [hashtable]$Data = @{})
    $Data['Type'] = $Type
    if ($script:WP.Queue) { $script:WP.Queue.Enqueue($Data) }
    elseif ($Type -eq 'log') { Write-Host $Data.Text }
}

function Write-WPLog {
    param(
        [string]$Text,
        [ValidateSet('info', 'ok', 'warn', 'error', 'step')][string]$Level = 'info'
    )
    Send-WPMessage 'log' @{ Text = $Text; Level = $Level }
}

function Set-WPProgress {
    param([int]$Value, [int]$Maximum, [string]$Text)
    Send-WPMessage 'progress' @{ Value = $Value; Maximum = $Maximum; Text = $Text }
}

function Test-WPCancel {
    return [bool]($script:WP.Sync -and $script:WP.Sync.Cancel)
}

#endregion

#region Small helpers ---------------------------------------------------------

function Read-WPJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-WPJson {
    param($Object, [string]$Path)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function ConvertTo-WPHashtable {
    # ConvertFrom-Json gives PSCustomObjects in Windows PowerShell; settings code wants hashtables.
    param($Object)
    $h = @{}
    if ($null -eq $Object) { return $h }
    if ($Object -is [hashtable]) { return $Object }
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-WPSafeName {
    param([string]$Name, [int]$Max = 60)
    $n = ($Name -replace '[\\/:*?"<>|]', '_') -replace '\s+', ' '
    $n = $n.Trim().TrimEnd('.')
    if ($n.Length -gt $Max) { $n = $n.Substring(0, $Max).Trim() }
    if (-not $n) { $n = 'App' }
    return $n
}

function Get-WPCleanName {
    # "Mozilla Firefox (x64 en-US)" -> "Mozilla Firefox", "Audacity 3.7.8" -> "Audacity".
    # -Strict keeps " - suffix" text, so a store listing called "Foo - Pro Edition" doesn't pass as "Foo".
    param([string]$Name, [switch]$Strict)
    $n = $Name -replace '[\u00AE\u2122\u00A9]', ''
    $n = $n -replace '\s*\([^)]*\)', ''
    if (-not $Strict) { $n = $n -replace '\s+-\s+[^-]*$', '' }
    $n = $n -replace '\s+(version\s+)?v?\d+(\.\d+)+([.\-+][\w.]+)?\s*$', ''
    $n = $n -replace '\s{2,}', ' '
    return $n.Trim()
}

function Get-WPNormName {
    param([string]$Name, [switch]$Strict)
    return ((Get-WPCleanName $Name -Strict:$Strict).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Format-WPSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Compare-WPVersion {
    param([string]$A, [string]$B)
    $va = $null; $vb = $null
    $ca = ($A -replace '[^\d.]', '' -replace '\.+', '.').Trim('.')
    $cb = ($B -replace '[^\d.]', '' -replace '\.+', '.').Trim('.')
    if ($ca -notmatch '\.') { $ca += '.0' }
    if ($cb -notmatch '\.') { $cb += '.0' }
    if ([version]::TryParse($ca, [ref]$va) -and [version]::TryParse($cb, [ref]$vb)) { return $va.CompareTo($vb) }
    return [string]::Compare($A, $B, $true)
}

function Open-WPUrl {
    # explorer.exe hands the URL to the signed-in user's shell, so the browser
    # doesn't start elevated just because WinPrestige runs as admin.
    param([string]$Url)
    if (-not $Url) { return }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Url`""
}

function Get-WPDownloadsFolder {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Get-WPFolderMap {
    # Order matters only for readability; tokens never contain each other.
    $m = [ordered]@{}
    $m['%LOCALAPPDATA%'] = $env:LOCALAPPDATA
    $m['%APPDATA%'] = $env:APPDATA
    $m['%DOCUMENTS%'] = [Environment]::GetFolderPath('MyDocuments')
    $m['%DESKTOP%'] = [Environment]::GetFolderPath('Desktop')
    $m['%PICTURES%'] = [Environment]::GetFolderPath('MyPictures')
    $m['%VIDEOS%'] = [Environment]::GetFolderPath('MyVideos')
    $m['%MUSIC%'] = [Environment]::GetFolderPath('MyMusic')
    $m['%DOWNLOADS%'] = Get-WPDownloadsFolder
    $m['%USERPROFILE%'] = $env:USERPROFILE
    $m['%PROGRAMDATA%'] = $env:ProgramData
    $m['%PROGRAMFILES(X86)%'] = ${env:ProgramFiles(x86)}
    $m['%PROGRAMFILES%'] = $env:ProgramFiles
    $m['%WINDIR%'] = $env:windir
    return $m
}

function Expand-WPPath {
    param([string]$Path, [string]$InstallDir)
    $p = $Path
    if ($InstallDir) { $p = $p.Replace('%INSTALLDIR%', $InstallDir.TrimEnd('\')) }
    $map = Get-WPFolderMap
    foreach ($k in $map.Keys) { if ($map[$k]) { $p = $p.Replace($k, $map[$k].TrimEnd('\')) } }
    return $p
}

function ConvertTo-WPTokenPath {
    # C:\Users\me\AppData\Roaming\obs-studio -> %APPDATA%\obs-studio, so restores land in the
    # right place even if the user name or Documents location changes.
    param([string]$Path)
    $map = Get-WPFolderMap
    $best = $null; $bestLen = 0
    foreach ($k in $map.Keys) {
        $v = [string]$map[$k]
        if (-not $v) { continue }
        $v = $v.TrimEnd('\')
        if (($Path -eq $v -or $Path.StartsWith($v + '\', [StringComparison]::OrdinalIgnoreCase)) -and $v.Length -gt $bestLen) {
            $best = $k; $bestLen = $v.Length
        }
    }
    if ($best) { return $best + $Path.Substring($bestLen) }
    return $Path
}

function ConvertTo-WPStoredName {
    # %APPDATA%\obs-studio -> APPDATA\obs-studio ; D:\Games\x -> D\Games\x
    param([string]$TokenPath)
    $s = $TokenPath -replace '%', '' -replace '^([A-Za-z]):', '$1' -replace '^\\\\', 'UNC\'
    $s = ($s -split '\\' | Where-Object { $_ } | ForEach-Object { $_ -replace '[:*?"<>|]', '_' }) -join '\'
    return $s
}

function Get-WPUniqueName {
    param([string]$Base, [hashtable]$Used)
    $name = $Base; $i = 2
    while ($Used.ContainsKey($name.ToLowerInvariant())) { $name = "$Base ($i)"; $i++ }
    $Used[$name.ToLowerInvariant()] = $true
    return $name
}

function Get-WPCategoryInfo {
    param([string]$Id)
    foreach ($c in $script:WP.Rules.categories) { if ($c.id -eq $Id) { return $c } }
    return [pscustomobject]@{ id = $Id; title = $Id; selected = $false; hidden = $false; hint = '' }
}

#endregion

#region winget ----------------------------------------------------------------

function Get-WPWingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    # Elevated sessions on a fresh install sometimes lack the alias; use the package folder directly.
    $pkg = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

function ConvertTo-WPArgument {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $v = $Value -replace '(\\*)"', '$1$1\"'
    $v = $v -replace '(\\+)$', '$1$1'
    return '"' + $v + '"'
}

function Invoke-WPWinget {
    param([string[]]$Arguments, [int]$TimeoutSec = 1800)
    if (-not $script:WP.Winget) {
        return [pscustomobject]@{ ExitCode = -1; Lines = @('winget is not available on this PC.') }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:WP.Winget
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-WPArgument $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    try { $p = [Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ ExitCode = -1; Lines = @("Could not start winget: $($_.Exception.Message)") } }
    $script:WP.CurrentProcess = $p
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false
    while (-not $p.WaitForExit(400)) {
        if ((Test-WPCancel) -or (Get-Date) -gt $deadline) {
            $timedOut = -not (Test-WPCancel)
            try { $p.Kill() } catch { }
            break
        }
    }
    $p.WaitForExit()
    $script:WP.CurrentProcess = $null
    $text = $outTask.Result + "`n" + $errTask.Result
    # winget redraws spinners and progress bars with carriage returns; keep the final text of each line.
    $lines = @($text -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] })
    $code = $p.ExitCode
    if ($timedOut) { $lines += 'Timed out.'; $code = -2 }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Get-WPColumnStart {
    param([string]$Line, [int]$Pos)
    if ($Pos -le 0) { return 0 }
    if ($Pos -ge $Line.Length) { return $Line.Length }
    if ($Line[$Pos - 1] -eq ' ' -and $Line[$Pos] -ne ' ') { return $Pos }
    # A wide or narrow glyph earlier in the row can shift columns by a character or two.
    for ($d = 1; $d -le 3; $d++) {
        foreach ($q in @(($Pos + $d), ($Pos - $d))) {
            if ($q -gt 0 -and $q -lt $Line.Length -and $Line[$q - 1] -eq ' ' -and $Line[$q] -ne ' ') { return $q }
        }
    }
    return $Pos
}

function ConvertFrom-WPWingetTable {
    # Parses winget's fixed-width tables. The first three columns are always Name, Id, Version;
    # later ones keep their header text (Available, Match, Source).
    param([string[]]$Lines)
    $sep = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^-{10,}\s*$') { $sep = $i; break }
    }
    if ($sep -lt 1) { return }
    $header = $Lines[$sep - 1]
    $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { [pscustomobject]@{ Name = $_.Value; Start = $_.Index } })
    if ($cols.Count -lt 3) { return }
    $names = @('Name', 'Id', 'Version')
    for ($c = 3; $c -lt $cols.Count; $c++) { $names += $cols[$c].Name }
    for ($i = $sep + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $line.Trim()) { break }
        if ($line -match '^<.*>$' -or $line.Length -lt $cols[1].Start) { continue }
        $obj = [ordered]@{}
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $s = Get-WPColumnStart $line $cols[$c].Start
            if ($c -lt $cols.Count - 1) { $e = Get-WPColumnStart $line $cols[$c + 1].Start } else { $e = $line.Length }
            $val = ''
            if ($s -lt $line.Length -and $e -gt $s) { $val = $line.Substring($s, [Math]::Min($e, $line.Length) - $s).Trim() }
            $obj[$names[$c]] = $val
        }
        [pscustomobject]$obj
    }
}

function Get-WPWingetError {
    param($Result)
    switch ($Result.ExitCode) {
        -1978335215 { return 'Installer hash mismatch: the vendor changed the file since winget last checked. Restore will install it online instead.' }
        -1978335212 { return 'winget could not find the package anymore.' }
        -1978335139 { return 'The publisher does not allow downloading this installer. Restore will install it online instead.' }
        -2 { return 'Timed out.' }
    }
    $msg = @($Result.Lines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[\u2588\u2592]' }) | Select-Object -Last 2
    $txt = ($msg -join ' ').Trim()
    if (-not $txt) { $txt = "winget exit code $($Result.ExitCode)" }
    return $txt
}

function Get-WPYamlValue {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { return $v.Substring(1, $v.Length - 2).Replace("''", "'") }
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { return $v.Substring(1, $v.Length - 2).Replace('\"', '"').Replace('\\', '\') }
    return $v
}

function Read-WPWingetManifest {
    # Pulls the few fields restore needs out of the merged manifest winget saves next to a
    # downloaded installer. Installer-level values come later in the file and win.
    param([string]$Path)
    $info = @{
        Version = ''; Name = ''; Publisher = ''; PackageUrl = ''; InstallerType = ''; NestedType = ''
        InstallerUrl = ''; Sha256 = ''; Scope = ''; Silent = ''; SilentWithProgress = ''; Custom = ''
        Dependencies = @(); Codes = @{}
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $info }
    $inSwitches = $false; $switchIndent = 0; $lastCode = $null
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^PackageVersion:\s*(.+)$') { $info.Version = Get-WPYamlValue $Matches[1]; continue }
        if ($line -match '^PackageName:\s*(.+)$') { $info.Name = Get-WPYamlValue $Matches[1]; continue }
        if ($line -match '^Publisher:\s*(.+)$') { $info.Publisher = Get-WPYamlValue $Matches[1]; continue }
        if ($line -match '^PackageUrl:\s*(.+)$') { $info.PackageUrl = Get-WPYamlValue $Matches[1]; continue }

        $indent = 0
        if ($line -match '^(\s*)(-\s+)?') { $indent = $Matches[1].Length + $(if ($Matches[2]) { 2 } else { 0 }) }

        if ($inSwitches) {
            if ($line -match '^(\s*)(\w+):\s*(.*)$' -and $Matches[1].Length -gt $switchIndent) {
                $val = Get-WPYamlValue $Matches[3]
                switch ($Matches[2]) {
                    'Silent' { $info.Silent = $val }
                    'SilentWithProgress' { $info.SilentWithProgress = $val }
                    'Custom' { $info.Custom = $val }
                }
                continue
            }
            $inSwitches = $false
        }
        if ($indent -le 2 -and $line -match '^(\s*)(-\s+)?InstallerSwitches:\s*$') {
            $inSwitches = $true; $switchIndent = $Matches[1].Length + $(if ($Matches[2]) { 2 } else { 0 }); continue
        }
        if ($indent -le 2 -and $line -match '^\s*(-\s+)?InstallerType:\s*(.+)$') { $info.InstallerType = (Get-WPYamlValue $Matches[2]).ToLowerInvariant(); continue }
        if ($indent -le 2 -and $line -match '^\s*(-\s+)?NestedInstallerType:\s*(.+)$') { $info.NestedType = (Get-WPYamlValue $Matches[2]).ToLowerInvariant(); continue }
        if ($indent -le 2 -and $line -match '^\s*(-\s+)?InstallerUrl:\s*(.+)$') { $info.InstallerUrl = Get-WPYamlValue $Matches[2]; continue }
        if ($indent -le 2 -and $line -match '^\s*(-\s+)?InstallerSha256:\s*(.+)$') { $info.Sha256 = Get-WPYamlValue $Matches[2]; continue }
        if ($indent -le 2 -and $line -match '^\s*(-\s+)?Scope:\s*(.+)$') { $info.Scope = Get-WPYamlValue $Matches[2]; continue }
        if ($line -match '^\s*-\s+PackageIdentifier:\s*(.+)$') { $info.Dependencies += (Get-WPYamlValue $Matches[1]); continue }
        if ($line -match '^\s*(-\s+)?InstallerReturnCode:\s*(-?\d+)') { $lastCode = $Matches[2]; continue }
        if ($line -match '^\s*ReturnResponse:\s*(\S+)' -and $null -ne $lastCode) { $info.Codes[$lastCode] = $Matches[1]; $lastCode = $null; continue }
    }
    return $info
}

#endregion

#region Inventory -------------------------------------------------------------

function New-WPApp {
    return [pscustomobject]@{
        Key = ''; Name = ''; Version = ''; Latest = ''; Publisher = ''
        WingetId = ''; Source = ''; Kind = ''; ArpId = ''; Pfn = ''; RegKey = ''
        InstallLocation = ''; UninstallString = ''; Url = ''
        Category = ''; Via = ''; GameUri = ''; LauncherGame = $false
        Selected = $false; Match = ''; Candidates = @(); CustomUrl = ''
        Status = ''; Detail = ''
    }
}

function Get-WPRegistryApps {
    $roots = @(
        @{ Hive = 'Machine'; Arch = 'X64'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'Machine'; Arch = 'X86'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'User'; Arch = 'X64'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
        @{ Hive = 'User'; Arch = 'X86'; Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    foreach ($root in $roots) {
        foreach ($k in (Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            $url = @($p.URLInfoAbout, $p.URLUpdateInfo, $p.HelpLink) | Where-Object { $_ -and $_ -match '^https?://' } | Select-Object -First 1
            [pscustomobject]@{
                ArpId = "ARP\$($root.Hive)\$($root.Arch)\$($k.PSChildName)"
                Key = $k.PSChildName
                Name = ([string]$p.DisplayName).Trim()
                Version = [string]$p.DisplayVersion
                Publisher = [string]$p.Publisher
                InstallLocation = ([string]$p.InstallLocation).Trim('"')
                UninstallString = [string]$p.UninstallString
                Url = [string]$url
                SystemComponent = $p.SystemComponent
                ParentKeyName = $p.ParentKeyName
                ReleaseType = [string]$p.ReleaseType
            }
        }
    }
}

function ConvertTo-WPPfn {
    # Name_Version_Arch_ResourceId_PublisherId -> Name_PublisherId
    param([string]$FullName)
    $parts = $FullName -split '_'
    if ($parts.Count -ge 5) { return "$($parts[0])_$($parts[-1])" }
    return $FullName
}

function Set-WPCategory {
    param($App)
    $idField = $App.WingetId
    if (-not $idField) { $idField = $App.ArpId }
    $fields = @{
        name = $App.Name; id = $idField; key = $App.RegKey; publisher = $App.Publisher
        uninstall = $App.UninstallString; location = $App.InstallLocation
    }
    $App.Category = ''; $App.Via = ''; $App.GameUri = ''; $App.LauncherGame = $false
    foreach ($rule in $script:WP.Rules.rules) {
        $v = [string]$fields[$rule.field]
        if (-not $v) { continue }
        $m = [regex]::Match($v, $rule.match, 'IgnoreCase')
        if (-not $m.Success) { continue }
        $App.Category = $rule.category
        if ($rule.via) { $App.Via = $rule.via }
        if ($rule.launcherGame) { $App.LauncherGame = $true }
        if ($rule.gameUri -and $m.Groups.Count -gt 1) { $App.GameUri = $rule.gameUri.Replace('{1}', $m.Groups[1].Value) }
        break
    }
    if (-not $App.Category) {
        if ($App.Kind -eq 'msix' -or $App.Source -eq 'msstore') { $App.Category = 'store' } else { $App.Category = 'apps' }
    }
}

function Set-WPDefaultSelection {
    param($App, [hashtable]$Saved)
    if ($Saved -and $Saved.ContainsKey($App.Key)) { $App.Selected = [bool]$Saved[$App.Key]; return }
    $App.Selected = [bool](Get-WPCategoryInfo $App.Category).selected
    if ($App.Category -eq 'runtimes' -and $script:WP.Rules.essentialRuntimes -contains $App.WingetId) { $App.Selected = $true }
}

function Get-WPInventory {
    Write-WPLog 'Reading installed programs from the registry...' 'step'
    $reg = @(Get-WPRegistryApps)
    $regById = @{}; $regByName = @{}
    foreach ($r in $reg) {
        $regById[$r.ArpId.ToLowerInvariant()] = $r
        $n = $r.Name.ToLowerInvariant()
        if (-not $regByName.ContainsKey($n)) { $regByName[$n] = $r }
    }
    $appx = @{}
    try { foreach ($p in (Get-AppxPackage -ErrorAction Stop)) { $appx[$p.PackageFullName.ToLowerInvariant()] = $p } } catch { }

    $apps = [ordered]@{}
    $rows = @()
    if ($script:WP.Winget) {
        Write-WPLog 'Asking winget which programs it recognises...' 'step'
        $res = Invoke-WPWinget @('list', '--accept-source-agreements', '--disable-interactivity')
        $rows = @(ConvertFrom-WPWingetTable $res.Lines)
        if ($rows.Count -eq 0) { Write-WPLog 'winget did not return a list, so only the registry is used this time.' 'warn' }
    } else {
        Write-WPLog 'winget is not installed, so apps are read from the registry only.' 'warn'
    }

    if ($rows.Count -gt 0) {
        foreach ($row in $rows) {
            $id = $row.Id
            if (-not $id) { continue }
            $app = New-WPApp
            $app.Name = $row.Name -replace '^Uninstall\s+', ''
            $app.Version = $row.Version
            $app.Latest = $row.Version
            if ($row.PSObject.Properties['Available'] -and $row.Available) { $app.Latest = $row.Available }
            $r = $null
            if ($id -like 'ARP\*') {
                $app.Kind = 'arp'; $app.ArpId = $id
                $app.Key = 'arp:' + (Get-WPNormName $row.Name)
                $r = $regById[$id.ToLowerInvariant()]
            } elseif ($id -like 'MSIX\*') {
                $full = $id.Substring(5)
                $pkg = $appx[$full.ToLowerInvariant()]
                $app.Kind = 'msix'; $app.ArpId = $id
                if ($pkg) {
                    $app.Pfn = $pkg.PackageFamilyName; $app.InstallLocation = $pkg.InstallLocation
                    if ($pkg.Publisher -match 'O=("[^"]+"|[^,]+)' -or $pkg.Publisher -match 'CN=("[^"]+"|[^,]+)') { $app.Publisher = $Matches[1].Trim('"') }
                } else { $app.Pfn = ConvertTo-WPPfn $full }
                $app.Key = 'msix:' + $app.Pfn.ToLowerInvariant()
            } else {
                $app.Kind = 'winget'; $app.WingetId = $id; $app.Key = $id
                if ($row.PSObject.Properties['Source']) { $app.Source = $row.Source }
                if (-not $app.Source) { $app.Source = 'winget' }
                $app.Match = 'installed'
                $r = $regByName[$row.Name.ToLowerInvariant()]
            }
            if ($r) {
                $app.Publisher = $r.Publisher; $app.InstallLocation = $r.InstallLocation
                $app.UninstallString = $r.UninstallString; $app.Url = $r.Url; $app.RegKey = $r.Key
                if (-not $app.ArpId) { $app.ArpId = $r.ArpId }
            }
            $k = $app.Key.ToLowerInvariant()
            if ($apps.Contains($k)) {
                if ((Compare-WPVersion $app.Version $apps[$k].Version) -gt 0) { $apps[$k] = $app }
                continue
            }
            $apps[$k] = $app
        }
    } else {
        foreach ($r in $reg) {
            if ($r.SystemComponent -eq 1 -or $r.ParentKeyName -or $r.ReleaseType -match 'Update|Hotfix' -or $r.Name -match '\(KB\d{6,}\)') { continue }
            $app = New-WPApp
            $app.Name = $r.Name; $app.Version = $r.Version; $app.Latest = $r.Version; $app.Kind = 'arp'
            $app.ArpId = $r.ArpId; $app.Key = 'arp:' + (Get-WPNormName $r.Name)
            $app.Publisher = $r.Publisher; $app.InstallLocation = $r.InstallLocation
            $app.UninstallString = $r.UninstallString; $app.Url = $r.Url; $app.RegKey = $r.Key
            $k = $app.Key.ToLowerInvariant()
            if (-not $apps.Contains($k)) { $apps[$k] = $app }
        }
        foreach ($p in $appx.Values) {
            if ($p.IsFramework -or $p.IsResourcePackage -or $p.NonRemovable -or $p.SignatureKind -eq 'System') { continue }
            $app = New-WPApp
            $app.Name = $p.Name; $app.Version = [string]$p.Version; $app.Kind = 'msix'
            $app.ArpId = 'MSIX\' + $p.PackageFullName; $app.Pfn = $p.PackageFamilyName
            $app.InstallLocation = $p.InstallLocation; $app.Key = 'msix:' + $p.PackageFamilyName.ToLowerInvariant()
            $k = $app.Key.ToLowerInvariant()
            if (-not $apps.Contains($k)) { $apps[$k] = $app }
        }
    }

    $list = @($apps.Values)
    foreach ($a in $list) {
        Set-WPCategory $a
        if (-not $a.Url) {
            foreach ($kl in $script:WP.Rules.knownLinks) { if ($a.Name -match $kl.match) { $a.Url = $kl.url; break } }
        }
    }
    Write-WPLog ("Found {0} installed items." -f $list.Count) 'ok'
    return $list
}

#endregion

#region Download links --------------------------------------------------------

function Get-WPLinkCache {
    $h = @{}
    $data = Read-WPJson (Join-Path $script:WP.StateDir 'links.json')
    if ($data) { foreach ($p in $data.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Save-WPLinkCache {
    param([hashtable]$Cache)
    Write-WPJson $Cache (Join-Path $script:WP.StateDir 'links.json')
}

function Get-WPPublisherTokens {
    param([string]$Publisher)
    $stop = @('inc', 'llc', 'ltd', 'limited', 'corporation', 'corp', 'company', 'software', 'technologies', 'technology',
        'games', 'game', 'studio', 'studios', 'gmbh', 'the', 'and', 'group', 'srl', 'pty', 'sucursal', 'espana', 'labs', 'team', 'co')
    return @(($Publisher.ToLowerInvariant() -split '[^a-z0-9]+') | Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ })
}

function Test-WPPublisherMatch {
    # A name match alone can pick the wrong package ("FFmpeg" vs "FFmpeg for Audacity"),
    # so when the registry knows the publisher, check winget agrees.
    param($App, [string]$Id, [string]$Source, [switch]$Strict)
    # The Store is full of look-alike listings, so Store matches must have a publisher to compare.
    if (-not $App.Publisher) { return (-not $Strict) }
    $res = Invoke-WPWinget @('show', '--id', $Id, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 60
    $pubLine = $res.Lines | Where-Object { $_ -match '^\s*Publisher:\s*(.+)$' } | Select-Object -First 1
    if (-not $pubLine) { return (-not $Strict) }
    $wingetPub = ($pubLine -replace '^\s*Publisher:\s*', '')
    $a = Get-WPPublisherTokens $App.Publisher
    $b = Get-WPPublisherTokens $wingetPub
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $true }
    foreach ($t in $a) { if ($b -contains $t) { return $true } }
    return $false
}

function Select-WPBestCandidate {
    param([object[]]$Candidates)
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    $region = $null
    try { $region = [Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName } catch { }
    $suffix = $null
    if ($region -and $script:WP.Rules.regionSuffix.PSObject.Properties[$region]) { $suffix = $script:WP.Rules.regionSuffix.$region }
    if ($suffix) {
        $hit = $Candidates | Where-Object { $_.Id -match ('\.' + [regex]::Escape($suffix) + '$') } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return ($Candidates | Sort-Object { $_.Id.Length } | Select-Object -First 1)
}

function Find-WPWingetMatch {
    param($App)
    $result = @{ Id = ''; Source = ''; Match = 'manual'; Candidates = @() }
    foreach ($o in $script:WP.Rules.wingetOverrides) {
        if ($App.Name -match $o.match) {
            $result.Id = $o.id
            $result.Source = if ($o.source) { $o.source } else { 'winget' }
            $result.Match = 'override'
            return $result
        }
    }
    $query = Get-WPCleanName $App.Name
    if (-not $query -or $query.Length -lt 2) { return $result }
    $target = Get-WPNormName $App.Name
    $sources = if ($App.Kind -eq 'msix') { @('msstore', 'winget') } else { @('winget', 'msstore') }
    $all = @()
    foreach ($src in $sources) {
        if (Test-WPCancel) { break }
        $searchArgs = @('search')
        if ($src -eq 'winget') { $searchArgs += @('--name', $query) } else { $searchArgs += @('--query', $query) }
        $searchArgs += @('--source', $src, '--count', '12', '--accept-source-agreements', '--disable-interactivity')
        $res = Invoke-WPWinget $searchArgs -TimeoutSec 90
        $cands = @(ConvertFrom-WPWingetTable $res.Lines | Where-Object { $_.Id } | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Source = $src; Norm = (Get-WPNormName $_.Name -Strict) }
            })
        $all += $cands
        $exact = @($cands | Where-Object { $_.Norm -eq $target })
        if ($exact.Count -gt 0) {
            $pick = Select-WPBestCandidate $exact
            if (Test-WPPublisherMatch $App $pick.Id $src -Strict:($src -eq 'msstore')) {
                $result.Id = $pick.Id; $result.Source = $src; $result.Match = 'search'
                return $result
            }
        }
    }
    $result.Candidates = @($all | Select-Object -First 6 | ForEach-Object { @{ Name = $_.Name; Id = $_.Id; Source = $_.Source } })
    return $result
}

function Set-WPLinkResult {
    param($App, $Result)
    if ($Result.Id) {
        $App.WingetId = [string]$Result.Id
        $App.Source = [string]$Result.Source
        $App.Match = [string]$Result.Match
        $App.Candidates = @()
    } else {
        $App.Match = 'manual'
        $App.Candidates = @($Result.Candidates)
    }
}

function Test-WPNeedsLink {
    param($App)
    if ($App.Kind -eq 'winget') { return $false }
    if ($App.Selected) { return $true }
    if (@('games', 'system', 'bundled') -contains $App.Category) { return $false }
    return [bool](Get-WPCategoryInfo $App.Category).selected
}

function Resolve-WPLinks {
    # Looks up winget / Store packages for apps winget didn't recognise on its own.
    param([object[]]$Apps, [hashtable]$Chosen, [switch]$Force)
    $cache = Get-WPLinkCache
    $todo = @($Apps | Where-Object { Test-WPNeedsLink $_ })
    if ($todo.Count -eq 0) { return }
    Write-WPLog ("Looking up download sources for {0} apps winget didn't recognise..." -f $todo.Count) 'step'
    $i = 0; $found = 0
    foreach ($app in $todo) {
        if (Test-WPCancel) { Write-WPLog 'Lookup cancelled.' 'warn'; break }
        $i++
        Set-WPProgress $i $todo.Count ("Looking up {0}" -f $app.Name)
        if ($Chosen -and $Chosen.ContainsKey($app.Key)) {
            $c = $Chosen[$app.Key]
            if ($c.Id) { Set-WPLinkResult $app @{ Id = $c.Id; Source = $c.Source; Match = 'chosen' } }
            else { $app.Match = 'manual' }
            $found += [int][bool]$app.WingetId
            Send-WPMessage 'app' @{ Key = $app.Key }
            continue
        }
        $ck = $app.Key.ToLowerInvariant()
        $hit = $cache[$ck]
        $fresh = $false
        if ($hit -and $hit.When) {
            try { $fresh = ((Get-Date) - [datetime]::Parse($hit.When)).TotalDays -lt 14 } catch { $fresh = $false }
        }
        if ($hit -and $fresh -and -not $Force) {
            Set-WPLinkResult $app @{ Id = $hit.Id; Source = $hit.Source; Match = $hit.Match; Candidates = @($hit.Candidates) }
        } else {
            $app.Match = 'searching'
            Send-WPMessage 'app' @{ Key = $app.Key }
            $r = Find-WPWingetMatch $app
            $r.When = (Get-Date).ToString('o')
            $cache[$ck] = $r
            Set-WPLinkResult $app $r
        }
        if ($app.WingetId) { $found++ }
        Send-WPMessage 'app' @{ Key = $app.Key }
    }
    Save-WPLinkCache $cache
    Write-WPLog ("Found packages for {0} of {1}. The rest are marked manual; pick a match or paste a download link in the details panel." -f $found, $todo.Count) 'ok'
}

#endregion

#region Measuring -------------------------------------------------------------

function Test-WPExcluded {
    param($Entry, [string]$Root, [string[]]$Exclude)
    foreach ($x in $Exclude) {
        if ($x.Contains('\')) {
            $rel = $Entry.FullName.Substring([Math]::Min($Root.TrimEnd('\').Length, $Entry.FullName.Length)).TrimStart('\')
            if ($rel -like $x) { return $true }
        } elseif ($Entry.Name -like $x) { return $true }
    }
    return $false
}

function Measure-WPPath {
    # Excluded folders are pruned rather than walked, so skipping a 20 GB cache costs nothing.
    param([string]$Path, [string[]]$Include, [string[]]$Exclude)
    $bytes = [long]0; $files = 0
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $f = Get-Item -LiteralPath $Path -Force
        return @{ Bytes = [long]$f.Length; Files = 1 }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @{ Bytes = [long]0; Files = 0 } }
    $stack = New-Object System.Collections.Stack
    if ($Include) {
        foreach ($inc in $Include) {
            $full = Join-Path $Path $inc
            if (Test-Path -LiteralPath $full -PathType Leaf) { $bytes += (Get-Item -LiteralPath $full -Force).Length; $files++ }
            elseif (Test-Path -LiteralPath $full -PathType Container) { $stack.Push((New-Object IO.DirectoryInfo $full)) }
        }
    } else {
        $stack.Push((New-Object IO.DirectoryInfo $Path))
    }
    while ($stack.Count -gt 0) {
        if (Test-WPCancel) { break }
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($Exclude -and (Test-WPExcluded $e $Path $Exclude)) { continue }
            if ($e -is [IO.DirectoryInfo]) {
                if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($e) }
            } else {
                $bytes += $e.Length; $files++
            }
        }
    }
    return @{ Bytes = $bytes; Files = $files }
}

#endregion

#region Config detection ------------------------------------------------------

function Find-WPInstallDir {
    param($Apps, [string]$AppPattern, $Fallback)
    if ($AppPattern -and $Apps) {
        foreach ($a in $Apps) {
            if ($a.Name -match $AppPattern -and $a.InstallLocation -and (Test-Path -LiteralPath $a.InstallLocation)) { return $a.InstallLocation.TrimEnd('\') }
        }
    }
    foreach ($f in @($Fallback)) {
        if (-not $f) { continue }
        $p = Expand-WPPath $f
        if (Test-Path -LiteralPath $p) { return $p.TrimEnd('\') }
    }
    return $null
}

function Resolve-WPProfileItems {
    param($Prof, [string]$InstallDir)
    $out = @()
    foreach ($item in @($Prof.items)) {
        if (-not $item.path) { continue }
        if ($item.path -like '*%INSTALLDIR%*' -and -not $InstallDir) { continue }
        $expanded = Expand-WPPath $item.path $InstallDir
        $paths = @()
        if ($expanded.Contains('*')) {
            $paths = @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        } elseif (Test-Path -LiteralPath $expanded) {
            $paths = @($expanded)
        }
        foreach ($p in $paths) {
            $isFile = Test-Path -LiteralPath $p -PathType Leaf
            if (-not $isFile -and $item.include) {
                $any = @($item.include | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $p $_)) }).Count
                if ($any -eq 0) { continue }
            }
            if ($item.path -like '*%INSTALLDIR%*') {
                $target = '%INSTALLDIR%' + $p.Substring($InstallDir.TrimEnd('\').Length)
            } else {
                $target = ConvertTo-WPTokenPath $p
            }
            $out += [pscustomobject]@{
                Source = $p
                Target = $target
                Type = $(if ($isFile) { 'file' } else { 'dir' })
                Include = @($item.include | Where-Object { $_ })
                Exclude = @($item.exclude | Where-Object { $_ })
            }
        }
    }
    return $out
}

function Test-WPRegistryKey {
    param([string]$Key)
    $k = $Key -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
    return (Test-Path -LiteralPath ("Registry::" + $k))
}

function New-WPConfig {
    param([string]$Id, [string]$Name)
    return [pscustomobject]@{
        Id = $Id; Name = $Name; App = ''; Items = @(); Registry = @(); Processes = @(); Services = @()
        InstallDir = ''; InstallDirFallback = @(); Rewrite = @(); Notes = ''
        Sensitive = $false; Custom = $false; Selected = $false
        Bytes = [long]-1; Files = 0; Running = @(); Status = ''; Detail = ''
    }
}

function Get-WPConfigCandidates {
    param($Apps, [object[]]$CustomConfigs)
    Write-WPLog 'Looking for app settings to back up...' 'step'
    $list = @()
    foreach ($prof in $script:WP.Profiles) {
        $installDir = $null
        if (@($prof.items | Where-Object { $_.path -like '*%INSTALLDIR%*' }).Count -gt 0) {
            $installDir = Find-WPInstallDir $Apps $prof.app $prof.installDirFallback
        }
        $items = @(Resolve-WPProfileItems $prof $installDir)
        $regs = @($prof.registry | Where-Object { $_ -and (Test-WPRegistryKey $_) })
        if ($items.Count -eq 0 -and $regs.Count -eq 0) { continue }
        $c = New-WPConfig $prof.id $prof.name
        $c.App = [string]$prof.app
        $c.Items = $items
        $c.Registry = $regs
        $c.Processes = @($prof.processes | Where-Object { $_ })
        $c.Services = @($prof.services | Where-Object { $_ })
        $c.InstallDir = [string]$installDir
        $c.InstallDirFallback = @($prof.installDirFallback | Where-Object { $_ })
        $c.Rewrite = @($prof.rewrite | Where-Object { $_ })
        $c.Notes = [string]$prof.notes
        $c.Sensitive = [bool]$prof.sensitive
        $list += $c
        if ($prof.special -eq 'obsMedia') {
            $media = Get-WPObsMediaConfig
            if ($media) { $list += $media }
        }
    }
    foreach ($cc in @($CustomConfigs)) {
        if (-not $cc -or -not $cc.Path) { continue }
        $c = New-WPCustomConfig $cc.Name $cc.Path
        if ($c) { $list += $c }
    }
    Write-WPLog ("Found settings for {0} apps." -f $list.Count) 'ok'
    return $list
}

function New-WPCustomConfig {
    # A file or folder you added yourself on the App settings tab.
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $c = New-WPConfig ('custom:' + $Path.ToLowerInvariant()) $Name
    $isFile = Test-Path -LiteralPath $Path -PathType Leaf
    $c.Items = @([pscustomobject]@{ Source = $Path; Target = (ConvertTo-WPTokenPath $Path); Type = $(if ($isFile) { 'file' } else { 'dir' }); Include = @(); Exclude = @() })
    $c.Custom = $true
    $c.Notes = 'Added by you. Restored to the same place.'
    return $c
}

function Get-WPObsMediaConfig {
    # Scene collections point at images, videos and sounds by absolute path. Anything on this
    # PC outside OBS's own folder would be lost in the reset, so back those files up too.
    $scenes = Join-Path $env:APPDATA 'obs-studio\basic\scenes'
    if (-not (Test-Path -LiteralPath $scenes)) { return $null }
    $found = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $scenes -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($text, '"((?:[A-Za-z]:)(?:[\\/]|\\\\)[^"]+)"')) {
            $p = $m.Groups[1].Value.Replace('\\', '\').Replace('/', '\')
            if ($found.ContainsKey($p.ToLowerInvariant())) { continue }
            $found[$p.ToLowerInvariant()] = $p
        }
    }
    $skip = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:windir, (Join-Path $env:APPDATA 'obs-studio')) | Where-Object { $_ }
    $items = @()
    foreach ($p in $found.Values) {
        $inSkip = $false
        foreach ($s in $skip) { if ($p.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { $inSkip = $true; break } }
        if ($inSkip) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try { $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($p)); if ($drive.DriveType -ne 'Fixed') { continue } } catch { continue }
        $isFile = Test-Path -LiteralPath $p -PathType Leaf
        $items += [pscustomobject]@{ Source = $p; Target = (ConvertTo-WPTokenPath $p); Type = $(if ($isFile) { 'file' } else { 'dir' }); Include = @(); Exclude = @() }
    }
    if ($items.Count -eq 0) { return $null }
    $c = New-WPConfig 'obs-media' 'OBS Studio - media used in scenes'
    $c.App = '^OBS Studio'
    $c.Items = $items
    $c.Notes = "Images, videos and sounds your scenes use, put back at the same paths ($($items.Count) files or folders)."
    return $c
}

function Update-WPConfigSize {
    param($Config)
    $bytes = [long]0; $files = 0
    foreach ($it in $Config.Items) {
        $m = Measure-WPPath $it.Source $it.Include $it.Exclude
        $bytes += $m.Bytes; $files += $m.Files
    }
    $Config.Bytes = $bytes
    $Config.Files = $files
}

function Get-WPRunningProcesses {
    param($Config)
    $running = @()
    foreach ($p in @($Config.Processes)) {
        if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $running += $p }
    }
    return $running
}

#endregion

#region Extras ----------------------------------------------------------------

function New-WPExtra {
    param([string]$Id, [string]$Name, [string]$Description)
    return [pscustomobject]@{
        Id = $Id; Name = $Name; Description = $Description; Available = $true; Selected = $false
        Sensitive = $false; Bytes = [long]-1; Info = ''; Data = $null; Status = ''; Detail = ''
    }
}

function Get-WPCustomFonts {
    # Fonts Windows ships are owned by TrustedInstaller; anything else in the Fonts folder
    # was added by you or by an app.
    $names = @{}
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $file = [IO.Path]::GetFileName([string]$p.Value).ToLowerInvariant()
            if ($file -and -not $names.ContainsKey($file)) { $names[$file] = $p.Name }
        }
    }
    $fonts = @()
    $win = Join-Path $env:windir 'Fonts'
    foreach ($f in (Get-ChildItem -LiteralPath $win -File -ErrorAction SilentlyContinue)) {
        if ($f.Extension -notmatch '^\.(ttf|otf|ttc|fon|fnt)$') { continue }
        $owner = ''
        try { $owner = (Get-Acl -LiteralPath $f.FullName).Owner } catch { }
        if ($owner -match 'TrustedInstaller') { continue }
        $fonts += [pscustomobject]@{ Path = $f.FullName; File = $f.Name; Name = [string]$names[$f.Name.ToLowerInvariant()]; Bytes = $f.Length }
    }
    $userDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    foreach ($f in (Get-ChildItem -LiteralPath $userDir -File -ErrorAction SilentlyContinue)) {
        $fonts += [pscustomobject]@{ Path = $f.FullName; File = $f.Name; Name = [string]$names[$f.Name.ToLowerInvariant()]; Bytes = $f.Length }
    }
    return $fonts
}

function Get-WPWifiProfiles {
    $out = netsh.exe wlan show profiles 2>$null
    return @($out | ForEach-Object { if ($_ -match 'Profile\s*:\s*(.+?)\s*$') { $Matches[1] } } | Where-Object { $_ })
}

function Get-WPUserFolders {
    $folders = @(
        @{ Id = 'Desktop'; Path = [Environment]::GetFolderPath('Desktop') },
        @{ Id = 'Documents'; Path = [Environment]::GetFolderPath('MyDocuments') },
        @{ Id = 'Pictures'; Path = [Environment]::GetFolderPath('MyPictures') },
        @{ Id = 'Videos'; Path = [Environment]::GetFolderPath('MyVideos') },
        @{ Id = 'Music'; Path = [Environment]::GetFolderPath('MyMusic') },
        @{ Id = 'Downloads'; Path = (Get-WPDownloadsFolder) }
    )
    $oneDrive = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ } | Select-Object -First 1
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        $synced = [bool]($oneDrive -and $f.Path.StartsWith($oneDrive, [StringComparison]::OrdinalIgnoreCase))
        [pscustomobject]@{ Id = $f.Id; Path = $f.Path; OneDrive = $synced }
    }
}

function Get-WPExtras {
    Write-WPLog 'Checking fonts, Wi-Fi, drivers and user folders...' 'step'
    $list = @()

    $fonts = @(Get-WPCustomFonts)
    $e = New-WPExtra 'fonts' 'Fonts you installed' 'Fonts that did not come with Windows. Restored for all users.'
    $e.Data = $fonts
    $e.Available = $fonts.Count -gt 0
    $e.Selected = $e.Available
    $e.Bytes = [long](($fonts | Measure-Object Bytes -Sum).Sum)
    $e.Info = if ($fonts.Count) { "$($fonts.Count) fonts" } else { 'None found' }
    $list += $e

    $ev = New-WPExtra 'envvars' 'Environment variables' 'Your user PATH entries and custom variables (for dev tools and scripts).'
    $ev.Selected = $true
    $ev.Bytes = 0
    $ev.Info = 'Small'
    $list += $ev

    $wifi = @(Get-WPWifiProfiles)
    $w = New-WPExtra 'wifi' 'Wi-Fi networks' 'Saved networks and their passwords, stored as plain text in the backup.'
    $w.Available = $wifi.Count -gt 0
    $w.Sensitive = $true
    $w.Bytes = 0
    $w.Info = if ($wifi.Count) { "$($wifi.Count) networks" } else { 'None saved' }
    $list += $w

    $d = New-WPExtra 'drivers' 'Third-party drivers' 'Exports every non-Microsoft driver so network or audio works before you can reach the internet. Usually 1-4 GB.'
    $d.Info = 'Exported at backup time'
    $list += $d

    foreach ($f in @(Get-WPUserFolders)) {
        $u = New-WPExtra ('folder:' + $f.Id) ("$($f.Id) folder") $f.Path
        $u.Data = $f
        if ($f.OneDrive) { $u.Info = 'Synced by OneDrive'; $u.Description = "$($f.Path) (already synced by OneDrive)" }
        $list += $u
    }
    return $list
}

function Update-WPExtraSize {
    param($Extra)
    if ($Extra.Id -like 'folder:*') {
        $m = Measure-WPPath $Extra.Data.Path
        $Extra.Bytes = $m.Bytes
        $info = "{0} - {1:N0} files" -f (Format-WPSize $m.Bytes), $m.Files
        if ($Extra.Data.OneDrive) { $info += ' - synced by OneDrive' }
        $Extra.Info = $info
    }
}

#endregion

#region Copying ---------------------------------------------------------------

function Invoke-WPRobocopy {
    param(
        [string]$Source, [string]$Destination, [string[]]$Files, [string[]]$Exclude,
        [switch]$Flat, [switch]$OnlyMissing
    )
    $src = $Source.TrimEnd('\'); if ($src -match '^[A-Za-z]:$') { $src += '\.' }
    $dst = $Destination.TrimEnd('\'); if ($dst -match '^[A-Za-z]:$') { $dst += '\.' }
    $a = @($src, $dst)
    if ($Files) { $a += $Files }
    if (-not $Flat) { $a += '/E' }
    $a += @('/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/MT:8', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($OnlyMissing) { $a += @('/XC', '/XN', '/XO') }
    if ($Exclude) {
        $xd = @(); $xf = @()
        foreach ($x in $Exclude) {
            if ($x.Contains('\')) { $xd += (Join-Path $Source $x); $xf += (Join-Path $Source $x) }
            else { $xd += $x; $xf += $x }
        }
        $a += '/XD'; $a += $xd
        $a += '/XF'; $a += $xf
    }
    & robocopy.exe @a | Out-Null
    return $LASTEXITCODE
}

function Copy-WPItem {
    # Copies one resolved config item into $Destination. Returns $true when everything copied.
    param($Item, [string]$Destination)
    if ($Item.Type -eq 'file') {
        $parent = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $Item.Source -Destination $Destination -Force
        return $true
    }
    $ok = $true
    if ($Item.Include -and $Item.Include.Count -gt 0) {
        $files = @()
        foreach ($inc in $Item.Include) {
            $full = Join-Path $Item.Source $inc
            if (Test-Path -LiteralPath $full -PathType Container) {
                $code = Invoke-WPRobocopy $full (Join-Path $Destination $inc) -Exclude $Item.Exclude
                if ($code -ge 8) { $ok = $false }
            } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $files += $inc
            }
        }
        if ($files.Count) {
            $code = Invoke-WPRobocopy $Item.Source $Destination -Files $files -Flat
            if ($code -ge 8) { $ok = $false }
        }
    } else {
        $code = Invoke-WPRobocopy $Item.Source $Destination -Exclude $Item.Exclude
        if ($code -ge 8) { $ok = $false }
    }
    return $ok
}

#endregion

#region Backup ----------------------------------------------------------------

function Save-WPWingetInstaller {
    param($App, [string]$InstallersRoot, [string]$FolderName, $Previous, [switch]$Force)
    $folder = Join-Path $InstallersRoot $FolderName
    $prevDl = $null
    if ($Previous -and $Previous.Download) { $prevDl = $Previous.Download }

    $prevFilesOk = $false
    if ($prevDl -and $prevDl.Installer) { $prevFilesOk = Test-Path -LiteralPath (Join-Path $folder $prevDl.Installer) }
    if (-not $Force -and $prevFilesOk -and $prevDl.Version -and $App.Latest -and $prevDl.Version -eq $App.Latest -and $prevDl.WingetId -eq $App.WingetId) {
        $dl = ConvertTo-WPHashtable $prevDl
        $dl.Status = 'Up to date'
        return $dl
    }

    $tmp = Join-Path $InstallersRoot ('.partial\' + $FolderName)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $res = Invoke-WPWinget @('download', '--id', $App.WingetId, '--exact', '--source', 'winget', '--download-directory', $tmp,
        '--skip-dependencies', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 3600
    $yaml = Get-ChildItem -LiteralPath $tmp -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $bins = @(Get-ChildItem -LiteralPath $tmp -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.yaml' })
    if ($res.ExitCode -ne 0 -or $bins.Count -eq 0) {
        $err = Get-WPWingetError $res
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if ($prevFilesOk) {
            $dl = ConvertTo-WPHashtable $prevDl
            $dl.Status = 'Kept previous'
            $dl.Error = $err
            return $dl
        }
        return @{ Status = 'Failed'; Error = $err; WingetId = $App.WingetId; Folder = $FolderName }
    }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    Move-Item -LiteralPath $tmp -Destination $folder
    $info = @{}
    if ($yaml) { $info = Read-WPWingetManifest (Join-Path $folder $yaml.Name) }
    $installer = $bins | Sort-Object Length -Descending | Select-Object -First 1
    return @{
        Status = 'Downloaded'; Folder = $FolderName; WingetId = $App.WingetId
        Installer = $installer.Name; Manifest = $(if ($yaml) { $yaml.Name } else { '' })
        Bytes = [long]$installer.Length; Version = [string]$info.Version
        Type = [string]$info.InstallerType; NestedType = [string]$info.NestedType
        Silent = [string]$info.Silent; SilentWithProgress = [string]$info.SilentWithProgress; Custom = [string]$info.Custom
        Dependencies = @($info.Dependencies); Codes = $info.Codes
        InstallerUrl = [string]$info.InstallerUrl; PackageUrl = [string]$info.PackageUrl; Sha256 = [string]$info.Sha256
        Date = (Get-Date).ToString('yyyy-MM-dd')
    }
}

function Save-WPUrlInstaller {
    param($App, [string]$InstallersRoot, [string]$FolderName, $Previous, [switch]$Force)
    $folder = Join-Path $InstallersRoot $FolderName
    $prevDl = $null
    if ($Previous -and $Previous.Download) { $prevDl = $Previous.Download }
    $uri = $null
    try { $uri = [Uri]$App.CustomUrl } catch { return @{ Status = 'Failed'; Error = 'That download link is not a valid URL.' } }
    $fileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath))
    if (-not $fileName -or $fileName -notmatch '\.\w{2,5}$') { $fileName = (Get-WPSafeName (Get-WPCleanName $App.Name)) + '-setup.exe' }
    if (-not $Force -and $prevDl -and $prevDl.SourceUrl -eq $App.CustomUrl -and (Test-Path -LiteralPath (Join-Path $folder $prevDl.Installer))) {
        $dl = ConvertTo-WPHashtable $prevDl
        $dl.Status = 'Up to date'
        return $dl
    }
    $tmp = Join-Path $InstallersRoot ('.partial\' + $FolderName)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $App.CustomUrl -OutFile (Join-Path $tmp $fileName) -UseBasicParsing -MaximumRedirection 10 -UserAgent 'Mozilla/5.0 WinPrestige'
    } catch {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Status = 'Failed'; Error = "Download failed: $($_.Exception.Message)" }
    }
    $file = Get-Item -LiteralPath (Join-Path $tmp $fileName)
    if ($file.Length -lt 50KB -and (Get-Content -LiteralPath $file.FullName -TotalCount 1 -ErrorAction SilentlyContinue) -match '<!DOCTYPE|<html') {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Status = 'Failed'; Error = 'That link returned a web page, not an installer. Use the direct download link.' }
    }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    Move-Item -LiteralPath $tmp -Destination $folder
    $ext = $file.Extension.ToLowerInvariant()
    $type = switch ($ext) { '.msi' { 'msi' } '.msix' { 'msix' } '.msixbundle' { 'msix' } '.appx' { 'msix' } '.appxbundle' { 'msix' } '.zip' { 'zip' } default { 'exe' } }
    return @{
        Status = 'Downloaded'; Folder = $FolderName; Installer = $fileName; Bytes = [long]$file.Length
        Type = $type; SourceUrl = $App.CustomUrl; InstallerUrl = $App.CustomUrl; Date = (Get-Date).ToString('yyyy-MM-dd')
        Version = $App.Version; Silent = ''; Custom = ''; Dependencies = @(); Codes = @{}
    }
}

function Get-WPMethod {
    param($Entry)
    $dl = $Entry.Download
    if ($dl -and $dl.Installer -and $dl.Status -ne 'Failed') { return 'local' }
    if ($Entry.WingetId -and $Entry.Source -eq 'msstore') { return 'store' }
    if ($Entry.WingetId) { return 'winget' }
    if ($Entry.Pfn) { return 'storelink' }
    if ($Entry.GameUri) { return 'game' }
    return 'manual'
}

function Backup-WPConfig {
    param($Config, [string]$ConfigsRoot, [string]$FolderName)
    $folder = Join-Path $ConfigsRoot $FolderName
    $staging = Join-Path $ConfigsRoot ('.partial\' + $FolderName)
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $items = @(); $regs = @(); $problems = @()
    foreach ($it in $Config.Items) {
        $stored = 'files\' + (ConvertTo-WPStoredName $it.Target)
        $dst = Join-Path $staging $stored
        try {
            if (-not (Copy-WPItem $it $dst)) { $problems += "some files in $($it.Source) were in use" }
        } catch {
            $problems += "$($it.Source): $($_.Exception.Message)"
            continue
        }
        $items += [ordered]@{ type = $it.Type; stored = $stored; target = $it.Target; original = $it.Source }
    }
    $i = 0
    foreach ($key in $Config.Registry) {
        $i++
        $regDir = Join-Path $staging 'registry'
        if (-not (Test-Path -LiteralPath $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
        $file = "registry\$i.reg"
        & reg.exe export $key (Join-Path $staging $file) /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $regs += [ordered]@{ key = $key; stored = $file } }
        else { $problems += "could not export $key" }
    }

    $originalInstallDir = ''
    if ($Config.InstallDir) { $originalInstallDir = $Config.InstallDir }
    $spec = [ordered]@{
        tool = 'WinPrestige'
        name = $Config.Name
        id = $Config.Id
        created = (Get-Date).ToString('s')
        computer = $env:COMPUTERNAME
        userProfile = $env:USERPROFILE
        documents = [Environment]::GetFolderPath('MyDocuments')
        app = $Config.App
        installDir = $originalInstallDir
        installDirFallback = @($Config.InstallDirFallback)
        processes = @($Config.Processes)
        services = @($Config.Services | Where-Object { $_ })
        items = @($items)
        registry = @($regs)
        rewrite = @($Config.Rewrite)
        notes = $Config.Notes
    }
    Write-WPJson $spec (Join-Path $staging 'restore.json')
    Copy-Item -LiteralPath (Join-Path $script:WP.Root 'lib\Restore-Config.ps1') -Destination (Join-Path $staging 'Restore-Config.ps1') -Force
    $cmd = "@echo off`r`nrem Puts $($Config.Name) settings back. Install the app first.`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Restore-Config.ps1`"`r`npause`r`n"
    [IO.File]::WriteAllText((Join-Path $staging 'Restore-Config.cmd'), $cmd, [Text.Encoding]::ASCII)

    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $folder
    $m = Measure-WPPath $folder
    return @{
        Status = $(if ($problems.Count) { 'Partial' } else { 'Saved' })
        Detail = ($problems -join '; ')
        Folder = $FolderName
        Bytes = $m.Bytes
        Files = $m.Files
    }
}

function Backup-WPExtra {
    param($Extra, [string]$ExtrasRoot)
    switch -Wildcard ($Extra.Id) {
        'fonts' {
            $dir = Join-Path $ExtrasRoot 'Fonts'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $index = @()
            foreach ($f in @($Extra.Data)) {
                try { Copy-Item -LiteralPath $f.Path -Destination (Join-Path $dir $f.File) -Force; $index += [ordered]@{ file = $f.File; name = $f.Name } } catch { }
            }
            Write-WPJson @($index) (Join-Path $dir 'fonts.json')
            return @{ Status = 'Saved'; Detail = "$($index.Count) fonts"; Folder = 'Fonts' }
        }
        'envvars' {
            $dir = Join-Path $ExtrasRoot 'Environment'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $vars = [ordered]@{}
            $key = Get-Item -LiteralPath 'HKCU:\Environment'
            foreach ($name in $key.GetValueNames()) {
                if (@('TEMP', 'TMP', 'Path', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') -contains $name) { continue }
                $vars[$name] = [string]$key.GetValue($name, '', 'DoNotExpandEnvironmentNames')
            }
            $path = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            $spec = [ordered]@{ userProfile = $env:USERPROFILE; variables = $vars; path = @($path -split ';' | Where-Object { $_ }) }
            Write-WPJson $spec (Join-Path $dir 'environment.json')
            return @{ Status = 'Saved'; Detail = "$($vars.Count) variables, $(@($spec.path).Count) PATH entries"; Folder = 'Environment' }
        }
        'wifi' {
            $dir = Join-Path $ExtrasRoot 'WiFi'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            & netsh.exe wlan export profile key=clear folder="$dir" | Out-Null
            $n = @(Get-ChildItem -LiteralPath $dir -Filter '*.xml').Count
            return @{ Status = 'Saved'; Detail = "$n networks"; Folder = 'WiFi' }
        }
        'drivers' {
            $dir = Join-Path $ExtrasRoot 'Drivers'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # pnputil can't write to network paths reliably, so export locally first.
            $tmp = Join-Path $env:TEMP 'WinPrestige-drivers'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            & pnputil.exe /export-driver * "$tmp" | Out-Null
            $code = Invoke-WPRobocopy $tmp $dir
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            $n = @(Get-ChildItem -LiteralPath $dir -Filter '*.inf' -Recurse).Count
            return @{ Status = $(if ($code -ge 8) { 'Partial' } else { 'Saved' }); Detail = "$n driver packages"; Folder = 'Drivers' }
        }
        'folder:*' {
            $name = $Extra.Id.Substring(7)
            $dir = Join-Path $ExtrasRoot ("UserFolders\" + $name)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $code = Invoke-WPRobocopy $Extra.Data.Path $dir -Exclude @('desktop.ini', 'Thumbs.db')
            return @{ Status = $(if ($code -ge 8) { 'Partial' } else { 'Saved' }); Detail = $(if ($code -ge 8) { 'Some files were in use or unreadable' } else { '' }); Folder = "UserFolders\$name" }
        }
    }
    return @{ Status = 'Skipped' }
}

function Copy-WPSelf {
    # Puts a copy of WinPrestige next to the backup so it's there after the reset.
    param([string]$Destination)
    $target = Join-Path $Destination 'WinPrestige'
    $src = $script:WP.Root.TrimEnd('\')
    if ($src -ieq $target.TrimEnd('\')) { return }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($name in @('WinPrestige.exe', 'WinPrestige.ps1', 'WinPrestige.cmd', 'README.md', 'LICENSE')) {
        $p = Join-Path $src $name
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $target $name) -Force }
    }
    foreach ($dir in @('lib', 'data', 'assets')) {
        if (Test-Path -LiteralPath (Join-Path $src $dir)) { Invoke-WPRobocopy (Join-Path $src $dir) (Join-Path $target $dir) | Out-Null }
    }
    $cmd = "@echo off`r`nrem Opens WinPrestige on its Restore tab with this backup loaded.`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0WinPrestige\WinPrestige.ps1`" -Mode Restore -HideConsole -BackupPath `"%~dp0.`"`r`n"
    [IO.File]::WriteAllText((Join-Path $Destination 'Restore.cmd'), $cmd, [Text.Encoding]::ASCII)
}

function Invoke-WPBackup {
    param($Apps, $Configs, $Extras, [string]$Destination, [hashtable]$Options)
    $dest = $Destination.TrimEnd('\')
    $started = Get-Date
    foreach ($d in @($dest, "$dest\Installers", "$dest\Configs", "$dest\Extras")) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $prev = Read-WPJson "$dest\manifest.json"
    $prevApps = @{}; $prevConfigs = @{}
    if ($prev) {
        foreach ($a in @($prev.apps)) { if ($a.Key) { $prevApps[$a.Key] = $a } }
        foreach ($c in @($prev.configs)) { if ($c.Id) { $prevConfigs[$c.Id] = $c } }
    }

    # Installers --------------------------------------------------------------
    $usedFolders = @{}
    foreach ($a in $prevApps.Values) { if ($a.Selected -and $a.Download -and $a.Download.Folder) { $usedFolders[([string]$a.Download.Folder).ToLowerInvariant()] = $true } }
    $entries = @()
    $selected = @($Apps | Where-Object { $_.Selected })
    $toDownload = @($selected | Where-Object { ($_.WingetId -and $_.Source -eq 'winget') -or $_.CustomUrl })
    Write-WPLog ("Backing up {0} selected apps to {1}" -f $selected.Count, $dest) 'step'
    $n = 0
    foreach ($app in $Apps) {
        if (Test-WPCancel) { break }
        $p = $prevApps[$app.Key]
        $entry = [ordered]@{
            Key = $app.Key; Name = $app.Name; Version = $app.Version; Publisher = $app.Publisher
            Category = $app.Category; Via = $app.Via; Selected = [bool]$app.Selected
            WingetId = $app.WingetId; Source = $app.Source; Match = $app.Match; Pfn = $app.Pfn
            Url = $app.Url; CustomUrl = $app.CustomUrl; GameUri = $app.GameUri; LauncherGame = [bool]$app.LauncherGame
            Download = $null; Method = ''
        }
        if ($app.Selected -and $Options.Installers -and (($app.WingetId -and $app.Source -eq 'winget') -or $app.CustomUrl)) {
            $n++
            Set-WPProgress $n $toDownload.Count ("Downloading {0}" -f $app.Name)
            $folderName = $null
            if ($p -and $p.Download -and $p.Download.Folder) { $folderName = [string]$p.Download.Folder }
            if (-not $folderName) { $folderName = Get-WPUniqueName (Get-WPSafeName (Get-WPCleanName $app.Name)) $usedFolders }
            $app.Status = 'Downloading'; Send-WPMessage 'app' @{ Key = $app.Key }
            if ($app.CustomUrl) { $dl = Save-WPUrlInstaller $app "$dest\Installers" $folderName $p -Force:$Options.Redownload }
            else { $dl = Save-WPWingetInstaller $app "$dest\Installers" $folderName $p -Force:$Options.Redownload }
            $entry.Download = $dl
            $app.Status = $dl.Status
            $app.Detail = [string]$dl.Error
            switch ($dl.Status) {
                'Downloaded' { Write-WPLog ("Downloaded {0} {1} ({2})" -f (Get-WPCleanName $app.Name), $dl.Version, (Format-WPSize $dl.Bytes)) 'ok' }
                'Up to date' { Write-WPLog ("{0} is already current ({1})" -f (Get-WPCleanName $app.Name), $dl.Version) 'info' }
                'Kept previous' { Write-WPLog ("{0}: {1} Kept the installer from the last backup." -f $app.Name, $dl.Error) 'warn' }
                default { Write-WPLog ("{0}: {1}" -f $app.Name, $dl.Error) 'error' }
            }
            Send-WPMessage 'app' @{ Key = $app.Key }
        } elseif ($app.Selected -and $p -and $p.Download -and -not $Options.Installers) {
            $entry.Download = $p.Download
        }
        $entry.Method = Get-WPMethod ([pscustomobject]$entry)
        $entries += $entry
    }

    # Dependencies that installers need (e.g. .NET runtimes), downloaded once each.
    $deps = @{}
    foreach ($e in $entries) {
        if ($e.Selected -and $e.Download -and $e.Download.Dependencies) {
            foreach ($d in @($e.Download.Dependencies)) { if ($d) { $deps[[string]$d] = $true } }
        }
    }
    $depEntries = @()
    $prevDeps = @{}
    if ($prev) { foreach ($d in @($prev.dependencies)) { if ($d.WingetId) { $prevDeps[$d.WingetId] = $d } } }
    if ($Options.Installers -and $deps.Count -and -not (Test-WPCancel)) {
        Write-WPLog ("Downloading {0} shared dependencies..." -f $deps.Count) 'step'
        foreach ($id in $deps.Keys) {
            if (Test-WPCancel) { break }
            $pseudo = [pscustomobject]@{ WingetId = $id; Name = $id; Latest = '' }
            $installed = $Apps | Where-Object { $_.WingetId -eq $id } | Select-Object -First 1
            if ($installed) { $pseudo.Latest = $installed.Latest }
            $prevDep = $null
            if ($prevDeps[$id]) { $prevDep = [pscustomobject]@{ Download = $prevDeps[$id].Download } }
            $dl = Save-WPWingetInstaller $pseudo "$dest\Installers\_Dependencies" (Get-WPSafeName $id) $prevDep -Force:$Options.Redownload
            if ($dl.Status -eq 'Failed') { Write-WPLog ("Dependency {0}: {1}" -f $id, $dl.Error) 'warn' }
            $depEntries += [ordered]@{ WingetId = $id; Download = $dl }
        }
    } elseif ($prev -and $prev.dependencies) {
        $depEntries = @($prev.dependencies)
    }

    # Configs -----------------------------------------------------------------
    $configEntries = @()
    $usedConfigFolders = @{}
    foreach ($c in $prevConfigs.Values) { if ($c.Folder) { $usedConfigFolders[([string]$c.Folder).ToLowerInvariant()] = $true } }
    $selConfigs = @($Configs | Where-Object { $_.Selected })
    if ($Options.Configs -and $selConfigs.Count -and -not (Test-WPCancel)) {
        Write-WPLog ("Copying settings for {0} apps..." -f $selConfigs.Count) 'step'
        $i = 0
        foreach ($c in $selConfigs) {
            if (Test-WPCancel) { break }
            $i++
            Set-WPProgress $i $selConfigs.Count ("Copying {0} settings" -f $c.Name)
            $pc = $prevConfigs[$c.Id]
            $folderName = $null
            if ($pc -and $pc.Folder) { $folderName = [string]$pc.Folder }
            if (-not $folderName) { $folderName = Get-WPUniqueName (Get-WPSafeName $c.Name) $usedConfigFolders }
            $c.Status = 'Copying'; Send-WPMessage 'config' @{ Id = $c.Id }
            try {
                $r = Backup-WPConfig $c "$dest\Configs" $folderName
            } catch {
                $r = @{ Status = 'Failed'; Detail = $_.Exception.Message; Folder = $folderName }
            }
            $c.Status = $r.Status; $c.Detail = $r.Detail
            Send-WPMessage 'config' @{ Id = $c.Id }
            $level = switch ($r.Status) { 'Saved' { 'ok' } 'Partial' { 'warn' } default { 'error' } }
            $msg = "{0}: {1}" -f $c.Name, $r.Status
            if ($r.Bytes) { $msg += " ($(Format-WPSize $r.Bytes))" }
            if ($r.Detail) { $msg += " - $($r.Detail)" }
            Write-WPLog $msg $level
            $configEntries += [ordered]@{ Id = $c.Id; Name = $c.Name; App = $c.App; Folder = $r.Folder; Status = $r.Status; Detail = $r.Detail; Bytes = $r.Bytes; Notes = $c.Notes; Sensitive = [bool]$c.Sensitive }
        }
    } elseif (-not $Options.Configs -and $prev) {
        $configEntries = @($prev.configs)
    }

    # Extras ------------------------------------------------------------------
    $extraEntries = @()
    $selExtras = @($Extras | Where-Object { $_.Selected -and $_.Available })
    if ($Options.Extras -and $selExtras.Count -and -not (Test-WPCancel)) {
        Write-WPLog 'Saving extras...' 'step'
        foreach ($e in $selExtras) {
            if (Test-WPCancel) { break }
            Set-WPProgress 0 1 ("Saving {0}" -f $e.Name)
            $e.Status = 'Saving'; Send-WPMessage 'extra' @{ Id = $e.Id }
            try { $r = Backup-WPExtra $e "$dest\Extras" } catch { $r = @{ Status = 'Failed'; Detail = $_.Exception.Message } }
            $e.Status = $r.Status; $e.Detail = $r.Detail
            Send-WPMessage 'extra' @{ Id = $e.Id }
            $msg = "{0}: {1}" -f $e.Name, $r.Status
            if ($r.Detail) { $msg += " - $($r.Detail)" }
            Write-WPLog $msg $(if ($r.Status -eq 'Saved') { 'ok' } else { 'warn' })
            $extraEntries += [ordered]@{ Id = $e.Id; Name = $e.Name; Folder = $r.Folder; Status = $r.Status; Detail = $r.Detail }
        }
    } elseif (-not $Options.Extras -and $prev) {
        $extraEntries = @($prev.extras)
    }

    if (Test-WPCancel) {
        Write-WPLog 'Backup cancelled. Nothing was pruned and the previous manifest was left in place.' 'warn'
        return @{ Cancelled = $true }
    }

    # Prune: remove what this tool created last time but isn't part of this backup.
    $removed = @(); $added = @()
    $keepInstaller = @{}
    foreach ($e in $entries) { if ($e.Selected -and $e.Download -and $e.Download.Folder) { $keepInstaller[([string]$e.Download.Folder).ToLowerInvariant()] = $true } }
    $keepConfig = @{}
    foreach ($c in $configEntries) { if ($c.Folder) { $keepConfig[([string]$c.Folder).ToLowerInvariant()] = $true } }
    if ($prev) {
        foreach ($pa in @($prev.apps)) {
            if (-not $pa.Selected) { continue }
            $now = $entries | Where-Object { $_.Key -eq $pa.Key } | Select-Object -First 1
            if (-not $now) { $removed += "$($pa.Name) (uninstalled)" }
            elseif (-not $now.Selected) { $removed += "$($pa.Name) (unticked)" }
            if ($Options.Prune -and $pa.Download -and $pa.Download.Folder -and -not $keepInstaller[([string]$pa.Download.Folder).ToLowerInvariant()]) {
                $path = Join-Path "$dest\Installers" $pa.Download.Folder
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue; Write-WPLog ("Removed old installer for {0}" -f $pa.Name) 'info' }
            }
        }
        foreach ($pc in @($prev.configs)) {
            if ($Options.Prune -and $pc.Folder -and -not $keepConfig[([string]$pc.Folder).ToLowerInvariant()]) {
                $path = Join-Path "$dest\Configs" $pc.Folder
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue; Write-WPLog ("Removed old settings backup for {0}" -f $pc.Name) 'info' }
            }
        }
        $prevKeys = @{}
        foreach ($pa in @($prev.apps)) { if ($pa.Selected) { $prevKeys[$pa.Key] = $true } }
        foreach ($e in $entries) { if ($e.Selected -and -not $prevKeys[$e.Key]) { $added += $e.Name } }
    }
    foreach ($tmp in @("$dest\Installers\.partial", "$dest\Installers\_Dependencies\.partial", "$dest\Configs\.partial")) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $manifest = [ordered]@{
        tool = 'WinPrestige'; version = $script:WP.Version
        created = (Get-Date).ToString('s')
        computer = $env:COMPUTERNAME
        user = $env:USERNAME
        userProfile = $env:USERPROFILE
        windows = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        apps = @($entries)
        dependencies = @($depEntries)
        configs = @($configEntries)
        extras = @($extraEntries)
        added = @($added)
        removed = @($removed)
    }
    Write-WPJson $manifest "$dest\manifest.json"
    Copy-WPSelf $dest
    Export-WPReport $manifest $dest
    $elapsed = (Get-Date) - $started
    $failed = @($entries | Where-Object { $_.Selected -and $_.Download -and $_.Download.Status -eq 'Failed' }).Count
    Write-WPLog ("Backup finished in {0:mm\:ss}. Report: {1}" -f $elapsed, "$dest\AppInventory.html") 'ok'
    return @{ Cancelled = $false; Failed = $failed; Report = "$dest\AppInventory.html"; Destination = $dest; Added = $added; Removed = $removed }
}

#endregion

#region Report ----------------------------------------------------------------

function ConvertTo-WPHtml {
    param([string]$Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Get-WPEntryLinks {
    param($Entry)
    $links = @()
    $dl = $Entry.Download
    if ($dl -and $dl.InstallerUrl) { $links += @{ Text = 'Official installer'; Url = $dl.InstallerUrl } }
    if ($dl -and $dl.PackageUrl) { $links += @{ Text = 'Homepage'; Url = $dl.PackageUrl } }
    if ($Entry.WingetId -and $Entry.Source -eq 'winget') {
        $path = $Entry.WingetId.Substring(0, 1).ToLowerInvariant() + '/' + ($Entry.WingetId -replace '\.', '/')
        $links += @{ Text = 'winget manifest'; Url = "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$path" }
    }
    if ($Entry.WingetId -and $Entry.Source -eq 'msstore') { $links += @{ Text = 'Microsoft Store'; Url = "https://apps.microsoft.com/detail/$($Entry.WingetId)" } }
    if (-not $Entry.WingetId -and $Entry.Pfn) { $links += @{ Text = 'Microsoft Store'; Url = "https://apps.microsoft.com/search?query=$([Uri]::EscapeDataString((Get-WPCleanName $Entry.Name)))" } }
    if ($Entry.CustomUrl) { $links += @{ Text = 'Your download link'; Url = $Entry.CustomUrl } }
    if ($Entry.Url -and -not ($links | Where-Object { $_.Url -eq $Entry.Url })) { $links += @{ Text = 'Vendor site'; Url = $Entry.Url } }
    if ($links.Count -eq 0) { $links += @{ Text = 'Search the web'; Url = "https://www.bing.com/search?q=$([Uri]::EscapeDataString((Get-WPCleanName $Entry.Name) + ' download'))" } }
    return $links
}

function Get-WPMethodText {
    param($Entry)
    switch ($Entry.Method) {
        'local' { return 'Installer saved' }
        'winget' { return 'winget (online)' }
        'store' { return 'Microsoft Store (winget)' }
        'storelink' { return 'Microsoft Store page' }
        'game' { return "Reinstall from $($Entry.Via)" }
        default { return 'Manual download' }
    }
}

function Export-WPReport {
    param($Manifest, [string]$Destination)
    $apps = @($Manifest.apps)
    $sel = @($apps | Where-Object { $_.Selected })
    $saved = @($sel | Where-Object { $_.Method -eq 'local' }).Count
    $online = @($sel | Where-Object { @('winget', 'store') -contains $_.Method }).Count
    $manual = @($sel | Where-Object { @('manual', 'storelink') -contains $_.Method })
    $games = @($apps | Where-Object { $_.Category -eq 'games' })
    $sb = New-Object System.Text.StringBuilder
    $css = @'
:root{--bg:#0a0f1a;--panel:#0f1726;--panel2:#152036;--line:#1f2b42;--text:#e4edf7;--muted:#7f8fa9;--accent:#5fcfe3;--good:#3ddc97;--warn:#f2b24c;--bad:#f2667a;--brand:linear-gradient(90deg,#4cdbda,#7b9ce9 55%,#c094f0)}
@media (prefers-color-scheme: light){:root{--bg:#f6f7f9;--panel:#fff;--panel2:#f0f2f5;--line:#dde1e7;--text:#1b1f24;--muted:#5d6673;--accent:#1f6feb;--good:#1a7f37;--warn:#9a6700;--bad:#cf222e}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif;border-top:3px solid #4cdbda;border-image:var(--brand) 1}
main{max-width:1100px;margin:0 auto;padding:32px 20px 60px}h1{font-size:26px;margin:0 0 4px}h2{font-size:17px;margin:34px 0 10px;color:var(--accent)}
.sub{color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px;margin:22px 0}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}.stat b{display:block;font-size:22px;background:var(--brand);-webkit-background-clip:text;background-clip:text;color:transparent}.stat span{color:var(--muted);font-size:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 18px}ol{margin:6px 0 0;padding-left:20px}li{margin:4px 0}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--panel2);font-size:12px;color:var(--muted);font-weight:600}
tr:last-child td{border-bottom:0}td.v{color:var(--muted);white-space:nowrap}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.tag{display:inline-block;font-size:11px;padding:1px 7px;border-radius:9px;background:var(--panel2);color:var(--muted);white-space:nowrap}
.ok{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.wrap{overflow-x:auto}code{font-family:Consolas,monospace;font-size:12px}
'@
    [void]$sb.Append("<!doctype html><html lang=`"en`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>App Inventory - $(ConvertTo-WPHtml $Manifest.computer)</title><style>$css</style></head><body><main>")
    [void]$sb.Append("<h1>App inventory for $(ConvertTo-WPHtml $Manifest.computer)</h1><div class=`"sub`">Backed up $(ConvertTo-WPHtml ([datetime]$Manifest.created).ToString('dddd d MMMM yyyy, HH:mm')) &middot; $(ConvertTo-WPHtml $Manifest.windows)</div>")
    [void]$sb.Append('<div class="stats">')
    foreach ($s in @(@($sel.Count, 'apps to reinstall'), @($saved, 'installers saved'), @($online, 'install online'), @($manual.Count, 'manual downloads'), @(@($Manifest.configs).Count, 'app settings saved'), @($games.Count, 'games (skipped)'))) {
        [void]$sb.Append("<div class=`"stat`"><b>$($s[0])</b><span>$($s[1])</span></div>")
    }
    [void]$sb.Append('</div>')
    [void]$sb.Append('<h2>After the reset</h2><div class="card"><ol><li>Install your NAS app (or open the share in File Explorer) and reach this folder.</li><li>Double-click <code>Restore.cmd</code>. WinPrestige opens on its Restore tab with this backup loaded.</li><li>Leave everything ticked and press <b>Start restore</b>. Installers run from this folder; anything that fails falls back to winget online.</li><li>Install the <b>manual downloads</b> below, then sign in to your launchers and re-download games.</li><li>Restart the PC so drivers and hardware apps (iCUE, G HUB, SteelSeries) pick up their restored settings.</li></ol></div>')
    if (@($Manifest.added).Count -or @($Manifest.removed).Count) {
        [void]$sb.Append('<h2>Changes since the last backup</h2><div class="card">')
        if (@($Manifest.added).Count) { [void]$sb.Append("<div><span class=`"ok`">Added:</span> $(ConvertTo-WPHtml (@($Manifest.added) -join ', '))</div>") }
        if (@($Manifest.removed).Count) { [void]$sb.Append("<div><span class=`"warn`">Removed:</span> $(ConvertTo-WPHtml (@($Manifest.removed) -join ', '))</div>") }
        [void]$sb.Append('</div>')
    }
    if ($manual.Count) {
        [void]$sb.Append('<h2>Manual downloads</h2><div class="wrap"><table><tr><th>App</th><th>Version</th><th>Publisher</th><th>Where to get it</th></tr>')
        foreach ($e in ($manual | Sort-Object Name)) {
            $l = (Get-WPEntryLinks $e | ForEach-Object { "<a href=`"$(ConvertTo-WPHtml $_.Url)`">$(ConvertTo-WPHtml $_.Text)</a>" }) -join ' &middot; '
            [void]$sb.Append("<tr><td>$(ConvertTo-WPHtml $e.Name)</td><td class=`"v`">$(ConvertTo-WPHtml $e.Version)</td><td>$(ConvertTo-WPHtml $e.Publisher)</td><td>$l</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }
    foreach ($cat in $script:WP.Rules.categories) {
        if ($cat.id -eq 'system') { continue }
        $rows = @($apps | Where-Object { $_.Category -eq $cat.id } | Sort-Object Name)
        if ($rows.Count -eq 0) { continue }
        [void]$sb.Append("<h2>$(ConvertTo-WPHtml $cat.title) <span class=`"tag`">$($rows.Count)</span></h2><div class=`"wrap`"><table><tr><th>App</th><th>Version</th><th>Publisher</th><th>Comes back via</th><th>Links</th></tr>")
        foreach ($e in $rows) {
            $how = if (-not $e.Selected) { if ($e.Via) { "via $($e.Via)" } else { 'Not included' } } else { Get-WPMethodText $e }
            $cls = ''
            if ($e.Selected -and $e.Download -and $e.Download.Status -eq 'Failed') { $cls = 'bad'; $how = "Download failed, will use winget online: $($e.Download.Error)" }
            elseif ($e.Selected -and $e.Method -eq 'local') { $cls = 'ok' }
            elseif ($e.Selected -and $e.Method -eq 'manual') { $cls = 'warn' }
            $l = (Get-WPEntryLinks $e | ForEach-Object { "<a href=`"$(ConvertTo-WPHtml $_.Url)`">$(ConvertTo-WPHtml $_.Text)</a>" }) -join ' &middot; '
            $idText = ''
            if ($e.WingetId) { $idText = "<br><code class=`"sub`">$(ConvertTo-WPHtml $e.WingetId)</code>" }
            [void]$sb.Append("<tr><td>$(ConvertTo-WPHtml $e.Name)$idText</td><td class=`"v`">$(ConvertTo-WPHtml $e.Version)</td><td>$(ConvertTo-WPHtml $e.Publisher)</td><td class=`"$cls`">$(ConvertTo-WPHtml $how)</td><td>$l</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }
    if (@($Manifest.configs).Count) {
        [void]$sb.Append('<h2>App settings</h2><div class="wrap"><table><tr><th>Settings</th><th>Size</th><th>Status</th><th>Notes</th></tr>')
        foreach ($c in @($Manifest.configs)) {
            $cls = if ($c.Status -eq 'Saved') { 'ok' } elseif ($c.Status -eq 'Partial') { 'warn' } else { 'bad' }
            $size = ''
            if ($c.Bytes) { $size = Format-WPSize $c.Bytes }
            [void]$sb.Append("<tr><td>$(ConvertTo-WPHtml $c.Name)<br><code class=`"sub`">Configs\$(ConvertTo-WPHtml $c.Folder)\Restore-Config.cmd</code></td><td class=`"v`">$size</td><td class=`"$cls`">$(ConvertTo-WPHtml $c.Status)</td><td>$(ConvertTo-WPHtml $c.Notes) $(ConvertTo-WPHtml $c.Detail)</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }
    if (@($Manifest.extras).Count) {
        [void]$sb.Append('<h2>Extras</h2><div class="wrap"><table><tr><th>Item</th><th>Status</th><th>Details</th></tr>')
        foreach ($x in @($Manifest.extras)) {
            [void]$sb.Append("<tr><td>$(ConvertTo-WPHtml $x.Name)</td><td>$(ConvertTo-WPHtml $x.Status)</td><td>$(ConvertTo-WPHtml $x.Detail)</td></tr>")
        }
        [void]$sb.Append('</table></div>')
    }
    [void]$sb.Append('<p class="sub" style="margin-top:30px">Made by WinPrestige. Installer links come from the winget community repository, which records each vendor''s official download URL and its SHA-256 hash.</p></main></body></html>')
    [IO.File]::WriteAllText((Join-Path $Destination 'AppInventory.html'), $sb.ToString(), (New-Object Text.UTF8Encoding $false))

    $apps | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name; Version = $_.Version; Publisher = $_.Publisher
            Category = (Get-WPCategoryInfo $_.Category).title; Included = [bool]$_.Selected
            HowItComesBack = $(if ($_.Selected) { Get-WPMethodText $_ } elseif ($_.Via) { "via $($_.Via)" } else { '' })
            WingetId = $_.WingetId; Source = $_.Source
            Installer = $(if ($_.Download) { $_.Download.Installer } else { '' })
            InstallerUrl = $(if ($_.Download) { $_.Download.InstallerUrl } else { '' })
            Link = (@(Get-WPEntryLinks $_) | Select-Object -First 1).Url
        }
    } | Export-Csv -LiteralPath (Join-Path $Destination 'AppInventory.csv') -NoTypeInformation -Encoding UTF8
}

#endregion

#region Restore ---------------------------------------------------------------

function Get-WPInstalledIndex {
    $ids = @{}; $names = @{}
    if ($script:WP.Winget) {
        $res = Invoke-WPWinget @('list', '--accept-source-agreements', '--disable-interactivity')
        foreach ($row in @(ConvertFrom-WPWingetTable $res.Lines)) {
            if ($row.Id) { $ids[$row.Id.ToLowerInvariant()] = $true }
            if ($row.Name) { $names[(Get-WPNormName $row.Name)] = $true }
        }
    }
    foreach ($r in @(Get-WPRegistryApps)) { $names[(Get-WPNormName $r.Name)] = $true }
    return @{ Ids = $ids; Names = $names }
}

function Test-WPInstalled {
    param($Entry, $Index)
    if (-not $Index) { return $false }
    if ($Entry.WingetId -and $Index.Ids[([string]$Entry.WingetId).ToLowerInvariant()]) { return $true }
    $n = Get-WPNormName $Entry.Name
    return [bool]($n -and $Index.Names[$n])
}

function Get-WPSilentArgs {
    param([string]$Type, $Download)
    if ($Download.Silent) { return [string]$Download.Silent }
    switch ($Type) {
        'inno' { return '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        'nullsoft' { return '/S' }
        'burn' { return '/quiet /norestart' }
        'msi' { return '/qn /norestart' }
        'wix' { return '/qn /norestart' }
    }
    return ''
}

function Start-WPLocalInstall {
    # Copies a saved installer to local temp (some installers misbehave when run from a network share)
    # and starts it without waiting. Finish with Complete-WPLocalInstall, or use Install-WPLocal to wait.
    param($Download, [string]$Folder, [switch]$Interactive)
    $src = Join-Path $Folder $Download.Installer
    if (-not (Test-Path -LiteralPath $src)) { return @{ Done = $true; Ok = $false; Detail = 'Installer file is missing from the backup.' } }
    $type = ([string]$Download.Type).ToLowerInvariant()
    if (@('zip', 'portable') -contains $type) { return @{ Done = $true; Ok = $false; Detail = 'Portable/zip package; installing it with winget instead.' } }
    $work = Join-Path $env:TEMP ('WinPrestige\' + (Get-WPSafeName ([string]$Download.Folder)))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $file = Join-Path $work $Download.Installer
    Copy-Item -LiteralPath $src -Destination $file -Force
    Unblock-File -LiteralPath $file -ErrorAction SilentlyContinue

    if (@('msix', 'appx') -contains $type -or $file -match '\.(msix|msixbundle|appx|appxbundle)$') {
        try { Add-AppxPackage -Path $file -ForceApplicationShutdown -ErrorAction Stop; return @{ Done = $true; Ok = $true; Detail = 'Installed' } }
        catch { return @{ Done = $true; Ok = $false; Detail = $_.Exception.Message } }
    }

    $silent = ''
    if (-not $Interactive) { $silent = Get-WPSilentArgs $type $Download }
    $custom = [string]$Download.Custom
    if ($type -eq 'msi' -or $type -eq 'wix' -or $file -match '\.msi$') {
        $exe = Join-Path $env:windir 'System32\msiexec.exe'
        $argText = ("/i `"$file`" $silent $custom").Trim()
    } else {
        $exe = $file
        $argText = ("$silent $custom").Trim()
    }
    try {
        if ($argText) { $p = Start-Process -FilePath $exe -ArgumentList $argText -PassThru -ErrorAction Stop }
        else { $p = Start-Process -FilePath $exe -PassThru -ErrorAction Stop }
        $null = $p.Handle   # opening the handle now keeps ExitCode readable after the process exits
    } catch { return @{ Done = $true; Ok = $false; Detail = $_.Exception.Message } }
    return @{
        Done = $false; Process = $p; Download = $Download; Started = (Get-Date)
        RanInteractive = ([bool]$Interactive -or -not $silent); AskedInteractive = [bool]$Interactive
    }
}

function Complete-WPLocalInstall {
    param($Handle)
    $code = $Handle.Process.ExitCode
    $response = $null
    if ($Handle.Download.Codes) {
        $codes = ConvertTo-WPHashtable $Handle.Download.Codes
        $response = $codes["$code"]
    }
    if (@(0, 3010, 1641) -contains $code -or @('rebootRequiredToFinish', 'rebootRequiredForInstall', 'rebootInitiated', 'alreadyInstalled') -contains $response) {
        $detail = 'Installed'
        if (@(3010, 1641) -contains $code -or $response -like 'reboot*') { $detail = 'Installed (restart needed)' }
        if ($Handle.RanInteractive -and -not $Handle.AskedInteractive) { $detail += ' - no silent switch known, so it ran normally' }
        return @{ Ok = $true; Detail = $detail }
    }
    $why = "Installer exit code $code"
    if ($code -eq 1618) { $why = 'Another installer was running at the same time' }
    elseif ($response) { $why += " ($response)" }
    return @{ Ok = $false; Detail = $why; Code = $code }
}

function Install-WPLocal {
    # Runs a saved installer and waits for it (but not for apps it launches when it finishes).
    param($Download, [string]$Folder, [switch]$Interactive)
    $h = Start-WPLocalInstall $Download $Folder -Interactive:$Interactive
    if ($h.Done) { return @{ Ok = $h.Ok; Detail = $h.Detail } }
    $script:WP.CurrentProcess = $h.Process
    $deadline = (Get-Date).AddMinutes(60)
    while (-not $h.Process.WaitForExit(500)) {
        if (Test-WPCancel) { try { $h.Process.Kill() } catch { }; return @{ Ok = $false; Detail = 'Cancelled' } }
        if ((Get-Date) -gt $deadline) { return @{ Ok = $false; Detail = 'Installer is still running after an hour; moving on.' } }
    }
    $script:WP.CurrentProcess = $null
    return (Complete-WPLocalInstall $h)
}

function Get-WPInstallLane {
    # Which part of the restore an app goes in. Silent non-MSI installers can run side by side.
    # MSI-based ones (msi, wix, burn) share Windows Installer's one-at-a-time lock, so they go last.
    param($Entry, [hashtable]$Options)
    switch ($Entry.Method) {
        'local' {
            $type = ([string]$Entry.Download.Type).ToLowerInvariant()
            if (@('msi', 'wix', 'burn') -contains $type -or [string]$Entry.Download.Installer -match '\.msi$') { return 'msi' }
            if (-not $Options.Silent) { return 'one' }
            if (@('inno', 'nullsoft') -contains $type) { return 'parallel' }
            if ($type -eq 'exe' -and $Entry.Download.Silent) { return 'parallel' }
            return 'one'
        }
        'winget' { return 'one' }
        'store' { return 'one' }
    }
    return 'manual'
}

function Install-WPDependency {
    param([string]$Id, [string]$BackupRoot, $DepIndex, $Installed, [switch]$TestRun)
    if ($Installed -and $Installed.Ids[$Id.ToLowerInvariant()]) { return }
    if ($TestRun) { Write-WPLog "  would install dependency $Id first" 'info'; return }
    Write-WPLog "  installing dependency $Id" 'info'
    $d = $DepIndex[$Id]
    $r = $null
    if ($d -and $d.Download -and $d.Download.Installer) { $r = Install-WPLocal $d.Download (Join-Path $BackupRoot ("Installers\_Dependencies\" + $d.Download.Folder)) }
    if ((-not $r -or -not $r.Ok) -and $script:WP.Winget) { $r = Install-WPOnline $Id 'winget' }
    if ($r -and -not $r.Ok) { Write-WPLog "  dependency $Id failed: $($r.Detail)" 'warn' }
}

function Install-WPOnline {
    param([string]$Id, [string]$Source, [switch]$Interactive)
    $a = @('install', '--id', $Id, '--exact', '--source', $Source, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Interactive) { $a += '--interactive' } else { $a += '--silent' }
    $res = Invoke-WPWinget $a -TimeoutSec 3600
    if ($res.ExitCode -eq 0) { return @{ Ok = $true; Detail = "Installed with winget ($Source)" } }
    # Already installed / no newer version available are fine outcomes here.
    if (@(-1978335189, -1978335135) -contains $res.ExitCode) { return @{ Ok = $true; Detail = 'Already installed' } }
    return @{ Ok = $false; Detail = (Get-WPWingetError $res) }
}

function Install-WPEntry {
    param($Entry, [string]$BackupRoot, [hashtable]$Options, $DepIndex, [hashtable]$DoneDeps, $Installed)
    $dl = $Entry.Download
    if ($dl -and $dl.Dependencies) {
        foreach ($dep in @($dl.Dependencies)) {
            if (-not $dep -or $DoneDeps[$dep]) { continue }
            $DoneDeps[$dep] = $true
            Install-WPDependency $dep $BackupRoot $DepIndex $Installed -TestRun:$Options.TestRun
        }
    }
    $interactive = -not $Options.Silent
    switch ($Entry.Method) {
        'local' {
            if ($Options.TestRun) { return @{ Ok = $true; Detail = "Would run $($dl.Installer)" } }
            $r = @{ Ok = $false; Detail = 'Skipped local installer' }
            if ($Options.PreferLocal -or -not $Entry.WingetId) {
                $r = Install-WPLocal $dl (Join-Path $BackupRoot ("Installers\" + $dl.Folder)) -Interactive:$interactive
                if ($r.Ok) { return $r }
            }
            if ($Entry.WingetId -and $Options.OnlineFallback -and $script:WP.Winget) {
                $why = $r.Detail
                $r = Install-WPOnline $Entry.WingetId $Entry.Source -Interactive:$interactive
                if ($r.Ok) { $r.Detail = "$($r.Detail) (local installer: $why)" }
            }
            return $r
        }
        { @('winget', 'store') -contains $_ } {
            if ($Options.TestRun) { return @{ Ok = $true; Detail = "Would install $($Entry.WingetId) from $($Entry.Source)" } }
            if (-not $script:WP.Winget) { return @{ Ok = $false; Detail = 'winget is not available yet. Update "App Installer" from the Microsoft Store and try again.' } }
            return (Install-WPOnline $Entry.WingetId $Entry.Source -Interactive:$interactive)
        }
        'storelink' { return @{ Ok = $false; Manual = $true; Detail = 'Open it in the Microsoft Store (Manual links button).' } }
        'game' { return @{ Ok = $false; Manual = $true; Detail = "Reinstall from $($Entry.Via)." } }
        default { return @{ Ok = $false; Manual = $true; Detail = 'Manual download (Manual links button).' } }
    }
}

function Get-WPRestoreProgressPath {
    return (Join-Path $script:WP.StateDir 'restore-progress.json')
}

function Save-WPRestoreProgress {
    param($Progress)
    $Progress.updated = (Get-Date).ToString('s')
    try { Write-WPJson $Progress (Get-WPRestoreProgressPath) } catch { }
}

function Get-WPRestoreProgress {
    # An unfinished restore from the last week, if there is one.
    $p = $null
    try { $p = Read-WPJson (Get-WPRestoreProgressPath) } catch { }
    if (-not $p -or $p.complete -or -not $p.backup) { return $null }
    try { if (((Get-Date) - [datetime]$p.updated).TotalDays -gt 7) { return $null } } catch { }
    return $p
}

function Clear-WPRestoreProgress {
    $path = Get-WPRestoreProgressPath
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
}

function Find-WPBackups {
    # Looks for WinPrestige backups next to the app, in recent places, on other drives (including USB),
    # on mapped network shares and in Desktop, Documents and Downloads. Checks one folder level deep.
    param([string[]]$Extra)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Extra)) { if ($x) { $roots.Add([string]$x) } }
    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($d.DeviceID -eq $env:SystemDrive) { continue }
        if (@(2, 3) -contains [int]$d.DriveType) { $roots.Add($d.DeviceID + '\') }
    }
    foreach ($k in (Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $unc = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($unc) { $roots.Add([string]$unc) }
    }
    foreach ($kf in @('Desktop', 'MyDocuments')) { $roots.Add([Environment]::GetFolderPath($kf)) }
    $roots.Add((Get-WPDownloadsFolder))
    $seen = @{}
    $found = @()
    foreach ($r in $roots) {
        if (-not $r) { continue }
        $candidates = @($r, (Join-Path $r 'WinPrestige Backup'))
        try {
            $candidates += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction Stop | Select-Object -First 300 | ForEach-Object { $_.FullName; (Join-Path $_.FullName 'WinPrestige Backup') })
        } catch { }
        foreach ($c in $candidates) {
            $key = $c.TrimEnd('\').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $mf = Join-Path $c 'manifest.json'
            if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { continue }
            $m = $null
            try { $m = Read-WPJson $mf } catch { continue }
            if (-not $m -or @('WinPrestige', 'ResetKit') -notcontains [string]$m.tool) { continue }
            $found += [pscustomobject]@{
                Path = $c.TrimEnd('\'); Computer = [string]$m.computer; Created = [string]$m.created
                Apps = @($m.apps | Where-Object { $_.Selected }).Count; Configs = @($m.configs).Count
            }
        }
    }
    return @($found | Sort-Object Created -Descending)
}

function Restore-WPExtra {
    param($Extra, [string]$BackupRoot, [switch]$TestRun)
    $dir = Join-Path $BackupRoot ("Extras\" + $Extra.Folder)
    if (-not $Extra.Folder -or -not (Test-Path -LiteralPath $dir)) { return @{ Ok = $false; Detail = 'Not found in the backup.' } }
    switch -Wildcard ($Extra.Id) {
        'fonts' {
            $index = @(Read-WPJson (Join-Path $dir 'fonts.json'))
            if ($TestRun) { return @{ Ok = $true; Detail = "Would install $($index.Count) fonts" } }
            $fontDir = Join-Path $env:windir 'Fonts'
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
            $n = 0
            foreach ($f in $index) {
                $src = Join-Path $dir $f.file
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $dst = Join-Path $fontDir $f.file
                if (-not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $src -Destination $dst -Force }
                $valueName = $f.name
                if (-not $valueName) { $valueName = [IO.Path]::GetFileNameWithoutExtension($f.file) + ' (TrueType)' }
                New-ItemProperty -LiteralPath $key -Name $valueName -Value $f.file -PropertyType String -Force | Out-Null
                $n++
            }
            return @{ Ok = $true; Detail = "$n fonts installed (visible after a restart)" }
        }
        'envvars' {
            $spec = Read-WPJson (Join-Path $dir 'environment.json')
            if (-not $spec) { return @{ Ok = $false; Detail = 'environment.json missing' } }
            $added = 0
            foreach ($p in $spec.variables.PSObject.Properties) {
                if ([Environment]::GetEnvironmentVariable($p.Name, 'User')) { continue }
                $v = ([string]$p.Value).Replace($spec.userProfile, $env:USERPROFILE)
                if (-not $TestRun) { [Environment]::SetEnvironmentVariable($p.Name, $v, 'User') }
                $added++
            }
            $current = [string](Get-Item -LiteralPath 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            $parts = @($current -split ';' | Where-Object { $_ })
            $newParts = @()
            foreach ($entry in @($spec.path)) {
                $e = ([string]$entry).Replace($spec.userProfile, $env:USERPROFILE)
                if ($parts -contains $e -or $newParts -contains $e) { continue }
                if (-not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($e)))) { continue }
                $newParts += $e
            }
            if ($newParts.Count -and -not $TestRun) {
                $value = (($parts + $newParts) -join ';')
                Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' -Value $value -Type ExpandString
            }
            return @{ Ok = $true; Detail = "$added variables and $($newParts.Count) PATH entries added (PATH entries whose folders don't exist yet were skipped)" }
        }
        'wifi' {
            $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.xml')
            if ($TestRun) { return @{ Ok = $true; Detail = "Would add $($files.Count) networks" } }
            foreach ($f in $files) { & netsh.exe wlan add profile filename="$($f.FullName)" user=all | Out-Null }
            return @{ Ok = $true; Detail = "$($files.Count) networks added" }
        }
        'drivers' {
            if ($TestRun) { return @{ Ok = $true; Detail = 'Would add all exported drivers' } }
            $tmp = Join-Path $env:TEMP 'WinPrestige-drivers'
            Invoke-WPRobocopy $dir $tmp | Out-Null
            & pnputil.exe /add-driver (Join-Path $tmp '*.inf') /subdirs /install | Out-Null
            return @{ Ok = $true; Detail = 'Drivers added (restart to finish)' }
        }
        'folder:*' {
            $name = $Extra.Id.Substring(7)
            $target = switch ($name) {
                'Desktop' { [Environment]::GetFolderPath('Desktop') }
                'Documents' { [Environment]::GetFolderPath('MyDocuments') }
                'Pictures' { [Environment]::GetFolderPath('MyPictures') }
                'Videos' { [Environment]::GetFolderPath('MyVideos') }
                'Music' { [Environment]::GetFolderPath('MyMusic') }
                'Downloads' { Get-WPDownloadsFolder }
            }
            if ($TestRun) { return @{ Ok = $true; Detail = "Would copy into $target (existing files are kept)" } }
            $code = Invoke-WPRobocopy $dir $target -OnlyMissing
            return @{ Ok = ($code -lt 8); Detail = "Copied into $target (existing files kept)" }
        }
    }
    return @{ Ok = $false; Detail = 'Unknown item' }
}

function Invoke-WPRestore {
    param([string]$BackupRoot, $Entries, $Configs, $Extras, $Dependencies, [hashtable]$Options)
    $root = $BackupRoot.TrimEnd('\')
    $test = [bool]$Options.TestRun
    $maxParallel = 1
    if ($Options.Parallel -and $Options.Silent -and -not $test) { $maxParallel = 3 }
    if ($test) { Write-WPLog 'Test run: nothing will be installed or changed.' 'step' }

    # Progress is saved after every app so a restart mid-restore can pick up where it left off.
    $progress = $null
    if (-not $test) {
        $done = @{}
        $selected = [ordered]@{
            apps = @($Entries | ForEach-Object { [string]$_.Key })
            configs = @($Configs | ForEach-Object { [string]$_.Id })
            extras = @($Extras | ForEach-Object { [string]$_.Id })
        }
        $started = (Get-Date).ToString('s')
        if ($Options.Progress) {
            $done = ConvertTo-WPHashtable $Options.Progress.done
            $selected = $Options.Progress.selected
            $started = [string]$Options.Progress.started
        }
        $total = @($selected.apps).Count + @($selected.configs).Count + @($selected.extras).Count
        $progress = [ordered]@{ backup = $root; computer = [string]$Options.Computer; started = $started; updated = ''; complete = $false; total = $total; selected = $selected; done = $done }
        Save-WPRestoreProgress $progress
    }

    $installed = $null
    if ($Options.SkipInstalled) {
        Write-WPLog 'Checking what is already installed...' 'step'
        $installed = Get-WPInstalledIndex
    }
    $depIndex = @{}
    foreach ($d in @($Dependencies)) { if ($d.WingetId) { $depIndex[[string]$d.WingetId] = $d } }
    $doneDeps = @{}
    $order = @{ runtimes = 0; drivers = 1; launchers = 2; apps = 3; store = 4; bundled = 5; games = 6; system = 7 }
    $list = @($Entries | Sort-Object { $order[[string]$_.Category] }, Name)
    $stats = @{ ok = 0; failed = 0; manual = 0; skipped = 0; finished = 0; total = $list.Count; restart = $false }

    $finish = {
        param($e, $r)
        $stats.finished++
        if ($r.Skipped) { $stats.skipped++; $lvl = 'info'; $mk = 'skipped' }
        elseif ($r.Ok) { $stats.ok++; $lvl = 'ok'; $mk = 'ok' }
        elseif ($r.Manual) { $stats.manual++; $lvl = 'warn'; $mk = 'manual' }
        else { $stats.failed++; $lvl = 'error'; $mk = 'failed' }
        if ([string]$r.Detail -like '*restart needed*') { $stats.restart = $true }
        Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = $r.Detail; Level = $lvl }
        Write-WPLog ("{0}: {1}" -f $e.Name, $r.Detail) $lvl
        Set-WPProgress $stats.finished $stats.total ("Installed {0} of {1}" -f $stats.finished, $stats.total)
        if ($progress) { $progress.done[[string]$e.Key] = $mk; Save-WPRestoreProgress $progress }
    }

    # Sort everything into lanes; skip what's already installed and what needs a manual download.
    $lanes = @{ parallel = New-Object System.Collections.Generic.List[object]; one = New-Object System.Collections.Generic.List[object]; msi = New-Object System.Collections.Generic.List[object] }
    foreach ($e in $list) {
        if (Test-WPCancel) { break }
        if ($Options.SkipInstalled -and (Test-WPInstalled $e $installed)) { & $finish $e @{ Skipped = $true; Detail = 'Already installed' }; continue }
        $lane = Get-WPInstallLane $e $Options
        if ($lane -eq 'manual') { & $finish $e (Install-WPEntry $e $root $Options $depIndex $doneDeps $installed); continue }
        if ($test) {
            $r = Install-WPEntry $e $root $Options $depIndex $doneDeps $installed
            $note = @{ parallel = 'alongside others'; one = 'on its own'; msi = 'on its own, at the end (MSI)' }[$lane]
            $r.Detail = "$($r.Detail) ($note)"
            & $finish $e $r
            continue
        }
        $lanes[$lane].Add($e)
    }

    if (-not $test -and -not (Test-WPCancel)) {
        # 1. Shared dependencies (e.g. .NET runtimes) before anything that needs them.
        $deps = @()
        foreach ($lane in @('parallel', 'one', 'msi')) {
            foreach ($e in $lanes[$lane]) { if ($e.Download -and $e.Download.Dependencies) { $deps += @($e.Download.Dependencies) } }
        }
        $deps = @($deps | Where-Object { $_ } | Select-Object -Unique)
        if ($deps.Count) {
            Write-WPLog ("Installing {0} shared dependencies first..." -f $deps.Count) 'step'
            foreach ($dep in $deps) {
                if (Test-WPCancel) { break }
                $doneDeps[$dep] = $true
                Install-WPDependency $dep $root $depIndex $installed
            }
        }

        # 2. Silent non-MSI installers, a few at a time. Failures get one more go on their own later.
        if ($lanes.parallel.Count -and -not (Test-WPCancel)) {
            Write-WPLog ("Installing {0} apps, up to {1} at a time..." -f $lanes.parallel.Count, $maxParallel) 'step'
            $queue = New-Object System.Collections.Queue
            foreach ($e in $lanes.parallel) { $queue.Enqueue($e) }
            $running = New-Object System.Collections.Generic.List[object]
            $retry = New-Object System.Collections.Generic.List[object]
            while ($queue.Count -gt 0 -or $running.Count -gt 0) {
                if (Test-WPCancel) {
                    foreach ($r in $running) { try { $r.Handle.Process.Kill() } catch { } }
                    break
                }
                while ($running.Count -lt $maxParallel -and $queue.Count -gt 0) {
                    $e = $queue.Dequeue()
                    Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = 'Installing...'; Level = 'step' }
                    $h = Start-WPLocalInstall $e.Download (Join-Path $root ("Installers\" + $e.Download.Folder))
                    if ($h.Done) {
                        if ($h.Ok) { & $finish $e @{ Ok = $true; Detail = $h.Detail } } else { $retry.Add($e) }
                        continue
                    }
                    $running.Add(@{ Entry = $e; Handle = $h })
                }
                Start-Sleep -Milliseconds 400
                foreach ($r in $running.ToArray()) {
                    if ($r.Handle.Process.HasExited) {
                        [void]$running.Remove($r)
                        $res = Complete-WPLocalInstall $r.Handle
                        if ($res.Ok) { & $finish $r.Entry $res } else { $retry.Add($r.Entry) }
                    } elseif (((Get-Date) - $r.Handle.Started).TotalMinutes -gt 60) {
                        [void]$running.Remove($r)
                        & $finish $r.Entry @{ Ok = $false; Detail = 'Installer is still running after an hour; moving on.' }
                    }
                }
            }
            foreach ($e in $retry) {
                Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = 'Will retry on its own'; Level = 'info' }
                $lanes.one.Insert(0, $e)
            }
        }

        # 3. Installers that need a window, winget and Store installs, and retries, one at a time.
        # 4. MSI-based installers last, one at a time.
        foreach ($lane in @('one', 'msi')) {
            if ($lane -eq 'msi' -and $lanes.msi.Count -and -not (Test-WPCancel)) { Write-WPLog ("Installing {0} MSI-based installers one at a time..." -f $lanes.msi.Count) 'step' }
            foreach ($e in $lanes[$lane]) {
                if (Test-WPCancel) { break }
                Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = 'Installing...'; Level = 'step' }
                $r = $null
                try { $r = Install-WPEntry $e $root $Options $depIndex $doneDeps $installed } catch { $r = @{ Ok = $false; Detail = $_.Exception.Message } }
                & $finish $e $r
            }
        }
    }

    if (-not (Test-WPCancel) -and @($Configs).Count) {
        Write-WPLog 'Putting app settings back...' 'step'
        foreach ($c in @($Configs)) {
            if (Test-WPCancel) { break }
            $folder = Join-Path $root ("Configs\" + $c.Folder)
            $script = Join-Path $folder 'Restore-Config.ps1'
            # Prefer this version's restore script over the copy saved in the backup, so older backups get fixes.
            $engine = Join-Path $script:WP.Root 'lib\Restore-Config.ps1'
            $key = 'config:' + $c.Id
            if (-not (Test-Path -LiteralPath (Join-Path $folder 'restore.json'))) {
                Send-WPMessage 'restoreItem' @{ Key = $key; Status = 'Missing from backup'; Level = 'error' }
                if ($progress) { $progress.done[$key] = 'failed'; Save-WPRestoreProgress $progress }
                continue
            }
            Send-WPMessage 'restoreItem' @{ Key = $key; Status = 'Restoring...'; Level = 'step' }
            try {
                if (Test-Path -LiteralPath $engine) { $out = & $engine -Folder $folder -TestRun:$test *>&1 | ForEach-Object { "$_" } }
                else { $out = & $script -TestRun:$test *>&1 | ForEach-Object { "$_" } }
                $last = @($out | Where-Object { $_.Trim() }) | Select-Object -Last 1
                # Restore-Config.ps1 ends with "Check <app>: ..." when its own verification found files that didn't land.
                $level = $(if ($last -and $last.Trim().StartsWith('Check ')) { 'warn' } else { 'ok' })
                Send-WPMessage 'restoreItem' @{ Key = $key; Status = $(if ($last) { $last.Trim() } else { 'Restored' }); Level = $level }
                foreach ($line in $out) { if ($line.Trim()) { Write-WPLog ("  " + $line.Trim()) 'info' } }
                if ($level -eq 'warn') { Write-WPLog ("{0} settings restored, but some files need a look (see above)" -f $c.Name) 'warn' }
                else { Write-WPLog ("{0} settings restored" -f $c.Name) 'ok' }
                if ($progress) { $progress.done[$key] = 'ok'; Save-WPRestoreProgress $progress }
            } catch {
                Send-WPMessage 'restoreItem' @{ Key = $key; Status = $_.Exception.Message; Level = 'error' }
                Write-WPLog ("{0} settings: {1}" -f $c.Name, $_.Exception.Message) 'error'
                if ($progress) { $progress.done[$key] = 'failed'; Save-WPRestoreProgress $progress }
            }
        }
    }

    if (-not (Test-WPCancel) -and @($Extras).Count) {
        Write-WPLog 'Restoring extras...' 'step'
        foreach ($x in @($Extras)) {
            if (Test-WPCancel) { break }
            $key = 'extra:' + $x.Id
            Send-WPMessage 'restoreItem' @{ Key = $key; Status = 'Restoring...'; Level = 'step' }
            try { $r = Restore-WPExtra $x $root -TestRun:$test } catch { $r = @{ Ok = $false; Detail = $_.Exception.Message } }
            Send-WPMessage 'restoreItem' @{ Key = $key; Status = $r.Detail; Level = $(if ($r.Ok) { 'ok' } else { 'error' }) }
            Write-WPLog ("{0}: {1}" -f $x.Name, $r.Detail) $(if ($r.Ok) { 'ok' } else { 'error' })
            if ($progress) { $progress.done[$key] = $(if ($r.Ok) { 'ok' } else { 'failed' }); Save-WPRestoreProgress $progress }
        }
    }

    $cancelled = Test-WPCancel
    if ($progress -and -not $cancelled) { Clear-WPRestoreProgress }
    Write-WPLog ("Done: {0} installed, {1} already there, {2} manual, {3} failed." -f $stats.ok, $stats.skipped, $stats.manual, $stats.failed) 'ok'
    if ($stats.failed -or $stats.manual) { Write-WPLog 'Use "Manual links" for the rest, then restart the PC.' 'info' }
    return @{ Ok = $stats.ok; Failed = $stats.failed; Manual = $stats.manual; Skipped = $stats.skipped; Complete = (-not $cancelled); RestartNeeded = $stats.restart }
}

#endregion
