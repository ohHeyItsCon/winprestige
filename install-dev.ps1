# Installs the latest WinPrestige code on main (unreleased; may be broken). Run in PowerShell:
#   irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install-dev.ps1 | iex
$env:WINPRESTIGE_CHANNEL = 'dev'
Invoke-RestMethod 'https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install.ps1' | Invoke-Expression
