#Requires -Version 5.1
<#
.SYNOPSIS
    WinPrestige: back up your apps, their installers and settings before a Windows reset,
    then put everything back afterwards.

.DESCRIPTION
    Scans installed programs (registry, winget and the Microsoft Store), finds official
    installers through winget, saves installers and app settings to a folder such as a
    NAS share, and restores them on the fresh install.

.PARAMETER Mode
    Backup (default) opens on the Apps tab and scans this PC. Restore opens the Restore tab.

.PARAMETER BackupPath
    Backup folder to load on the Restore tab.

.PARAMETER NoElevate
    Don't ask for administrator rights (installs and some settings folders need them).

.PARAMETER Demo
    Show a made-up PC full of well-known apps instead of this one, for screenshots and videos.
    Nothing on this PC is read or changed, and backup and restore are simulated.

.PARAMETER Resume
    Offer to continue an unfinished restore (used when Windows reopens WinPrestige after a restart).

.PARAMETER Screenshot
    Testing aid: once background work finishes, render the window to this PNG and exit.
#>
[CmdletBinding()]
param(
    [ValidateSet('Backup', 'Restore')][string]$Mode = 'Backup',
    [string]$BackupPath,
    [switch]$NoElevate,
    [switch]$Demo,
    [switch]$Resume,
    [switch]$HideConsole,
    [string]$Screenshot,
    [ValidateSet('Apps', 'Configs', 'Extras', 'Backup', 'Restore')][string]$ScreenshotTab = 'Apps',
    [int]$ScreenshotWait = 180,
    [ValidateSet('', 'Backup', 'Restore', 'Banner', 'Review', 'Drop')][string]$ScreenshotAction = '',
    [string]$ScreenshotSelect
)

$ErrorActionPreference = 'Stop'
$WPRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-WPAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-WPUncPath {
    # Elevated processes don't see drive letters mapped in your normal session, so use the share path.
    param([string]$Path)
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:') { return $Path }
    $drive = Get-PSDrive -Name $Path.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($drive -and $drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\')) {
        return $drive.DisplayRoot.TrimEnd('\') + $Path.Substring(2)
    }
    return $Path
}

#region Elevation --------------------------------------------------------------

if (-not $NoElevate -and -not $Screenshot -and -not $Demo -and -not (Test-WPAdmin)) {
    $selfDir = $WPRoot
    $resolvedDir = ConvertTo-WPUncPath $WPRoot
    if ($resolvedDir.StartsWith('\\')) {
        # The admin window may not be signed in to the NAS yet, so run the app from a local copy.
        # The backup itself is still read from the share.
        $selfDir = Join-Path $env:LOCALAPPDATA 'WinPrestige\app'
        New-Item -ItemType Directory -Path $selfDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $WPRoot 'WinPrestige.ps1') -Destination $selfDir -Force
        foreach ($d in @('lib', 'data', 'assets')) {
            if (Test-Path -LiteralPath (Join-Path $WPRoot $d)) { Copy-Item -LiteralPath (Join-Path $WPRoot $d) -Destination $selfDir -Recurse -Force }
        }
        foreach ($name in @('README.md', 'LICENSE', 'WinPrestige.exe')) {
            if (Test-Path -LiteralPath (Join-Path $WPRoot $name)) { Copy-Item -LiteralPath (Join-Path $WPRoot $name) -Destination $selfDir -Force }
        }
        if (-not $BackupPath -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $WPRoot) 'manifest.json'))) {
            # Running the copy stored next to a backup: pre-fill the Restore tab with that backup.
            $BackupPath = Split-Path -Parent $WPRoot
        }
    }
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $selfDir 'WinPrestige.ps1')`" -Mode $Mode"
    if ($Resume) { $argList += ' -Resume' }
    if ($BackupPath) {
        $bp = $BackupPath
        try { $bp = (Resolve-Path -LiteralPath $BackupPath -ErrorAction Stop).ProviderPath } catch { }
        $bp = (ConvertTo-WPUncPath $bp).TrimEnd('\')
        if ($bp -match '^[A-Za-z]:$') { $bp += '\.' }
        $argList += " -BackupPath `"$bp`""
    }
    try {
        Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("WinPrestige needs administrator rights to install apps, read some settings folders and export drivers.`n`nStart it again and choose Yes when Windows asks.", 'WinPrestige')
    }
    exit
}

if ($HideConsole -and -not $Screenshot) {
    try {
        Add-Type -Namespace WinPrestige -Name ConsoleWindow -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
        [void][WinPrestige.ConsoleWindow]::ShowWindow([WinPrestige.ConsoleWindow]::GetConsoleWindow(), 0)
    } catch { }
}

#endregion

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $WPRoot 'lib\Core.ps1')
$sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Cancel = $false })
Initialize-WP -Root $WPRoot -Sync $sync
. (Join-Path $WPRoot 'lib\Demo.ps1')

$MidDot = [string][char]0x00B7
# Screenshots are rendered mid-frame, so code-driven animations are off in screenshot mode.
$Animate = -not [bool]$Screenshot
$Ellipsis = [string][char]0x2026
$Palette = @{ Text = '#E4EDF7'; Soft = '#B8C5D9'; Muted = '#7F8FA9'; Accent = '#5FCFE3'; Good = '#3DDC97'; Warn = '#F2B24C'; Bad = '#F2667A'; Purple = '#C094F0'; Line = '#1F2B42'; Tile = '#152036' }
$AvatarColors = @('#4CDBDA', '#7B9CE9', '#C094F0', '#5FCFE3', '#3DDC97', '#F2B24C', '#F2667A', '#8FA8FF', '#E78FD0', '#6EC1FF')

#region Settings ---------------------------------------------------------------

$SettingsPath = Join-Path $script:WP.StateDir 'settings.json'
# No settings yet means WinPrestige has never run on this PC, which is the "just reset" case.
$FirstRun = $Demo -or -not (Test-Path -LiteralPath $SettingsPath)

function Get-WPSettings {
    $s = @{ Destination = ''; Selections = @{}; Chosen = @{}; CustomUrls = @{}; CustomConfigs = @(); ConfigSelections = @{}; ExtraSelections = @{}; RecentBackups = @() }
    if ($Demo) { return $s }
    $raw = $null
    try { $raw = Read-WPJson $SettingsPath } catch { }
    if ($raw) {
        if ($raw.Destination) { $s.Destination = [string]$raw.Destination }
        foreach ($k in @('Selections', 'Chosen', 'CustomUrls', 'ConfigSelections', 'ExtraSelections')) {
            if ($raw.$k) { $s[$k] = ConvertTo-WPHashtable $raw.$k }
        }
        if ($raw.CustomConfigs) { $s.CustomConfigs = @(foreach ($c in $raw.CustomConfigs) { $c }) }
        if ($raw.RecentBackups) { $s.RecentBackups = @(foreach ($b in $raw.RecentBackups) { $b }) }
    }
    return $s
}

function Save-WPSettings {
    if ($Demo) { return }
    try { Write-WPJson $state.Settings $SettingsPath } catch { }
}

#endregion

#region Window and state -------------------------------------------------------

[xml]$xaml = [IO.File]::ReadAllText((Join-Path $WPRoot 'lib\MainWindow.xaml'), [Text.Encoding]::UTF8)
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $attr = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($attr) { $ui[$attr.Value] = $window.FindName($attr.Value) }
}

$logoPath = Join-Path $WPRoot 'assets\logo.png'
if (Test-Path -LiteralPath $logoPath) {
    $logoImage = New-Object Windows.Media.Imaging.BitmapImage
    $logoImage.BeginInit(); $logoImage.UriSource = [Uri]$logoPath; $logoImage.CacheOption = 'OnLoad'; $logoImage.EndInit()
    $ui.LogoImage.Source = $logoImage
}
$iconPath = Join-Path $WPRoot 'assets\WinPrestige.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch { }
}

$state = @{
    Apps = @(); AppIndex = @{}; Rows = @{}; DetailKey = $null
    Configs = @(); ConfigIndex = @{}; Cards = @{}
    Extras = @(); ExtraIndex = @{}; ExtraCards = @{}
    Jobs = New-Object System.Collections.ArrayList
    LogTarget = $null; Filter = ''; Page = 'Apps'
    Settings = Get-WPSettings
    AppCols = 0; ConfigCols = 0; RestoreCols = 0
    Restore = $null; RestoreRoot = ''; RRows = @{}; RestoreSel = @{}
    Dirty = @{}; LastReport = ''; GroupChecks = @{}; LastBackupTab = 'TabApps'; SummaryLast = @{}; WasBusy = $false
    FoundBackups = @(); BannerKind = ''; BannerBackup = $null; BannerProgress = $null
    LogFile = Join-Path $script:WP.StateDir ("winprestige-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
}

$script:BrushCache = @{}
function Get-WPBrush {
    param([string]$Hex, [int]$Alpha = 255)
    $k = "$Hex/$Alpha"
    if (-not $script:BrushCache.ContainsKey($k)) {
        $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
        $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb([byte]$Alpha, $c.R, $c.G, $c.B))
        $b.Freeze()
        $script:BrushCache[$k] = $b
    }
    return $script:BrushCache[$k]
}

function New-WPText {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#E6E8EB', [string]$Weight = 'Normal', [switch]$Wrap, [string]$Margin = '0', [switch]$Mono)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = Get-WPBrush $Color
    $t.FontWeight = $Weight
    $t.Margin = $Margin
    if ($Mono) { $t.FontFamily = 'Cascadia Mono, Consolas' }
    if ($Wrap) { $t.TextWrapping = 'Wrap' } else { $t.TextTrimming = 'CharacterEllipsis' }
    return $t
}

function New-WPBadge {
    param([string]$Text, [string]$Color, [string]$Margin = '6,0,0,0', [string]$Tip)
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 9
    $b.Padding = '7,1,7,2'
    $b.Margin = $Margin
    $b.VerticalAlignment = 'Center'
    $b.Background = Get-WPBrush $Color 38
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = 11
    $t.Foreground = Get-WPBrush $Color
    $b.Child = $t
    if ($Tip) { $b.ToolTip = $Tip }
    return $b
}

function New-WPLinkButton {
    param([string]$Text, $Tag, [scriptblock]$OnClick, [string]$Margin = '0,0,14,0')
    $b = New-Object Windows.Controls.Button
    $b.Style = $window.FindResource('BtnLink')
    $b.Content = $Text
    $b.Tag = $Tag
    $b.Margin = $Margin
    $b.Add_Click($OnClick)
    return $b
}

function New-WPCopyText {
    # Read-only text you can select and copy (ids, paths, links).
    param([string]$Text, [string]$Color = '#C9CED6')
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = $Text
    $tb.IsReadOnly = $true
    $tb.BorderThickness = 0
    $tb.Background = [Windows.Media.Brushes]::Transparent
    $tb.Foreground = Get-WPBrush $Color
    $tb.FontFamily = 'Cascadia Mono, Consolas'
    $tb.FontSize = 12
    $tb.TextWrapping = 'Wrap'
    $tb.Padding = '0'
    $tb.Margin = '0,3,0,0'
    return $tb
}

function New-WPDoubleAnimation {
    param([double]$To, [int]$Ms = 220, $From = $null, [switch]$Forever, [switch]$Linear)
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $From) { $a.From = [double]$From }
    $a.To = $To
    $a.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($Ms))
    if ($Forever) { $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }
    if (-not $Linear) {
        $e = New-Object Windows.Media.Animation.CubicEase
        $e.EasingMode = 'EaseOut'
        $a.EasingFunction = $e
    }
    return $a
}

function Invoke-WPFadeIn {
    # Pages and panels fade in and slide up a little when they change.
    param($Element, [double]$Offset = 10, [int]$Ms = 220)
    if (-not $Animate -or -not $Element) { return }
    if ($Element.RenderTransform -isnot [Windows.Media.TranslateTransform]) { $Element.RenderTransform = New-Object Windows.Media.TranslateTransform }
    $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-WPDoubleAnimation 1 $Ms 0))
    $Element.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-WPDoubleAnimation 0 $Ms $Offset))
}

function New-WPSpinner {
    # A spinning arc on a faint ring, used wherever something is loading.
    param([double]$Size = 14, [string]$Color = $Palette.Accent)
    $g = New-Object Windows.Controls.Grid
    $g.Width = $Size; $g.Height = $Size
    $thick = [Math]::Max(1.6, $Size / 8)
    $radius = ($Size - $thick) / 2
    $mid = $Size / 2
    $ring = New-Object Windows.Shapes.Ellipse
    $ring.Stroke = Get-WPBrush $Color 45
    $ring.StrokeThickness = $thick
    $arc = New-Object Windows.Shapes.Path
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $arc.Data = [Windows.Media.Geometry]::Parse([string]::Format($inv, 'M {0},{1} A {2},{2} 0 0 1 {3},{4}', $mid, ($thick / 2), $radius, ($Size - $thick / 2), $mid))
    $arc.Stroke = Get-WPBrush $Color
    $arc.StrokeThickness = $thick
    $arc.StrokeStartLineCap = 'Round'
    $arc.StrokeEndLineCap = 'Round'
    $spin = New-Object Windows.Media.RotateTransform
    $spin.CenterX = $mid; $spin.CenterY = $mid
    $arc.RenderTransform = $spin
    [void]$g.Children.Add($ring)
    [void]$g.Children.Add($arc)
    $spin.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-WPDoubleAnimation 360 850 0 -Forever -Linear))
    return $g
}

function Move-WPModeThumb {
    # Slides the gradient pill behind the Back up / Restore switch to the selected side.
    param([switch]$Instant)
    $btn = $ui.ModeBackup
    if ($ui.ModeRestore.IsChecked) { $btn = $ui.ModeRestore }
    if ($btn.ActualWidth -le 0) { return }
    $x = $btn.TranslatePoint((New-Object Windows.Point 0, 0), $ui.ModeButtons).X
    $thumb = $ui.ModeThumb
    if ($Instant -or -not $Animate) {
        $thumb.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
        $thumb.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
        $thumb.Width = $btn.ActualWidth
        $thumb.RenderTransform.X = $x
        return
    }
    $thumb.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-WPDoubleAnimation $btn.ActualWidth 260))
    $thumb.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, (New-WPDoubleAnimation $x 260))
}

function New-WPAvatar {
    # A small monogram tile in a colour picked from the name, so every app gets a recognisable mark.
    param([string]$Name, [double]$Size = 24)
    $clean = Get-WPCleanName $Name
    if (-not $clean) { $clean = $Name }
    $words = @($clean -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    $letters = '?'
    if ($words.Count -ge 2) { $letters = ($words[0].Substring(0, 1) + $words[1].Substring(0, 1)).ToUpperInvariant() }
    elseif ($words.Count -eq 1) { $letters = $words[0].Substring(0, 1).ToUpperInvariant() }
    $sum = 0
    foreach ($ch in $clean.ToCharArray()) { $sum += [int]$ch }
    $color = $AvatarColors[$sum % $AvatarColors.Count]
    $b = New-Object Windows.Controls.Border
    $b.Width = $Size; $b.Height = $Size
    $b.CornerRadius = [Math]::Round($Size * 0.3)
    $b.Background = Get-WPBrush $color 34
    $b.BorderBrush = Get-WPBrush $color 70
    $b.BorderThickness = 1
    $b.VerticalAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $letters
    $tb.FontSize = [Math]::Round($Size * 0.4, 1)
    $tb.FontWeight = 'SemiBold'
    $tb.Foreground = Get-WPBrush $color
    $tb.HorizontalAlignment = 'Center'
    $tb.VerticalAlignment = 'Center'
    $b.Child = $tb
    return $b
}

function Set-WPSummaryCard {
    # Big "x of y" figure with a progress bar, then a breakdown with coloured dots.
    param($Panel, [int]$Value, [int]$Total, [string]$Label, [object[]]$Lines)
    $Panel.Children.Clear()
    $top = New-Object Windows.Controls.TextBlock
    $r1 = New-Object Windows.Documents.Run ([string]$Value)
    $r1.FontSize = 26; $r1.FontWeight = 'SemiBold'; $r1.Foreground = Get-WPBrush $Palette.Text
    $r2 = New-Object Windows.Documents.Run ("  of $Total")
    $r2.FontSize = 13; $r2.Foreground = Get-WPBrush $Palette.Muted
    [void]$top.Inlines.Add($r1); [void]$top.Inlines.Add($r2)
    [void]$Panel.Children.Add($top)
    [void]$Panel.Children.Add((New-WPText $Label 12 $Palette.Muted))
    $bar = New-Object Windows.Controls.ProgressBar
    $bar.Style = $window.FindResource('Thin')
    $bar.Maximum = [Math]::Max(1, $Total)
    $bar.Value = [Math]::Min($Value, $bar.Maximum)
    $bar.Margin = '0,10,0,10'
    [void]$Panel.Children.Add($bar)
    $key = [string]$Panel.Name
    $from = 0
    if ($state.SummaryLast.ContainsKey($key)) { $from = [Math]::Min([double]$state.SummaryLast[$key], $bar.Maximum) }
    $state.SummaryLast[$key] = $bar.Value
    if ($Animate) { $bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, (New-WPDoubleAnimation $bar.Value 420 $from)) }
    foreach ($l in $Lines) {
        $dp = New-Object Windows.Controls.DockPanel
        $dp.Margin = '0,3'
        $dotColor = $Palette.Muted
        if ($l.Count -gt 2 -and $l[2]) { $dotColor = $l[2] }
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.Fill = Get-WPBrush $dotColor; $dot.Margin = '0,0,9,0'; $dot.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($dot, 'Left')
        $v = New-WPText ([string]$l[1]) 12.5 $Palette.Text 'SemiBold'
        [Windows.Controls.DockPanel]::SetDock($v, 'Right')
        [void]$dp.Children.Add($dot)
        [void]$dp.Children.Add($v)
        [void]$dp.Children.Add((New-WPText ([string]$l[0]) 12.5 $Palette.Soft))
        [void]$Panel.Children.Add($dp)
    }
}

