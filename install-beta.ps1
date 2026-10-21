# Installs the newest WinPrestige release, pre-releases included. Run in PowerShell:
#   irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install-beta.ps1 | iex
$env:WINPRESTIGE_CHANNEL = 'beta'
Invoke-RestMethod 'https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install.ps1' | Invoke-Expression
