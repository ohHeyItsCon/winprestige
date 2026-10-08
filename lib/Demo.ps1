#Requires -Version 5.1
<#
  Demo mode (WinPrestige.exe -Demo): a made-up PC full of well-known apps, for screenshots
  and videos. Nothing on the real PC is read or changed; backup and restore are simulated
  with the same progress messages the real ones send.
#>

$script:WPDemoUser = 'C:\Users\Alex'

function ConvertTo-WPDemoPath {
    param([string]$TokenPath)
    $map = [ordered]@{
        '%LOCALAPPDATA%' = "$script:WPDemoUser\AppData\Local"
        '%APPDATA%' = "$script:WPDemoUser\AppData\Roaming"
        '%DOCUMENTS%' = "$script:WPDemoUser\OneDrive\Documents"
        '%PICTURES%' = "$script:WPDemoUser\OneDrive\Pictures"
        '%VIDEOS%' = "$script:WPDemoUser\Videos"
        '%USERPROFILE%' = $script:WPDemoUser
        '%PROGRAMDATA%' = 'C:\ProgramData'
        '%PROGRAMFILES(X86)%' = 'C:\Program Files (x86)'
        '%PROGRAMFILES%' = 'C:\Program Files'
        '%INSTALLDIR%' = 'C:\Program Files (x86)\FanControl'
    }
    $p = $TokenPath
    foreach ($k in $map.Keys) { $p = $p.Replace($k, $map[$k]) }
    return $p
}

function New-WPDemoApp {
    param(
        [string]$Name, [string]$Version, [string]$Publisher, [string]$Category,
        [string]$Id = '', [string]$Source = 'winget', [string]$Latest = '', [string]$Match = '',
        [string]$Via = '', [string]$GameUri = '', [string]$Pfn = '', [string]$Url = '', [string]$Location = '',
        [object[]]$Candidates = @(), [switch]$LauncherGame
    )
    $a = New-WPApp
    $a.Name = $Name
    $a.Version = $Version
    $a.Latest = $(if ($Latest) { $Latest } else { $Version })
    $a.Publisher = $Publisher
    $a.Category = $Category
    $a.Via = $Via
    $a.GameUri = $GameUri
    $a.Url = $Url
    $a.InstallLocation = $Location
    $a.LauncherGame = [bool]$LauncherGame
    $a.Candidates = @($Candidates)
    if ($Id -and -not $Match) {
        $a.Kind = 'winget'; $a.WingetId = $Id; $a.Source = $Source; $a.Match = 'installed'; $a.Key = $Id
        $a.ArpId = $Id
    } else {
        $a.WingetId = $Id
        if ($Id) { $a.Source = $Source }
        $a.Match = $Match
        if ($Pfn) {
            $a.Kind = 'msix'; $a.Pfn = $Pfn; $a.Key = 'msix:' + $Pfn.ToLowerInvariant(); $a.ArpId = 'MSIX\' + $Pfn
        } else {
            $a.Kind = 'arp'; $a.Key = 'arp:' + (Get-WPNormName $Name); $a.ArpId = "ARP\Machine\X64\$Name"
        }
    }
    return $a
}

