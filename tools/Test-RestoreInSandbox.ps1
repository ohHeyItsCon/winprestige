#Requires -Version 5.1
<#
.SYNOPSIS
  Tries a WinPrestige restore inside Windows Sandbox, a throwaway copy of Windows.

.DESCRIPTION
  Opens Windows Sandbox with your backup folder mapped in read-only and WinPrestige open
  on the Restore page. Pick a few apps that have an installer saved in the backup, plus
  their settings, press Restore, then open those apps inside the sandbox and check your
  settings came back. Close the sandbox window when you're done: everything in it is
  thrown away and nothing on this PC changes.

  Windows Sandbox needs Windows 10/11 Pro or higher. If it isn't turned on yet, open
  "Turn Windows features on or off", tick "Windows Sandbox", press OK and restart.

  winget and the Microsoft Store aren't available inside the sandbox, so only apps with
  an installer saved in the backup will install there. Hardware apps (fan, RGB, mouse
  software) can't see your devices from inside the sandbox, so test those on the real PC.

.EXAMPLE
  .\tools\Test-RestoreInSandbox.ps1 -BackupPath 'D:\WinPrestige Backup'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath,
    [string]$AppPath,
    [int]$MemoryMB = 0
)
$ErrorActionPreference = 'Stop'
# The app folder is the one above tools\ (worked out here, since $PSScriptRoot is empty in param defaults on PowerShell 5.1).
if (-not $AppPath) { $AppPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

$sandboxExe = Join-Path $env:windir 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) {
    Write-Host 'Windows Sandbox is not turned on.' -ForegroundColor Yellow
    Write-Host 'Open "Turn Windows features on or off", tick "Windows Sandbox", press OK, restart, then run this again.'
    exit 1
}

$backup = (Resolve-Path -LiteralPath $BackupPath).ProviderPath.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $backup 'manifest.json'))) {
    $inner = Join-Path $backup 'WinPrestige Backup'
    if (Test-Path -LiteralPath (Join-Path $inner 'manifest.json')) { $backup = $inner }
    else { throw "$backup isn't a WinPrestige backup (there's no manifest.json in it)." }
}
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($backup))
if ($backup.StartsWith('\\') -or $drive.DriveType -eq 'Network') {
    throw "Windows Sandbox can only map folders on this PC's own drives. Copy the backup to a local drive first."
}

$app = (Resolve-Path -LiteralPath $AppPath).ProviderPath.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $app 'WinPrestige.ps1'))) { throw "WinPrestige.ps1 isn't in $app. Pass -AppPath." }

if ($MemoryMB -le 0) {
    # Half of this PC's memory, between 4 and 8 GB.
    $totalMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    $MemoryMB = [Math]::Max(4096, [Math]::Min(8192, [int]($totalMB / 2)))
}

$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\WinPrestige\WinPrestige.ps1" -Mode Restore -BackupPath "C:\Backup"'
$wsb = @"
<Configuration>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(& $esc $backup)</HostFolder>
      <SandboxFolder>C:\Backup</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(& $esc $app)</HostFolder>
      <SandboxFolder>C:\WinPrestige</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>$(& $esc $command)</Command>
  </LogonCommand>
</Configuration>
"@
$file = Join-Path $env:TEMP 'WinPrestige-Sandbox.wsb'
[IO.File]::WriteAllText($file, $wsb, (New-Object Text.UTF8Encoding $false))

Write-Host "Starting Windows Sandbox with $backup (read-only) and WinPrestige from $app."
Write-Host 'In the sandbox: untick everything, tick a few apps with a saved installer and their settings, press Restore.'
Write-Host 'Then open those apps and check your settings are there. Close the sandbox to throw it all away.'
Start-Process -FilePath $file
