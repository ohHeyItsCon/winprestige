# Downloads WinPrestige and starts it. Run in PowerShell:
#   Stable (the latest full release):
#     irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install.ps1 | iex
#   Beta (the newest release, including pre-releases that haven't been fully tested):
#     irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install-beta.ps1 | iex
#   Dev (the latest code on main, unreleased; may be broken):
#     irm https://raw.githubusercontent.com/ohHeyItsCon/winprestige/main/install-dev.ps1 | iex
# The beta and dev scripts set $env:WINPRESTIGE_CHANNEL and run this one.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = 'ohHeyItsCon/winprestige'
    $channel = ([string]$env:WINPRESTIGE_CHANNEL).Trim().ToLowerInvariant()
    $env:WINPRESTIGE_CHANNEL = $null
    if (@('beta', 'dev') -notcontains $channel) { $channel = 'stable' }
    $dest = Join-Path $env:LOCALAPPDATA 'WinPrestige\app'
    $zip = Join-Path $env:TEMP 'WinPrestige.zip'
    $tmp = Join-Path $env:TEMP ('WinPrestige-' + [guid]::NewGuid().ToString('N'))
    $main = "https://github.com/$repo/archive/refs/heads/main.zip"

    $url = $null; $label = ''
    switch ($channel) {
        'stable' { $url = "https://github.com/$repo/releases/latest/download/WinPrestige.zip"; $label = 'the latest stable release' }
        'beta' {
            # The newest published release, pre-releases included (GitHub lists them newest first).
            try {
                $rel = @(Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=20" -Headers @{ 'User-Agent' = 'WinPrestige-installer' } |
                        Where-Object { -not $_.draft }) | Select-Object -First 1
                $asset = @($rel.assets | Where-Object { $_.name -eq 'WinPrestige.zip' }) | Select-Object -First 1
                if ($asset) {
                    $url = $asset.browser_download_url
                    $label = "$($rel.tag_name)$(if ($rel.prerelease) { ' (pre-release)' })"
                }
            } catch { }
        }
        'dev' { $url = $main; $label = 'the latest code on main (dev)' }
    }
    if (-not $url) { $url = $main; $label = 'the latest code on main (no release found)' }

    Write-Host "Downloading WinPrestige: $label..."
    try {
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    } catch {
        # No release published yet: use the latest code instead.
        Write-Host 'No release to download, so using the latest code on main.'
        Invoke-WebRequest $main -OutFile $zip -UseBasicParsing
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