function Get-WPDemoApps {
    param([switch]$Quiet)
    if (-not $Quiet) {
        Write-WPLog 'Reading installed programs from the registry...' 'step'
        Start-Sleep -Milliseconds 500
        Write-WPLog 'Asking winget which programs it recognises...' 'step'
        Start-Sleep -Milliseconds 900
    }
    $u = $script:WPDemoUser
    $apps = @(
        New-WPDemoApp 'Google Chrome' '141.0.7390.66' 'Google LLC' 'apps' 'Google.Chrome' -Location 'C:\Program Files\Google\Chrome\Application'
        New-WPDemoApp 'Discord' '1.0.9261' 'Discord Inc.' 'apps' 'Discord.Discord' -Match 'search' -Location "$u\AppData\Local\Discord"
        New-WPDemoApp 'Spotify' '1.2.92.148' 'Spotify AB' 'apps' 'Spotify.Spotify' -Latest '1.3.3.264'
        New-WPDemoApp 'OBS Studio' '32.1.2' 'OBS Project' 'apps' 'OBSProject.OBSStudio' -Latest '32.2.2' -Location 'C:\Program Files\obs-studio'
        New-WPDemoApp 'VLC media player' '3.0.23' 'VideoLAN' 'apps' 'VideoLAN.VLC'
        New-WPDemoApp '7-Zip 25.01 (x64)' '25.01' 'Igor Pavlov' 'apps' '7zip.7zip'
        New-WPDemoApp 'Microsoft Visual Studio Code' '1.105.1' 'Microsoft Corporation' 'apps' 'Microsoft.VisualStudioCode'
        New-WPDemoApp 'Notepad++ (64-bit x64)' '8.8.6' 'Notepad++ Team' 'apps' 'Notepad++.Notepad++'
        New-WPDemoApp 'Elgato Stream Deck' '7.4.2' 'Corsair Memory, Inc.' 'apps' 'Elgato.StreamDeck' -Latest '7.6.0'
        New-WPDemoApp 'Elgato Wave Link' '3.2.10' 'Corsair Memory, Inc.' 'apps' 'Elgato.WaveLink'
        New-WPDemoApp 'Elgato Camera Hub' '2.1.0' 'Corsair Memory, Inc.' 'apps' 'Elgato.CameraHub'
        New-WPDemoApp 'Elgato 4K Capture Utility' '1.7.15' 'Corsair Memory, Inc.' 'apps' 'Elgato.4KCaptureUtility'
        New-WPDemoApp 'Corsair iCUE5 Software' '5.46.67' 'Corsair' 'apps' 'Corsair.iCUE.5' -Latest '5.52.93'
        New-WPDemoApp 'Logitech G HUB' '2026.6.98' 'Logitech' 'apps' 'Logitech.GHUB'
        New-WPDemoApp 'SteelSeries GG 121.0.0' '121.0.0' 'SteelSeries ApS' 'apps' 'SteelSeries.GG'
        New-WPDemoApp 'FanControl' '282' 'Remi Mercier Software Inc' 'apps' 'Rem0o.FanControl' -Location 'C:\Program Files (x86)\FanControl'
        New-WPDemoApp 'MSI Afterburner 4.6.6' '4.6.6' 'MSI Co., LTD' 'apps' 'Guru3D.Afterburner'
        New-WPDemoApp 'ShareX' '18.0.1' 'ShareX Team' 'apps' 'ShareX.ShareX'
        New-WPDemoApp 'PowerToys (Preview) x64' '0.95.1' 'Microsoft Corporation' 'apps' 'Microsoft.PowerToys'
        New-WPDemoApp 'Everything 1.4.1.1028 (x64)' '1.4.1.1028' 'voidtools' 'apps' 'voidtools.Everything'
        New-WPDemoApp 'qBittorrent' '5.1.2' 'The qBittorrent project' 'apps' 'qBittorrent.qBittorrent'
        New-WPDemoApp 'HandBrake 1.10.2' '1.10.2' 'HandBrake Team' 'apps' 'HandBrake.HandBrake'
        New-WPDemoApp 'Audacity 3.7.5' '3.7.5' 'Audacity Team' 'apps' 'Audacity.Audacity'
        New-WPDemoApp 'Blender' '4.5.3' 'Blender Foundation' 'apps' 'BlenderFoundation.Blender'
        New-WPDemoApp 'Git' '2.51.0' 'The Git Development Community' 'apps' 'Git.Git'
        New-WPDemoApp 'Python 3.13.7 (64-bit)' '3.13.7' 'Python Software Foundation' 'apps' 'Python.Python.3.13'
        New-WPDemoApp 'Node.js' '22.20.0' 'Node.js Foundation' 'apps' 'OpenJS.NodeJS.LTS'
        New-WPDemoApp 'Visual Studio Community 2022' '17.14.33' 'Microsoft Corporation' 'apps' 'Microsoft.VisualStudio.2022.Community' -Latest '17.14.41'
        New-WPDemoApp 'Windows Terminal' '1.24.12741.0' 'Microsoft Corporation' 'apps' 'Microsoft.WindowsTerminal'
        New-WPDemoApp 'Zoom Workplace' '6.6.0' 'Zoom Communications, Inc.' 'apps' 'Zoom.Zoom'
        New-WPDemoApp 'Telegram Desktop' '6.1.3' 'Telegram FZ-LLC' 'apps' 'Telegram.TelegramDesktop'
        New-WPDemoApp 'Voicemeeter Banana' '2.1.1.9' 'VB-Audio Software' 'apps' 'VB-Audio.Voicemeeter.Banana'
        New-WPDemoApp 'Medal' '2622.204.1' 'Medal B.V.' 'apps' 'MedalB.V.Medal'
        New-WPDemoApp 'Parsec' '150.97' 'Parsec Cloud, Inc.' 'apps' 'Parsec.Parsec'
        New-WPDemoApp 'Mozilla Firefox (x64 en-US)' '144.0' 'Mozilla' 'apps' 'Mozilla.Firefox' -Match 'search' -Url 'https://www.mozilla.org'
        New-WPDemoApp 'Brave' '1.83.118' 'Brave Software Inc' 'apps' 'Brave.Brave'
        New-WPDemoApp 'WinRAR 7.13 (64-bit)' '7.13' 'win.rar GmbH' 'apps' 'RARLab.WinRAR'
        New-WPDemoApp 'Rainmeter' '4.5.23' 'Rainmeter' 'apps' 'Rainmeter.Rainmeter'
        New-WPDemoApp 'Revo Uninstaller 2.6.0' '2.6.0' 'VS Revo Group, Ltd.' 'apps' 'RevoUninstaller.RevoUninstaller'
        New-WPDemoApp 'CPUID CPU-Z 2.17' '2.17' 'CPUID, Inc.' 'apps' 'CPUID.CPU-Z'
        New-WPDemoApp 'Malwarebytes version 5.3.9' '5.3.9' 'Malwarebytes' 'apps' 'Malwarebytes.Malwarebytes'
        New-WPDemoApp 'NordVPN' '8.12.0.0' 'Nord Security' 'apps' 'NordSecurity.NordVPN'
        New-WPDemoApp 'NVIDIA App 11.0.9.251' '11.0.9.251' 'NVIDIA Corporation' 'apps' 'XP8CLZL93F5Z4P' -Source 'msstore' -Match 'search'
        New-WPDemoApp 'Streamer.bot' '1.0.1' 'Streamer.bot' 'apps' -Match 'manual' -Url 'https://streamer.bot'
        New-WPDemoApp 'Razer Synapse' '4.0.598' 'Razer Inc.' 'apps' -Match 'manual' -Url 'https://www.razer.com/synapse-4'
        New-WPDemoApp 'Equalizer APO' '1.4.2' '' 'apps' -Match 'manual' -Url 'https://sourceforge.net/projects/equalizerapo/' -Candidates @(@{ Name = 'Equalizer APO - 3D SoundFx'; Id = '9MV49Z407RH6'; Source = 'msstore' })

        New-WPDemoApp 'Steam' '2.10.91.91' 'Valve Corporation' 'launchers' 'Valve.Steam'
        New-WPDemoApp 'Epic Games Launcher' '1.3.142.0' 'Epic Games, Inc.' 'launchers' 'EpicGames.EpicGamesLauncher' -Latest '1.3.210.0'
        New-WPDemoApp 'Battle.net' '2.40.0' 'Blizzard Entertainment' 'launchers' 'Blizzard.BattleNet'
        New-WPDemoApp 'EA app' '13.512.0' 'Electronic Arts' 'launchers' 'ElectronicArts.EADesktop'
        New-WPDemoApp 'Ubisoft Connect' '174.1.0' 'Ubisoft' 'launchers' 'Ubisoft.Connect'
        New-WPDemoApp 'VALORANT' '' 'Riot Games, Inc' 'launchers' 'RiotGames.Valorant.NA' -Match 'search' -LauncherGame -Location 'C:\Riot Games\VALORANT\live'
        New-WPDemoApp 'League of Legends' '' 'Riot Games, Inc' 'launchers' 'RiotGames.LeagueOfLegends.NA' -Match 'search' -LauncherGame -Location 'C:\Riot Games\League of Legends'
        New-WPDemoApp 'Minecraft Launcher' '2.6.2.0' 'Microsoft Studios' 'launchers' -Match 'manual' -Pfn 'Microsoft.4297127D64EC6_8wekyb3d8bbwe' -LauncherGame
        New-WPDemoApp 'Prism Launcher' '9.4' 'Prism Launcher Contributors' 'launchers' 'PrismLauncher.PrismLauncher'
        New-WPDemoApp 'Modrinth App' '0.21.4' 'Modrinth' 'launchers' 'Modrinth.ModrinthApp'

        New-WPDemoApp 'HWiNFO 64' '8.50' 'Martin Malik - REALiX' 'store' 'XP9CS6FHQ00B8J' -Source 'msstore'
        New-WPDemoApp 'WhatsApp' '2.2546.3.0' 'WhatsApp Inc.' 'store' '9NKSQGP7F2NH' -Source 'msstore' -Match 'search' -Pfn '5319275A.WhatsAppDesktop_cv1g1gvanyjgm'
        New-WPDemoApp 'Netflix' '6.99.5' 'Netflix, Inc.' 'store' '9WZDNCRFJ3TJ' -Source 'msstore' -Match 'search' -Pfn '4DF9E0F8.Netflix_mcm4njqhnhss8'
        New-WPDemoApp 'TranslucentTB' '2025.1' 'Charles Milette' 'store' '9PF4KZ2VN4W9' -Source 'msstore' -Match 'search' -Pfn '28017CharlesMilette.TranslucentTB_v826wp6bftszj'
        New-WPDemoApp 'Dolby Access' '3.27.12250.0' 'Dolby Laboratories' 'store' -Match 'manual' -Pfn 'DolbyLaboratories.DolbyAccess_rz1tebttyb220'
        New-WPDemoApp 'iCloud' '15.10.39.0' 'Apple Inc.' 'store' -Match 'manual' -Pfn 'AppleInc.iCloud_nzyj5cx40ttqa'
        New-WPDemoApp 'Apple Music' '1.1540.23042.0' 'Apple Inc.' 'store' -Match 'manual' -Pfn 'AppleInc.AppleMusicWin_nzyj5cx40ttqa'

        New-WPDemoApp 'NVIDIA Graphics Driver 581.57' '581.57' 'NVIDIA Corporation' 'drivers'
        New-WPDemoApp 'NVIDIA HD Audio Driver 1.4.5.6' '1.4.5.6' 'NVIDIA Corporation' 'drivers'
        New-WPDemoApp 'Realtek Audio Driver' '6.0.9918.1' 'Realtek Semiconductor Corp.' 'drivers'
        New-WPDemoApp 'Realtek Ethernet Controller Driver' '10.79.50.1003' 'Realtek' 'drivers'
        New-WPDemoApp 'AMD Chipset Software' '7.06.02.123' 'Advanced Micro Devices, Inc.' 'drivers'
        New-WPDemoApp 'Intel(R) Wireless Bluetooth(R)' '23.160.0.3' 'Intel Corporation' 'drivers'

        New-WPDemoApp 'Microsoft Visual C++ v14 Redistributable (x64) - 14.44.35211' '14.44.35211.0' 'Microsoft Corporation' 'runtimes' 'Microsoft.VCRedist.2015+.x64'
        New-WPDemoApp 'Microsoft Visual C++ v14 Redistributable (x86) - 14.44.35211' '14.44.35211.0' 'Microsoft Corporation' 'runtimes' 'Microsoft.VCRedist.2015+.x86'
        New-WPDemoApp 'Microsoft Windows Desktop Runtime - 8.0.20 (x64)' '8.0.20' 'Microsoft Corporation' 'runtimes' 'Microsoft.DotNet.DesktopRuntime.8'
        New-WPDemoApp 'Microsoft Windows Desktop Runtime - 9.0.9 (x64)' '9.0.9' 'Microsoft Corporation' 'runtimes' 'Microsoft.DotNet.DesktopRuntime.9'
        New-WPDemoApp 'DirectX' '9.29.1974.0' 'Microsoft Corporation' 'runtimes' 'Microsoft.DirectX'
        New-WPDemoApp 'Java 8 Update 461 (64-bit)' '8.0.4610.11' 'Oracle Corporation' 'runtimes' 'Oracle.JavaRuntimeEnvironment'
        New-WPDemoApp 'NVIDIA PhysX System Software 9.23.1019' '9.23.1019' 'NVIDIA Corporation' 'runtimes' 'Nvidia.PhysX'

        New-WPDemoApp 'Riot Vanguard' '' 'Riot Games, Inc.' 'bundled' -Via 'VALORANT / League of Legends'
        New-WPDemoApp 'Riot Client' '' 'Riot Games, Inc' 'bundled' -Via 'VALORANT / League of Legends'
        New-WPDemoApp 'Epic Online Services' '2.0.44.0' 'Epic Games, Inc.' 'bundled' 'EpicGames.EpicOnlineServices' -Via 'Epic Games Launcher'
        New-WPDemoApp 'Mozilla Maintenance Service' '144.0' 'Mozilla' 'bundled' -Via 'Firefox'
        New-WPDemoApp 'Microsoft Visual Studio Installer' '3.14.2086.54749' 'Microsoft Corporation' 'bundled' -Via 'Visual Studio'
        New-WPDemoApp 'Elgato Wave Link Driver' '3.0.0.466' 'Corsair Memory, Inc.' 'bundled' -Via 'Elgato Wave Link'
    )
    $steam = @(
        @('Counter-Strike 2', '730'), @('Rocket League', '252950'), @('Apex Legends', '1172470'), @("Baldur's Gate 3", '1086940'),
        @('Stardew Valley', '413150'), @('ELDEN RING', '1245620'), @('Cyberpunk 2077', '1091500'), @('HELLDIVERS 2', '553850'),
        @('Lethal Company', '1966720'), @('Satisfactory', '526870'), @('Marvel Rivals', '2767030'), @('PEAK', '3527290'),
        @('R.E.P.O.', '3241660'), @('Phasmophobia', '739630'), @('Wallpaper Engine', '431960')
    )
    foreach ($g in $steam) {
        $apps += New-WPDemoApp $g[0] '' 'Steam' 'games' -Via 'Steam' -GameUri "steam://install/$($g[1])" -Location "D:\SteamLibrary\steamapps\common\$($g[0])"
    }
    $apps += New-WPDemoApp 'Fortnite' '' 'Epic Games, Inc.' 'games' -Via 'Epic Games'
    $apps += New-WPDemoApp 'Overwatch' '' 'Blizzard Entertainment' 'games' -Via 'Battle.net'
    foreach ($s in @('Microsoft Edge', 'Microsoft Store', 'Windows Calculator', 'Snipping Tool', 'Microsoft OneDrive', 'Game Bar', 'Windows Notepad', 'Phone Link', 'Microsoft Photos', 'Windows Security')) {
        $apps += New-WPDemoApp $s '' 'Microsoft Corporation' 'system'
    }
    foreach ($a in $apps) { Set-WPDefaultSelection $a @{} }
    if (-not $Quiet) { Write-WPLog ("Found {0} installed items." -f $apps.Count) 'ok' }
    return $apps
}