function Set-WPSummary {
    param($Panel, [object[]]$Lines)
    $Panel.Children.Clear()
    foreach ($l in $Lines) {
        $dp = New-Object Windows.Controls.DockPanel
        $dp.Margin = '0,2'
        $color = $Palette.Text
        if ($l.Count -gt 2 -and $l[2]) { $color = $l[2] }
        $v = New-WPText ([string]$l[1]) 13 $color 'SemiBold'
        [Windows.Controls.DockPanel]::SetDock($v, 'Right')
        [void]$dp.Children.Add($v)
        [void]$dp.Children.Add((New-WPText ([string]$l[0]) 12.5 $Palette.Muted))
        [void]$Panel.Children.Add($dp)
    }
}

function Set-WPStatus {
    param([string]$Text)
    $ui.StatusText.Text = $Text
}

function Add-WPLogLine {
    param([string]$Text, [string]$Level = 'info')
    $color = switch ($Level) { 'ok' { $Palette.Good } 'warn' { $Palette.Warn } 'error' { $Palette.Bad } 'step' { $Palette.Accent } default { '#AEBBD0' } }
    if ($Level -ne 'info' -or -not $state.LogTarget) { Set-WPStatus $Text }
    $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Text
    if (-not $Demo) { try { [IO.File]::AppendAllText($state.LogFile, $line + "`r`n") } catch { } }
    $list = $state.LogTarget
    if (-not $list) { return }
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $line
    $t.Foreground = Get-WPBrush $color
    $t.TextWrapping = 'Wrap'
    [void]$list.Items.Add($t)
    if ($list.Items.Count -gt 4000) { $list.Items.RemoveAt(0) }
    $list.ScrollIntoView($t)
}

function Set-WPMasonry {
    # WinUtil-style flowing columns: headers and rows fill one column, then continue in the next.
    param($Grid, $Scroll, [object[]]$Groups, [int]$MinColWidth = 300, [int]$MaxCols = 4)
    foreach ($child in @($Grid.Children)) { if ($child -is [Windows.Controls.Panel]) { $child.Children.Clear() } }
    $Grid.Children.Clear()
    $Grid.ColumnDefinitions.Clear()
    $width = $Scroll.ActualWidth - 30
    if ($width -lt 100) { $width = 960 }
    $cols = [int][Math]::Max(1, [Math]::Min($MaxCols, [Math]::Floor($width / $MinColWidth)))
    $elements = New-Object System.Collections.Generic.List[object]
    foreach ($g in $Groups) {
        if ($g.Header) { $elements.Add(@($true, $g.Header, $g.Title)) }
        foreach ($i in $g.Items) { $elements.Add(@($false, $i, $g.Title)) }
    }
    $perCol = [Math]::Max(1, [Math]::Ceiling($elements.Count / $cols))
    $panels = @()
    for ($i = 0; $i -lt $cols; $i++) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star)
        $Grid.ColumnDefinitions.Add($cd)
        $sp = New-Object Windows.Controls.StackPanel
        if ($i -lt $cols - 1) { $sp.Margin = '0,0,16,0' }
        [Windows.Controls.Grid]::SetColumn($sp, $i)
        [void]$Grid.Children.Add($sp)
        $panels += $sp
    }
    $ci = 0; $count = 0
    foreach ($e in $elements) {
        if ($ci -lt $cols - 1) {
            # Start a new column when this one is full, and don't strand a header at the bottom.
            if ($count -ge $perCol -or ($e[0] -and $count -gt 0 -and ($perCol - $count) -lt 3)) {
                $ci++; $count = 0
                if (-not $e[0] -and $e[2]) {
                    # The group carries on in this column; label it so the rows aren't orphaned.
                    [void]$panels[$ci].Children.Add((New-WPText "$($e[2]), continued" 12 $Palette.Muted 'SemiBold' -Margin '2,14,0,8'))
                }
            }
        }
        [void]$panels[$ci].Children.Add($e[1])
        $count++
    }
    return $cols
}

function Get-WPColumnCount {
    param($Scroll, [int]$MinColWidth, [int]$MaxCols)
    $width = $Scroll.ActualWidth - 30
    if ($width -lt 100) { $width = 960 }
    return [int][Math]::Max(1, [Math]::Min($MaxCols, [Math]::Floor($width / $MinColWidth)))
}

function New-WPGroupHeader {
    param([string]$Title, [int]$Count, [string]$Hint, [string]$Tag, [switch]$NoSelectLinks)
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '0,14,0,4'
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    if (-not $NoSelectLinks) {
        # One checkbox per group: ticked, unticked, or a dash when only some are ticked.
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Style = $window.FindResource('Chk')
        $cb.Tag = $Tag
        $cb.Margin = '6,0,0,0'
        $cb.ToolTip = 'Tick or untick everything in this group'
        $cb.Add_Click({ Set-WPGroupSelection ($this.Tag + '|' + $(if ($this.IsChecked -eq $true) { '1' } else { '0' })) })
        $state.GroupChecks[$Tag] = $cb
        [void]$row.Children.Add($cb)
    }
    $titleText = New-WPText $Title 14.5 $Palette.Text 'SemiBold' -Margin '10,0,0,0'
    $titleText.VerticalAlignment = 'Center'
    [void]$row.Children.Add($titleText)
    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = 8
    $pill.Padding = '7,1,7,2'
    $pill.Margin = '8,0,0,0'
    $pill.VerticalAlignment = 'Center'
    $pill.Background = Get-WPBrush $Palette.Tile
    $pill.Child = New-WPText ([string]$Count) 11.5 $Palette.Muted 'SemiBold'
    [void]$row.Children.Add($pill)
    [void]$sp.Children.Add($row)
    if ($Hint) {
        $indent = 10
        if (-not $NoSelectLinks) { $indent = 34 }
        [void]$sp.Children.Add((New-WPText $Hint 11.5 $Palette.Muted -Wrap -Margin "$indent,3,0,2"))
    }
    $line = New-Object Windows.Controls.Border
    $line.Height = 1
    $line.Background = Get-WPBrush $Palette.Line
    $line.Margin = '6,7,0,3'
    [void]$sp.Children.Add($line)
    return $sp
}

function Update-WPGroupChecks {
    # Keeps each group checkbox in step with the rows under it.
    foreach ($tag in @($state.GroupChecks.Keys)) {
        $parts = $tag -split '\|'
        $values = @()
        if ($parts[0] -eq 'apps') {
            $values = @($state.Apps | Where-Object { $_.Category -eq $parts[1] -and (Test-WPFilter @($_.Name, $_.WingetId, $_.Publisher)) } | ForEach-Object { [bool]$_.Selected })
        } elseif ($parts[0] -eq 'restore') {
            $values = @($state.RRows.Keys | Where-Object { $state.RRows[$_].Group -eq $parts[1] -and $state.RRows[$_].Check.IsEnabled } | ForEach-Object { [bool]$state.RestoreSel[$_] })
        }
        $on = @($values | Where-Object { $_ }).Count
        $cb = $state.GroupChecks[$tag]
        if ($values.Count -gt 0 -and $on -eq $values.Count) { $cb.IsChecked = $true }
        elseif ($on -eq 0) { $cb.IsChecked = $false }
        else { $cb.IsChecked = $null }
    }
}

