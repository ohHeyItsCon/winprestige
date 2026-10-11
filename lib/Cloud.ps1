#Requires -Version 5.1
<#
  WinPrestige cloud destinations: sign-in, upload, verify and download for
  OneDrive, Google Drive, Dropbox, Nextcloud, any WebDAV server and any
  S3-compatible storage.

  A cloud backup is built in a local staging folder first (the normal backup
  code runs unchanged), then mirrored to the remote folder and checked file by
  file against the sizes and checksums the provider reports back. Restoring
  downloads the folder again, checking each file, and loads it as usual.

  Dot-sourced by Core.ps1, so the window and background jobs both have it.
  Heavy lifting (HTTP streaming, hashes, SigV4, the OAuth loopback, DPAPI) is
  in CloudTools.cs.
#>

#region Catalogue and app registrations ---------------------------------------

$script:WPCloudProviders = @(
    [pscustomobject]@{ Id = 'onedrive'; Name = 'OneDrive'; Kind = 'oauth'; Hash = 'quickxor'; Web = 'https://onedrive.live.com'; Where = 'OneDrive > Apps > WinPrestige'
        Blurb = 'Sign in with your Microsoft account. WinPrestige only gets its own folder (Apps > WinPrestige), not the rest of your OneDrive.'
    }
    [pscustomobject]@{ Id = 'googledrive'; Name = 'Google Drive'; Kind = 'oauth'; Hash = 'md5'; Web = 'https://drive.google.com'; Where = 'Google Drive > My Drive'
        Blurb = 'Sign in with your Google account. WinPrestige can only see the files it creates, not the rest of your Drive.'
    }
    [pscustomobject]@{ Id = 'dropbox'; Name = 'Dropbox'; Kind = 'oauth'; Hash = 'dropbox'; Web = 'https://www.dropbox.com/home/Apps'; Where = 'Dropbox > Apps > WinPrestige'
        Blurb = 'Sign in with your Dropbox account. WinPrestige only gets its own folder (Apps > WinPrestige).'
    }
    [pscustomobject]@{ Id = 'nextcloud'; Name = 'Nextcloud'; Kind = 'nextcloud'; Hash = 'sha1'; Web = ''; Where = 'Nextcloud > Files'
        Blurb = 'Your own Nextcloud: Docker, AIO, a NAS app or a hosted one. You sign in in the browser and Nextcloud gives WinPrestige its own app password, which you can revoke any time.'
    }
    [pscustomobject]@{ Id = 'webdav'; Name = 'WebDAV server'; Kind = 'webdav'; Hash = 'sha1'; Web = ''; Where = 'WebDAV'
        Blurb = 'Any WebDAV server: ownCloud, Synology (WebDAV Server package), QNAP, Seafile, pCloud, Koofr, Apache, Caddy or rclone serve webdav.'
    }
    [pscustomobject]@{ Id = 's3'; Name = 'S3-compatible storage'; Kind = 's3'; Hash = 'etag'; Web = ''; Where = 'S3 bucket'
        Blurb = 'Any S3-compatible bucket: MinIO, Garage, SeaweedFS, Ceph, Backblaze B2, Wasabi, Cloudflare R2 or AWS S3. Use an access key limited to this bucket.'
    }
)

function Get-WPCloudProvider {
    param([string]$Id)
    return ($script:WPCloudProviders | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Get-WPCloudApp {
    # Client IDs ship in data\cloud-apps.json; a copy in the settings folder overrides it (for testing).
    param([string]$Provider)
    $app = @{}
    foreach ($f in @((Join-Path $script:WP.Root 'data\cloud-apps.json'), (Join-Path $script:WP.StateDir 'cloud-apps.json'))) {
        $j = Read-WPJson $f
        if ($j -and $j.$Provider) { foreach ($p in $j.$Provider.PSObject.Properties) { if ([string]$p.Value) { $app[$p.Name] = [string]$p.Value } } }
    }
    switch ($Provider) {
        'onedrive' {
            if (-not $app.authorizeUrl) { $app.authorizeUrl = 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize' }
            if (-not $app.tokenUrl) { $app.tokenUrl = 'https://login.microsoftonline.com/common/oauth2/v2.0/token' }
            if (-not $app.apiUrl) { $app.apiUrl = 'https://graph.microsoft.com/v1.0' }
            if (-not $app.redirect) { $app.redirect = 'http://localhost' }
            $app.scope = 'Files.ReadWrite.AppFolder User.Read offline_access'
        }
        'googledrive' {
            if (-not $app.authorizeUrl) { $app.authorizeUrl = 'https://accounts.google.com/o/oauth2/v2/auth' }
            if (-not $app.tokenUrl) { $app.tokenUrl = 'https://oauth2.googleapis.com/token' }
            if (-not $app.apiUrl) { $app.apiUrl = 'https://www.googleapis.com' }
            if (-not $app.redirect) { $app.redirect = 'http://127.0.0.1' }
            $app.scope = 'https://www.googleapis.com/auth/drive.file'
        }
        'dropbox' {
            if ($app.appKey -and -not $app.clientId) { $app.clientId = $app.appKey }
            if (-not $app.authorizeUrl) { $app.authorizeUrl = 'https://www.dropbox.com/oauth2/authorize' }
            if (-not $app.tokenUrl) { $app.tokenUrl = 'https://api.dropboxapi.com/oauth2/token' }
            if (-not $app.apiUrl) { $app.apiUrl = 'https://api.dropboxapi.com/2' }
            if (-not $app.contentUrl) { $app.contentUrl = 'https://content.dropboxapi.com/2' }
            if (-not $app.redirect) { $app.redirect = 'http://127.0.0.1:47615/' }
        }
    }
    return $app
}

function Initialize-WPCloudTools {
    # Compiled once per version of CloudTools.cs and cached next to the settings.
    if ('WinPrestige.CloudHttp' -as [type]) { return }
    $src = [IO.File]::ReadAllText((Join-Path $script:WP.Root 'lib\CloudTools.cs'))
    $sha = New-Object Security.Cryptography.SHA1Managed
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src))) -replace '-', '').Substring(0, 12)
    $dll = Join-Path $script:WP.StateDir "CloudTools-$hash.dll"
    $refs = @('System.Net.Http', 'System.Security', 'System.Core')
    try {
        if (-not (Test-Path -LiteralPath $dll)) { Add-Type -TypeDefinition $src -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library -ErrorAction Stop }
        Add-Type -Path $dll -ErrorAction Stop
    } catch {
        Add-Type -TypeDefinition $src -ReferencedAssemblies $refs -ErrorAction Stop
    }
    [WinPrestige.CloudHttp]::UserAgent = "WinPrestige/$($script:WP.Version)"
}

#endregion

#region Accounts ----------------------------------------------------------------

function Get-WPCloudAccountsPath { return (Join-Path $script:WP.StateDir 'cloud-accounts.json') }

function Get-WPCloudAccounts {
    $j = Read-WPJson (Get-WPCloudAccountsPath)
    return @($j | Where-Object { $_ -and $_.Id })
}