function Get-WPDemoConfigs {
    param([switch]$Quiet)
    if (-not $Quiet) { Write-WPLog 'Looking for app settings to back up...' 'step' }
    $defs = @(
        @('obs', 'OBS Studio', @('%APPDATA%\obs-studio', '%PROGRAMDATA%\obs-studio\plugins'), 132120576, 531, @(), @(), $false),
        @('obs-media', 'OBS Studio - media used in scenes', @('%VIDEOS%\Stream\intro.webm', '%VIDEOS%\Stream\brb-loop.mp4', '%PICTURES%\Overlays'), 358612992, 18, @(), @(), $false),
        @('fancontrol', 'FanControl', @('%INSTALLDIR%\Configurations', '%INSTALLDIR%\Plugins'), 22528, 4, @(), @(), $false),
        @('streamdeck', 'Elgato Stream Deck', @('%APPDATA%\Elgato\StreamDeck'), 113246208, 3871, @('HKCU\Software\Elgato Systems GmbH\StreamDeck'), @('StreamDeck'), $false),
        @('wavelink', 'Elgato Wave Link', @('%APPDATA%\Elgato\WaveLink'), 161792, 13, @(), @(), $false),
        @('icue', 'Corsair iCUE', @('%APPDATA%\Corsair\CUE5'), 697344, 41, @(), @('iCUE'), $false),
        @('ghub', 'Logitech G HUB', @('%LOCALAPPDATA%\LGHUB'), 12582912, 40, @(), @(), $false),
        @('steelseries', 'SteelSeries GG', @('%PROGRAMDATA%\SteelSeries\GG'), 74448896, 293, @(), @(), $false),
        @('afterburner', 'MSI Afterburner', @('%PROGRAMFILES(X86)%\MSI Afterburner\Profiles'), 18432, 6, @(), @(), $false),
        @('vscode', 'VS Code', @('%APPDATA%\Code\User'), 2202009, 64, @(), @(), $false),
        @('terminal', 'Windows Terminal', @('%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'), 9216, 1, @(), @(), $false),
        @('powertoys', 'PowerToys', @('%LOCALAPPDATA%\Microsoft\PowerToys'), 45056, 57, @(), @(), $false),
        @('sharex', 'ShareX', @('%DOCUMENTS%\ShareX'), 3145728, 12, @(), @(), $false),
        @('everything', 'Everything', @('%APPDATA%\Everything'), 41984, 3, @(), @(), $false),
        @('rainmeter', 'Rainmeter', @('%APPDATA%\Rainmeter', '%DOCUMENTS%\Rainmeter\Skins'), 39845888, 812, @(), @(), $false),
        @('bakkesmod', 'BakkesMod', @('%APPDATA%\bakkesmod\bakkesmod'), 81788928, 206, @(), @(), $false),
        @('minecraft', 'Minecraft worlds & settings', @('%APPDATA%\.minecraft'), 2469606195, 18422, @(), @(), $false),
        @('prism', 'Prism Launcher instances', @('%APPDATA%\PrismLauncher'), 7301444403, 41207, @(), @(), $false),
        @('firefox', 'Firefox profile', @('%APPDATA%\Mozilla\Firefox'), 299892736, 2572, @(), @(), $true),
        @('ssh', 'SSH keys', @('%USERPROFILE%\.ssh'), 4096, 4, @(), @(), $true),
        @('git', 'Git config', @('%USERPROFILE%\.gitconfig'), 1024, 1, @(), @(), $false),
        @('7zip', '7-Zip settings', @(), 0, 0, @('HKCU\Software\7-Zip'), @(), $false)
    )
    $list = @()
    foreach ($d in $defs) {
        $c = New-WPConfig $d[0] $d[1]
        $prof = $script:WP.Profiles | Where-Object { $_.id -eq $d[0] } | Select-Object -First 1
        $c.Items = @(foreach ($t in $d[2]) {
                [pscustomobject]@{ Source = (ConvertTo-WPDemoPath $t); Target = $t; Type = $(if ($t -match '\.\w{2,5}$') { 'file' } else { 'dir' }); Include = @(); Exclude = @() }
            })
        $c.Bytes = [long]$d[3]
        $c.Files = [int]$d[4]
        $c.Registry = @($d[5])
        $c.Running = @($d[6])
        $c.Sensitive = [bool]$d[7]
        if ($prof) { $c.Notes = [string]$prof.notes; $c.Processes = @($prof.processes) }
        if ($d[0] -eq 'obs-media') { $c.Notes = 'Images, videos and sounds your scenes use, put back at the same paths (3 files or folders).' }
        $c.Selected = (-not $c.Sensitive) -and $c.Bytes -lt 1GB
        $c | Add-Member -NotePropertyName SizeChecked -NotePropertyValue $true -Force
        $list += $c
    }
    if (-not $Quiet) { Write-WPLog ("Found settings for {0} apps." -f $list.Count) 'ok' }
    return $list
}

