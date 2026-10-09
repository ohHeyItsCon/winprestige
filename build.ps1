#Requires -Version 5.1
<#
.SYNOPSIS
    Builds WinPrestige.exe and the release zip.

.DESCRIPTION
    Compiles src\Launcher.cs with the C# compiler that ships with Windows, so no SDK is
    needed. Puts WinPrestige.exe in the repo root and dist\WinPrestige.zip ready to attach
    to a GitHub release.

.EXAMPLE
    .\build.ps1 -Version 1.0.1
#>
param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$core = Join-Path $root 'lib\Core.ps1'
$launcher = Join-Path $root 'src\Launcher.cs'
if ($Version) {
    # Keep the app and the exe on the same version number.
    $text = [IO.File]::ReadAllText($core)
    $text = [regex]::Replace($text, "\`$script:WP\.Version = '[^']*'", "`$script:WP.Version = '$Version'")
    [IO.File]::WriteAllText($core, $text, (New-Object Text.UTF8Encoding $false))
    $cs = [IO.File]::ReadAllText($launcher)
    $cs = [regex]::Replace($cs, 'Assembly(File)?Version\("[^"]*"\)', "Assembly`$1Version(`"$Version.0`")")
    [IO.File]::WriteAllText($launcher, $cs, (New-Object Text.UTF8Encoding $false))
} else {
    $Version = [regex]::Match([IO.File]::ReadAllText($core), "\`$script:WP\.Version = '([^']*)'").Groups[1].Value
}

$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw "The .NET Framework C# compiler wasn't found." }

$exe = Join-Path $root 'WinPrestige.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32icon:$(Join-Path $root 'assets\WinPrestige.ico')" /reference:System.Windows.Forms.dll $launcher
if ($LASTEXITCODE -ne 0) { throw 'Compiling the launcher failed.' }
Write-Host "Built WinPrestige.exe $Version"

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'WinPrestige'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($name in @('WinPrestige.exe', 'WinPrestige.ps1', 'WinPrestige.cmd', 'README.md', 'LICENSE')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $stage
}
foreach ($dir in @('lib', 'data', 'assets', 'tools')) {
    Copy-Item -LiteralPath (Join-Path $root $dir) -Destination $stage -Recurse
}
Remove-Item -LiteralPath (Join-Path $stage 'assets\screenshots') -Recurse -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $stage -DestinationPath (Join-Path $dist 'WinPrestige.zip') -Force
Write-Host "Release zip: $(Join-Path $dist 'WinPrestige.zip')"