function Test-WPFilter {
    param([string[]]$Values)
    $q = $state.Filter
    if (-not $q) { return $true }
    foreach ($v in $Values) { if ($v -and $v.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    return $false
}

#endregion

#region Background jobs --------------------------------------------------------

function Set-WPBusy {
    $busy = @($state.Jobs | Where-Object { -not $_.Quiet }).Count -gt 0
    $vis = if ($busy) { 'Visible' } else { 'Collapsed' }
    $ui.BtnCancel.Visibility = $vis
    $ui.Progress.Visibility = $vis
    foreach ($n in @('BtnScan', 'BtnLinks', 'BtnStartBackup', 'BtnStartRestore', 'BtnDetectConfigs', 'BtnLoadBackup')) { $ui[$n].IsEnabled = -not $busy }
    if ($busy -and -not $ui.BusySpinner.Content) { $ui.BusySpinner.Content = New-WPSpinner 14 }
    $ui.BusySpinner.Visibility = $vis
    if ($busy -and -not $state.WasBusy) {
        $ui.Progress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
        $ui.Progress.Value = 0
        $ui.Progress.IsIndeterminate = $true
    }
    if (-not $busy) {
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
        $ui.Progress.Value = 0
        $ui.BtnCancel.IsEnabled = $true
    }
    $state.WasBusy = $busy
}

function Start-WPJob {
    param([string]$Name, [scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnDone, [switch]$Quiet)
    if ($state.Jobs.Count -eq 0) { $sync.Cancel = $false }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $code = "param(`$sync, `$WPRoot, `$P)`n`$ErrorActionPreference = 'Continue'`n. (Join-Path `$WPRoot 'lib\Core.ps1')`nInitialize-WP -Root `$WPRoot -Sync `$sync`n. (Join-Path `$WPRoot 'lib\Demo.ps1')`n" + $Script.ToString()
    [void]$ps.AddScript($code).AddArgument($sync).AddArgument($WPRoot).AddArgument($Params)
    $handle = $ps.BeginInvoke()
    [void]$state.Jobs.Add(@{ Name = $Name; PS = $ps; Handle = $handle; Runspace = $rs; OnDone = $OnDone; Quiet = [bool]$Quiet })
    Set-WPBusy
}

function Invoke-WPMessage {
    param($m)
    switch ($m.Type) {
        'log' { Add-WPLogLine $m.Text $m.Level }
        'progress' {
            $ui.Progress.Visibility = 'Visible'
            $ui.Progress.IsIndeterminate = $false
            $max = [Math]::Max(1, [int]$m.Maximum)
            $val = [Math]::Min([int]$m.Value, $max)
            if ($ui.Progress.Maximum -ne $max) {
                $ui.Progress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
                $ui.Progress.Value = 0
                $ui.Progress.Maximum = $max
            }
            if ($Animate) { $ui.Progress.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, (New-WPDoubleAnimation $val 300)) }
            else { $ui.Progress.Value = $val }
            if ($m.Text) { Set-WPStatus $m.Text }
        }
        'app' {
            $a = $state.AppIndex[$m.Key]
            if ($a) {
                Update-WPAppRow $a
                if ($state.DetailKey -eq $m.Key) { Show-WPDetails $m.Key }
                $state.Dirty['apps'] = $true
            }
        }
        'config' {
            $c = $state.ConfigIndex[$m.Id]
            if ($c) { Update-WPConfigDefault $c; Update-WPConfigCard $c; $state.Dirty['configs'] = $true }
        }
        'extra' {
            $e = $state.ExtraIndex[$m.Id]
            if ($e) { Update-WPExtraCard $e; $state.Dirty['configs'] = $true }
        }
        'restoreItem' { Update-WPRestoreStatus $m.Key $m.Status $m.Level }
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
        $msg = $null; $n = 0
        while ($n -lt 400 -and $sync.Queue.TryDequeue([ref]$msg)) {
            $n++
            try { Invoke-WPMessage $msg } catch { }
        }
        if ($state.Dirty['apps']) { $state.Dirty.Remove('apps'); Update-WPAppSummary; Update-WPBackupStats }
        if ($state.Dirty['configs']) { $state.Dirty.Remove('configs'); Update-WPConfigSummary; Update-WPBackupStats }
        foreach ($job in @($state.Jobs)) {
            if (-not $job.Handle.IsCompleted) { continue }
            [void]$state.Jobs.Remove($job)
            $result = $null; $err = $null
            try {
                $out = $job.PS.EndInvoke($job.Handle)
                if ($out -and $out.Count -gt 0) { $result = $out[$out.Count - 1] }
            } catch {
                $err = $_.Exception
                while ($err.InnerException) { $err = $err.InnerException }
            }
            $shown = 0
            foreach ($e in $job.PS.Streams.Error) { if ($shown -lt 10) { Add-WPLogLine ([string]$e) 'warn'; $shown++ } }
            $job.PS.Dispose()
            $job.Runspace.Dispose()
            # Drain anything the job queued just before finishing.
            while ($sync.Queue.TryDequeue([ref]$msg)) { try { Invoke-WPMessage $msg } catch { } }
            Set-WPBusy
            if ($err) { Add-WPLogLine ("{0} stopped: {1}" -f $job.Name, $err.Message) 'error' }
            elseif ($state.Jobs.Count -eq 0) { Set-WPStatus 'Ready' }
            if ($job.OnDone) {
                try { & $job.OnDone $result $err } catch { Add-WPLogLine ("Error: " + $_.Exception.Message) 'error' }
            }
        }
    })

#endregion

#region Apps tab ---------------------------------------------------------------

function Get-WPAppPlan {
    param($App)
    if ($App.CustomUrl) { return 'custom' }
    if ($App.WingetId -and $App.Source -eq 'msstore') { return 'store' }
    if ($App.WingetId) { return 'winget' }
    if ($App.Category -eq 'games') { return 'game' }
    if ($App.Category -eq 'bundled' -and $App.Via) { return 'bundled' }
    if ($App.Category -eq 'system') { return 'system' }
    if ($App.Pfn) { return 'storelink' }
    if (-not $App.Match) { return 'unchecked' }
    return 'manual'
}

function Get-WPAppBadge {
    param($App)
    if ($App.Match -eq 'searching') { return @{ Text = "looking up$Ellipsis"; Color = $Palette.Muted; Tip = 'Searching winget and the Microsoft Store.' } }
    switch (Get-WPAppPlan $App) {
        'custom' { return @{ Text = 'your link'; Color = $Palette.Good; Tip = "Downloaded from your link: $($App.CustomUrl)" } }
        'store' { return @{ Text = 'Store'; Color = $Palette.Purple; Tip = "Reinstalled from the Microsoft Store ($($App.WingetId))." } }
        'winget' {
            $tip = "Official installer from winget: $($App.WingetId)"
            if (@('search', 'override') -contains $App.Match) { $tip += "`nMatched by name; check the details panel." }
            return @{ Text = 'winget'; Color = $Palette.Accent; Tip = $tip }
        }
        'game' { return @{ Text = $App.Via; Color = $Palette.Muted; Tip = "Reinstall from $($App.Via)." } }
        'bundled' {
            $via = $App.Via
            if ($via.Length -gt 22) { $via = $via.Substring(0, 20) + $Ellipsis }
            return @{ Text = "via $via"; Color = $Palette.Muted; Tip = "Comes back with $($App.Via)." }
        }
        'system' { return @{ Text = 'built-in'; Color = $Palette.Muted; Tip = 'Comes with Windows.' } }
        'storelink' { return @{ Text = 'Store page'; Color = $Palette.Purple; Tip = 'Not in winget. Restore opens its Store page.' } }
        'unchecked' { return @{ Text = 'not looked up'; Color = $Palette.Muted; Tip = 'Tick it and press "Look up download links".' } }
        default { return @{ Text = 'manual'; Color = $Palette.Warn; Tip = 'No package found. Pick a match or paste a download link in the details panel.' } }
    }
}

function New-WPAppRow {
    param($App)
    $row = New-Object Windows.Controls.Border
    $row.Style = $window.FindResource('Row')
    $row.Tag = $App.Key
    $g = New-Object Windows.Controls.Grid
    foreach ($w in @('Auto', 'Auto', '*', 'Auto', 'Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -eq '*') { $cd.Width = New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star) } else { $cd.Width = [Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
    }
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('Chk')
    $cb.Tag = $App.Key
    $cb.Add_Click({ Set-WPAppSelected $this.Tag ([bool]$this.IsChecked) })
    $avatar = New-WPAvatar $App.Name 24
    $avatar.Margin = '1,0,0,0'
    $name = New-WPText $App.Name 13 $Palette.Text -Margin '10,0,4,0'
    $name.VerticalAlignment = 'Center'
    $badgeHost = New-Object Windows.Controls.Border
    $badgeHost.VerticalAlignment = 'Center'
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 7; $dot.Height = 7; $dot.Margin = '7,0,1,0'; $dot.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($avatar, 1)
    [Windows.Controls.Grid]::SetColumn($name, 2)
    [Windows.Controls.Grid]::SetColumn($badgeHost, 3)
    [Windows.Controls.Grid]::SetColumn($dot, 4)
    foreach ($el in @($cb, $avatar, $name, $badgeHost, $dot)) { [void]$g.Children.Add($el) }
    $row.Child = $g
    $row.Add_MouseLeftButtonUp({ Show-WPDetails $this.Tag })
    $state.Rows[$App.Key] = @{ Root = $row; Check = $cb; Name = $name; Badge = $badgeHost; Dot = $dot }
    Update-WPAppRow $App
}

function Update-WPAppRow {
    param($App)
    $r = $state.Rows[$App.Key]
    if (-not $r) { return }
    $r.Check.IsChecked = [bool]$App.Selected
    $r.Name.Text = $App.Name
    $b = Get-WPAppBadge $App
    $r.Badge.Child = New-WPBadge $b.Text $b.Color
    $dotColor = switch ($App.Status) {
        'Downloaded' { $Palette.Good } 'Up to date' { $Palette.Good } 'Kept previous' { $Palette.Warn } 'Failed' { $Palette.Bad } 'Downloading' { $Palette.Accent } default { $null }
    }
    if ($dotColor) { $r.Dot.Fill = Get-WPBrush $dotColor; $r.Dot.Visibility = 'Visible' } else { $r.Dot.Visibility = 'Collapsed' }
    if ($App.Status -eq 'Downloading' -or $App.Match -eq 'searching') {
        if (-not $r.Spin) {
            $r.Spin = New-WPSpinner 12
            $r.Spin.Margin = '7,0,0,0'
            [Windows.Controls.Grid]::SetColumn($r.Spin, 4)
            [void]$r.Dot.Parent.Children.Add($r.Spin)
        }
        $r.Spin.Visibility = 'Visible'
        $r.Dot.Visibility = 'Collapsed'
    } elseif ($r.Spin) {
        $r.Spin.Visibility = 'Collapsed'
    }
    $tip = @($App.Name)
    $meta = @($App.Publisher, $App.Version) | Where-Object { $_ }
    if ($meta) { $tip += ($meta -join "  $MidDot  ") }
    $tip += $b.Tip
    if ($App.Status) { $tip += "Last backup: $($App.Status) $($App.Detail)".Trim() }
    $r.Root.ToolTip = $tip -join "`n"
    if ($state.DetailKey -eq $App.Key) { $r.Root.Background = Get-WPBrush $Palette.Accent 40 }
}

function Get-WPVisibleAppGroups {
    foreach ($cat in $script:WP.Rules.categories) {
        if ($cat.id -eq 'games' -and -not $ui.ShowGames.IsChecked) { continue }
        if ($cat.id -eq 'system' -and -not $ui.ShowSystem.IsChecked) { continue }
        $items = @($state.Apps | Where-Object {
                $_.Category -eq $cat.id -and
                (-not $ui.ShowSelectedOnly.IsChecked -or $_.Selected) -and
                (Test-WPFilter @($_.Name, $_.WingetId, $_.Publisher))
            } | Sort-Object Name)
        if ($items.Count -eq 0) { continue }
        [pscustomobject]@{ Category = $cat; Items = $items }
    }
}

function Update-WPAppLayout {
    foreach ($k in @($state.GroupChecks.Keys)) { if ($k -like 'apps|*') { $state.GroupChecks.Remove($k) } }
    $groups = @()
    foreach ($g in @(Get-WPVisibleAppGroups)) {
        $groups += @{
            Title = $g.Category.title
            Header = (New-WPGroupHeader $g.Category.title $g.Items.Count $g.Category.hint ('apps|' + $g.Category.id))
            Items = @($g.Items | ForEach-Object { $state.Rows[$_.Key].Root } | Where-Object { $_ })
        }
    }
    $state.AppCols = Set-WPMasonry $ui.AppColumns $ui.AppScroll $groups 300 4
    if ($state.Apps.Count -gt 0) { $ui.AppEmpty.Visibility = 'Collapsed' } else { $ui.AppEmpty.Visibility = 'Visible' }
    Update-WPAppSummary
}

function Update-WPAppSummary {
    $visible = @($state.Apps | Where-Object { $_.Category -ne 'system' })
    $sel = @($state.Apps | Where-Object { $_.Selected })
    $counts = @{}
    foreach ($a in $sel) { $p = Get-WPAppPlan $a; $counts[$p] = 1 + [int]$counts[$p] }
    $games = @($state.Apps | Where-Object { $_.Category -eq 'games' }).Count
    Set-WPSummaryCard $ui.AppSummary $sel.Count $visible.Count 'apps ticked for the backup' @(
        @('winget installers', [int]$counts['winget'], $Palette.Accent),
        @('Microsoft Store', ([int]$counts['store'] + [int]$counts['storelink']), $Palette.Purple),
        @('Your links', [int]$counts['custom'], $Palette.Good),
        @('Manual', ([int]$counts['manual'] + [int]$counts['unchecked']), $Palette.Warn),
        @('Games skipped', $games, $Palette.Muted)
    )
    Update-WPGroupChecks
}

function Set-WPAppSelected {
    param([string]$Key, [bool]$Value)
    $a = $state.AppIndex[$Key]
    if (-not $a) { return }
    $a.Selected = $Value
    $state.Settings.Selections[$Key] = $Value
    Save-WPSettings
    Update-WPAppRow $a
    Update-WPAppSummary
    Update-WPBackupStats
    if ($ui.ShowSelectedOnly.IsChecked) { Update-WPAppLayout }
    Update-WPGroupChecks
}

function Set-WPGroupSelection {
    param([string]$Tag)
    $parts = $Tag -split '\|'
    $page = $parts[0]; $group = $parts[1]; $value = $parts[2] -eq '1'
    if ($page -eq 'apps') {
        foreach ($a in $state.Apps) {
            if ($a.Category -ne $group -or -not (Test-WPFilter @($a.Name, $a.WingetId, $a.Publisher))) { continue }
            $a.Selected = $value
            $state.Settings.Selections[$a.Key] = $value
            Update-WPAppRow $a
        }
        Save-WPSettings
        Update-WPAppSummary
        Update-WPBackupStats
    } elseif ($page -eq 'restore') {
        foreach ($k in @($state.RRows.Keys)) {
            $r = $state.RRows[$k]
            if ($r.Group -ne $group -or -not $r.Check.IsEnabled) { continue }
            $state.RestoreSel[$k] = $value
            $r.Check.IsChecked = $value
        }
        Update-WPRestoreSummary
    }
}

function Set-WPAppsFromScan {
    param([object[]]$Apps)
    $prevIndex = $state.AppIndex
    $state.Apps = @($Apps | Where-Object { $_ -and $_.Key })
    $state.AppIndex = @{}
    $state.Rows = @{}
    foreach ($a in $state.Apps) {
        $state.AppIndex[$a.Key] = $a
        Set-WPDefaultSelection $a $state.Settings.Selections
        if ($state.Settings.CustomUrls.ContainsKey($a.Key)) { $a.CustomUrl = [string]$state.Settings.CustomUrls[$a.Key] }
        $old = $prevIndex[$a.Key]
        if ($old -and $a.Kind -ne 'winget' -and -not $a.WingetId -and $old.Match -and $old.Match -ne 'searching') {
            $a.WingetId = $old.WingetId; $a.Source = $old.Source; $a.Match = $old.Match; $a.Candidates = $old.Candidates
        }
        if ($a.Kind -ne 'winget' -and $state.Settings.Chosen.ContainsKey($a.Key)) {
            $ch = $state.Settings.Chosen[$a.Key]
            if ($ch.Id) { $a.WingetId = [string]$ch.Id; $a.Source = [string]$ch.Source; $a.Match = 'chosen' }
            else { $a.WingetId = ''; $a.Source = ''; $a.Match = 'manual' }
        }
        New-WPAppRow $a
    }
    Update-WPAppLayout
    if ($state.DetailKey -and -not $state.AppIndex[$state.DetailKey]) { $state.DetailKey = $null }
    Show-WPDetails $state.DetailKey
    Update-WPBackupStats
}

function Add-WPDetailHeading {
    param([string]$Title)
    [void]$ui.Details.Children.Add((New-WPText $Title 11 $Palette.Muted 'SemiBold' -Margin '0,20,0,6'))
}

function Add-WPDetailText {
    param([string]$Text, [string]$Color = '#C9CED6', [string]$Margin = '0,0,0,4')
    [void]$ui.Details.Children.Add((New-WPText $Text 12.5 $Color -Wrap -Margin $Margin))
}

function Add-WPDetailLinks {
    param([object[]]$Buttons)
    $wp = New-Object Windows.Controls.WrapPanel
    $wp.Margin = '0,6,0,0'
    foreach ($b in $Buttons) { [void]$wp.Children.Add($b) }
    [void]$ui.Details.Children.Add($wp)
}

function Get-WPSearchUrl {
    param([string]$Name)
    return 'https://www.bing.com/search?q=' + [Uri]::EscapeDataString((Get-WPCleanName $Name) + ' download')
}

function Show-WPDetails {
    param([string]$Key)
    $prev = $state.DetailKey
    if ($prev -and $prev -ne $Key -and $state.Rows[$prev]) { $state.Rows[$prev].Root.ClearValue([Windows.Controls.Border]::BackgroundProperty) }
    $state.DetailKey = $Key
    $p = $ui.Details
    $p.Children.Clear()
    $app = $null
    if ($Key) { $app = $state.AppIndex[$Key] }
    if (-not $app) {
        [void]$p.Children.Add((New-WPText 'Details' 17 $Palette.Text 'SemiBold'))
        Add-WPDetailText 'Click an app to see where its installer comes from. Tick the box to include it in the backup.' $Palette.Muted '0,6,0,0'
        Add-WPDetailHeading 'WHAT THE TAGS MEAN'
        foreach ($l in @(
                @('winget', $Palette.Accent, 'Official installer, saved to your backup'),
                @('Store', $Palette.Purple, 'Reinstalled from the Microsoft Store'),
                @('Store page', $Palette.Purple, 'Restore opens its Store page; you click Get'),
                @('your link', $Palette.Good, 'Downloaded from a link you pasted'),
                @('manual', $Palette.Warn, 'You download it yourself (link in the report)'),
                @('via ...', $Palette.Muted, 'Comes back with another app'))) {
            $dp = New-Object Windows.Controls.DockPanel
            $dp.Margin = '0,3'
            $badge = New-WPBadge $l[0] $l[1] '0,0,8,0'
            $badge.MinWidth = 74
            [void]$dp.Children.Add($badge)
            [void]$dp.Children.Add((New-WPText $l[2] 12 $Palette.Soft -Wrap))
            [void]$p.Children.Add($dp)
        }
        Add-WPDetailHeading 'STATUS DOT'
        Add-WPDetailText 'After a backup, green means the installer is saved, amber means the previous one was kept, red means it failed (restore will use winget online).' $Palette.Muted
        return
    }
    if ($state.Rows[$Key]) { $state.Rows[$Key].Root.Background = Get-WPBrush $Palette.Accent 40 }

    $head = New-Object Windows.Controls.DockPanel
    $big = New-WPAvatar $app.Name 44
    $big.Margin = '0,0,12,0'
    [Windows.Controls.DockPanel]::SetDock($big, 'Left')
    [void]$head.Children.Add($big)
    $titles = New-Object Windows.Controls.StackPanel
    $titles.VerticalAlignment = 'Center'
    [void]$titles.Children.Add((New-WPText $app.Name 17 $Palette.Text 'SemiBold' -Wrap))
    $meta = @($app.Publisher, $app.Version) | Where-Object { $_ }
    if ($meta) { [void]$titles.Children.Add((New-WPText ($meta -join "  $MidDot  ") 12.5 $Palette.Muted -Wrap -Margin '0,2,0,0')) }
    [void]$head.Children.Add($titles)
    [void]$p.Children.Add($head)
    $chips = New-Object Windows.Controls.WrapPanel
    $chips.Margin = '0,8,0,0'
    $cat = Get-WPCategoryInfo $app.Category
    [void]$chips.Children.Add((New-WPBadge $cat.title $Palette.Muted '0,0,6,0'))
    $b = Get-WPAppBadge $app
    [void]$chips.Children.Add((New-WPBadge $b.Text $b.Color '0'))
    [void]$p.Children.Add($chips)

    Add-WPDetailHeading 'WHERE IT COMES FROM'
    switch (Get-WPAppPlan $app) {
        'winget' {
            Add-WPDetailText 'The official installer is downloaded with winget and saved to your backup.'
            [void]$p.Children.Add((New-WPCopyText $app.WingetId))
            if ($app.Latest -and $app.Version -and $app.Latest -ne $app.Version) { Add-WPDetailText "Installed $($app.Version), newest $($app.Latest). The backup saves the newest." $Palette.Muted '0,6,0,0' }
            if (@('search', 'override') -contains $app.Match) {
                Add-WPDetailText "Found by searching winget for the name. Make sure it's the right app." $Palette.Warn '0,8,0,0'
            }
            if ($app.Match -eq 'chosen') { Add-WPDetailText 'You picked this package.' $Palette.Muted '0,8,0,0' }
            $path = $app.WingetId.Substring(0, 1).ToLowerInvariant() + '/' + ($app.WingetId -replace '\.', '/')
            $btns = @(New-WPLinkButton 'winget manifest' "https://github.com/microsoft/winget-pkgs/tree/master/manifests/$path" { Open-WPUrl $this.Tag })
            if ($app.Url) { $btns += New-WPLinkButton 'Vendor site' $app.Url { Open-WPUrl $this.Tag } }
            if ($app.Kind -ne 'winget') { $btns += New-WPLinkButton 'Not this app' $app.Key { Set-WPChosen $this.Tag '' '' } }
            if ($app.Match -eq 'chosen') { $btns += New-WPLinkButton 'Undo my pick' $app.Key { Clear-WPChosen $this.Tag } }
            Add-WPDetailLinks $btns
        }
        'store' {
            Add-WPDetailText 'Reinstalled from the Microsoft Store through winget during the restore (needs internet).'
            [void]$p.Children.Add((New-WPCopyText $app.WingetId))
            $btns = @(New-WPLinkButton 'Open in Store' "https://apps.microsoft.com/detail/$($app.WingetId)" { Open-WPUrl $this.Tag })
            if ($app.Kind -ne 'winget') { $btns += New-WPLinkButton 'Not this app' $app.Key { Set-WPChosen $this.Tag '' '' } }
            if ($app.Match -eq 'chosen') { $btns += New-WPLinkButton 'Undo my pick' $app.Key { Clear-WPChosen $this.Tag } }
            Add-WPDetailLinks $btns
        }
        'storelink' {
            Add-WPDetailText "This Store app isn't available through winget. The restore opens its Store page so you can click Get."
            Add-WPDetailLinks @(New-WPLinkButton 'Open Store page' "ms-windows-store://pdp/?PFN=$($app.Pfn)" { Open-WPUrl $this.Tag })
        }
        'custom' {
            Add-WPDetailText 'Downloaded from your link and saved to the backup. The restore runs it normally (no silent switches are known for it).'
            [void]$p.Children.Add((New-WPCopyText $app.CustomUrl))
            Add-WPDetailLinks @(New-WPLinkButton 'Remove link' $app.Key { Set-WPCustomUrl $this.Tag '' })
        }
        'game' {
            Add-WPDetailText "Games are skipped. Reinstall it from $($app.Via)."
            if ($app.GameUri) { Add-WPDetailText 'Tick it if you want the restore to queue its download in Steam.' $Palette.Muted '0,6,0,0' }
            if ($app.InstallLocation) { Add-WPDetailText "Installed on $([IO.Path]::GetPathRoot($app.InstallLocation)). If that drive isn't wiped, Steam can find the files again." $Palette.Muted '0,6,0,0' }
        }
        'bundled' {
            Add-WPDetailText "Comes back when you reinstall $($app.Via). Tick it only if you want it looked up separately."
        }
        'system' { Add-WPDetailText 'Part of Windows. Nothing to do.' }
        default {
            if ($app.Match -eq '') {
                Add-WPDetailText 'Not looked up yet. Tick it, then press "Look up download links".'
            } else {
                Add-WPDetailText 'No matching winget or Microsoft Store package was found.'
            }
            $cands = @($app.Candidates | Where-Object { $_ -and $_.Id })
            if ($cands.Count) {
                Add-WPDetailHeading 'POSSIBLE MATCHES'
                foreach ($c in $cands) {
                    $dp = New-Object Windows.Controls.DockPanel
                    $dp.Margin = '0,2,0,4'
                    $use = New-WPLinkButton 'Use' @{ Key = $app.Key; Id = [string]$c.Id; Source = [string]$c.Source } { Set-WPChosen $this.Tag.Key $this.Tag.Id $this.Tag.Source } '8,0,0,0'
                    [Windows.Controls.DockPanel]::SetDock($use, 'Right')
                    [void]$dp.Children.Add($use)
                    $sp = New-Object Windows.Controls.StackPanel
                    [void]$sp.Children.Add((New-WPText $c.Name 12.5 $Palette.Text))
                    [void]$sp.Children.Add((New-WPText ("{0}  {1}  {2}" -f $c.Id, $MidDot, $c.Source) 11 $Palette.Muted -Mono))
                    [void]$dp.Children.Add($sp)
                    [void]$p.Children.Add($dp)
                }
                Add-WPDetailText 'Store listings with familiar names are often copycats. Check the publisher before using one.' $Palette.Muted '0,2,0,0'
            }
            Add-WPDetailHeading 'DOWNLOAD LINK'
            Add-WPDetailText "Paste a direct link to the installer and it's downloaded with everything else:" $Palette.Muted
            $box = New-Object Windows.Controls.TextBox
            $box.Style = $window.FindResource('Field')
            $box.Margin = '0,4,0,6'
            $box.FontSize = 12
            [void]$p.Children.Add($box)
            $save = New-Object Windows.Controls.Button
            $save.Style = $window.FindResource('Btn')
            $save.Content = 'Save link'
            $save.HorizontalAlignment = 'Left'
            $save.Padding = '14,6'
            $save.Tag = @{ Key = $app.Key; Box = $box }
            $save.Add_Click({ Set-WPCustomUrl $this.Tag.Key $this.Tag.Box.Text })
            [void]$p.Children.Add($save)
            $btns = @()
            if ($app.Url) { $btns += New-WPLinkButton 'Vendor site' $app.Url { Open-WPUrl $this.Tag } }
            $btns += New-WPLinkButton 'Search the web' (Get-WPSearchUrl $app.Name) { Open-WPUrl $this.Tag }
            Add-WPDetailLinks $btns
        }
    }

    Add-WPDetailHeading 'ON THIS PC'
    if ($app.InstallLocation) {
        [void]$p.Children.Add((New-WPCopyText $app.InstallLocation))
        Add-WPDetailLinks @(New-WPLinkButton 'Open folder' $app.InstallLocation { if (Test-Path -LiteralPath $this.Tag) { Start-Process explorer.exe "`"$($this.Tag)`"" } })
    }
    $ident = $app.ArpId
    if (-not $ident) { $ident = $app.WingetId }
    if ($ident) { [void]$p.Children.Add((New-WPCopyText $ident $Palette.Muted)) }
    if ($app.Status) {
        Add-WPDetailHeading 'LAST BACKUP'
        $color = switch ($app.Status) { 'Failed' { $Palette.Bad } 'Kept previous' { $Palette.Warn } default { $Palette.Good } }
        Add-WPDetailText $app.Status $color
        if ($app.Detail) { Add-WPDetailText $app.Detail $Palette.Muted }
    }
    if ($prev -ne $Key) { Invoke-WPFadeIn $ui.Details 6 180 }
}

function Set-WPChosen {
    param([string]$Key, [string]$Id, [string]$Source)
    $a = $state.AppIndex[$Key]
    if (-not $a) { return }
    if ($Id) { $a.WingetId = $Id; $a.Source = $Source; $a.Match = 'chosen' }
    else { $a.WingetId = ''; $a.Source = ''; $a.Match = 'manual' }
    $state.Settings.Chosen[$Key] = @{ Id = $Id; Source = $Source }
    Save-WPSettings
    Update-WPAppRow $a
    Show-WPDetails $Key
    Update-WPAppSummary
    Update-WPBackupStats
}

function Clear-WPChosen {
    param([string]$Key)
    $state.Settings.Chosen.Remove($Key)
    Save-WPSettings
    $a = $state.AppIndex[$Key]
    if (-not $a) { return }
    $a.WingetId = ''; $a.Source = ''; $a.Match = ''
    Update-WPAppRow $a
    Show-WPDetails $Key
    Start-WPLookup @($a) -Force
}

function Set-WPCustomUrl {
    param([string]$Key, [string]$Url)
    $a = $state.AppIndex[$Key]
    if (-not $a) { return }
    $Url = $Url.Trim()
    if ($Url -and $Url -notmatch '^https?://\S+$') {
        [void][System.Windows.MessageBox]::Show($window, 'That does not look like a web link. It should start with https://', 'WinPrestige')
        return
    }
    $a.CustomUrl = $Url
    if ($Url) { $state.Settings.CustomUrls[$Key] = $Url; if (-not $a.Selected) { $a.Selected = $true; $state.Settings.Selections[$Key] = $true } }
    else { $state.Settings.CustomUrls.Remove($Key) }
    Save-WPSettings
    Update-WPAppRow $a
    Show-WPDetails $Key
    Update-WPAppSummary
    Update-WPBackupStats
}

function Set-WPRecommendedApps {
    foreach ($a in $state.Apps) {
        $state.Settings.Selections.Remove($a.Key)
        Set-WPDefaultSelection $a @{}
        Update-WPAppRow $a
    }
    Save-WPSettings
    Update-WPAppLayout
    Update-WPBackupStats
}

function Set-WPAllShownApps {
    param([bool]$Value)
    foreach ($g in @(Get-WPVisibleAppGroups)) {
        foreach ($a in $g.Items) {
            $a.Selected = $Value
            $state.Settings.Selections[$a.Key] = $Value
            Update-WPAppRow $a
        }
    }
    Save-WPSettings
    Update-WPAppLayout
    Update-WPBackupStats
}

function Save-WPScanCache {
    try { Write-WPJson @($state.Apps) (Join-Path $script:WP.StateDir 'last-scan.json') } catch { }
}

function Start-WPScan {
    $ui.AppEmptyText.Text = "Scanning your apps$Ellipsis"
    if (-not $ui.AppSpinner.Content) { $ui.AppSpinner.Content = New-WPSpinner 40 }
    $ui.AppSpinner.Visibility = 'Visible'
    $ui.AppEmptyIcon.Visibility = 'Collapsed'
    $state.LogTarget = $null
    Start-WPJob 'Scan' {
        if ($P.Demo) {
            $apps = Get-WPDemoApps; $configs = Get-WPDemoConfigs; $extras = Get-WPDemoExtras
        } else {
            $apps = Get-WPInventory
            $configs = Get-WPConfigCandidates $apps $P.CustomConfigs
            $extras = Get-WPExtras
        }
        @{ Apps = $apps; Configs = $configs; Extras = $extras }
    } @{ CustomConfigs = @($state.Settings.CustomConfigs); Demo = [bool]$Demo } {
        param($r, $err)
        if ($err -or -not $r) {
            $ui.AppEmptyText.Text = 'The scan failed. See the status bar, then press Scan this PC to try again.'
            $ui.AppSpinner.Visibility = 'Collapsed'
            $ui.AppEmptyIcon.Visibility = 'Visible'
            return
        }
        Set-WPAppsFromScan @($r.Apps)
        Set-WPConfigs @($r.Configs)
        Set-WPExtras @($r.Extras)
        $ui.ScanInfo.Text = "Scanned $(Get-Date -Format 't'). Rescan any time to pick up new or removed apps."
        if (-not $Demo) {
            Save-WPScanCache
            Start-WPLookup $state.Apps
            Start-WPMeasure
        }
    }
}

function Start-WPLookup {
    param([object[]]$Apps, [switch]$Force)
    if ($Demo) { Set-WPStatus 'Every ticked app already has a download source.'; return }
    Start-WPJob 'Lookup' {
        Resolve-WPLinks $P.Apps $P.Chosen -Force:$P.Force
        'done'
    } @{ Apps = @($Apps); Chosen = $state.Settings.Chosen; Force = [bool]$Force } {
        param($r, $err)
        Save-WPScanCache
        Update-WPAppSummary
        Update-WPBackupStats
    }
}

function Start-WPMeasure {
    if ($Demo) { return }
    Start-WPJob 'Measure' {
        foreach ($c in $P.Configs) {
            if (Test-WPCancel) { break }
            $c.Running = @(Get-WPRunningProcesses $c)
            Update-WPConfigSize $c
            Send-WPMessage 'config' @{ Id = $c.Id }
        }
        foreach ($e in $P.Extras) {
            if (Test-WPCancel) { break }
            if ($e.Id -like 'folder:*') { Update-WPExtraSize $e; Send-WPMessage 'extra' @{ Id = $e.Id } }
        }
        'done'
    } @{ Configs = @($state.Configs); Extras = @($state.Extras) } {
        param($r, $err)
        Update-WPConfigSummary
        Update-WPBackupStats
    }
}

#endregion

#region App settings tab -------------------------------------------------------

function Update-WPConfigDefault {
    # Very large settings folders (game instances, browser profiles) start unticked unless you chose otherwise.
    param($Cfg)
    if ($state.Settings.ConfigSelections.ContainsKey($Cfg.Id)) { return }
    if ($Cfg.Bytes -ge 1GB -and -not $Cfg.SizeChecked) { $Cfg.Selected = $false }
    $Cfg | Add-Member -NotePropertyName SizeChecked -NotePropertyValue $true -Force
}

function New-WPConfigCard {
    param($Cfg)
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    $card.Padding = '14,12'
    $card.Margin = '0,0,0,10'
    $sp = New-Object Windows.Controls.StackPanel
    $top = New-Object Windows.Controls.DockPanel
    $size = New-WPText '' 12 $Palette.Muted -Margin '10,0,0,0'
    $size.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($size, 'Right')
    [void]$top.Children.Add($size)
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('Chk')
    $cb.Tag = $Cfg.Id
    $label = New-Object Windows.Controls.StackPanel
    $label.Orientation = 'Horizontal'
    [void]$label.Children.Add((New-WPAvatar $Cfg.Name 26))
    $cfgName = New-WPText $Cfg.Name 14 $Palette.Text 'SemiBold' -Margin '10,0,0,0'
    $cfgName.VerticalAlignment = 'Center'
    [void]$label.Children.Add($cfgName)
    $cb.Content = $label
    $cb.Add_Click({ Set-WPConfigSelected $this.Tag ([bool]$this.IsChecked) })
    [void]$top.Children.Add($cb)
    [void]$sp.Children.Add($top)
    $tags = New-Object Windows.Controls.WrapPanel
    $tags.Margin = '26,7,0,0'
    [void]$sp.Children.Add($tags)
    $paths = New-Object Windows.Controls.StackPanel
    $paths.Margin = '26,6,0,0'
    $shown = 0
    foreach ($it in @($Cfg.Items)) {
        if ($shown -ge 4) { break }
        $t = New-WPText $it.Target 11.5 $Palette.Muted -Mono
        $t.ToolTip = $it.Source
        [void]$paths.Children.Add($t)
        $shown++
    }
    if (@($Cfg.Items).Count -gt 4) { [void]$paths.Children.Add((New-WPText ("+ {0} more" -f (@($Cfg.Items).Count - 4)) 11.5 $Palette.Muted)) }
    foreach ($r in @($Cfg.Registry)) { [void]$paths.Children.Add((New-WPText ("Registry: $r") 11.5 $Palette.Muted -Mono)) }
    [void]$sp.Children.Add($paths)
    if ($Cfg.Notes) { [void]$sp.Children.Add((New-WPText $Cfg.Notes 12 $Palette.Soft -Wrap -Margin '26,7,0,0')) }
    if ($Cfg.Custom) {
        $rm = New-WPLinkButton 'Remove' $Cfg.Id { Remove-WPCustomConfig $this.Tag } '26,6,0,0'
        $rm.HorizontalAlignment = 'Left'
        [void]$sp.Children.Add($rm)
    }
    $card.Child = $sp
    $state.Cards[$Cfg.Id] = @{ Root = $card; Check = $cb; Size = $size; Tags = $tags }
    Update-WPConfigCard $Cfg
}

function Update-WPConfigCard {
    param($Cfg)
    $r = $state.Cards[$Cfg.Id]
    if (-not $r) { return }
    $r.Check.IsChecked = [bool]$Cfg.Selected
    if (@($Cfg.Items).Count -eq 0) { $r.Size.Text = 'registry' }
    elseif ($Cfg.Bytes -lt 0) { $r.Size.Text = "measuring$Ellipsis" }
    else { $r.Size.Text = "{0}  $MidDot  {1:N0} files" -f (Format-WPSize $Cfg.Bytes), $Cfg.Files }
    $r.Tags.Children.Clear()
    if ($Cfg.Sensitive) { [void]$r.Tags.Children.Add((New-WPBadge 'private data' $Palette.Warn '0,0,6,4' 'Contains passwords, keys or sign-ins. Your backup folder should be private.')) }
    if ($Cfg.Custom) { [void]$r.Tags.Children.Add((New-WPBadge 'added by you' $Palette.Accent '0,0,6,4')) }
    if ($Cfg.Bytes -ge 1GB) { [void]$r.Tags.Children.Add((New-WPBadge 'large' $Palette.Warn '0,0,6,4' 'Over 1 GB, so it starts unticked.')) }
    if (@($Cfg.Running).Count) { [void]$r.Tags.Children.Add((New-WPBadge ('running: ' + (@($Cfg.Running) -join ', ')) $Palette.Warn '0,0,6,4' 'Close the app before backing up for a clean copy.')) }
    if ($Cfg.Status) {
        $sc = switch ($Cfg.Status) { 'Saved' { $Palette.Good } 'Partial' { $Palette.Warn } 'Copying' { $Palette.Accent } default { $Palette.Bad } }
        [void]$r.Tags.Children.Add((New-WPBadge $Cfg.Status $sc '0,0,6,4' $Cfg.Detail))
    }
    if ($r.Tags.Children.Count) { $r.Tags.Visibility = 'Visible' } else { $r.Tags.Visibility = 'Collapsed' }
}

function Update-WPConfigLayout {
    $items = @($state.Configs | Where-Object { Test-WPFilter @($_.Name) } | Sort-Object @{ Expression = { [bool]$_.Custom } }, Name | ForEach-Object { $state.Cards[$_.Id].Root })
    $state.ConfigCols = Set-WPMasonry $ui.ConfigColumns $ui.ConfigScroll @(@{ Header = $null; Items = $items }) 400 3
    Update-WPConfigSummary
}

function Update-WPConfigSummary {
    $sel = @($state.Configs | Where-Object { $_.Selected })
    $bytes = [long](($sel | Where-Object { $_.Bytes -gt 0 } | Measure-Object Bytes -Sum).Sum)
    $running = @($sel | Where-Object { @($_.Running).Count }).Count
    Set-WPSummaryCard $ui.ConfigSummary $sel.Count $state.Configs.Count 'app settings ticked' @(
        @('Total size', (Format-WPSize $bytes), $Palette.Accent),
        @('Open right now', $running, $(if ($running) { $Palette.Warn } else { $Palette.Muted }))
    )
}

function Set-WPConfigs {
    param([object[]]$Configs)
    $state.Configs = @($Configs | Where-Object { $_ })
    $state.ConfigIndex = @{}
    $state.Cards = @{}
    foreach ($c in $state.Configs) {
        $state.ConfigIndex[$c.Id] = $c
        if ($state.Settings.ConfigSelections.ContainsKey($c.Id)) { $c.Selected = [bool]$state.Settings.ConfigSelections[$c.Id] }
        else { $c.Selected = (-not $c.Sensitive) -and $c.Bytes -lt 1GB }
        New-WPConfigCard $c
    }
    Update-WPConfigLayout
    Update-WPBackupStats
}

function Set-WPConfigSelected {
    param([string]$Id, [bool]$Value)
    $c = $state.ConfigIndex[$Id]
    if (-not $c) { return }
    $c.Selected = $Value
    $state.Settings.ConfigSelections[$Id] = $Value
    Save-WPSettings
    Update-WPConfigCard $c
    Update-WPConfigSummary
    Update-WPBackupStats
}

function Set-WPAllConfigs {
    param([string]$How)
    foreach ($c in $state.Configs) {
        if ($How -eq 'recommended') {
            $state.Settings.ConfigSelections.Remove($c.Id)
            $c.Selected = (-not $c.Sensitive) -and ($c.Bytes -lt 1GB)
        } else {
            $c.Selected = ($How -eq 'all')
            $state.Settings.ConfigSelections[$c.Id] = $c.Selected
        }
        Update-WPConfigCard $c
    }
    Save-WPSettings
    Update-WPConfigSummary
    Update-WPBackupStats
}

function Add-WPCustomConfig {
    param([string]$Path)
    if (-not $Path) { return }
    $name = Split-Path -Leaf $Path
    if (-not $name) { $name = $Path }
    $existing = @($state.Settings.CustomConfigs | Where-Object { $_.Path -eq $Path })
    if ($existing.Count) { return }
    $state.Settings.CustomConfigs = @($state.Settings.CustomConfigs) + @([pscustomobject]@{ Name = $name; Path = $Path })
    Save-WPSettings
    $c = New-WPCustomConfig $name $Path
    if (-not $c) { return }
    $c.Selected = $true
    Update-WPConfigSize $c
    $state.Configs = @($state.Configs) + @($c)
    $state.ConfigIndex[$c.Id] = $c
    New-WPConfigCard $c
    Update-WPConfigLayout
    Update-WPBackupStats
}

function Remove-WPCustomConfig {
    param([string]$Id)
    $c = $state.ConfigIndex[$Id]
    if (-not $c) { return }
    $path = $c.Items[0].Source
    $state.Settings.CustomConfigs = @($state.Settings.CustomConfigs | Where-Object { $_.Path -ne $path })
    $state.Settings.ConfigSelections.Remove($Id)
    Save-WPSettings
    $state.Configs = @($state.Configs | Where-Object { $_.Id -ne $Id })
    $state.ConfigIndex.Remove($Id)
    $state.Cards.Remove($Id)
    Update-WPConfigLayout
    Update-WPBackupStats
}

function Start-WPDetectConfigs {
    Start-WPJob 'Detect' {
        if ($P.Demo) { $configs = Get-WPDemoConfigs } else { $configs = Get-WPConfigCandidates $P.Apps $P.CustomConfigs }
        @{ Configs = $configs }
    } @{ Apps = @($state.Apps); CustomConfigs = @($state.Settings.CustomConfigs); Demo = [bool]$Demo } {
        param($r, $err)
        if ($r) { Set-WPConfigs @($r.Configs); Start-WPMeasure }
    }
}

#endregion

#region Extras tab -------------------------------------------------------------

function New-WPExtraCard {
    param($Ex)
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    $card.Padding = '16,13'
    $card.Margin = '0,0,0,10'
    $dp = New-Object Windows.Controls.DockPanel
    $sw = New-Object Windows.Controls.CheckBox
    $sw.Style = $window.FindResource('Switch')
    $sw.Tag = $Ex.Id
    $sw.VerticalAlignment = 'Center'
    $sw.Margin = '16,0,0,0'
    $sw.Add_Click({ Set-WPExtraSelected $this.Tag ([bool]$this.IsChecked) })
    [Windows.Controls.DockPanel]::SetDock($sw, 'Right')
    [void]$dp.Children.Add($sw)
    $glyphs = @{ fonts = 0xE8D2; envvars = 0xE756; wifi = 0xE701; drivers = 0xE964 }
    $glyph = 0xE8B7
    if ($glyphs.ContainsKey($Ex.Id)) { $glyph = $glyphs[$Ex.Id] }
    $tile = New-Object Windows.Controls.Border
    $tile.Width = 40; $tile.Height = 40; $tile.CornerRadius = 10; $tile.Margin = '0,0,14,0'; $tile.VerticalAlignment = 'Top'
    $tile.Background = Get-WPBrush $Palette.Accent 30
    $icon = New-Object Windows.Controls.TextBlock
    $icon.Text = [string][char]$glyph
    $icon.FontFamily = $window.FindResource('Icons')
    $icon.FontSize = 18
    $icon.Foreground = Get-WPBrush $Palette.Accent
    $icon.HorizontalAlignment = 'Center'; $icon.VerticalAlignment = 'Center'
    $tile.Child = $icon
    [Windows.Controls.DockPanel]::SetDock($tile, 'Left')
    [void]$dp.Children.Add($tile)
    $sp = New-Object Windows.Controls.StackPanel
    $titleRow = New-Object Windows.Controls.WrapPanel
    [void]$titleRow.Children.Add((New-WPText $Ex.Name 14 $Palette.Text 'SemiBold'))
    if ($Ex.Sensitive) { [void]$titleRow.Children.Add((New-WPBadge 'contains passwords' $Palette.Warn '10,0,0,0')) }
    [void]$sp.Children.Add($titleRow)
    [void]$sp.Children.Add((New-WPText $Ex.Description 12.5 $Palette.Muted -Wrap -Margin '0,3,0,0'))
    $info = New-WPText '' 12 $Palette.Accent -Margin '0,5,0,0'
    [void]$sp.Children.Add($info)
    [void]$dp.Children.Add($sp)
    $card.Child = $dp
    $state.ExtraCards[$Ex.Id] = @{ Root = $card; Switch = $sw; Info = $info }
    Update-WPExtraCard $Ex
    return $card
}

function Update-WPExtraCard {
    param($Ex)
    $r = $state.ExtraCards[$Ex.Id]
    if (-not $r) { return }
    $r.Switch.IsChecked = [bool]$Ex.Selected
    $r.Switch.IsEnabled = [bool]$Ex.Available
    $text = $Ex.Info
    if ($Ex.Id -like 'folder:*' -and $Ex.Bytes -lt 0) { $text = "measuring$Ellipsis" }
    if ($Ex.Status) { $text = "$text   Last backup: $($Ex.Status) $($Ex.Detail)".Trim() }
    $r.Info.Text = $text
    if ($Ex.Available) { $r.Info.Foreground = Get-WPBrush $Palette.Accent } else { $r.Info.Foreground = Get-WPBrush $Palette.Muted }
}

function Set-WPExtras {
    param([object[]]$Extras)
    $state.Extras = @($Extras | Where-Object { $_ })
    $state.ExtraIndex = @{}
    $state.ExtraCards = @{}
    $ui.ExtrasList.Children.Clear()
    $folderHeaderAdded = $false
    foreach ($e in $state.Extras) {
        $state.ExtraIndex[$e.Id] = $e
        if ($state.Settings.ExtraSelections.ContainsKey($e.Id) -and $e.Available) { $e.Selected = [bool]$state.Settings.ExtraSelections[$e.Id] }
        if ($e.Id -like 'folder:*' -and -not $folderHeaderAdded) {
            $folderHeaderAdded = $true
            [void]$ui.ExtrasList.Children.Add((New-WPText 'Your folders' 16 $Palette.Text 'SemiBold' -Margin '0,14,0,2'))
            [void]$ui.ExtrasList.Children.Add((New-WPText 'A reset that removes everything deletes these. Folders synced by OneDrive are already safe; turn on the others if they have anything you need. Restore copies files back without overwriting anything.' 12.5 $Palette.Muted -Wrap -Margin '0,0,0,10'))
        }
        [void]$ui.ExtrasList.Children.Add((New-WPExtraCard $e))
    }
    Update-WPBackupStats
}

function Set-WPExtraSelected {
    param([string]$Id, [bool]$Value)
    $e = $state.ExtraIndex[$Id]
    if (-not $e) { return }
    $e.Selected = $Value
    $state.Settings.ExtraSelections[$Id] = $Value
    Save-WPSettings
    Update-WPExtraCard $e
    Update-WPBackupStats
}

#endregion

#region Backup tab -------------------------------------------------------------

function Get-WPNetworkDrives {
    if ($Demo) { return @([pscustomobject]@{ Letter = 'N'; Unc = '\\NAS\Backups' }, [pscustomobject]@{ Letter = 'M'; Unc = '\\NAS\Media' }) }
    # Read from the registry: an elevated window can't see drives mapped in your normal session.
    foreach ($k in (Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $remote = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($remote) { [pscustomobject]@{ Letter = $k.PSChildName.ToUpperInvariant(); Unc = [string]$remote } }
    }
}

function Get-WPSuggestedDestination {
    $drives = @(Get-WPNetworkDrives)
    $pick = $drives | Where-Object { $_.Unc -match 'backup|personal|home|user' } | Select-Object -First 1
    if (-not $pick) { $pick = $drives | Select-Object -First 1 }
    if ($pick) { return ($pick.Unc.TrimEnd('\') + '\WinPrestige Backup') }
    return ''
}

function Set-WPDestChips {
    $ui.DestChips.Children.Clear()
    $chips = @()
    foreach ($d in @(Get-WPNetworkDrives)) {
        $leaf = @($d.Unc.TrimEnd('\') -split '\\' | Where-Object { $_ })[-1]
        $chips += @{ Text = "$($d.Letter):  $leaf"; Path = $d.Unc.TrimEnd('\') + '\WinPrestige Backup'; Tip = $d.Unc }
    }
    $disks = if ($Demo) { @([pscustomobject]@{ DeviceID = 'D:'; VolumeName = 'Games' }) } else { @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) }
    foreach ($d in $disks) {
        if ($d.DeviceID -eq $env:SystemDrive) { continue }
        $chips += @{ Text = "$($d.DeviceID)  $($d.VolumeName)".Trim(); Path = "$($d.DeviceID)\WinPrestige Backup"; Tip = 'Local drive (survives a reset only if you don''t wipe all drives)' }
    }
    foreach ($c in $chips) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $window.FindResource('Btn')
        $b.Padding = '10,4'
        $b.Margin = '0,0,6,6'
        $b.FontSize = 12
        $b.Content = $c.Text
        $b.Tag = $c.Path
        $b.ToolTip = $c.Tip
        $b.Add_Click({ $ui.DestBox.Text = $this.Tag; Update-WPDestInfo -CheckExisting })
        [void]$ui.DestChips.Children.Add($b)
    }
}

function Get-WPFreeSpace {
    param([string]$Path)
    if ($Demo) { return [long]3958241859174 }
    try {
        if ($Path -match '^\\\\') {
            foreach ($d in @(Get-WPNetworkDrives)) {
                if ($Path.StartsWith($d.Unc.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                    $di = New-Object IO.DriveInfo $d.Letter
                    if ($di.IsReady) { return $di.AvailableFreeSpace }
                }
            }
            return $null
        }
        $di = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))
        if ($di.IsReady) { return $di.AvailableFreeSpace }
    } catch { }
    return $null
}

function Update-WPDestInfo {
    param([switch]$CheckExisting)
    $p = $ui.DestBox.Text.Trim().Trim('"')
    $color = $Palette.Muted
    $msgs = @()
    if (-not $p) {
        $ui.DestInfo.Text = 'Choose where to save the backup, for example a folder on your NAS.'
        $ui.DestInfo.Foreground = Get-WPBrush $Palette.Warn
        return
    }
    if ($p -match '^\\\\') {
        $msgs += 'Network share. After the reset, open it in File Explorer (or your NAS app) and run Restore.cmd.'
    } else {
        $root = [IO.Path]::GetPathRoot($p)
        if ($root -and $root.TrimEnd('\') -ieq $env:SystemDrive) {
            $msgs += "This is on $($env:SystemDrive), which the reset wipes. Pick your NAS or another drive."
            $color = $Palette.Warn
        }
    }
    $free = Get-WPFreeSpace $p
    if ($null -ne $free) { $msgs += "$(Format-WPSize $free) free." }
    if ($CheckExisting -and $Demo) {
        $msgs += "Already has a backup from $((Get-Date).AddDays(-1).ToString('d MMM yyyy')) 21:14. It gets updated: new apps added, removed ones pruned."
    } elseif ($CheckExisting) {
        try {
            $mf = Join-Path $p 'manifest.json'
            if (Test-Path -LiteralPath $mf) {
                $m = Read-WPJson $mf
                $msgs += "Already has a backup from $(([datetime]$m.created).ToString('d MMM yyyy HH:mm')). It gets updated: new apps added, removed ones pruned."
                $state.LastReport = Join-Path $p 'AppInventory.html'
            }
        } catch { }
    }
    $ui.DestInfo.Text = $msgs -join '  '
    $ui.DestInfo.Foreground = Get-WPBrush $color
}

function New-WPStatTile {
    param($Value, [string]$Label, [string]$Color = '#E6E8EB')
    $b = New-Object Windows.Controls.Border
    $b.Background = Get-WPBrush $Palette.Tile
    $b.CornerRadius = 8
    $b.Padding = '14,9'
    $b.Margin = '0,0,8,8'
    $b.MinWidth = 128
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-WPText ([string]$Value) 20 $Color 'SemiBold'))
    [void]$sp.Children.Add((New-WPText $Label 11.5 $Palette.Muted))
    $b.Child = $sp
    return $b
}

function Update-WPBackupStats {
    if (-not $ui.BackupStats) { return }
    $sel = @($state.Apps | Where-Object { $_.Selected })
    $counts = @{}
    foreach ($a in $sel) { $p = Get-WPAppPlan $a; $counts[$p] = 1 + [int]$counts[$p] }
    $cfg = @($state.Configs | Where-Object { $_.Selected })
    $cfgBytes = [long](($cfg | Where-Object { $_.Bytes -gt 0 } | Measure-Object Bytes -Sum).Sum)
    $ext = @($state.Extras | Where-Object { $_.Selected -and $_.Available })
    $manual = [int]$counts['manual'] + [int]$counts['unchecked']
    $ui.BackupStats.Children.Clear()
    foreach ($t in @(
            @($sel.Count, 'apps ticked', $Palette.Text),
            @(([int]$counts['winget'] + [int]$counts['custom']), 'installers to save', $Palette.Accent),
            @(([int]$counts['store'] + [int]$counts['storelink']), 'from the Store', $Palette.Purple),
            @($manual, 'manual downloads', $(if ($manual) { $Palette.Warn } else { $Palette.Text })),
            @($cfg.Count, "app settings ($(Format-WPSize $cfgBytes))", $Palette.Text),
            @($ext.Count, 'extras', $Palette.Text))) {
        [void]$ui.BackupStats.Children.Add((New-WPStatTile $t[0] $t[1] $t[2]))
    }
}

function Test-WPWritable {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Path ('.winprestige-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe, 'ok')
        [IO.File]::Delete($probe)
        return $null
    } catch { return $_.Exception.Message }
}

function Connect-WPShare {
    # Shows Windows' own sign-in prompt for the share, so this admin window can reach it.
    param([string]$Unc)
    if (-not ('WinPrestige.Net' -as [type])) {
        Add-Type -Namespace WinPrestige -Name Net -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public class NETRESOURCE { public int dwScope; public int dwType = 1; public int dwDisplayType; public int dwUsage; public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider; }
[DllImport("mpr.dll", CharSet = CharSet.Unicode)]
public static extern int WNetAddConnection3(IntPtr hwndOwner, NETRESOURCE lpNetResource, string lpPassword, string lpUserName, int dwFlags);
'@
    }
    $share = $Unc -replace '^(\\\\[^\\]+\\[^\\]+).*$', '$1'
    $nr = New-Object 'WinPrestige.Net+NETRESOURCE'
    $nr.lpRemoteName = $share
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    return [WinPrestige.Net]::WNetAddConnection3($hwnd, $nr, $null, $null, 0x18)
}

function Confirm-WPReachable {
    # Returns $true when the folder can be written, offering to sign in to the share if not.
    param([string]$Path)
    $err = Test-WPWritable $Path
    if (-not $err) { return $true }
    if ($Path -match '^\\\\') {
        $ans = [System.Windows.MessageBox]::Show($window, "This admin window can't reach the share yet:`n$err`n`nSign in to it now? Windows will ask for your NAS user name and password.", 'WinPrestige', 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            $rc = Connect-WPShare $Path
            if ($rc -eq 0) { $err = Test-WPWritable $Path; if (-not $err) { return $true } }
        }
    }
    if ($err) { [void][System.Windows.MessageBox]::Show($window, "Can't write to that folder:`n$err", 'WinPrestige', 'OK', 'Warning') }
    return $false
}

function Start-WPBackup {
    $dest = $ui.DestBox.Text.Trim().Trim('"')
    if (-not $dest) { [void][System.Windows.MessageBox]::Show($window, 'Choose where to save the backup first.', 'WinPrestige'); $ui.DestBox.Focus(); return }
    if ($Demo) {
        $ui.BackupLog.Items.Clear()
        $state.LogTarget = $ui.BackupLog
        $demoOpts = @{ Installers = $true; Configs = [bool]$ui.OptConfigs.IsChecked; Extras = [bool]$ui.OptExtras.IsChecked; Prune = [bool]$ui.OptPrune.IsChecked }
        Start-WPJob 'Backup' {
            Invoke-WPDemoBackup $P.Apps $P.Configs $P.Extras $P.Destination $P.Options
        } @{ Apps = @($state.Apps); Configs = @($state.Configs); Extras = @($state.Extras); Destination = $dest; Options = $demoOpts } {
            param($r, $err)
            if ($r -and $r.Report) {
                $state.LastReport = [string]$r.Report
                Set-WPStatus 'Backup saved. 1 download failed; the restore installs it with winget online.'
            }
            foreach ($a in $state.Apps) { Update-WPAppRow $a }
        }
        return
    }
    $dest = ConvertTo-WPUncPath $dest
    $ui.DestBox.Text = $dest
    $root = [IO.Path]::GetPathRoot($dest)
    if ($root -and $root.TrimEnd('\') -ieq $env:SystemDrive) {
        $ans = [System.Windows.MessageBox]::Show($window, "This folder is on $($env:SystemDrive), which the reset will wipe. Back up there anyway?", 'WinPrestige', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    if (-not (Confirm-WPReachable $dest)) { return }
    if ($ui.OptCloseApps.IsChecked -and $ui.OptConfigs.IsChecked) {
        $running = @()
        foreach ($c in @($state.Configs | Where-Object { $_.Selected })) {
            $c.Running = @(Get-WPRunningProcesses $c)
            if (@($c.Running).Count) { $running += $c }
            Update-WPConfigCard $c
        }
        if ($running.Count) {
            $names = ($running | ForEach-Object { $_.Name }) -join ', '
            $ans = [System.Windows.MessageBox]::Show($window, "These apps are open: $names.`n`nClose them now so their settings copy cleanly?`n`nYes closes them. No backs up anyway.", 'WinPrestige', 'YesNoCancel', 'Question')
            if ($ans -eq 'Cancel') { return }
            if ($ans -eq 'Yes') {
                foreach ($c in $running) { foreach ($p in @($c.Running)) { Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } }
                Start-Sleep -Milliseconds 1200
                foreach ($c in $running) { $c.Running = @(); Update-WPConfigCard $c }
            }
        }
    }
    $state.Settings.Destination = $dest
    Save-WPSettings
    $ui.BackupLog.Items.Clear()
    $state.LogTarget = $ui.BackupLog
    $opts = @{
        Installers = [bool]$ui.OptInstallers.IsChecked; Configs = [bool]$ui.OptConfigs.IsChecked; Extras = [bool]$ui.OptExtras.IsChecked
        Prune = [bool]$ui.OptPrune.IsChecked; Redownload = [bool]$ui.OptRedownload.IsChecked
    }
    Start-WPJob 'Backup' {
        Invoke-WPBackup $P.Apps $P.Configs $P.Extras $P.Destination $P.Options
    } @{ Apps = @($state.Apps); Configs = @($state.Configs); Extras = @($state.Extras); Destination = $dest; Options = $opts } {
        param($r, $err)
        if ($r -and $r.Report) {
            $state.LastReport = [string]$r.Report
            $msg = 'Backup saved.'
            if ($r.Failed) { $msg += " $($r.Failed) downloads failed; the restore installs those with winget online." }
            Set-WPStatus $msg
            Update-WPDestInfo -CheckExisting
        }
        foreach ($a in $state.Apps) { Update-WPAppRow $a }
    }
}

#endregion

#region Restore tab ------------------------------------------------------------

function Get-WPRestoreBadge {
    param($Entry)
    switch ($Entry.Method) {
        'local' { return @{ Text = 'saved installer'; Color = $Palette.Good } }
        'winget' { return @{ Text = 'winget online'; Color = $Palette.Accent } }
        'store' { return @{ Text = 'Store'; Color = $Palette.Purple } }
        'storelink' { return @{ Text = 'Store page'; Color = $Palette.Purple } }
        'game' { return @{ Text = [string]$Entry.Via; Color = $Palette.Muted } }
        default { return @{ Text = 'manual'; Color = $Palette.Warn } }
    }
}

function New-WPRestoreRow {
    param([string]$Key, [string]$Name, [string]$Group, $Badge, [string]$Tip, [bool]$Checked, [bool]$Enabled = $true)
    $row = New-Object Windows.Controls.Border
    $row.Style = $window.FindResource('Row')
    $row.Height = [double]::NaN
    $row.Padding = '8,4,6,4'
    $g = New-Object Windows.Controls.Grid
    foreach ($w in @('Auto', 'Auto', '*', 'Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -eq '*') { $cd.Width = New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star) } else { $cd.Width = [Windows.GridLength]::Auto }
        $g.ColumnDefinitions.Add($cd)
    }
    $cb = New-Object Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('Chk')
    $cb.Tag = $Key
    $cb.IsChecked = $Checked
    $cb.IsEnabled = $Enabled
    $cb.VerticalAlignment = 'Top'
    $cb.Margin = '0,2,0,0'
    $cb.Add_Click({ $state.RestoreSel[$this.Tag] = [bool]$this.IsChecked; Update-WPRestoreSummary })
    $avatar = New-WPAvatar $Name 22
    $avatar.Margin = '9,0,0,0'
    $avatar.VerticalAlignment = 'Top'
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '10,0,4,0'
    $nameText = New-WPText $Name 13 $Palette.Text
    $statusRow = New-Object Windows.Controls.DockPanel
    $statusRow.Visibility = 'Collapsed'
    $spinHost = New-Object Windows.Controls.ContentControl
    $spinHost.Margin = '0,1,6,0'
    $spinHost.VerticalAlignment = 'Center'
    $spinHost.Visibility = 'Collapsed'
    [Windows.Controls.DockPanel]::SetDock($spinHost, 'Left')
    $status = New-WPText '' 11.5 $Palette.Muted
    [void]$statusRow.Children.Add($spinHost)
    [void]$statusRow.Children.Add($status)
    [void]$sp.Children.Add($nameText)
    [void]$sp.Children.Add($statusRow)
    $badgeHost = New-Object Windows.Controls.Border
    $badgeHost.VerticalAlignment = 'Top'
    $badgeHost.Margin = '0,1,0,0'
    if ($Badge) { $badgeHost.Child = New-WPBadge $Badge.Text $Badge.Color }
    [Windows.Controls.Grid]::SetColumn($avatar, 1)
    [Windows.Controls.Grid]::SetColumn($sp, 2)
    [Windows.Controls.Grid]::SetColumn($badgeHost, 3)
    [void]$g.Children.Add($cb)
    [void]$g.Children.Add($avatar)
    [void]$g.Children.Add($sp)
    [void]$g.Children.Add($badgeHost)
    $row.Child = $g
    if ($Tip) { $row.ToolTip = $Tip }
    $state.RRows[$Key] = @{ Root = $row; Check = $cb; Status = $status; StatusRow = $statusRow; SpinHost = $spinHost; Name = $Name; Group = $Group }
    $state.RestoreSel[$Key] = $Checked
}

function Update-WPRestoreStatus {
    param([string]$Key, [string]$Status, [string]$Level)
    $r = $state.RRows[$Key]
    if (-not $r) { return }
    $color = switch ($Level) { 'ok' { $Palette.Good } 'warn' { $Palette.Warn } 'error' { $Palette.Bad } 'step' { $Palette.Accent } default { $Palette.Muted } }
    $r.Status.Text = $Status
    $r.Status.ToolTip = $Status
    $r.Status.Foreground = Get-WPBrush $color
    $r.StatusRow.Visibility = 'Visible'
    if ($Level -eq 'step') {
        if (-not $r.SpinHost.Content) { $r.SpinHost.Content = New-WPSpinner 11 }
        $r.SpinHost.Visibility = 'Visible'
    } else {
        $r.SpinHost.Visibility = 'Collapsed'
    }
}

function Import-WPBackup {
    param([string]$Path)
    $path = $Path.Trim().Trim('"')
    if (-not $path) { return }
    $path = ConvertTo-WPUncPath $path
    $ui.RestorePath.Text = $path
    if ($Demo) { $m = Get-WPDemoManifest } else {
    $mf = Join-Path $path 'manifest.json'
    $found = $false
    try { $found = Test-Path -LiteralPath $mf } catch { }
    if (-not $found -and $path -match '^\\\\') {
        if (Confirm-WPReadable $path) { $found = Test-Path -LiteralPath $mf }
    }
    if (-not $found) {
        $ui.RestoreInfo.Text = "No WinPrestige backup found there (manifest.json is missing)."
        $ui.RestoreInfo.Foreground = Get-WPBrush $Palette.Warn
        return
    }
    try { $m = Read-WPJson $mf } catch {
        $ui.RestoreInfo.Text = "Couldn't read the backup: $($_.Exception.Message)"
        return
    }
    }
    $state.Restore = $m
    $state.RestoreRoot = $path
    $state.RRows = @{}
    $state.RestoreSel = @{}
    $apps = @($m.apps)
    foreach ($e in $apps) {
        if ($e.Category -eq 'system') { continue }
        if ($e.Category -eq 'games') {
            if (-not $e.GameUri) { continue }
            New-WPRestoreRow $e.Key $e.Name 'games' (Get-WPRestoreBadge ([pscustomobject]@{ Method = 'game'; Via = $e.Via })) 'Tick, then use "Queue ticked games in Steam" once Steam is installed and signed in.' $false
            continue
        }
        if (-not $e.Selected) { continue }
        $tip = $e.Name
        if ($e.Download -and $e.Download.Installer) { $tip += "`nInstaller: $($e.Download.Installer)" }
        if ($e.WingetId) { $tip += "`nwinget: $($e.WingetId)" }
        New-WPRestoreRow $e.Key $e.Name ([string]$e.Category) (Get-WPRestoreBadge $e) $tip $true
    }
    foreach ($c in @($m.configs)) {
        $ok = @('Saved', 'Partial') -contains $c.Status
        New-WPRestoreRow ('config:' + $c.Id) $c.Name 'configs' @{ Text = 'settings'; Color = $Palette.Accent } ([string]$c.Notes) $ok $ok
    }
    foreach ($x in @($m.extras)) {
        $ok = @('Saved', 'Partial') -contains $x.Status
        New-WPRestoreRow ('extra:' + $x.Id) $x.Name 'extras' @{ Text = 'extra'; Color = $Palette.Muted } ([string]$x.Detail) $ok $ok
    }
    $selCount = @($apps | Where-Object { $_.Selected }).Count
    $info = "Backup of $($m.computer) from $(([datetime]$m.created).ToString('d MMM yyyy HH:mm')): $selCount apps, $(@($m.configs).Count) app settings."
    if (-not $script:WP.Winget) { $info += ' winget is not ready yet, so only saved installers work. Update "App Installer" from the Microsoft Store, or wait a few minutes after first sign-in.' }
    $ui.RestoreInfo.Text = $info
    $ui.RestoreInfo.Foreground = Get-WPBrush $Palette.Muted
    if (-not $Demo) { Add-WPRecentBackup $path ([string]$m.computer) ([string]$m.created) }
    Update-WPRestoreChips
    Update-WPRestoreLayout
}

function Format-WPBackupDate {
    param([string]$Created, [switch]$Short)
    try {
        $d = [datetime]$Created
        if ($Short) { return $d.ToString('d MMM') }
        return $d.ToString('d MMM yyyy, HH:mm')
    } catch { return '' }
}

function Add-WPRecentBackup {
    param([string]$Path, [string]$Computer, [string]$Created)
    $list = @([pscustomobject]@{ Path = $Path; Computer = $Computer; Created = $Created })
    foreach ($b in @($state.Settings.RecentBackups)) { if ($b -and $b.Path -and $b.Path -ne $Path) { $list += $b } }
    $state.Settings.RecentBackups = @($list | Select-Object -First 5)
    Save-WPSettings
}

function Update-WPRestoreChips {
    # Shortcuts to recently loaded and automatically found backups.
    $ui.RestoreChips.Children.Clear()
    $items = @()
    $seen = @{}
    foreach ($b in (@($state.Settings.RecentBackups) + @($state.FoundBackups))) {
        if (-not $b -or -not $b.Path) { continue }
        $k = ([string]$b.Path).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $items += $b
    }
    foreach ($b in @($items | Select-Object -First 5)) {
        $btn = New-Object Windows.Controls.Button
        $btn.Style = $window.FindResource('Btn')
        $btn.Padding = '9,4'
        $btn.Margin = '0,0,6,6'
        $btn.FontSize = 11.5
        $label = [string]$b.Computer
        if (-not $label) { $label = Split-Path -Leaf $b.Path }
        $when = Format-WPBackupDate $b.Created -Short
        if ($when) { $label = "$label  $MidDot  $when" }
        $btn.Content = $label
        $btn.ToolTip = [string]$b.Path
        $btn.Tag = [string]$b.Path
        $btn.Add_Click({ Hide-WPBanner; Import-WPBackup $this.Tag })
        [void]$ui.RestoreChips.Children.Add($btn)
    }
    if ($items.Count) { $ui.RestoreChips.Visibility = 'Visible' } else { $ui.RestoreChips.Visibility = 'Collapsed' }
}

function Show-WPBanner {
    param([string]$Kind, [string]$Title, [string]$Text, [string]$Primary, [string]$Secondary, [int]$Glyph = 0xE777)
    $state.BannerKind = $Kind
    $ui.BannerTitle.Text = $Title
    $ui.BannerText.Text = $Text
    $ui.BannerPrimary.Content = $Primary
    $ui.BannerSecondary.Content = $Secondary
    if ($Secondary) { $ui.BannerSecondary.Visibility = 'Visible' } else { $ui.BannerSecondary.Visibility = 'Collapsed' }
    $ui.BannerIcon.Text = [string][char]$Glyph
    $ui.Banner.Visibility = 'Visible'
    Invoke-WPFadeIn $ui.Banner 8 260
}

function Hide-WPBanner {
    $ui.Banner.Visibility = 'Collapsed'
    $state.BannerKind = ''
}

function Show-WPFoundBanner {
    param($Backup)
    $state.BannerBackup = $Backup
    $when = Format-WPBackupDate $Backup.Created
    $text = "Made {0}: {1} apps and {2} app settings, in {3}. Just reset this PC? Put it all back in one go." -f $when, $Backup.Apps, $Backup.Configs, $Backup.Path
    Show-WPBanner 'found' ("Found a backup of {0}" -f $Backup.Computer) $text 'Restore everything' 'Review first'
}

function Show-WPResumeBanner {
    param($Progress)
    $state.BannerProgress = $Progress
    $doneMap = ConvertTo-WPHashtable $Progress.done
    $finished = @($doneMap.Values | Where-Object { @('ok', 'manual', 'skipped') -contains $_ }).Count
    $pc = [string]$Progress.computer
    if (-not $pc) { $pc = 'your PC' }
    Show-WPBanner 'resume' ("Your restore of {0} is {1} of {2} done" -f $pc, $finished, $Progress.total) 'It stopped before it finished, usually because of a restart. Pick up where it left off; anything already installed is skipped.' 'Continue restore' 'Review first' 0xE768
}

function Set-WPResumeSelection {
    # Ticks only what's left from an interrupted restore and shows what happened to the rest.
    param($Progress)
    $doneMap = ConvertTo-WPHashtable $Progress.done
    $sel = @{}
    foreach ($k in @($Progress.selected.apps)) { if ($k) { $sel[[string]$k] = $true } }
    foreach ($k in @($Progress.selected.configs)) { if ($k) { $sel['config:' + $k] = $true } }
    foreach ($k in @($Progress.selected.extras)) { if ($k) { $sel['extra:' + $k] = $true } }
    foreach ($key in @($state.RRows.Keys)) {
        $was = [string]$doneMap[$key]
        $want = $sel.ContainsKey($key) -and (@('ok', 'manual', 'skipped') -notcontains $was)
        $state.RestoreSel[$key] = $want
        $state.RRows[$key].Check.IsChecked = $want
        switch ($was) {
            'ok' { Update-WPRestoreStatus $key 'Installed before the restart' 'ok' }
            'skipped' { Update-WPRestoreStatus $key 'Already installed' 'info' }
            'manual' { Update-WPRestoreStatus $key 'Needs a manual download' 'warn' }
            'failed' { Update-WPRestoreStatus $key 'Failed last time; will try again' 'warn' }
        }
    }
    Update-WPRestoreSummary
}

function Invoke-WPBannerAction {
    param([string]$Which)
    $kind = $state.BannerKind
    Hide-WPBanner
    switch ($kind) {
        'found' {
            Import-WPBackup $state.BannerBackup.Path
            if (-not $state.Restore) { return }
            $ui.TabRestore.IsChecked = $true
            if ($Which -eq 'primary') { Start-WPRestore -NoConfirm }
        }
        'resume' {
            $pr = $state.BannerProgress
            Import-WPBackup ([string]$pr.backup)
            if (-not $state.Restore) { return }
            Set-WPResumeSelection $pr
            $ui.TabRestore.IsChecked = $true
            if ($Which -eq 'primary') { Start-WPRestore -NoConfirm -Progress $pr }
        }
        'welcome' {
            if ($Which -ne 'primary') { return }
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = 'Pick the WinPrestige backup folder you made before the reset (the one with manifest.json in it).'
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Import-WPBackup $d.SelectedPath
                if ($state.Restore) { $ui.TabRestore.IsChecked = $true }
            }
        }
    }
}

function Start-WPFindBackups {
    # Looks for backups in the background so the window stays responsive.
    $extra = @()
    $parent = Split-Path -Parent $WPRoot
    if ($parent) { $extra += $parent }
    $extra += @($state.Settings.RecentBackups | ForEach-Object { if ($_) { [string]$_.Path } })
    Start-WPJob 'FindBackups' {
        @{ Found = @(Find-WPBackups $P.Extra) }
    } @{ Extra = @($extra) } {
        param($r, $err)
        $state.FoundBackups = @()
        if ($r) { $state.FoundBackups = @($r.Found | Where-Object { $_ }) }
        Update-WPRestoreChips
        if (-not $ui.RestorePath.Text -and $state.FoundBackups.Count) { $ui.RestorePath.Text = [string]$state.FoundBackups[0].Path }
        if (-not $FirstRun -or $state.Restore -or $state.Page -eq 'Restore' -or $state.BannerKind) { return }
        if ($Screenshot -and @('Banner', 'Review') -notcontains $ScreenshotAction) { return }
        if ($state.FoundBackups.Count) { Show-WPFoundBanner $state.FoundBackups[0] }
        else {
            Show-WPBanner 'welcome' 'Just reset this PC?' 'Link the backup folder you made before the reset, on your NAS or an external drive (or drag it onto this window), and WinPrestige reinstalls everything. Or carry on to back up this PC.' 'Find my backup...' 'Back up this PC' 0xE8B7
        }
    } -Quiet
}

function Initialize-WPRestoreHelpers {
    Update-WPRestoreChips
    if ($Demo) {
        $state.FoundBackups = @(Find-WPDemoBackups)
        Update-WPRestoreChips
        if ($Mode -ne 'Restore' -and (-not $Screenshot -or @('Banner', 'Review') -contains $ScreenshotAction)) { Show-WPFoundBanner $state.FoundBackups[0] }
        return
    }
    $pr = Get-WPRestoreProgress
    if ($pr -and -not ($Screenshot -and @('Banner', 'Review') -notcontains $ScreenshotAction)) { Show-WPResumeBanner $pr; return }
    if ($Mode -eq 'Restore' -and $BackupPath) { return }
    Start-WPFindBackups
}

$FileDropCode = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Interop;

namespace WinPrestige
{
    // Windows blocks modern (OLE) drag-and-drop from Explorer into windows running as administrator.
    // The classic WM_DROPFILES message still works once it's allowed through the window's message filter.
    public static class FileDrop
    {
        const int WM_DROPFILES = 0x0233;
        const uint WM_COPYDATA = 0x004A;
        const uint WM_COPYGLOBALDATA = 0x0049;
        const uint MSGFLT_ALLOW = 1;

        [DllImport("shell32.dll")] static extern void DragAcceptFiles(IntPtr hwnd, bool accept);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint DragQueryFile(IntPtr hDrop, uint index, StringBuilder file, uint size);
        [DllImport("shell32.dll")] static extern void DragFinish(IntPtr hDrop);
        [DllImport("user32.dll")] static extern bool ChangeWindowMessageFilterEx(IntPtr hwnd, uint msg, uint action, IntPtr info);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);

        static Action<string[]> onDrop;

        public static void Enable(IntPtr hwnd, Action<string[]> callback)
        {
            onDrop = callback;
            ChangeWindowMessageFilterEx(hwnd, (uint)WM_DROPFILES, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(hwnd, WM_COPYGLOBALDATA, MSGFLT_ALLOW, IntPtr.Zero);
            DragAcceptFiles(hwnd, true);
            HwndSource.FromHwnd(hwnd).AddHook(Hook);
        }

        static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg != WM_DROPFILES) return IntPtr.Zero;
            uint count = DragQueryFile(wParam, 0xFFFFFFFF, null, 0);
            string[] files = new string[count];
            for (uint i = 0; i < count; i++)
            {
                StringBuilder sb = new StringBuilder(1024);
                DragQueryFile(wParam, i, sb, (uint)sb.Capacity);
                files[i] = sb.ToString();
            }
            DragFinish(wParam);
            handled = true;
            if (onDrop != null) onDrop(files);
            return IntPtr.Zero;
        }

        // Testing aid: posts the same message Explorer sends when files are dropped on the window.
        public static void SimulateDrop(IntPtr hwnd, string[] files)
        {
            byte[] chars = Encoding.Unicode.GetBytes(string.Join("\0", files) + "\0\0");
            const int header = 20;   // DROPFILES: pFiles, pt.x, pt.y, fNC, fWide
            IntPtr handle = GlobalAlloc(0x0042, (UIntPtr)(uint)(header + chars.Length));
            IntPtr p = GlobalLock(handle);
            Marshal.WriteInt32(p, 0, header);
            Marshal.WriteInt32(p, 16, 1);
            Marshal.Copy(chars, 0, IntPtr.Add(p, header), chars.Length);
            GlobalUnlock(handle);
            PostMessage(hwnd, WM_DROPFILES, handle, IntPtr.Zero);
        }
    }
}
"@

function Enable-WPFileDrop {
    # Compiled once and cached, so later starts don't pay for the compiler.
    if (-not ('WinPrestige.FileDrop' -as [type])) {
        $refs = @([Windows.Interop.HwndSource].Assembly.Location, [Windows.Threading.Dispatcher].Assembly.Location)
        $sha = New-Object Security.Cryptography.SHA1Managed
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($FileDropCode))) -replace '-', '').Substring(0, 12)
        $dll = Join-Path $script:WP.StateDir "FileDrop-$hash.dll"
        try {
            if (-not (Test-Path -LiteralPath $dll)) { Add-Type -TypeDefinition $FileDropCode -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library -ErrorAction Stop }
            if (-not ('WinPrestige.FileDrop' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        } catch {
            try { Add-Type -TypeDefinition $FileDropCode -ReferencedAssemblies $refs -ErrorAction Stop } catch { return }
        }
    }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    [WinPrestige.FileDrop]::Enable($hwnd, [Action[string[]]] { param($files) Invoke-WPDroppedPaths $files })
}

function Find-WPBackupFolder {
    # The dropped item itself, a "WinPrestige Backup" folder inside it, or (for the app folder
    # that sits inside every backup) its parent.
    param([string]$Path)
    if (-not $Path) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $Path = Split-Path -Parent $Path }
    foreach ($c in @($Path, (Join-Path $Path 'WinPrestige Backup'), (Split-Path -Parent $Path))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'manifest.json'))) { return $c.TrimEnd('\') }
    }
    return $null
}

function Invoke-WPDroppedPaths {
    param([string[]]$Paths)
    $items = @($Paths | Where-Object { $_ })
    if ($items.Count -eq 0) { return }
    $backup = Find-WPBackupFolder $items[0]
    if ($backup) {
        Hide-WPBanner
        Import-WPBackup $backup
        if ($state.Restore) { $ui.TabRestore.IsChecked = $true }
        return
    }
    if ($state.Page -eq 'Configs') {
        foreach ($p in $items) { Add-WPCustomConfig $p }
        Set-WPStatus ("Added {0} to App settings." -f $(if ($items.Count -eq 1) { Split-Path -Leaf $items[0] } else { "$($items.Count) items" }))
        return
    }
    Set-WPStatus "That isn't a WinPrestige backup. Drop the backup folder, the one with manifest.json in it."
}

function Set-WPRunOnce {
    # If Windows restarts mid-restore, reopen WinPrestige after sign-in so it can offer to continue.
    $exe = Join-Path $WPRoot 'WinPrestige.exe'
    if (Test-Path -LiteralPath $exe) { $cmd = "`"$exe`" -Mode Restore -Resume" }
    else { $cmd = "`"$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Join-Path $WPRoot 'WinPrestige.ps1')`" -Mode Restore -Resume" }
    try { New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'WinPrestige' -Value $cmd -PropertyType String -Force | Out-Null } catch { }
}

function Remove-WPRunOnce {
    try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'WinPrestige' -ErrorAction Stop } catch { }
}

function Confirm-WPReadable {
    param([string]$Path)
    $ans = [System.Windows.MessageBox]::Show($window, "This admin window can't open the share yet.`n`nSign in to it now? Windows will ask for your NAS user name and password.", 'WinPrestige', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return $false }
    return ((Connect-WPShare $Path) -eq 0)
}

function Update-WPRestoreLayout {
    if (-not $state.Restore) {
        $ui.RestoreEmpty.Visibility = 'Visible'
        return
    }
    $ui.RestoreEmpty.Visibility = 'Collapsed'
    foreach ($k in @($state.GroupChecks.Keys)) { if ($k -like 'restore|*') { $state.GroupChecks.Remove($k) } }
    $groups = @()
    $order = @('runtimes', 'drivers', 'launchers', 'apps', 'store', 'bundled', 'configs', 'extras', 'games')
    $titles = @{ configs = 'App settings'; extras = 'Extras' }
    $hints = @{
        configs = 'Restored after the apps are installed.'; extras = 'Fonts, environment variables and anything else you saved.'
        games = 'Not installed automatically. Tick some, then queue them in Steam.'
    }
    foreach ($gid in $order) {
        $rows = @($state.RRows.Keys | ForEach-Object { $state.RRows[$_] } | Where-Object { $_.Group -eq $gid -and (Test-WPFilter @($_.Name)) } | Sort-Object Name)
        if ($rows.Count -eq 0) { continue }
        $title = $titles[$gid]
        if (-not $title) { $title = (Get-WPCategoryInfo $gid).title }
        $hint = $hints[$gid]
        $groups += @{ Title = $title; Header = (New-WPGroupHeader $title $rows.Count $hint ('restore|' + $gid)); Items = @($rows | ForEach-Object { $_.Root }) }
    }
    $state.RestoreCols = Set-WPMasonry $ui.RestoreColumns $ui.RestoreScroll $groups 320 3
    Update-WPRestoreSummary
}

function Update-WPRestoreSummary {
    if (-not $state.Restore) { $ui.RestoreSummary.Children.Clear(); $ui.RestoreSummaryCard.Visibility = 'Collapsed'; return }
    $ui.RestoreSummaryCard.Visibility = 'Visible'
    $all = @($state.Restore.apps | Where-Object { $_.Selected -and $_.Category -ne 'games' -and $_.Category -ne 'system' })
    $apps = @($state.Restore.apps | Where-Object { $state.RestoreSel[$_.Key] -and $_.Category -ne 'games' })
    $counts = @{}
    foreach ($a in $apps) { $counts[[string]$a.Method] = 1 + [int]$counts[[string]$a.Method] }
    $cfg = @($state.Restore.configs | Where-Object { $state.RestoreSel['config:' + $_.Id] }).Count
    $ext = @($state.Restore.extras | Where-Object { $state.RestoreSel['extra:' + $_.Id] }).Count
    $games = @($state.Restore.apps | Where-Object { $_.Category -eq 'games' -and $state.RestoreSel[$_.Key] }).Count
    Set-WPSummaryCard $ui.RestoreSummary $apps.Count $all.Count 'apps to reinstall' @(
        @('Saved installers', [int]$counts['local'], $Palette.Good),
        @('winget online', [int]$counts['winget'], $Palette.Accent),
        @('Microsoft Store', ([int]$counts['store'] + [int]$counts['storelink']), $Palette.Purple),
        @('Manual', [int]$counts['manual'], $Palette.Warn),
        @('App settings', $cfg, $Palette.Soft),
        @('Extras', $ext, $Palette.Soft),
        @('Games to queue', $games, $Palette.Muted)
    )
    Update-WPGroupChecks
}

function Start-WPRestore {
    param([switch]$NoConfirm, $Progress)
    if (-not $state.Restore) { [void][System.Windows.MessageBox]::Show($window, 'Load a backup folder first.', 'WinPrestige'); return }
    Hide-WPBanner
    $entries = @($state.Restore.apps | Where-Object { $state.RestoreSel[$_.Key] -and $_.Category -ne 'games' })
    $configs = @($state.Restore.configs | Where-Object { $state.RestoreSel['config:' + $_.Id] })
    $extras = @($state.Restore.extras | Where-Object { $state.RestoreSel['extra:' + $_.Id] })
    $test = [bool]$ui.OptTestRun.IsChecked
    $parallel = [bool]$ui.OptParallel.IsChecked -and [bool]$ui.OptSilent.IsChecked
    if (-not $test -and -not $Screenshot -and -not $NoConfirm) {
        $how = 'Installers run one after another.'
        if ($parallel) { $how = 'Simple installers run three at a time; MSI-based ones run one by one at the end.' }
        $ans = [System.Windows.MessageBox]::Show($window, "Install $($entries.Count) apps, then restore $($configs.Count) app settings and $($extras.Count) extras?`n`n$how Leave the PC alone until it finishes; some installers may still show a window.", 'WinPrestige', 'OKCancel', 'Question')
        if ($ans -ne 'OK') { return }
    }
    $ui.RestoreLog.Items.Clear()
    $state.LogTarget = $ui.RestoreLog
    foreach ($k in @($state.RRows.Keys)) { $state.RRows[$k].StatusRow.Visibility = 'Collapsed' }
    $state.RestoreTestRun = $test
    $opts = @{
        TestRun = $test; SkipInstalled = [bool]$ui.OptSkipInstalled.IsChecked; PreferLocal = [bool]$ui.OptPreferLocal.IsChecked
        OnlineFallback = [bool]$ui.OptOnlineFallback.IsChecked; Silent = [bool]$ui.OptSilent.IsChecked
        Parallel = $parallel; Computer = [string]$state.Restore.computer; Progress = $Progress
    }
    if (-not $test -and -not $Demo) { Set-WPRunOnce }
    Start-WPJob 'Restore' {
        if ($P.Demo) { Invoke-WPDemoRestore $P.Root $P.Entries $P.Configs $P.Extras $P.Dependencies $P.Options }
        else { Invoke-WPRestore $P.Root $P.Entries $P.Configs $P.Extras $P.Dependencies $P.Options }
    } @{ Root = $state.RestoreRoot; Entries = $entries; Configs = $configs; Extras = $extras; Dependencies = @($state.Restore.dependencies); Options = $opts; Demo = [bool]$Demo } {
        param($r, $err)
        if (-not $Demo) { Remove-WPRunOnce }
        if ($r -and -not $r.Complete) {
            Set-WPStatus 'Restore stopped. Open WinPrestige again any time to continue where it left off.'
            return
        }
        if ($r -and -not $state.RestoreTestRun -and -not $Screenshot) {
            $msg = "Restore finished: $($r.Ok) installed, $($r.Skipped) already there, $($r.Manual) manual, $($r.Failed) failed."
            Set-WPStatus $msg
            $next = "Use 'Open manual links' for the rest, then restart the PC so drivers and hardware apps pick up their settings."
            if ($r.RestartNeeded) { $next = "Some installers need a restart to finish. Use 'Open manual links' for the rest, then restart the PC." }
            [void][System.Windows.MessageBox]::Show($window, "$msg`n`n$next", 'WinPrestige')
        }
    }
}

function Open-WPManualLinks {
    if (-not $state.Restore) { return }
    if ($Demo) { Set-WPStatus 'Demo mode: this opens the download page for each manual app.'; return }
    $list = @($state.Restore.apps | Where-Object { $state.RestoreSel[$_.Key] -and @('manual', 'storelink') -contains $_.Method })
    if ($list.Count -eq 0) { [void][System.Windows.MessageBox]::Show($window, 'Nothing ticked needs a manual download.', 'WinPrestige'); return }
    $ans = [System.Windows.MessageBox]::Show($window, "Open $($list.Count) download pages in your browser?", 'WinPrestige', 'OKCancel', 'Question')
    if ($ans -ne 'OK') { return }
    foreach ($e in $list) {
        if ($e.Method -eq 'storelink' -and $e.Pfn) { Open-WPUrl "ms-windows-store://pdp/?PFN=$($e.Pfn)" }
        else { $l = @(Get-WPEntryLinks $e) | Select-Object -First 1; if ($l) { Open-WPUrl $l.Url } }
        Start-Sleep -Milliseconds 350
    }
}

function Start-WPQueueGames {
    if (-not $state.Restore) { return }
    if ($Demo) { Set-WPStatus 'Demo mode: this opens a Steam install window for each ticked game.'; return }
    $games = @($state.Restore.apps | Where-Object { $_.Category -eq 'games' -and $_.GameUri -and $state.RestoreSel[$_.Key] })
    if ($games.Count -eq 0) { [void][System.Windows.MessageBox]::Show($window, 'Tick the games you want in the Games group first.', 'WinPrestige'); return }
    $ans = [System.Windows.MessageBox]::Show($window, "Steam opens an install window for each of the $($games.Count) games, one after another. Steam needs to be installed and signed in.`n`nContinue?", 'WinPrestige', 'OKCancel', 'Question')
    if ($ans -ne 'OK') { return }
    foreach ($g in $games) { Open-WPUrl $g.GameUri; Start-Sleep -Milliseconds 1500 }
}

#endregion

#region Wiring -----------------------------------------------------------------

function Show-WPPage {
    param([string]$Name)
    $state.Page = $Name
    foreach ($p in @('Apps', 'Configs', 'Extras', 'Backup', 'Restore')) {
        $vis = 'Collapsed'
        if ($p -eq $Name) { $vis = 'Visible' }
        $ui["Page$p"].Visibility = $vis
    }
    $ui.SearchBox.IsEnabled = @('Apps', 'Configs', 'Restore') -contains $Name
    if ($Name -eq 'Restore') {
        $ui.StepBar.Visibility = 'Collapsed'
        if (-not $ui.ModeRestore.IsChecked) { $ui.ModeRestore.IsChecked = $true }
    } else {
        $ui.StepBar.Visibility = 'Visible'
        $state.LastBackupTab = "Tab$Name"
        if (-not $ui.ModeBackup.IsChecked) { $ui.ModeBackup.IsChecked = $true }
        $next = @{ Apps = 'Next: App settings'; Configs = 'Next: Extras'; Extras = 'Next: Save backup' }
        if ($next[$Name]) { $ui.NextStepText.Text = $next[$Name]; $ui.BtnNextStep.Visibility = 'Visible' }
        else { $ui.BtnNextStep.Visibility = 'Collapsed' }
    }
    switch ($Name) {
        'Configs' { Update-WPConfigLayout }
        'Restore' { Update-WPRestoreLayout }
        'Backup' { Update-WPBackupStats; Update-WPDestInfo -CheckExisting }
    }
    Invoke-WPFadeIn $ui["Page$Name"] 12 240
}

$ui.ModeBackup.Add_Checked({ if ($state.Page -eq 'Restore') { $ui[$state.LastBackupTab].IsChecked = $true }; Move-WPModeThumb })
$ui.ModeRestore.Add_Checked({ $ui.TabRestore.IsChecked = $true; Move-WPModeThumb })
$window.Add_ContentRendered({
        Move-WPModeThumb -Instant
        try { Enable-WPFileDrop } catch { }
    })
$ui.BtnNextStep.Add_Click({
        $order = @('Apps', 'Configs', 'Extras', 'Backup')
        $i = [array]::IndexOf($order, $state.Page)
        if ($i -ge 0 -and $i -lt $order.Count - 1) { $ui["Tab$($order[$i + 1])"].IsChecked = $true }
    })
$ui.TabApps.Add_Checked({ Show-WPPage 'Apps' })
$ui.TabConfigs.Add_Checked({ Show-WPPage 'Configs' })
$ui.TabExtras.Add_Checked({ Show-WPPage 'Extras' })
$ui.TabBackup.Add_Checked({ Show-WPPage 'Backup' })
$ui.TabRestore.Add_Checked({ Show-WPPage 'Restore' })

$searchTimer = New-Object Windows.Threading.DispatcherTimer
$searchTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$searchTimer.Add_Tick({
        $searchTimer.Stop()
        $state.Filter = $ui.SearchBox.Text.Trim()
        switch ($state.Page) {
            'Apps' { Update-WPAppLayout }
            'Configs' { Update-WPConfigLayout }
            'Restore' { Update-WPRestoreLayout }
        }
    })
$ui.SearchBox.Add_TextChanged({
        if ($ui.SearchBox.Text) { $ui.SearchHint.Visibility = 'Collapsed' } else { $ui.SearchHint.Visibility = 'Visible' }
        $searchTimer.Stop(); $searchTimer.Start()
    })

$ui.BtnScan.Add_Click({ Start-WPScan })
$ui.BtnLinks.Add_Click({
        $todo = @($state.Apps | Where-Object { $_.Selected -and -not $_.WingetId -and $_.Kind -ne 'winget' -and -not $_.CustomUrl })
        if ($todo.Count -eq 0) { Set-WPStatus 'Every ticked app already has a download source.'; return }
        foreach ($a in $todo) { $state.Settings.Chosen.Remove($a.Key) }
        Start-WPLookup $todo -Force
    })
$ui.BtnSelRecommended.Add_Click({ Set-WPRecommendedApps })
$ui.BtnSelAll.Add_Click({ Set-WPAllShownApps $true })
$ui.BtnSelNone.Add_Click({ Set-WPAllShownApps $false })
foreach ($n in @('ShowGames', 'ShowSystem', 'ShowSelectedOnly')) {
    $ui[$n].Add_Click({ Update-WPAppLayout })
}
$ui.AppScroll.Add_SizeChanged({
        $cols = Get-WPColumnCount $ui.AppScroll 300 4
        if ($cols -ne $state.AppCols) { Update-WPAppLayout }
    })
$ui.ConfigScroll.Add_SizeChanged({
        if ($state.Page -ne 'Configs') { return }
        $cols = Get-WPColumnCount $ui.ConfigScroll 400 3
        if ($cols -ne $state.ConfigCols) { Update-WPConfigLayout }
    })
$ui.RestoreScroll.Add_SizeChanged({
        if ($state.Page -ne 'Restore') { return }
        $cols = Get-WPColumnCount $ui.RestoreScroll 320 3
        if ($cols -ne $state.RestoreCols) { Update-WPRestoreLayout }
    })

$ui.BtnDetectConfigs.Add_Click({ Start-WPDetectConfigs })
$ui.BtnAddFolder.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Pick a folder to include in the backup. It is restored to the same place.'
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-WPCustomConfig $d.SelectedPath }
    })