function Get-WPDemoExtras {
    $u = $script:WPDemoUser
    $list = @()
    $e = New-WPExtra 'fonts' 'Fonts you installed' 'Fonts that did not come with Windows. Restored for all users.'
    $e.Selected = $true; $e.Bytes = 41943040; $e.Info = '37 fonts'
    $list += $e
    $e = New-WPExtra 'envvars' 'Environment variables' 'Your user PATH entries and custom variables (for dev tools and scripts).'
    $e.Selected = $true; $e.Bytes = 0; $e.Info = 'Small'
    $list += $e
    $e = New-WPExtra 'wifi' 'Wi-Fi networks' 'Saved networks and their passwords, stored as plain text in the backup.'
    $e.Sensitive = $true; $e.Bytes = 0; $e.Info = '3 networks'
    $list += $e
    $e = New-WPExtra 'drivers' 'Third-party drivers' 'Exports every non-Microsoft driver so network or audio works before you can reach the internet. Usually 1-4 GB.'
    $e.Info = 'Exported at backup time'
    $list += $e
    foreach ($f in @(
            @('Desktop', "$u\OneDrive\Desktop", $true, 1288490188, 214),
            @('Documents', "$u\OneDrive\Documents", $true, 9019431321, 3815),
            @('Pictures', "$u\OneDrive\Pictures", $true, 24803282329, 11408),
            @('Videos', "$u\Videos", $false, 126701535232, 1342),
            @('Music', "$u\Music", $false, 4509715660, 2210),
            @('Downloads', "$u\Downloads", $false, 17931236147, 487))) {
        $x = New-WPExtra ('folder:' + $f[0]) "$($f[0]) folder" $f[1]
        $x.Data = [pscustomobject]@{ Id = $f[0]; Path = $f[1]; OneDrive = $f[2] }
        $x.Bytes = [long]$f[3]
        $x.Info = "{0} - {1:N0} files" -f (Format-WPSize $f[3]), $f[4]
        if ($f[2]) { $x.Info += ' - synced by OneDrive'; $x.Description = "$($f[1]) (already synced by OneDrive)" }
        $list += $x
    }
    return $list
}