function Get-WPCloudAccount {
    param([string]$Id)
    if (-not $Id) { return $null }
    return (Get-WPCloudAccounts | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Set-WPCloudAccount {
    param($Account)
    $list = @(Get-WPCloudAccounts | Where-Object { $_.Id -ne $Account.Id }) + @($Account)
    Write-WPJson @($list) (Get-WPCloudAccountsPath)
}

function Remove-WPCloudAccount {
    # Forgets the account on this PC. Tokens are dropped; nothing is deleted in the cloud.
    param([string]$Id)
    Write-WPJson @(Get-WPCloudAccounts | Where-Object { $_.Id -ne $Id }) (Get-WPCloudAccountsPath)
}

function New-WPCloudAccountObject {
    param([string]$Provider, [hashtable]$Fields)
    $a = [ordered]@{
        Id = [guid]::NewGuid().ToString('N'); Provider = $Provider; Label = ''; Email = ''
        Server = ''; User = ''; Endpoint = ''; Region = ''; Bucket = ''; PathStyle = $true
        Root = 'WinPrestige Backup'; Web = ''; Thumbprint = ''; Free = $null; Total = $null
        Created = (Get-Date).ToString('s'); Secret = ''
    }
    if ($Fields) { foreach ($k in $Fields.Keys) { $a[$k] = $Fields[$k] } }
    return [pscustomobject]$a
}

function Get-WPCloudSecret {
    param($Account)
    Initialize-WPCloudTools
    $raw = [WinPrestige.Secret]::Unprotect([string]$Account.Secret)
    if (-not $raw) { return @{} }
    return (ConvertTo-WPHashtable ($raw | ConvertFrom-Json))
}

function Set-WPCloudSecret {
    param($Account, [hashtable]$Secret)
    Initialize-WPCloudTools
    $Account.Secret = [WinPrestige.Secret]::Protect(($Secret | ConvertTo-Json -Compress))
}

function Get-WPCloudRemoteDir {
    # Each PC gets its own folder under the account's root, e.g. "WinPrestige Backup/USER-PC".
    param($Account, [string]$Computer = $env:COMPUTERNAME)
    $root = ([string]$Account.Root).Trim('/', ' ')
    if (-not $root) { $root = 'WinPrestige Backup' }
    return "$root/$(Get-WPSafeName $Computer)"
}

function Get-WPCloudStaging {
    # Where a cloud backup is assembled before upload. Kept between runs so the next backup only
    # downloads new installers and uploads what changed.
    param($Account)
    $p = Join-Path $script:WP.StateDir ('Cloud\' + $Account.Id + '\WinPrestige Backup')
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Get-WPCloudWhere {
    # Human description of where the files end up, for messages and the UI.
    param($Account, [string]$Dir)
    $prov = Get-WPCloudProvider $Account.Provider
    $d = ($Dir -replace '/', ' > ')
    switch ($Account.Provider) {
        's3' { return "bucket $($Account.Bucket) > $d" }
        'webdav' { return "$($Account.Server) > $d" }
        'nextcloud' { return "Nextcloud ($(([uri]$Account.Server).Host)) > Files > $d" }
        default { return "$($prov.Where) > $d" }
    }
}

#endregion

#region HTTP plumbing -----------------------------------------------------------

function ConvertTo-WPForm {
    param([hashtable]$Data)
    return (($Data.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { [Uri]::EscapeDataString($_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value) }) -join '&')
}

function ConvertTo-WPUrlPath {
    # "WinPrestige Backup/Configs/OBS #1" -> "WinPrestige%20Backup/Configs/OBS%20%231"
    param([string]$Path)
    return ((($Path -replace '\\', '/').Trim('/') -split '/' | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function ConvertTo-WPAsciiJson {
    # Dropbox wants its JSON header argument in plain ASCII.
    param($Object)
    $j = $Object | ConvertTo-Json -Compress -Depth 6
    return [regex]::Replace($j, '[^\x20-\x7E]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Join-WPRemote {
    param([string]$A, [string]$B)
    $a2 = ([string]$A).Trim('/'); $b2 = ([string]$B).Trim('/')
    if (-not $a2) { return $b2 }
    if (-not $b2) { return $a2 }
    return "$a2/$b2"
}

function Invoke-WPHttp {
    # One HTTP call through CloudTools, retried on throttling, server errors and dropped connections.
    # Body: $null, a string or a byte[]. File bodies go through -File/-Offset/-Length.
    param(
        [string]$Method, [string]$Url, [string[]]$Headers = @(), $Body,
        [string]$File, [long]$Offset = 0, [long]$Length = -1,
        [string]$OutFile, [switch]$NoRedirect, [int]$Tries = 4, [scriptblock]$Sign
    )
    Initialize-WPCloudTools
    [WinPrestige.CloudHttp]::Cancel = [bool](Test-WPCancel)
    $wait = 2
    for ($try = 1; $try -le $Tries; $try++) {
        if (Test-WPCancel) { [WinPrestige.CloudHttp]::Cancel = $true; throw 'Cancelled' }
        $h = @($Headers)
        if ($Sign) { $h += @(& $Sign) }   # S3 signs each attempt (the signature carries a timestamp)
        try {
            if ($OutFile) { $r = [WinPrestige.CloudHttp]::Download($Url, [string[]]$h, $OutFile) }
            elseif ($File) {
                $len = $(if ($Length -ge 0) { $Length } else { (Get-Item -LiteralPath $File).Length - $Offset })
                $r = [WinPrestige.CloudHttp]::SendFile($Method, $Url, [string[]]$h, $File, $Offset, $len, -not $NoRedirect)
            } else {
                $bytes = $null
                if ($Body -is [byte[]]) { $bytes = $Body } elseif ($null -ne $Body) { $bytes = (New-Object Text.UTF8Encoding $false).GetBytes([string]$Body) }
                $r = [WinPrestige.CloudHttp]::Send($Method, $Url, [string[]]$h, $bytes, -not $NoRedirect)
            }
        } catch {
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            throw "Can't use the address '$Url': $($inner.Message)"
        }
        if ($r.Status -eq 0 -and $r.Error -match 'Cancelled') { throw 'Cancelled' }
        if ($r.Status -eq 0 -and $r.Error -match 'trust relationship|certificate|SSL/TLS' -and [WinPrestige.CloudHttp]::LastCertThumbprint) {
            throw ("CERT:{0}|{1}" -f [WinPrestige.CloudHttp]::LastCertThumbprint, [WinPrestige.CloudHttp]::LastCertSubject)
        }
        $transient = ($r.Status -eq 0) -or ($r.Status -eq 429) -or ($r.Status -ge 500 -and $r.Status -ne 501 -and $r.Status -ne 507)
        if (-not $transient -or $try -eq $Tries) { return $r }
        $after = 0
        if ([int]::TryParse($r.Header('Retry-After'), [ref]$after) -and $after -gt 0) { $wait = [Math]::Min($after, 60) }
        Start-Sleep -Seconds $wait
        $wait = [Math]::Min($wait * 2, 30)
    }
}

function Get-WPHttpError {
    # A short, readable reason from a failed response.
    param($R, [string]$What)
    if ($R.Status -eq 0) { return "$What failed: $($R.Error)" }
    $msg = ''
    try {
        $j = $R.Body | ConvertFrom-Json -ErrorAction Stop
        foreach ($c in @($j.error.message, $j.error_description, $j.error_summary, $j.message, $j.error)) { if ($c -is [string] -and $c) { $msg = $c; break } }
    } catch {
        if ($R.Body -match '<Message>([^<]+)</Message>') { $msg = $Matches[1] }
        elseif ($R.Body -match '<s:message>([^<]+)</s:message>') { $msg = $Matches[1] }
    }
    if (-not $msg) { $msg = ($R.Body -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() }
    if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
    return "$What failed (HTTP $($R.Status))$(if ($msg) { ": $msg" })"
}

function ConvertFrom-WPJsonBody {
    param($R)
    if (-not $R.Body) { return $null }
    return ($R.Body | ConvertFrom-Json)
}

#endregion

#region Sign-in -----------------------------------------------------------------

$script:WPSignedInPage = @'
<!doctype html><html><head><meta charset="utf-8"><title>WinPrestige</title>
<style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#0A0F1A;color:#E4EDF7;font:16px "Segoe UI",sans-serif}
.c{text-align:center;padding:40px 48px;border-radius:18px;background:#0F1726;border:1px solid #1F2B42}
h1{font-size:22px;margin:0 0 8px;background:linear-gradient(90deg,#4CDBDA,#7B9CE9,#C094F0);-webkit-background-clip:text;color:transparent}
p{color:#7F8FA9;margin:0}</style></head><body><div class="c"><h1>You're signed in to WinPrestige</h1><p>You can close this tab and go back to the app.</p></div></body></html>
'@

function Get-WPQueryValue {
    param([string]$Target, [string]$Name)
    $q = $Target.Substring($Target.IndexOf('?') + 1)
    foreach ($pair in $q -split '&') {
        $kv = $pair -split '=', 2
        if ([Uri]::UnescapeDataString($kv[0]) -eq $Name) { return [Uri]::UnescapeDataString(($kv[1] -replace '\+', ' ')) }
    }
    return ''
}

function Connect-WPCloudOAuth {
    # Browser sign-in (authorization code + PKCE) with the redirect caught on this PC.
    param([string]$Provider, [int]$TimeoutSeconds = 300)
    Initialize-WPCloudTools
    $app = Get-WPCloudApp $Provider
    $prov = Get-WPCloudProvider $Provider
    if (-not $app.clientId) { throw "NOAPP:$Provider" }
    $verifier = [WinPrestige.Secret]::RandomUrlSafe(48)
    $challenge = [WinPrestige.Secret]::PkceChallenge($verifier)
    $stateTok = [WinPrestige.Secret]::RandomUrlSafe(18)
    $redirectBase = $app.redirect.TrimEnd('/')
    $fixed = [uri]$app.redirect
    if ($fixed.Port -gt 0 -and $app.redirect -match ':\d+') { $port = $fixed.Port; $redirect = $app.redirect }
    else { $port = [WinPrestige.Loopback]::FreePort(); $redirect = "${redirectBase}:$port" }
    $q = @{ client_id = $app.clientId; response_type = 'code'; redirect_uri = $redirect; code_challenge = $challenge; code_challenge_method = 'S256'; state = $stateTok }
    switch ($Provider) {
        'onedrive' { $q.scope = $app.scope; $q.prompt = 'select_account' }
        'googledrive' { $q.scope = $app.scope; $q.access_type = 'offline'; $q.prompt = 'consent select_account' }
        'dropbox' { $q.token_access_type = 'offline' }
    }
    $url = $app.authorizeUrl + '?' + (ConvertTo-WPForm $q)
    Write-WPLog "Opening $($prov.Name) sign-in in your browser..." 'step'
    Open-WPUrl $url
    $target = [WinPrestige.Loopback]::WaitForRedirect($port, $TimeoutSeconds, $script:WPSignedInPage)
    if (-not $target) { throw $(if (Test-WPCancel) { 'Cancelled' } else { "No answer from the $($prov.Name) sign-in page within $([int]($TimeoutSeconds / 60)) minutes." }) }
    $err = Get-WPQueryValue $target 'error'
    if ($err) { throw "$($prov.Name) sign-in was not completed: $err $(Get-WPQueryValue $target 'error_description')".Trim() }
    if ((Get-WPQueryValue $target 'state') -ne $stateTok) { throw 'The sign-in answer did not match this request, so it was ignored.' }
    $code = Get-WPQueryValue $target 'code'
    $form = @{ grant_type = 'authorization_code'; code = $code; redirect_uri = $redirect; client_id = $app.clientId; code_verifier = $verifier }
    if ($app.clientSecret) { $form.client_secret = $app.clientSecret }
    if ($Provider -eq 'onedrive') { $form.scope = $app.scope }
    $r = Invoke-WPHttp 'POST' $app.tokenUrl @('Content-Type', 'application/x-www-form-urlencoded') (ConvertTo-WPForm $form)
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Signing in to $($prov.Name)") }
    $tok = ConvertFrom-WPJsonBody $r
    $secret = @{ access_token = $tok.access_token; refresh_token = $tok.refresh_token; expires = (Get-Date).AddSeconds([int]$tok.expires_in - 60).ToString('o') }
    $acct = New-WPCloudAccountObject $Provider @{}
    Set-WPCloudSecret $acct $secret
    Update-WPCloudAccountInfo $acct
    Set-WPCloudAccount $acct
    Write-WPLog "Signed in to $($prov.Name) as $($acct.Label)." 'ok'
    return $acct
}

function Get-WPCloudToken {
    # A valid access token, refreshed (and saved) when it's about to expire.
    param($Account)
    $s = Get-WPCloudSecret $Account
    if ($s.access_token -and $s.expires -and ([datetime]$s.expires) -gt (Get-Date).AddMinutes(2)) { return $s.access_token }
    $prov = Get-WPCloudProvider $Account.Provider
    if (-not $s.refresh_token) { throw "Sign in to $($prov.Name) again (the saved sign-in has no refresh token)." }
    $app = Get-WPCloudApp $Account.Provider
    $form = @{ grant_type = 'refresh_token'; refresh_token = $s.refresh_token; client_id = $app.clientId }
    if ($app.clientSecret) { $form.client_secret = $app.clientSecret }
    if ($Account.Provider -eq 'onedrive') { $form.scope = $app.scope }
    $r = Invoke-WPHttp 'POST' $app.tokenUrl @('Content-Type', 'application/x-www-form-urlencoded') (ConvertTo-WPForm $form)
    if (-not $r.Ok) { throw ("Sign in to $($prov.Name) again. " + (Get-WPHttpError $r 'Refreshing the sign-in')) }
    $tok = ConvertFrom-WPJsonBody $r
    $s.access_token = $tok.access_token
    if ($tok.refresh_token) { $s.refresh_token = $tok.refresh_token }
    $s.expires = (Get-Date).AddSeconds([int]$tok.expires_in - 60).ToString('o')
    Set-WPCloudSecret $Account $s
    if (Get-WPCloudAccount $Account.Id) { Set-WPCloudAccount $Account }
    return $s.access_token
}

function Connect-WPNextcloud {
    # Nextcloud Login Flow v2: the user approves WinPrestige in the browser and Nextcloud hands
    # back an app password. No client registration needed.
    param([string]$Server, [string]$Thumbprint, [int]$TimeoutSeconds = 900)
    Initialize-WPCloudTools
    $srv = $Server.Trim().TrimEnd('/')
    if ($srv -notmatch '^https?://') { $srv = "https://$srv" }
    if ($Thumbprint) { [void][WinPrestige.CloudHttp]::TrustedThumbprints.Add($Thumbprint) }
    $r = Invoke-WPHttp 'POST' "$srv/index.php/login/v2" @() ''
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Reaching Nextcloud at $srv") }
    $flow = ConvertFrom-WPJsonBody $r
    Write-WPLog 'Opening Nextcloud in your browser. Log in and press "Grant access".' 'step'
    Open-WPUrl $flow.login
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    $done = $null
    while ((Get-Date) -lt $end) {
        if (Test-WPCancel) { throw 'Cancelled' }
        Start-Sleep -Seconds 2
        $p = Invoke-WPHttp 'POST' $flow.poll.endpoint @('Content-Type', 'application/x-www-form-urlencoded') ("token=" + [Uri]::EscapeDataString($flow.poll.token)) -Tries 1
        if ($p.Ok) { $done = ConvertFrom-WPJsonBody $p; break }
    }
    if (-not $done) { throw 'Nextcloud sign-in timed out.' }
    $acct = New-WPCloudAccountObject 'nextcloud' @{ Server = ([string]$done.server).TrimEnd('/'); User = [string]$done.loginName; Thumbprint = [string]$Thumbprint }
    Set-WPCloudSecret $acct @{ password = [string]$done.appPassword }
    Update-WPCloudAccountInfo $acct
    Set-WPCloudAccount $acct
    Write-WPLog "Connected to Nextcloud as $($acct.Label)." 'ok'
    return $acct
}

function Connect-WPWebDav {
    param([string]$Url, [string]$User, [string]$Password, [string]$Thumbprint)
    Initialize-WPCloudTools
    $u = $Url.Trim()
    if ($u -notmatch '^https?://') { $u = "https://$u" }
    if (-not $u.EndsWith('/')) { $u += '/' }
    if ($Thumbprint) { [void][WinPrestige.CloudHttp]::TrustedThumbprints.Add($Thumbprint) }
    $acct = New-WPCloudAccountObject 'webdav' @{ Server = $u; User = $User; Thumbprint = [string]$Thumbprint }
    Set-WPCloudSecret $acct @{ password = $Password }
    $ctx = New-WPCloudContext $acct ''
    $r = Invoke-WPDavPropfind $ctx $u 0
    if ($r.Status -eq 401) { throw 'The server turned down that user name and password.' }
    if ($r.Status -ne 207) { throw (Get-WPHttpError $r "Checking the WebDAV folder") }
    Update-WPCloudAccountInfo $acct
    Set-WPCloudAccount $acct
    Write-WPLog "Connected to $($acct.Label)." 'ok'
    return $acct
}

function Connect-WPS3 {
    param([string]$Endpoint, [string]$Region, [string]$Bucket, [string]$AccessKey, [string]$SecretKey, [bool]$PathStyle = $true, [string]$Thumbprint)
    Initialize-WPCloudTools
    $ep = $Endpoint.Trim().TrimEnd('/')
    if ($ep -notmatch '^https?://') { $ep = "https://$ep" }
    if (-not $Region) { $Region = 'us-east-1' }
    if ($Thumbprint) { [void][WinPrestige.CloudHttp]::TrustedThumbprints.Add($Thumbprint) }
    $acct = New-WPCloudAccountObject 's3' @{ Endpoint = $ep; Region = $Region.Trim(); Bucket = $Bucket.Trim(); PathStyle = $PathStyle; User = $AccessKey.Trim(); Thumbprint = [string]$Thumbprint }
    Set-WPCloudSecret $acct @{ secret = $SecretKey }
    $ctx = New-WPCloudContext $acct ''
    $r = Invoke-WPS3 $ctx 'GET' '' @{ 'list-type' = '2'; 'max-keys' = '1' }
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Opening bucket $($acct.Bucket)") }
    Update-WPCloudAccountInfo $acct
    Set-WPCloudAccount $acct
    Write-WPLog "Connected to bucket $($acct.Bucket)." 'ok'
    return $acct
}

function Update-WPCloudAccountInfo {
    # Fills in the account's name, free space and web link (best effort).
    param($Account)
    $ctx = New-WPCloudContext $Account ''
    try {
        switch ($Account.Provider) {
            'onedrive' {
                $me = ConvertFrom-WPJsonBody (Invoke-WPHttp 'GET' "$($ctx.Api)/me?`$select=displayName,userPrincipalName,mail" (Get-WPCloudAuth $ctx))
                $Account.Email = $(if ($me.mail) { [string]$me.mail } else { [string]$me.userPrincipalName })
                $Account.Label = $(if ($Account.Email) { $Account.Email } else { [string]$me.displayName })
                $root = ConvertFrom-WPJsonBody (Invoke-WPHttp 'GET' "$($ctx.Api)/me/drive/special/approot" (Get-WPCloudAuth $ctx))
                if ($root.webUrl) { $Account.Web = [string]$root.webUrl }
                $d = ConvertFrom-WPJsonBody (Invoke-WPHttp 'GET' "$($ctx.Api)/me/drive?`$select=quota" (Get-WPCloudAuth $ctx))
                if ($d.quota) { $Account.Free = [long]$d.quota.remaining; $Account.Total = [long]$d.quota.total }
            }
            'googledrive' {
                $ab = ConvertFrom-WPJsonBody (Invoke-WPHttp 'GET' "$($ctx.Api)/drive/v3/about?fields=user(emailAddress,displayName),storageQuota(limit,usage)" (Get-WPCloudAuth $ctx))
                $Account.Email = [string]$ab.user.emailAddress
                $Account.Label = $(if ($Account.Email) { $Account.Email } else { [string]$ab.user.displayName })
                if ($ab.storageQuota.limit) { $Account.Total = [long]$ab.storageQuota.limit; $Account.Free = [long]$ab.storageQuota.limit - [long]$ab.storageQuota.usage }
            }
            'dropbox' {
                $me = ConvertFrom-WPJsonBody (Invoke-WPHttp 'POST' "$($ctx.Api)/users/get_current_account" (Get-WPCloudAuth $ctx))
                $Account.Email = [string]$me.email
                $Account.Label = $(if ($me.email) { [string]$me.email } else { [string]$me.name.display_name })
                $sp = ConvertFrom-WPJsonBody (Invoke-WPHttp 'POST' "$($ctx.Api)/users/get_space_usage" (Get-WPCloudAuth $ctx))
                if ($sp.allocation.allocated) { $Account.Total = [long]$sp.allocation.allocated; $Account.Free = [long]$sp.allocation.allocated - [long]$sp.used }
            }
            'nextcloud' {
                $r = Invoke-WPHttp 'GET' "$($Account.Server)/ocs/v2.php/cloud/user?format=json" ((Get-WPCloudAuth $ctx) + @('OCS-APIRequest', 'true', 'Accept', 'application/json'))
                $u = (ConvertFrom-WPJsonBody $r).ocs.data
                if ($u.id) { $Account.User = [string]$u.id }
                $Account.Email = [string]$u.email
                $Account.Label = "$(if ($u.displayname) { $u.displayname } else { $Account.User }) on $(([uri]$Account.Server).Host)"
                $Account.Web = "$($Account.Server)/apps/files/"
                if ($u.quota -and [double]$u.quota.free -ge 0) { $Account.Free = [long]$u.quota.free; if ([double]$u.quota.total -gt 0) { $Account.Total = [long]$u.quota.total } }
            }
            'webdav' {
                $Account.Label = "$($Account.User) on $(([uri]$Account.Server).Host)"
                $Account.Web = $Account.Server
                $r = Invoke-WPDavPropfind $ctx $Account.Server 0 '<d:quota-available-bytes/><d:quota-used-bytes/>'
                if ($r.Status -eq 207 -and $r.Body -match 'quota-available-bytes>(\d+)<') { $Account.Free = [long]$Matches[1] }
            }
            's3' {
                $Account.Label = "$($Account.Bucket) on $(([uri]$Account.Endpoint).Host)"
            }
        }
    } catch {
        if (-not $Account.Label) { $Account.Label = (Get-WPCloudProvider $Account.Provider).Name }
    }
}

#endregion

#region Provider operations -----------------------------------------------------
# Every provider implements the same small set: list a folder's children, upload a file, delete
# a file, download a file. Items look like @{ Name; Path; IsDir; Size; Hash; Id }, where Path is
# the full remote path ("WinPrestige Backup/PC/manifest.json").

function New-WPCloudContext {
    param($Account, [string]$Dir)
    Initialize-WPCloudTools
    if ($Account.Thumbprint) { [void][WinPrestige.CloudHttp]::TrustedThumbprints.Add([string]$Account.Thumbprint) }
    $prov = Get-WPCloudProvider $Account.Provider
    $ctx = @{ Account = $Account; Provider = $Account.Provider; Dir = ([string]$Dir).Trim('/'); HashType = $prov.Hash; FolderIds = @{}; Made = @{}; Token = $null; TokenAt = [datetime]::MinValue }
    switch ($Account.Provider) {
        'onedrive' { $ctx.Api = (Get-WPCloudApp 'onedrive').apiUrl }
        'googledrive' { $ctx.Api = (Get-WPCloudApp 'googledrive').apiUrl }
        'dropbox' { $app = Get-WPCloudApp 'dropbox'; $ctx.Api = $app.apiUrl; $ctx.Content = $app.contentUrl }
        'nextcloud' { $ctx.Base = "$($Account.Server)/remote.php/dav/files/$([Uri]::EscapeDataString([string]$Account.User))/" }
        'webdav' { $ctx.Base = [string]$Account.Server }
    }
    return $ctx
}

function Get-WPCloudAuth {
    # Authorization header pair for the context, refreshing OAuth tokens as needed.
    param($Ctx)
    switch ($Ctx.Provider) {
        { $_ -in 'onedrive', 'googledrive', 'dropbox' } {
            if (-not $Ctx.Token -or ((Get-Date) - $Ctx.TokenAt).TotalMinutes -gt 30) {
                $Ctx.Token = Get-WPCloudToken $Ctx.Account
                $Ctx.TokenAt = Get-Date
            }
            return @('Authorization', "Bearer $($Ctx.Token)")
        }
        { $_ -in 'nextcloud', 'webdav' } {
            if (-not $Ctx.Basic) {
                $s = Get-WPCloudSecret $Ctx.Account
                $Ctx.Basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($Ctx.Account.User):$($s.password)"))
            }
            return @('Authorization', $Ctx.Basic)
        }
    }
    return @()
}

# ---- OneDrive (Microsoft Graph, app folder) ----

function Get-WPOdUrl {
    param($Ctx, [string]$Path, [string]$Suffix)
    $p = ConvertTo-WPUrlPath $Path
    if (-not $p) { return "$($Ctx.Api)/me/drive/special/approot$(if ($Suffix) { '/' + $Suffix })" }
    return "$($Ctx.Api)/me/drive/special/approot:/${p}:$(if ($Suffix) { '/' + $Suffix })"
}

function Get-WPOdChildren {
    param($Ctx, [string]$Path)
    $items = @()
    $url = (Get-WPOdUrl $Ctx $Path 'children') + '?$top=999&$select=id,name,size,file,folder'
    while ($url) {
        $r = Invoke-WPHttp 'GET' $url (Get-WPCloudAuth $Ctx)
        if ($r.Status -eq 404) { return $null }
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Listing $Path on OneDrive") }
        $j = ConvertFrom-WPJsonBody $r
        foreach ($v in @($j.value)) {
            $items += @{ Name = [string]$v.name; Path = (Join-WPRemote $Path $v.name); IsDir = [bool]$v.folder; Size = [long]$v.size; Hash = [string]$v.file.hashes.quickXorHash; Id = [string]$v.id }
        }
        $url = [string]$j.'@odata.nextLink'
    }
    return $items
}

function Send-WPOdFile {
    param($Ctx, [string]$Local, [string]$Path, [long]$Size)
    if ($Size -le 4MB) {
        $r = Invoke-WPHttp 'PUT' (Get-WPOdUrl $Ctx $Path 'content') ((Get-WPCloudAuth $Ctx) + @('Content-Type', 'application/octet-stream')) -File $Local
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
        return
    }
    $body = '{"item":{"@microsoft.graph.conflictBehavior":"replace"}}'
    $r = Invoke-WPHttp 'POST' (Get-WPOdUrl $Ctx $Path 'createUploadSession') ((Get-WPCloudAuth $Ctx) + @('Content-Type', 'application/json')) $body
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Starting the upload of $Path") }
    $session = (ConvertFrom-WPJsonBody $r).uploadUrl
    $chunk = 10MB   # a multiple of 320 KiB, as Graph requires
    for ($off = 0; $off -lt $Size; $off += $chunk) {
        $n = [Math]::Min($chunk, $Size - $off)
        $r = Invoke-WPHttp 'PUT' $session @('Content-Range', "bytes $off-$($off + $n - 1)/$Size") -File $Local -Offset $off -Length $n
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
    }
}

function Remove-WPOdItem {
    param($Ctx, $Item)
    $r = Invoke-WPHttp 'DELETE' (Get-WPOdUrl $Ctx $Item.Path '') (Get-WPCloudAuth $Ctx)
    if (-not $r.Ok -and $r.Status -ne 404) { throw (Get-WPHttpError $r "Deleting $($Item.Path)") }
}

function Receive-WPOdFile {
    param($Ctx, $Item, [string]$OutFile)
    # Graph hands out a short-lived, pre-signed download link; fetch that without the token.
    $r = Invoke-WPHttp 'GET' ((Get-WPOdUrl $Ctx $Item.Path '') + '?$select=id,@microsoft.graph.downloadUrl') (Get-WPCloudAuth $Ctx)
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
    $dl = (ConvertFrom-WPJsonBody $r).'@microsoft.graph.downloadUrl'
    $r = Invoke-WPHttp 'GET' ([string]$dl) @() -OutFile $OutFile
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
}

# ---- Google Drive (drive.file scope: only files WinPrestige created) ----

function Get-WPGdFolderId {
    param($Ctx, [string]$Path, [switch]$Create)
    $p = ([string]$Path).Trim('/')
    if (-not $p) { return 'root' }
    if ($Ctx.FolderIds[$p]) { return $Ctx.FolderIds[$p] }
    $parentPath = $(if ($p.Contains('/')) { $p.Substring(0, $p.LastIndexOf('/')) } else { '' })
    $name = $p.Substring($p.LastIndexOf('/') + 1)
    $parent = Get-WPGdFolderId $Ctx $parentPath -Create:$Create
    if (-not $parent) { return $null }
    $qName = $name -replace '\\', '\\' -replace "'", "\'"
    $q = "name = '$qName' and '$parent' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    $r = Invoke-WPHttp 'GET' ("$($Ctx.Api)/drive/v3/files?fields=files(id)&pageSize=10&q=" + [Uri]::EscapeDataString($q)) (Get-WPCloudAuth $Ctx)
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Finding folder $p on Google Drive") }
    $id = @((ConvertFrom-WPJsonBody $r).files | ForEach-Object { $_.id }) | Select-Object -First 1
    if (-not $id -and $Create) {
        $meta = @{ name = $name; mimeType = 'application/vnd.google-apps.folder'; parents = @($parent) } | ConvertTo-Json -Compress
        $r = Invoke-WPHttp 'POST' "$($Ctx.Api)/drive/v3/files?fields=id" ((Get-WPCloudAuth $Ctx) + @('Content-Type', 'application/json; charset=UTF-8')) $meta
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Creating folder $p on Google Drive") }
        $id = (ConvertFrom-WPJsonBody $r).id
    }
    if ($id) { $Ctx.FolderIds[$p] = [string]$id }
    return $id
}

function Get-WPGdChildren {
    param($Ctx, [string]$Path)
    $fid = Get-WPGdFolderId $Ctx $Path
    if (-not $fid) { return $null }
    $items = @(); $pageToken = ''
    do {
        $url = "$($Ctx.Api)/drive/v3/files?pageSize=1000&fields=nextPageToken,files(id,name,mimeType,size,md5Checksum)&q=" + [Uri]::EscapeDataString("'$fid' in parents and trashed = false")
        if ($pageToken) { $url += '&pageToken=' + [Uri]::EscapeDataString($pageToken) }
        $r = Invoke-WPHttp 'GET' $url (Get-WPCloudAuth $Ctx)
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Listing $Path on Google Drive") }
        $j = ConvertFrom-WPJsonBody $r
        foreach ($f in @($j.files)) {
            $isDir = $f.mimeType -eq 'application/vnd.google-apps.folder'
            $full = Join-WPRemote $Path $f.name
            if ($isDir) { $Ctx.FolderIds[$full] = [string]$f.id }
            $items += @{ Name = [string]$f.name; Path = $full; IsDir = $isDir; Size = [long]$f.size; Hash = [string]$f.md5Checksum; Id = [string]$f.id }
        }
        $pageToken = [string]$j.nextPageToken
    } while ($pageToken)
    return $items
}

function Send-WPGdFile {
    param($Ctx, [string]$Local, [string]$Path, [long]$Size, $Existing)
    $auth = Get-WPCloudAuth $Ctx
    $hdr = $auth + @('Content-Type', 'application/json; charset=UTF-8', 'X-Upload-Content-Type', 'application/octet-stream', 'X-Upload-Content-Length', [string]$Size)
    if ($Existing -and $Existing.Id) {
        $r = Invoke-WPHttp 'PATCH' "$($Ctx.Api)/upload/drive/v3/files/$($Existing.Id)?uploadType=resumable" $hdr '{}'
    } else {
        $parentPath = $(if ($Path.Contains('/')) { $Path.Substring(0, $Path.LastIndexOf('/')) } else { '' })
        $parent = Get-WPGdFolderId $Ctx $parentPath -Create
        $meta = @{ name = $Path.Substring($Path.LastIndexOf('/') + 1); parents = @($parent) } | ConvertTo-Json -Compress
        $r = Invoke-WPHttp 'POST' "$($Ctx.Api)/upload/drive/v3/files?uploadType=resumable" $hdr $meta
    }
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Starting the upload of $Path") }
    $session = $r.Header('Location')
    if ($Size -eq 0) {
        $r = Invoke-WPHttp 'PUT' $session @('Content-Range', 'bytes */0') ([byte[]]@())
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
        return
    }
    $chunk = 8MB   # a multiple of 256 KiB, as Drive requires
    for ($off = 0; $off -lt $Size; $off += $chunk) {
        $n = [Math]::Min($chunk, $Size - $off)
        $r = Invoke-WPHttp 'PUT' $session @('Content-Range', "bytes $off-$($off + $n - 1)/$Size") -File $Local -Offset $off -Length $n -NoRedirect
        if (-not ($r.Ok -or $r.Status -eq 308)) { throw (Get-WPHttpError $r "Uploading $Path") }
    }
}

function Remove-WPGdItem {
    param($Ctx, $Item)
    $r = Invoke-WPHttp 'DELETE' "$($Ctx.Api)/drive/v3/files/$($Item.Id)" (Get-WPCloudAuth $Ctx)
    if (-not $r.Ok -and $r.Status -ne 404) { throw (Get-WPHttpError $r "Deleting $($Item.Path)") }
}

function Receive-WPGdFile {
    param($Ctx, $Item, [string]$OutFile)
    $r = Invoke-WPHttp 'GET' "$($Ctx.Api)/drive/v3/files/$($Item.Id)?alt=media" (Get-WPCloudAuth $Ctx) -OutFile $OutFile
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
}

# ---- Dropbox (app folder) ----

function Get-WPDbxPath { param([string]$Path) $p = ([string]$Path).Trim('/'); if ($p) { return "/$p" } return '' }

function Get-WPDbxChildren {
    param($Ctx, [string]$Path)
    $items = @()
    $body = @{ path = (Get-WPDbxPath $Path); recursive = $false; limit = 2000 } | ConvertTo-Json -Compress
    $url = "$($Ctx.Api)/files/list_folder"
    while ($true) {
        $r = Invoke-WPHttp 'POST' $url ((Get-WPCloudAuth $Ctx) + @('Content-Type', 'application/json')) $body
        if ($r.Status -eq 409 -and $r.Body -match 'not_found') { return $null }
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Listing $Path on Dropbox") }
        $j = ConvertFrom-WPJsonBody $r
        foreach ($e in @($j.entries)) {
            $tag = [string]$e.'.tag'
            if ($tag -eq 'deleted') { continue }
            $items += @{ Name = [string]$e.name; Path = (Join-WPRemote $Path $e.name); IsDir = ($tag -eq 'folder'); Size = [long]$e.size; Hash = [string]$e.content_hash; Id = [string]$e.id }
        }
        if (-not $j.has_more) { break }
        $url = "$($Ctx.Api)/files/list_folder/continue"
        $body = @{ cursor = $j.cursor } | ConvertTo-Json -Compress
    }
    return $items
}

function Send-WPDbxFile {
    param($Ctx, [string]$Local, [string]$Path, [long]$Size)
    $commit = @{ path = (Get-WPDbxPath $Path); mode = 'overwrite'; autorename = $false; mute = $true }
    $oct = @('Content-Type', 'application/octet-stream')
    if ($Size -le 32MB) {
        $r = Invoke-WPHttp 'POST' "$($Ctx.Content)/files/upload" ((Get-WPCloudAuth $Ctx) + $oct + @('Dropbox-API-Arg', (ConvertTo-WPAsciiJson $commit))) -File $Local
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
        return
    }
    $chunk = 16MB
    $r = Invoke-WPHttp 'POST' "$($Ctx.Content)/files/upload_session/start" ((Get-WPCloudAuth $Ctx) + $oct + @('Dropbox-API-Arg', '{"close":false}')) -File $Local -Offset 0 -Length $chunk
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Starting the upload of $Path") }
    $sid = (ConvertFrom-WPJsonBody $r).session_id
    $off = [long]$chunk
    while ($Size - $off -gt $chunk) {
        $arg = ConvertTo-WPAsciiJson @{ cursor = @{ session_id = $sid; offset = $off }; close = $false }
        $r = Invoke-WPHttp 'POST' "$($Ctx.Content)/files/upload_session/append_v2" ((Get-WPCloudAuth $Ctx) + $oct + @('Dropbox-API-Arg', $arg)) -File $Local -Offset $off -Length $chunk
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
        $off += $chunk
    }
    $arg = ConvertTo-WPAsciiJson @{ cursor = @{ session_id = $sid; offset = $off }; commit = $commit }
    $r = Invoke-WPHttp 'POST' "$($Ctx.Content)/files/upload_session/finish" ((Get-WPCloudAuth $Ctx) + $oct + @('Dropbox-API-Arg', $arg)) -File $Local -Offset $off -Length ($Size - $off)
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Finishing the upload of $Path") }
}

function Remove-WPDbxItem {
    param($Ctx, $Item)
    $body = @{ path = (Get-WPDbxPath $Item.Path) } | ConvertTo-Json -Compress
    $r = Invoke-WPHttp 'POST' "$($Ctx.Api)/files/delete_v2" ((Get-WPCloudAuth $Ctx) + @('Content-Type', 'application/json')) $body
    if (-not $r.Ok -and -not ($r.Status -eq 409 -and $r.Body -match 'not_found')) { throw (Get-WPHttpError $r "Deleting $($Item.Path)") }
}

function Receive-WPDbxFile {
    param($Ctx, $Item, [string]$OutFile)
    $arg = ConvertTo-WPAsciiJson @{ path = (Get-WPDbxPath $Item.Path) }
    $r = Invoke-WPHttp 'GET' "$($Ctx.Content)/files/download" ((Get-WPCloudAuth $Ctx) + @('Dropbox-API-Arg', $arg)) -OutFile $OutFile
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
}

# ---- WebDAV and Nextcloud ----

function Get-WPDavUrl {
    param($Ctx, [string]$Path, [switch]$Folder)
    $p = ConvertTo-WPUrlPath $Path
    $u = $Ctx.Base + $p
    if ($Folder -and $p -and -not $u.EndsWith('/')) { $u += '/' }
    return $u
}

function Invoke-WPDavPropfind {
    param($Ctx, [string]$Url, [int]$Depth = 1, [string]$ExtraProps = '')
    $body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><d:resourcetype/><d:getcontentlength/><oc:checksums/>' + $ExtraProps + '</d:prop></d:propfind>'
    return (Invoke-WPHttp 'PROPFIND' $Url ((Get-WPCloudAuth $Ctx) + @('Depth', [string]$Depth, 'Content-Type', 'application/xml; charset=utf-8')) $body)
}

function Get-WPDavChildren {
    param($Ctx, [string]$Path)
    $url = Get-WPDavUrl $Ctx $Path -Folder
    $r = Invoke-WPDavPropfind $Ctx $url 1
    if ($r.Status -eq 404) { return $null }
    if ($r.Status -ne 207) { throw (Get-WPHttpError $r "Listing $Path") }
    $xml = New-Object Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml($r.Body)
    $self = [Uri]::UnescapeDataString(([uri]$url).AbsolutePath).TrimEnd('/')
    $items = @()
    foreach ($resp in @($xml.SelectNodes("//*[local-name()='response']"))) {
        $href = $resp.SelectSingleNode("*[local-name()='href']").InnerText
        $abs = $(if ($href -match '^https?://') { ([uri]$href).AbsolutePath } else { $href })
        $hp = [Uri]::UnescapeDataString($abs).TrimEnd('/')
        if ($hp -ieq $self) { continue }
        $name = $hp.Substring($hp.LastIndexOf('/') + 1)
        $ok = $null
        foreach ($ps in @($resp.SelectNodes("*[local-name()='propstat']"))) {
            if ($ps.SelectSingleNode("*[local-name()='status']").InnerText -match ' 200 ') { $ok = $ps.SelectSingleNode("*[local-name()='prop']") }
        }
        if (-not $ok) { continue }
        $isDir = [bool]$ok.SelectSingleNode("*[local-name()='resourcetype']/*[local-name()='collection']")
        $lenNode = $ok.SelectSingleNode("*[local-name()='getcontentlength']")
        $sum = ''
        foreach ($c in @($ok.SelectNodes(".//*[local-name()='checksum']"))) { if ($c.InnerText -match '(?i)SHA1:([0-9a-f]{40})') { $sum = $Matches[1].ToLowerInvariant() } }
        $items += @{ Name = $name; Path = (Join-WPRemote $Path $name); IsDir = $isDir; Size = $(if ($lenNode -and $lenNode.InnerText) { [long]$lenNode.InnerText } else { 0 }); Hash = $sum; Id = '' }
    }
    return $items
}

function New-WPDavFolder {
    # Creates the folder and any missing parents (MKCOL), remembering what exists.
    param($Ctx, [string]$Path)
    $p = ([string]$Path).Trim('/')
    if (-not $p -or $Ctx.Made[$p]) { return }
    if ($p.Contains('/')) { New-WPDavFolder $Ctx $p.Substring(0, $p.LastIndexOf('/')) }
    $r = Invoke-WPHttp 'MKCOL' (Get-WPDavUrl $Ctx $p -Folder) (Get-WPCloudAuth $Ctx)
    # 405 means it already exists.
    if (-not $r.Ok -and $r.Status -ne 405) { throw (Get-WPHttpError $r "Creating folder $p") }
    $Ctx.Made[$p] = $true
}

function Send-WPDavFile {
    param($Ctx, [string]$Local, [string]$Path, [long]$Size, [string]$Sha1)
    $parentPath = $(if ($Path.Contains('/')) { $Path.Substring(0, $Path.LastIndexOf('/')) } else { '' })
    New-WPDavFolder $Ctx $parentPath
    $dest = Get-WPDavUrl $Ctx $Path
    $sumHdr = $(if ($Sha1) { @('OC-Checksum', "SHA1:$Sha1") } else { @() })
    if ($Ctx.Provider -eq 'nextcloud' -and $Size -gt 64MB) {
        # Chunked upload (v2), so big installers get past reverse-proxy and tunnel size limits.
        $user = [Uri]::EscapeDataString([string]$Ctx.Account.User)
        $up = "$($Ctx.Account.Server)/remote.php/dav/uploads/$user/winprestige-$([guid]::NewGuid().ToString('N'))"
        $common = (Get-WPCloudAuth $Ctx) + @('Destination', $dest, 'OC-Total-Length', [string]$Size)
        $r = Invoke-WPHttp 'MKCOL' $up $common
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Starting the upload of $Path") }
        $chunk = 32MB; $n = 0
        try {
            for ($off = 0; $off -lt $Size; $off += $chunk) {
                $n++
                $len = [Math]::Min($chunk, $Size - $off)
                $r = Invoke-WPHttp 'PUT' ("$up/" + $n.ToString('00000')) ($common + @('Content-Type', 'application/octet-stream')) -File $Local -Offset $off -Length $len
                if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
            }
            $r = Invoke-WPHttp 'MOVE' "$up/.file" ($common + $sumHdr + @('Overwrite', 'T')) ''
            if (-not $r.Ok) { throw (Get-WPHttpError $r "Finishing the upload of $Path") }
        } catch {
            [void](Invoke-WPHttp 'DELETE' $up (Get-WPCloudAuth $Ctx) -Tries 1)
            throw
        }
        return
    }
    $r = Invoke-WPHttp 'PUT' $dest ((Get-WPCloudAuth $Ctx) + $sumHdr + @('Content-Type', 'application/octet-stream')) -File $Local
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
}

function Remove-WPDavItem {
    param($Ctx, $Item)
    $r = Invoke-WPHttp 'DELETE' (Get-WPDavUrl $Ctx $Item.Path) (Get-WPCloudAuth $Ctx)
    if (-not $r.Ok -and $r.Status -ne 404) { throw (Get-WPHttpError $r "Deleting $($Item.Path)") }
}

function Receive-WPDavFile {
    param($Ctx, $Item, [string]$OutFile)
    $r = Invoke-WPHttp 'GET' (Get-WPDavUrl $Ctx $Item.Path) (Get-WPCloudAuth $Ctx) -OutFile $OutFile
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
}

# ---- S3-compatible ----

function Get-WPS3Url {
    param($Ctx, [string]$Key, [hashtable]$Query)
    $a = $Ctx.Account
    $ep = [uri]$a.Endpoint
    $k = ConvertTo-WPUrlPath $Key
    if ($a.PathStyle) { $u = "$($a.Endpoint)/$([Uri]::EscapeDataString($a.Bucket))/$k" }
    else { $u = "$($ep.Scheme)://$($a.Bucket).$($ep.Authority)/$k" }
    if (-not $k) { $u = $u.TrimEnd('/'); if (-not $a.PathStyle) { $u += '/' } }
    if ($Query -and $Query.Count) {
        $u += '?' + (($Query.GetEnumerator() | Sort-Object Key | ForEach-Object {
                    if ($null -eq $_.Value) { [Uri]::EscapeDataString($_.Key) } else { [Uri]::EscapeDataString($_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value) }
                }) -join '&')
    }
    return $u
}

function Invoke-WPS3 {
    param($Ctx, [string]$Method, [string]$Key, [hashtable]$Query, [string[]]$Headers = @(), $Body, [string]$File, [long]$Offset = 0, [long]$Length = -1, [string]$OutFile)
    $url = Get-WPS3Url $Ctx $Key $Query
    $a = $Ctx.Account
    if (-not $Ctx.S3Secret) { $Ctx.S3Secret = (Get-WPCloudSecret $a).secret }
    $sec = $Ctx.S3Secret
    $signScript = { [WinPrestige.SigV4]::Sign($Method, $url, [string]$a.Region, 's3', [string]$a.User, [string]$sec, 'UNSIGNED-PAYLOAD', $null, '') }.GetNewClosure()
    if ($OutFile) { return (Invoke-WPHttp $Method $url $Headers -OutFile $OutFile -Sign $signScript) }
    if ($File) { return (Invoke-WPHttp $Method $url $Headers -File $File -Offset $Offset -Length $Length -Sign $signScript) }
    return (Invoke-WPHttp $Method $url $Headers $Body -Sign $signScript)
}

function Get-WPS3Prefix {
    param($Ctx, [string]$Path)
    $p = ([string]$Path).Trim('/')
    if ($p) { return "$p/" }
    return ''
}

function Get-WPS3PartSize {
    # Single PUT up to 64 MB; above that, multipart with parts of at least 16 MB (max 10,000 parts).
    param([long]$Size)
    if ($Size -le 64MB) { return [long]0 }
    return [long]([Math]::Max(16MB, [Math]::Ceiling($Size / 9000.0 / 1MB) * 1MB))
}

function Get-WPS3Children {
    param($Ctx, [string]$Path)
    $prefix = Get-WPS3Prefix $Ctx $Path
    $items = @(); $token = ''
    do {
        $q = @{ 'list-type' = '2'; prefix = $prefix; delimiter = '/' }
        if ($token) { $q['continuation-token'] = $token }
        $r = Invoke-WPS3 $Ctx 'GET' '' $q
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Listing $Path in the bucket") }
        $xml = New-Object Xml.XmlDocument; $xml.XmlResolver = $null; $xml.LoadXml($r.Body)
        foreach ($c in @($xml.SelectNodes("//*[local-name()='Contents']"))) {
            $key = $c.SelectSingleNode("*[local-name()='Key']").InnerText
            if ($key -eq $prefix) { continue }
            $name = $key.Substring($prefix.Length)
            $items += @{ Name = $name; Path = (Join-WPRemote $Path $name); IsDir = $false; Size = [long]$c.SelectSingleNode("*[local-name()='Size']").InnerText; Hash = ($c.SelectSingleNode("*[local-name()='ETag']").InnerText.Trim('"').ToLowerInvariant()); Id = $key }
        }
        foreach ($cp in @($xml.SelectNodes("//*[local-name()='CommonPrefixes']/*[local-name()='Prefix']"))) {
            $name = $cp.InnerText.Substring($prefix.Length).TrimEnd('/')
            if ($name) { $items += @{ Name = $name; Path = (Join-WPRemote $Path $name); IsDir = $true; Size = 0; Hash = ''; Id = $cp.InnerText } }
        }
        $trunc = $xml.SelectSingleNode("//*[local-name()='IsTruncated']")
        $next = $xml.SelectSingleNode("//*[local-name()='NextContinuationToken']")
        $token = $(if ($trunc -and $trunc.InnerText -eq 'true' -and $next) { $next.InnerText } else { '' })
    } while ($token)
    if (-not $items.Count -and $prefix) { return $null }
    return $items
}

function Send-WPS3File {
    param($Ctx, [string]$Local, [string]$Path, [long]$Size, [string]$Etag)
    $part = Get-WPS3PartSize $Size
    if (-not $part) {
        $hdr = @('Content-Type', 'application/octet-stream')
        if ($Etag -match '^[0-9a-f]{32}$') {
            $bytes = [byte[]]::new(16); for ($i = 0; $i -lt 16; $i++) { $bytes[$i] = [Convert]::ToByte($Etag.Substring($i * 2, 2), 16) }
            $hdr += @('Content-MD5', [Convert]::ToBase64String($bytes))   # the server rejects the upload if it arrives damaged
        }
        $r = Invoke-WPS3 $Ctx 'PUT' $Path $null $hdr -File $Local
        if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
        return
    }
    $r = Invoke-WPS3 $Ctx 'POST' $Path @{ uploads = $null } @('Content-Type', 'application/octet-stream') ''
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Starting the upload of $Path") }
    if ($r.Body -notmatch '<UploadId>([^<]+)</UploadId>') { throw "Starting the upload of ${Path}: no upload ID in the answer." }
    $uid = [Net.WebUtility]::HtmlDecode($Matches[1])
    $tags = New-Object Text.StringBuilder
    try {
        $n = 0
        for ($off = 0; $off -lt $Size; $off += $part) {
            $n++
            $len = [Math]::Min($part, $Size - $off)
            $r = Invoke-WPS3 $Ctx 'PUT' $Path @{ partNumber = [string]$n; uploadId = $uid } @() -File $Local -Offset $off -Length $len
            if (-not $r.Ok) { throw (Get-WPHttpError $r "Uploading $Path") }
            [void]$tags.Append("<Part><PartNumber>$n</PartNumber><ETag>$([Net.WebUtility]::HtmlEncode($r.Header('ETag')))</ETag></Part>")
        }
        $xmlBody = "<CompleteMultipartUpload>$tags</CompleteMultipartUpload>"
        $r = Invoke-WPS3 $Ctx 'POST' $Path @{ uploadId = $uid } @('Content-Type', 'application/xml') $xmlBody
        if (-not $r.Ok -or $r.Body -match '<Error>') { throw (Get-WPHttpError $r "Finishing the upload of $Path") }
    } catch {
        [void](Invoke-WPS3 $Ctx 'DELETE' $Path @{ uploadId = $uid })
        throw
    }
}

function Remove-WPS3Item {
    param($Ctx, $Item)
    $r = Invoke-WPS3 $Ctx 'DELETE' $Item.Path $null
    if (-not $r.Ok -and $r.Status -ne 404) { throw (Get-WPHttpError $r "Deleting $($Item.Path)") }
}

function Receive-WPS3File {
    param($Ctx, $Item, [string]$OutFile)
    $r = Invoke-WPS3 $Ctx 'GET' $Item.Path $null -OutFile $OutFile
    if (-not $r.Ok) { throw (Get-WPHttpError $r "Downloading $($Item.Path)") }
}

# ---- Dispatch ----

function Get-WPCloudChildren {
    param($Ctx, [string]$Path)
    switch ($Ctx.Provider) {
        'onedrive' { return (Get-WPOdChildren $Ctx $Path) }
        'googledrive' { return (Get-WPGdChildren $Ctx $Path) }
        'dropbox' { return (Get-WPDbxChildren $Ctx $Path) }
        's3' { return (Get-WPS3Children $Ctx $Path) }
        default { return (Get-WPDavChildren $Ctx $Path) }
    }
}

function Get-WPCloudListing {
    # Every file under the context's folder, keyed by path relative to it (case-insensitive).
    param($Ctx)
    $files = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue('')
    while ($queue.Count) {
        if (Test-WPCancel) { throw 'Cancelled' }
        $rel = [string]$queue.Dequeue()
        $kids = Get-WPCloudChildren $Ctx (Join-WPRemote $Ctx.Dir $rel)
        if ($null -eq $kids) { continue }
        foreach ($k in @($kids)) {
            $kr = Join-WPRemote $rel $k.Name
            if ($k.IsDir) { $queue.Enqueue($kr) }
            elseif (-not $files.ContainsKey($kr)) { $k.Rel = $kr; $files[$kr] = [pscustomobject]$k }
        }
    }
    return $files
}

function Get-WPCloudLocalHash {
    param($Ctx, [string]$Path, [long]$Size)
    switch ($Ctx.HashType) {
        'quickxor' { return [WinPrestige.FileHash]::QuickXor($Path) }
        'md5' { return [WinPrestige.FileHash]::Md5($Path) }
        'dropbox' { return [WinPrestige.FileHash]::Dropbox($Path) }
        'etag' { return [WinPrestige.FileHash]::S3Etag($Path, (Get-WPS3PartSize $Size)) }
        default { return [WinPrestige.FileHash]::Sha1($Path) }
    }
}

function Send-WPCloudItem {
    param($Ctx, [string]$Local, [string]$Rel, [long]$Size, [string]$Hash, $Existing)
    $path = Join-WPRemote $Ctx.Dir $Rel
    switch ($Ctx.Provider) {
        'onedrive' { Send-WPOdFile $Ctx $Local $path $Size }
        'googledrive' { Send-WPGdFile $Ctx $Local $path $Size $Existing }
        'dropbox' { Send-WPDbxFile $Ctx $Local $path $Size }
        's3' { Send-WPS3File $Ctx $Local $path $Size $Hash }
        default { Send-WPDavFile $Ctx $Local $path $Size $Hash }
    }
}

function Remove-WPCloudItem {
    param($Ctx, $Item)
    switch ($Ctx.Provider) {
        'onedrive' { Remove-WPOdItem $Ctx $Item }
        'googledrive' { Remove-WPGdItem $Ctx $Item }
        'dropbox' { Remove-WPDbxItem $Ctx $Item }
        's3' { Remove-WPS3Item $Ctx $Item }
        default { Remove-WPDavItem $Ctx $Item }
    }
}

function Receive-WPCloudItem {
    param($Ctx, $Item, [string]$OutFile)
    switch ($Ctx.Provider) {
        'onedrive' { Receive-WPOdFile $Ctx $Item $OutFile }
        'googledrive' { Receive-WPGdFile $Ctx $Item $OutFile }
        'dropbox' { Receive-WPDbxFile $Ctx $Item $OutFile }
        's3' { Receive-WPS3File $Ctx $Item $OutFile }
        default { Receive-WPDavFile $Ctx $Item $OutFile }
    }
}

#endregion

#region Upload, verify, download ------------------------------------------------

$script:WPCloudSums = '.winprestige-checksums.json'

function Test-WPCloudHashMatch {
    param([string]$Remote, [string]$Local)
    if (-not $Remote -or -not $Local) { return $null }   # unknown: the provider gave no checksum
    return ($Remote.Trim('"') -ieq $Local.Trim('"'))
}

function Sync-WPCloudUpload {
    # Mirrors the staging folder to the account's remote folder, then lists the remote side again
    # and checks every file's size and checksum. Returns the verification result.
    param($Account, [string]$Staging, [string]$Dir)
    Initialize-WPCloudTools
    $prov = Get-WPCloudProvider $Account.Provider
    $ctx = New-WPCloudContext $Account $Dir
    $where = Get-WPCloudWhere $Account $Dir
    Write-WPLog "Uploading to $($prov.Name): $where" 'step'
    $root = (Resolve-Path -LiteralPath $Staging).ProviderPath.TrimEnd('\')
    $local = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.partial(\\|$)' })
    $totalBytes = [long](($local | Measure-Object Length -Sum).Sum)
    Set-WPProgress 0 100 "Checking what's already on $($prov.Name)..."
    $remote = Get-WPCloudListing $ctx

    $ledgerDir = Join-Path $script:WP.StateDir "Cloud\$($Account.Id)"
    if (-not (Test-Path -LiteralPath $ledgerDir)) { New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null }
    $ledgerPath = Join-Path $ledgerDir ('uploaded-' + (($Dir -replace '[\/:*?"<>|\s]', '_')) + '.json')
    $ledger = @{}
    $lj = Read-WPJson $ledgerPath
    if ($lj) { foreach ($p in $lj.PSObject.Properties) { $ledger[$p.Name] = $p.Value } }
    $newLedger = @{}
    $done = [long]0; $uploaded = 0; $upBytes = [long]0; $skipped = 0; $errors = @()
    $localSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $local) {
        if (Test-WPCancel) { throw 'Cancelled' }
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void]$localSet.Add($rel)
        $size = [long]$f.Length; $ticks = $f.LastWriteTimeUtc.Ticks
        $prev = $ledger[$rel]
        $r = $null; if ($remote.ContainsKey($rel)) { $r = $remote[$rel] }
        $unchanged = $prev -and [long]$prev.Size -eq $size -and [long]$prev.Ticks -eq $ticks -and [string]$prev.Type -eq $ctx.HashType
        $hash = $(if ($unchanged) { [string]$prev.Hash } else { Get-WPCloudLocalHash $ctx $f.FullName $size })
        $same = $r -and [long]$r.Size -eq $size -and ((Test-WPCloudHashMatch $r.Hash $hash) -ne $false) -and ($unchanged -or $r.Hash)
        if ($same) { $skipped++ }
        else {
            $pct = [int](100 * ($done / [Math]::Max(1, $totalBytes)))
            Set-WPProgress $pct 100 ("Uploading {0} ({1})" -f $rel, (Format-WPSize $size))
            try {
                Send-WPCloudItem $ctx $f.FullName $rel $size $hash $r
                $uploaded++; $upBytes += $size
            } catch {
                if ("$_" -eq 'Cancelled') { throw }
                $errors += "$rel - $_"
                Write-WPLog ("Couldn't upload {0}: {1}" -f $rel, $_) 'error'
                $done += $size
                continue
            }
        }
        $newLedger[$rel] = @{ Size = $size; Ticks = $ticks; Hash = $hash; Type = $ctx.HashType }
        $done += $size
    }
    Write-WPJson $newLedger $ledgerPath

    # Mirror: files this backup no longer has (pruned apps, old installer versions) go too.
    [void]$localSet.Add($script:WPCloudSums)
    $removed = 0
    foreach ($k in @($remote.Keys)) {
        if (Test-WPCancel) { throw 'Cancelled' }
        if ($localSet.Contains($k)) { continue }
        try { Remove-WPCloudItem $ctx $remote[$k]; $removed++ } catch { Write-WPLog ("Couldn't remove old file {0}: {1}" -f $k, $_) 'warn' }
    }

    # The checksum list travels with the backup, so a restore can tell if anything changed in the
    # cloud since (even on servers that report no checksums of their own).
    $sumsTmp = Join-Path $env:TEMP ('wp-sums-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $sumFiles = @{}
        foreach ($k in $newLedger.Keys) { $sumFiles[$k] = @{ Size = $newLedger[$k].Size; Hash = $newLedger[$k].Hash } }
        Write-WPJson ([ordered]@{ tool = 'WinPrestige'; version = $script:WP.Version; type = $ctx.HashType; created = (Get-Date).ToString('s'); files = $sumFiles }) $sumsTmp
        $sz = (Get-Item -LiteralPath $sumsTmp).Length
        $old = $(if ($remote.ContainsKey($script:WPCloudSums)) { $remote[$script:WPCloudSums] })
        Send-WPCloudItem $ctx $sumsTmp $script:WPCloudSums $sz (Get-WPCloudLocalHash $ctx $sumsTmp $sz) $old
    } catch {
        if ("$_" -eq 'Cancelled') { throw }
        $errors += "$($script:WPCloudSums) - $_"
    } finally { Remove-Item -LiteralPath $sumsTmp -Force -ErrorAction SilentlyContinue }
    Write-WPLog ("Uploaded {0} files ({1}), {2} already there, {3} old files removed." -f $uploaded, (Format-WPSize $upBytes), $skipped, $removed) $(if ($errors.Count) { 'warn' } else { 'ok' })

    # Verify against a fresh listing, not against what the uploads reported.
    Set-WPProgress 99 100 "Checking the files on $($prov.Name)..."
    Write-WPLog "Checking every file on $($prov.Name)..." 'step'
    $after = Get-WPCloudListing $ctx
    $missing = @(); $wrongSize = @(); $hashOk = 0; $hashBad = @(); $sizeOnly = 0
    foreach ($rel in @($newLedger.Keys)) {
        $l = $newLedger[$rel]
        if (-not $after.ContainsKey($rel)) { $missing += $rel; continue }
        $a = $after[$rel]
        if ([long]$a.Size -ne [long]$l.Size) { $wrongSize += $rel; continue }
        $m = Test-WPCloudHashMatch $a.Hash $l.Hash
        if ($null -eq $m) { $sizeOnly++ } elseif ($m) { $hashOk++ } else { $hashBad += $rel }
    }
    # A provider whose checksum format we compute differently would fail every file the same way;
    # report that honestly as "sizes only" instead of hundreds of false alarms.
    $hashNote = ''
    if ($hashBad.Count -ge 3 -and -not $hashOk -and -not $missing.Count -and -not $wrongSize.Count) {
        $hashNote = "$($prov.Name) reported checksums WinPrestige couldn't match, so only sizes were compared."
        $sizeOnly += $hashBad.Count; $hashBad = @()
        Write-WPLog $hashNote 'warn'
    }
    $files = $newLedger.Count + @($errors).Count
    $problems = @()
    foreach ($x in $errors) { $problems += "Upload failed: $x" }
    foreach ($x in $missing) { $problems += "Not on $($prov.Name): $x" }
    foreach ($x in $wrongSize) { $problems += "Different size on $($prov.Name): $x" }
    foreach ($x in $hashBad) { $problems += "Checksum doesn't match: $x" }
    $verified = -not $problems.Count -and -not (Test-WPCancel)
    $result = [ordered]@{
        Provider = $prov.Name; ProviderId = $Account.Provider; AccountId = $Account.Id; Account = [string]$Account.Label
        Where = $where; Dir = $Dir; Web = $(if ($Account.Web) { [string]$Account.Web } else { $prov.Web })
        Files = $files; Bytes = $totalBytes; Uploaded = $uploaded; UploadedBytes = $upBytes; Skipped = $skipped; Removed = $removed
        HashChecked = $hashOk; SizeOnly = $sizeOnly; Problems = @($problems); Verified = $verified; HashNote = $hashNote
        Date = (Get-Date).ToString('s')
    }
    if ($verified) {
        $how = $(if ($sizeOnly -and -not $hashOk) { 'sizes match' } elseif ($sizeOnly) { "$hashOk checksums and $sizeOnly sizes match" } else { 'sizes and checksums match' })
        Write-WPLog ("Verified on {0}: all {1:N0} files ({2}) are there and {3}." -f $prov.Name, $files, (Format-WPSize $totalBytes), $how) 'ok'
    } else {
        Write-WPLog ("{0} of {1:N0} files on {2} didn't check out. Run the backup again to retry them." -f $problems.Count, $files, $prov.Name) 'error'
    }
    Write-WPJson $result (Join-Path $script:WP.StateDir "Cloud\$($Account.Id)\last-upload.json")
    return [pscustomobject]$result
}

function Find-WPCloudBackups {
    # WinPrestige backups under the account's root folder: any folder with a manifest.json.
    param($Account)
    Initialize-WPCloudTools
    $ctx = New-WPCloudContext $Account ''
    $root = ([string]$Account.Root).Trim('/')
    $found = @()
    $candidates = @($root)
    $kids = Get-WPCloudChildren $ctx $root
    foreach ($k in @($kids)) { if ($k.IsDir) { $candidates += $k.Path } }
    $tmp = Join-Path $env:TEMP ('wp-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    foreach ($c in $candidates) {
        if (Test-WPCancel) { break }
        $files = Get-WPCloudChildren $ctx $c
        $mf = @($files) | Where-Object { $_ -and -not $_.IsDir -and $_.Name -ieq 'manifest.json' } | Select-Object -First 1
        if (-not $mf) { continue }
        $info = [ordered]@{ Dir = $c; Computer = ($c -split '/')[-1]; Created = ''; Apps = 0; Configs = 0 }
        try {
            Receive-WPCloudItem $ctx $mf $tmp
            $m = Read-WPJson $tmp
            if ($m.computer) { $info.Computer = [string]$m.computer }
            $info.Created = [string]$m.created
            $info.Apps = @($m.apps | Where-Object { $_.Selected }).Count
            $info.Configs = @($m.configs).Count
        } catch { }
        $found += [pscustomobject]$info
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return @($found | Sort-Object Created -Descending)
}

function Receive-WPCloudBackup {
    # Downloads a backup folder, checking each file against the provider's size and checksum.
    # Files already downloaded and intact are kept, so an interrupted download picks up again.
    param($Account, [string]$Dir, [string]$Destination)
    Initialize-WPCloudTools
    $prov = Get-WPCloudProvider $Account.Provider
    $ctx = New-WPCloudContext $Account $Dir
    Write-WPLog "Downloading the backup from $($prov.Name) to $Destination" 'step'
    Set-WPProgress 0 100 "Listing the backup on $($prov.Name)..."
    $remote = Get-WPCloudListing $ctx
    if (-not $remote.Count) { throw "There's no backup in $(Get-WPCloudWhere $Account $Dir)." }
    # Checksums recorded at backup time, when present, beat whatever the server reports now.
    $expected = @{}
    if ($remote.ContainsKey($script:WPCloudSums)) {
        $tmp = Join-Path $env:TEMP ('wp-sums-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Receive-WPCloudItem $ctx $remote[$script:WPCloudSums] $tmp
            $sj = Read-WPJson $tmp
            if ($sj -and [string]$sj.type -eq $ctx.HashType) { foreach ($p in $sj.files.PSObject.Properties) { $expected[$p.Name] = $p.Value } }
        } catch { Write-WPLog "Couldn't read the backup's checksum list ($_); checking against $($prov.Name)'s own checksums instead." 'warn' }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        [void]$remote.Remove($script:WPCloudSums)
    }
    $total = [long](($remote.Values | Measure-Object Size -Sum).Sum)
    $done = [long]0; $got = 0; $kept = 0; $problems = @()
    foreach ($item in @($remote.Values | Sort-Object { $_.Rel -ne 'manifest.json' })) {
        if (Test-WPCancel) { throw 'Cancelled' }
        $local = Join-Path $Destination ($item.Rel -replace '/', '\')
        $dirPath = Split-Path -Parent $local
        if (-not (Test-Path -LiteralPath $dirPath)) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
        $exp = $expected[$item.Rel]
        $wantHash = $(if ($exp -and $exp.Hash) { [string]$exp.Hash } else { [string]$item.Hash })
        if ($exp -and [long]$exp.Size -ne [long]$item.Size) {
            $problems += "$($item.Rel): changed in the cloud since the backup ($(Format-WPSize $item.Size) now, $(Format-WPSize $exp.Size) then)"
            Write-WPLog ("{0} changed in the cloud since the backup, so it wasn't used." -f $item.Rel) 'error'
            $done += $item.Size; continue
        }
        $ok = $false
        if ((Test-Path -LiteralPath $local) -and (Get-Item -LiteralPath $local).Length -eq $item.Size) {
            $ok = (Test-WPCloudHashMatch $wantHash (Get-WPCloudLocalHash $ctx $local $item.Size)) -ne $false
        }
        if ($ok) { $kept++; $done += $item.Size; continue }
        Set-WPProgress ([int](100 * $done / [Math]::Max(1, $total))) 100 ("Downloading {0} ({1})" -f $item.Rel, (Format-WPSize $item.Size))
        $part = "$local.wpdownload"
        try {
            Receive-WPCloudItem $ctx $item $part
            $len = (Get-Item -LiteralPath $part).Length
            if ($len -ne $item.Size) { throw "got $(Format-WPSize $len), expected $(Format-WPSize $item.Size)" }
            if ((Test-WPCloudHashMatch $wantHash (Get-WPCloudLocalHash $ctx $part $item.Size)) -eq $false) { throw "checksum doesn't match the backup" }
            Move-Item -LiteralPath $part -Destination $local -Force
            $got++
        } catch {
            if ("$_" -eq 'Cancelled') { throw }
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            $problems += "$($item.Rel): $_"
            Write-WPLog ("Couldn't download {0}: {1}" -f $item.Rel, $_) 'error'
        }
        $done += $item.Size
    }
    $msg = "Downloaded {0} files ({1}), {2} were already here and intact." -f $got, (Format-WPSize $total), $kept
    Write-WPLog $msg $(if ($problems.Count) { 'warn' } else { 'ok' })
    if ($problems.Count) { Write-WPLog ("{0} files didn't download. Try again; finished files are kept." -f $problems.Count) 'error' }
    return [pscustomobject]@{ Files = $remote.Count; Bytes = $total; Downloaded = $got; Kept = $kept; Problems = @($problems); Destination = $Destination; Complete = (-not $problems.Count) }
}

#endregion