$ui.BtnAddFile.Add_Click({
        $d = New-Object Microsoft.Win32.OpenFileDialog
        $d.Title = 'Pick a file to include in the backup'
        if ($d.ShowDialog($window)) { Add-WPCustomConfig $d.FileName }
    })
$ui.BtnCfgRecommended.Add_Click({ Set-WPAllConfigs 'recommended' })
$ui.BtnCfgAll.Add_Click({ Set-WPAllConfigs 'all' })
$ui.BtnCfgNone.Add_Click({ Set-WPAllConfigs 'none' })

$ui.BtnBrowseDest.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Pick where to save the backup (your NAS share is best).'
        $d.ShowNewFolderButton = $true
        if ($ui.DestBox.Text) { $d.SelectedPath = $ui.DestBox.Text }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $p = ConvertTo-WPUncPath $d.SelectedPath
            $leaf = Split-Path -Leaf $p
            if ($leaf -notmatch 'WinPrestige' -and -not (Test-Path -LiteralPath (Join-Path $p 'manifest.json'))) { $p = Join-Path $p 'WinPrestige Backup' }
            $ui.DestBox.Text = $p
            Update-WPDestInfo -CheckExisting
        }
    })
$ui.DestBox.Add_LostFocus({ Update-WPDestInfo -CheckExisting })
$ui.BtnStartBackup.Add_Click({ Start-WPBackup })
$ui.BtnOpenDest.Add_Click({
        if ($Demo) { Set-WPStatus 'Demo mode: the backup folder only exists in the demo.'; return }
        $p = $ui.DestBox.Text.Trim()
        if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe "`"$p`"" }
    })
$ui.BtnOpenReport.Add_Click({
        $r = $state.LastReport
        if (-not $r -and $Demo) { Set-WPStatus 'Run the demo backup first to see the report.'; return }
        if (-not $r) { $r = Join-Path $ui.DestBox.Text.Trim() 'AppInventory.html' }
        if (Test-Path -LiteralPath $r) { Open-WPUrl $r } else { Set-WPStatus 'No report yet. Run a backup first.' }
    })
foreach ($n in @('OptInstallers', 'OptConfigs', 'OptExtras')) { $ui[$n].Add_Click({ Update-WPBackupStats }) }

$ui.BtnBrowseRestore.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Pick the WinPrestige backup folder (the one with manifest.json in it).'
        if ($ui.RestorePath.Text) { $d.SelectedPath = $ui.RestorePath.Text }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Import-WPBackup $d.SelectedPath }
    })
$ui.BtnLoadBackup.Add_Click({ Import-WPBackup $ui.RestorePath.Text })
$ui.RestorePath.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Import-WPBackup $ui.RestorePath.Text } })
$ui.BtnStartRestore.Add_Click({ Start-WPRestore })
$ui.BtnManualLinks.Add_Click({ Open-WPManualLinks })
$ui.BtnQueueGames.Add_Click({ Start-WPQueueGames })
$ui.BtnOpenRestoreReport.Add_Click({
        if ($Demo) {
            if ($state.LastReport) { Open-WPUrl $state.LastReport } else { Set-WPStatus 'Run the demo backup first to see the report.' }
            return
        }
        if ($state.RestoreRoot) {
            $r = Join-Path $state.RestoreRoot 'AppInventory.html'
            if (Test-Path -LiteralPath $r) { Open-WPUrl $r }
        }
    })

$ui.BannerPrimary.Add_Click({ Invoke-WPBannerAction 'primary' })
$ui.BannerSecondary.Add_Click({ Invoke-WPBannerAction 'secondary' })
$ui.BannerClose.Add_Click({
        if ($state.BannerKind -eq 'resume') { Clear-WPRestoreProgress }
        Hide-WPBanner
    })

$ui.BtnCancel.Add_Click({
        $sync.Cancel = $true
        $ui.BtnCancel.IsEnabled = $false
        Set-WPStatus "Stopping$Ellipsis"
    })

$window.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) {
            if ($ui.SearchBox.IsEnabled) { $ui.SearchBox.Focus() | Out-Null; $ui.SearchBox.SelectAll() }
            $e.Handled = $true
        } elseif ($e.Key -eq 'Escape' -and $ui.SearchBox.IsKeyboardFocused) {
            $ui.SearchBox.Text = ''
        }
    })

$window.Add_Closing({
        param($s, $e)
        if ($state.Jobs.Count -gt 0 -and -not $Screenshot) {
            $names = ($state.Jobs | ForEach-Object { $_.Name }) -join ', '
            $ans = [System.Windows.MessageBox]::Show($window, "$names is still running. Stop it and close WinPrestige?", 'WinPrestige', 'YesNo', 'Question')
            if ($ans -ne 'Yes') { $e.Cancel = $true; return }
            $sync.Cancel = $true
        }
        Save-WPSettings
    })

$window.Dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        try { Add-WPLogLine ("Unexpected error: " + $e.Exception.Message) 'error' } catch { }
    })

$window.Add_Loaded({
        $ui.AdminBadge.Text = "v$($script:WP.Version)"
        if (-not (Test-WPAdmin) -and -not $Screenshot) { $ui.AdminBadge.Text += "  $MidDot  Not elevated: installs and some settings may fail" }
        Show-WPDetails $null
        Set-WPDestChips
        $dest = $state.Settings.Destination
        if (-not $dest) { $dest = Get-WPSuggestedDestination }
        $ui.DestBox.Text = $dest
        Update-WPDestInfo
        Update-WPBackupStats
        $restorePath = $BackupPath
        if (-not $restorePath -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $WPRoot) 'manifest.json'))) { $restorePath = Split-Path -Parent $WPRoot }
        if (-not $restorePath -and $state.Settings.Destination) { $restorePath = $state.Settings.Destination }
        $ui.RestorePath.Text = $restorePath
        if ($Demo -and $Mode -ne 'Restore') { Import-WPBackup '\\NAS\Backups\WinPrestige Backup' }
        if (-not $script:WP.Winget) { Set-WPStatus 'winget was not found. Update "App Installer" from the Microsoft Store for the best results.' }
        $timer.Start()
        Invoke-WPFadeIn $window.Content 8 320
        Initialize-WPRestoreHelpers
        if ($Mode -eq 'Restore') {
            $ui.TabRestore.IsChecked = $true
            $ui.AppEmptyText.Text = 'Press "Scan this PC" to list the apps on this computer.'
            $ui.AppSpinner.Visibility = 'Collapsed'
            $ui.AppEmptyIcon.Visibility = 'Visible'
            if ($restorePath) { Import-WPBackup $restorePath }
        } else {
            $cached = $null
            if (-not $Demo) { try { $cached = @(Read-WPJson (Join-Path $script:WP.StateDir 'last-scan.json')) } catch { } }
            if ($cached -and $cached.Count) {
                Set-WPAppsFromScan $cached
                $ui.ScanInfo.Text = "Showing your last scan while this one runs$Ellipsis"
            }
            Start-WPScan
        }
    })

if ($Screenshot) {
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -32000
    $window.Top = -32000
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $state.ShotStart = Get-Date
    $shotTimer = New-Object Windows.Threading.DispatcherTimer
    $shotTimer.Interval = [TimeSpan]::FromSeconds(1)
    $shotTimer.Add_Tick({
            $elapsed = ((Get-Date) - $state.ShotStart).TotalSeconds
            if ($elapsed -lt 4) { return }
            if ($state.Jobs.Count -gt 0 -and $elapsed -lt $ScreenshotWait) { return }
            if ($ScreenshotAction -eq 'Drop' -and -not $state.ShotActionDone) {
                $state.ShotActionDone = $true
                $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
                [WinPrestige.FileDrop]::SimulateDrop($hwnd, [string[]]@($ScreenshotSelect))
                return
            }
            if ($ScreenshotAction -eq 'Review' -and -not $state.ShotActionDone) {
                $state.ShotActionDone = $true
                if ($state.BannerKind) { Invoke-WPBannerAction 'secondary' }
                return
            }
            if (@('Backup', 'Restore') -contains $ScreenshotAction -and -not $state.ShotActionDone) {
                $state.ShotActionDone = $true
                if ($ScreenshotAction -eq 'Backup') { $ui.TabBackup.IsChecked = $true; Start-WPBackup }
                else { $ui.TabRestore.IsChecked = $true; Start-WPRestore }
                return
            }
            if (-not $state.ShotPrepared) {
                $state.ShotPrepared = $true
                $ui["Tab$ScreenshotTab"].IsChecked = $true
                $window.UpdateLayout()
                switch ($ScreenshotTab) { 'Apps' { Update-WPAppLayout } 'Configs' { Update-WPConfigLayout } 'Restore' { Update-WPRestoreLayout } }
                if ($ScreenshotSelect -and $ScreenshotAction -ne 'Drop') {
                    $pick = $state.Apps | Where-Object { $_.Name -eq $ScreenshotSelect } | Select-Object -First 1
                    if ($pick) { Show-WPDetails $pick.Key }
                }
                if ($ScreenshotTab -eq 'Backup') { $window.Height = 1200 }
                $window.UpdateLayout()
                Move-WPModeThumb -Instant
                return
            }
            $shotTimer.Stop()
            $window.UpdateLayout()
            $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($window)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $fs = [IO.File]::Create($Screenshot)
            $enc.Save($fs)
            $fs.Close()
            $sync.Cancel = $true
            $window.Close()
        })
    $shotTimer.Start()
}

$ErrorActionPreference = 'Continue'
[void]$window.ShowDialog()
$timer.Stop()

#endregion