function New-WPDemoEntry {
    # The manifest entry the real backup writes for one app.
    param($App, [hashtable]$Download)
    $entry = [ordered]@{
        Key = $App.Key; Name = $App.Name; Version = $App.Version; Publisher = $App.Publisher
        Category = $App.Category; Via = $App.Via; Selected = [bool]$App.Selected
        WingetId = $App.WingetId; Source = $App.Source; Match = $App.Match; Pfn = $App.Pfn
        Url = $App.Url; CustomUrl = $App.CustomUrl; GameUri = $App.GameUri; LauncherGame = [bool]$App.LauncherGame
        Download = $Download; Method = ''
    }
    $entry.Method = Get-WPMethod ([pscustomobject]$entry)
    return $entry
}

function New-WPDemoDownload {
    param($App, [string]$Status = 'Downloaded', [long]$Bytes = 52428800)
    $clean = Get-WPSafeName (Get-WPCleanName $App.Name)
    return @{
        Status = $Status; Folder = $clean; WingetId = $App.WingetId; Version = $App.Latest
        Installer = ('{0}_{1}_X64_exe_en-US.exe' -f ($clean -replace ' ', '_'), $App.Latest); Bytes = $Bytes
        Type = 'exe'; Silent = '/S'; Dependencies = @(); Codes = @{}; Date = (Get-Date).ToString('yyyy-MM-dd')
    }
}

