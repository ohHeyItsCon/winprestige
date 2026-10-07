# Downloads the latest WinPrestige release and starts it. Run in PowerShell:
#   irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install.ps1 | iex
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = 'ohHeyItsCon/winprestige'
    $dest = Join-Path $env:LOCALAPPDATA 'WinPrestige\app'
    $zip = Join-Path $env:TEMP 'WinPrestige.zip'
    $tmp = Join-Path $env:TEMP ('WinPrestige-' + [guid]::NewGuid().ToString('N'))

    Write-Host 'Downloading WinPrestige...'
    try {
        Invoke-WebRequest "https://github.com/$repo/releases/latest/download/WinPrestige.zip" -OutFile $zip -UseBasicParsing
    } catch {
        # No release published yet: use the latest code instead.
        Invoke-WebRequest "https://github.com/$repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
    }

    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $script = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'WinPrestige.ps1' | Select-Object -First 1
    if (-not $script) { throw 'The download did not contain WinPrestige.ps1.' }

    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $script.DirectoryName '*') -Destination $dest -Recurse -Force
    Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File
    Remove-Item -LiteralPath $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Installed to $dest. Starting WinPrestige..."
    $exe = Join-Path $dest 'WinPrestige.exe'
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
    else { Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$(Join-Path $dest 'WinPrestige.ps1')`"" }
}