function Invoke-WPDemoBackup {
    param($Apps, $Configs, $Extras, [string]$Destination, [hashtable]$Options)
    $rand = New-Object Random 11
    $sel = @($Apps | Where-Object { $_.Selected })
    Write-WPLog ("Backing up {0} selected apps to {1}" -f $sel.Count, $Destination) 'step'
    $toDownload = @($sel | Where-Object { ($_.WingetId -and $_.Source -eq 'winget') -or $_.CustomUrl })
    $entries = @()
    $n = 0
    $failName = 'Blender'
    foreach ($app in $Apps) {
        if (Test-WPCancel) { break }
        $dl = $null
        if ($app.Selected -and (($app.WingetId -and $app.Source -eq 'winget') -or $app.CustomUrl)) {
            $n++
            Set-WPProgress $n $toDownload.Count ("Downloading {0}" -f (Get-WPCleanName $app.Name))
            $app.Status = 'Downloading'; Send-WPMessage 'app' @{ Key = $app.Key }
            Start-Sleep -Milliseconds (110 + $rand.Next(260))
            $bytes = [long](3 + $rand.Next(190)) * 1MB
            if ($app.Name -eq $failName) {
                $app.Status = 'Failed'
                $app.Detail = 'Installer hash mismatch: the vendor changed the file since winget last checked. Restore will install it online instead.'
                Write-WPLog ("{0}: {1}" -f $app.Name, $app.Detail) 'error'
                $dl = @{ Status = 'Failed'; Error = $app.Detail; WingetId = $app.WingetId }
            } elseif ($rand.Next(5) -eq 0 -and $app.Latest -eq $app.Version) {
                $app.Status = 'Up to date'; $app.Detail = ''
                $dl = New-WPDemoDownload $app 'Up to date' $bytes
                Write-WPLog ("{0} is already current ({1})" -f (Get-WPCleanName $app.Name), $app.Latest) 'info'
            } else {
                $app.Status = 'Downloaded'; $app.Detail = ''
                $dl = New-WPDemoDownload $app 'Downloaded' $bytes
                Write-WPLog ("Downloaded {0} {1} ({2})" -f (Get-WPCleanName $app.Name), $app.Latest, (Format-WPSize $bytes)) 'ok'
            }
            Send-WPMessage 'app' @{ Key = $app.Key }
        }
        $entries += New-WPDemoEntry $app $dl
    }
    if (-not (Test-WPCancel)) {
        Write-WPLog 'Downloading 2 shared dependencies...' 'step'
        Start-Sleep -Milliseconds 700
    }
    $configEntries = @()
    $selConfigs = @($Configs | Where-Object { $_.Selected })
    if ($Options.Configs -and -not (Test-WPCancel)) {
        Write-WPLog ("Copying settings for {0} apps..." -f $selConfigs.Count) 'step'
        $i = 0
        foreach ($c in $selConfigs) {
            if (Test-WPCancel) { break }
            $i++
            Set-WPProgress $i $selConfigs.Count ("Copying {0} settings" -f $c.Name)
            $c.Status = 'Copying'; Send-WPMessage 'config' @{ Id = $c.Id }
            Start-Sleep -Milliseconds (150 + $rand.Next(300))
            $c.Status = 'Saved'; $c.Detail = ''; $c.Running = @()
            Send-WPMessage 'config' @{ Id = $c.Id }
            $msg = "{0}: Saved" -f $c.Name
            if ($c.Bytes -gt 0) { $msg += " ($(Format-WPSize $c.Bytes))" }
            Write-WPLog $msg 'ok'
            $configEntries += [ordered]@{ Id = $c.Id; Name = $c.Name; App = $c.App; Folder = (Get-WPSafeName $c.Name); Status = 'Saved'; Detail = ''; Bytes = $c.Bytes; Notes = $c.Notes; Sensitive = [bool]$c.Sensitive }
        }
    }
    $extraEntries = @()
    if ($Options.Extras -and -not (Test-WPCancel)) {
        Write-WPLog 'Saving extras...' 'step'
        foreach ($e in @($Extras | Where-Object { $_.Selected -and $_.Available })) {
            Start-Sleep -Milliseconds 400
            $e.Status = 'Saved'
            $e.Detail = switch -Wildcard ($e.Id) { 'fonts' { '37 fonts' } 'envvars' { '4 variables, 9 PATH entries' } 'wifi' { '3 networks' } default { '' } }
            Send-WPMessage 'extra' @{ Id = $e.Id }
            Write-WPLog ("{0}: Saved{1}" -f $e.Name, $(if ($e.Detail) { " - $($e.Detail)" } else { '' })) 'ok'
            $extraEntries += [ordered]@{ Id = $e.Id; Name = $e.Name; Folder = $e.Id; Status = 'Saved'; Detail = $e.Detail }
        }
    }
    if (Test-WPCancel) {
        Write-WPLog 'Backup cancelled. Nothing was pruned and the previous manifest was left in place.' 'warn'
        return @{ Cancelled = $true }
    }
    if ($Options.Prune) {
        Write-WPLog 'Removed old installer for Skype' 'info'
        Write-WPLog 'Removed old installer for CCleaner' 'info'
    }
    $manifest = [ordered]@{
        tool = 'WinPrestige'; version = $script:WP.Version; created = (Get-Date).ToString('s')
        computer = 'ALEX-PC'; user = 'Alex'; userProfile = $script:WPDemoUser; windows = 'Microsoft Windows 11 Pro'
        apps = @($entries); dependencies = @(); configs = @($configEntries); extras = @($extraEntries)
        added = @('Telegram Desktop', 'Parsec'); removed = @('Skype (uninstalled)', 'CCleaner (uninstalled)')
    }
    $reportDir = Join-Path $env:TEMP 'WinPrestige-demo'
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    Export-WPReport $manifest $reportDir
    Write-WPLog ("Backup finished in 03:42. Report: {0}" -f (Join-Path $Destination 'AppInventory.html')) 'ok'
    return @{ Cancelled = $false; Failed = 1; Report = (Join-Path $reportDir 'AppInventory.html'); Destination = $Destination; Added = @(); Removed = @() }
}

function Get-WPDemoManifest {
    # What the Restore tab shows in demo mode: yesterday's backup of the demo PC.
    $apps = @(Get-WPDemoApps -Quiet)
    $entries = @()
    foreach ($a in $apps) {
        $dl = $null
        if ($a.Selected -and $a.WingetId -and $a.Source -eq 'winget') {
            if ($a.Name -eq 'Blender') { $dl = @{ Status = 'Failed'; Error = 'Installer hash mismatch'; WingetId = $a.WingetId } }
            else { $dl = New-WPDemoDownload $a 'Downloaded' }
        }
        $entries += New-WPDemoEntry $a $dl
    }
    $configs = @()
    foreach ($c in @(Get-WPDemoConfigs -Quiet | Where-Object { $_.Selected })) {
        $configs += [ordered]@{ Id = $c.Id; Name = $c.Name; Folder = (Get-WPSafeName $c.Name); Status = 'Saved'; Detail = ''; Bytes = $c.Bytes; Notes = $c.Notes }
    }
    $extras = @(
        [ordered]@{ Id = 'fonts'; Name = 'Fonts you installed'; Folder = 'Fonts'; Status = 'Saved'; Detail = '37 fonts' },
        [ordered]@{ Id = 'envvars'; Name = 'Environment variables'; Folder = 'Environment'; Status = 'Saved'; Detail = '4 variables, 9 PATH entries' }
    )
    $m = [ordered]@{
        tool = 'WinPrestige'; version = $script:WP.Version; created = (Get-Date).AddDays(-1).ToString('s')
        computer = 'ALEX-PC'; user = 'Alex'; userProfile = $script:WPDemoUser; windows = 'Microsoft Windows 11 Pro'
        apps = @($entries); dependencies = @(); configs = @($configs); extras = @($extras); added = @(); removed = @()
    }
    return ((ConvertTo-Json -InputObject $m -Depth 10) | ConvertFrom-Json)
}

function Invoke-WPDemoRestore {
    param([string]$BackupRoot, $Entries, $Configs, $Extras, $Dependencies, [hashtable]$Options)
    $rand = New-Object Random 5
    $test = [bool]$Options.TestRun
    if ($test) { Write-WPLog 'Test run: nothing will be installed or changed.' 'step' }
    Write-WPLog 'Checking what is already installed...' 'step'
    Start-Sleep -Milliseconds 900
    $order = @{ runtimes = 0; drivers = 1; launchers = 2; apps = 3; store = 4; bundled = 5 }
    $list = @($Entries | Sort-Object { $order[[string]$_.Category] }, Name)
    $ok = 0; $manual = 0; $skipped = 0; $i = 0
    Write-WPLog ("Installing {0} apps..." -f $list.Count) 'step'
    foreach ($e in $list) {
        if (Test-WPCancel) { Write-WPLog 'Restore cancelled.' 'warn'; break }
        $i++
        Set-WPProgress $i $list.Count ("Installing {0}" -f (Get-WPCleanName $e.Name))
        if ($e.Name -eq 'Windows Terminal' -and $Options.SkipInstalled) {
            $skipped++
            Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = 'Already installed'; Level = 'info' }
            Write-WPLog ("{0}: already installed" -f $e.Name) 'info'
            continue
        }
        Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = 'Installing...'; Level = 'step' }
        Start-Sleep -Milliseconds (140 + $rand.Next(320))
        $detail = $null; $lvl = 'ok'
        switch ($e.Method) {
            'local' { $detail = $(if ($test) { "Would run $($e.Download.Installer)" } elseif ($e.Name -like 'Visual Studio*') { 'Installed (restart needed)' } else { 'Installed' }) }
            'winget' { $detail = $(if ($test) { "Would install $($e.WingetId) from winget" } else { 'Installed with winget (winget)' }) }
            'store' { $detail = $(if ($test) { "Would install $($e.WingetId) from msstore" } else { 'Installed with winget (msstore)' }) }
            'storelink' { $detail = 'Open it in the Microsoft Store (Manual links button).'; $lvl = 'warn' }
            default { $detail = 'Manual download (Manual links button).'; $lvl = 'warn' }
        }
        if ($lvl -eq 'ok') { $ok++ } else { $manual++ }
        Send-WPMessage 'restoreItem' @{ Key = $e.Key; Status = $detail; Level = $lvl }
        Write-WPLog ("{0}: {1}" -f $e.Name, $detail) $lvl
    }
    if (-not (Test-WPCancel) -and @($Configs).Count) {
        Write-WPLog 'Putting app settings back...' 'step'
        foreach ($c in @($Configs)) {
            if (Test-WPCancel) { break }
            Send-WPMessage 'restoreItem' @{ Key = 'config:' + $c.Id; Status = 'Restoring...'; Level = 'step' }
            Start-Sleep -Milliseconds (200 + $rand.Next(250))
            $msg = $(if ($test) { "Test run finished for $($c.Name)." } else { "Restored $(2 + $rand.Next(3)) items for $($c.Name)." })
            Send-WPMessage 'restoreItem' @{ Key = 'config:' + $c.Id; Status = $msg; Level = 'ok' }
            Write-WPLog ("{0} settings restored" -f $c.Name) 'ok'
        }
    }
    if (-not (Test-WPCancel) -and @($Extras).Count) {
        Write-WPLog 'Restoring extras...' 'step'
        foreach ($x in @($Extras)) {
            Start-Sleep -Milliseconds 500
            $msg = switch ($x.Id) { 'fonts' { '37 fonts installed (visible after a restart)' } 'envvars' { '4 variables and 9 PATH entries added' } default { 'Restored' } }
            Send-WPMessage 'restoreItem' @{ Key = 'extra:' + $x.Id; Status = $msg; Level = 'ok' }
            Write-WPLog ("{0}: {1}" -f $x.Name, $msg) 'ok'
        }
    }
    Write-WPLog ("Done: {0} installed, {1} already there, {2} manual, 0 failed." -f $ok, $skipped, $manual) 'ok'
    if ($manual) { Write-WPLog 'Use "Manual links" for the rest, then restart the PC.' 'info' }
    return @{ Ok = $ok; Failed = 0; Manual = $manual; Skipped = $skipped }
}
