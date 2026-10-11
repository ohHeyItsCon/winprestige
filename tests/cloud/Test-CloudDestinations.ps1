<#
.SYNOPSIS
    End-to-end tests for WinPrestige's cloud destinations, against a local mock of each service.

.DESCRIPTION
    Starts MockCloud.cs (an in-memory stand-in for WebDAV, Nextcloud, S3 with SigV4 checking,
    OAuth with PKCE, Microsoft Graph, Google Drive and Dropbox), then for each provider: signs in,
    uploads a backup-shaped folder (including a 70 MB file and awkward names), verifies it, re-runs,
    changes and prunes, downloads it byte for byte, and checks a damaged file is refused.
    Nothing touches a real account. The real services still need a manual test once app IDs exist.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\cloud\Test-CloudDestinations.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\cloud\Test-CloudDestinations.ps1 -OnlyList 's3,webdav'
#>
param([string]$OnlyList)
$Only = @($OnlyList -split ',' | Where-Object { $_ })
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$work = Join-Path $env:TEMP 'WinPrestige-cloud-test'
if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
[void](New-Item -ItemType Directory $work -Force)
. "$repo\lib\Core.ps1"
Initialize-WP -Root $repo
$WP.StateDir = Join-Path $work 'state'
[void](New-Item -ItemType Directory $WP.StateDir -Force)
Initialize-WPCloudTools
$dll = [WinPrestige.CloudHttp].Assembly.Location
Add-Type -TypeDefinition ([IO.File]::ReadAllText("$here\MockCloud.cs")) -ReferencedAssemblies $dll, System.Core, System.Net.Http
$port = 47920 + (Get-Random -Maximum 50)
$mock = New-Object MockCloud $port
$MockBase = $mock.Base
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Info = '') { if ($Ok) { $script:pass++; "  PASS $Name" } else { $script:fail++; "  FAIL $Name $Info" } }
"=== helpers ==="
$h = [WinPrestige.SigV4]::Sign('GET', 'https://examplebucket.s3.amazonaws.com/test.txt', 'us-east-1', 's3', 'AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', @('range', 'bytes=0-9'), '20130524T000000Z')
Check 'SigV4 matches AWS example (GET object)' ($h[5] -match 'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41$')
$h = [WinPrestige.SigV4]::Sign('GET', 'https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J', 'us-east-1', 's3', 'AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', $null, '20130524T000000Z')
Check 'SigV4 matches AWS example (list objects)' ($h[5] -match '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7$')
Check 'PKCE matches RFC 7636 example' ([WinPrestige.Secret]::PkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') -eq 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
$e0 = Join-Path $work 'empty.bin'; [IO.File]::WriteAllBytes($e0, @())
Check 'QuickXorHash of an empty file' ([WinPrestige.FileHash]::QuickXor($e0) -eq 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=')
Check 'DPAPI round trip' ([WinPrestige.Secret]::Unprotect([WinPrestige.Secret]::Protect('x1')) -eq 'x1')

# The "browser": follows the sign-in URL like a user who clicks Allow.
function Open-WPUrl {
    param([string]$Url)
    $null = Start-Job -ScriptBlock { param($u) Start-Sleep -Milliseconds 400; try { Invoke-WebRequest $u -UseBasicParsing -MaximumRedirection 5 | Out-Null } catch { } } -ArgumentList $Url
}

@{
    onedrive    = @{ clientId = 'test-od'; authorizeUrl = "$MockBase/oauth/authorize"; tokenUrl = "$MockBase/oauth/token"; apiUrl = "$MockBase/graph/v1.0" }
    googledrive = @{ clientId = 'test-gd'; clientSecret = 'gd-secret'; authorizeUrl = "$MockBase/oauth/authorize"; tokenUrl = "$MockBase/oauth/token"; apiUrl = "$MockBase/gd" }
    dropbox     = @{ appKey = 'test-dbx'; redirect = 'http://127.0.0.1:47615/'; authorizeUrl = "$MockBase/oauth/authorize"; tokenUrl = "$MockBase/oauth/token"; apiUrl = "$MockBase/dbx/2"; contentUrl = "$MockBase/dbxc/2" }
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $WP.StateDir 'cloud-apps.json') -Encoding UTF8

# A staging folder that looks like a backup: nested folders, odd names, an empty file, a 70 MB installer.
$stage = Join-Path $work 'stage'
if (Test-Path $stage) { [IO.Directory]::Delete($stage, $true) }
$e = [char]0xE8
$files = @{
    'manifest.json'                                  = 1200
    'AppInventory.html'                              = 30000
    "Configs/OBS Studio #1/sc${e}nes (1).json"       = 4096
    'Configs/OBS Studio #1/empty.txt'                = 0
    'Configs/Git+Tools & More/.gitconfig'            = 333
    'Installers/7-Zip/7z2501-x64.exe'                = 1600000
    'Installers/Medium/medium.msi'                   = 6MB + 123
    'Installers/Big One/big setup.exe'               = 70MB + 4567
}
$rnd = New-Object Random 42
foreach ($k in $files.Keys) {
    $p = Join-Path $stage ($k -replace '/', '\'); [void](New-Item -ItemType Directory (Split-Path $p) -Force)
    $buf = New-Object byte[] $files[$k]; $rnd.NextBytes($buf); [IO.File]::WriteAllBytes($p, $buf)
}
function Get-Tree($root) {
    $h = @{}
    Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $h[$_.FullName.Substring($root.Length + 1).Replace('\', '/')] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    return $h
}
$want = Get-Tree $stage

$providers = @(
    @{ Id = 'webdav'; Connect = { Connect-WPWebDav "$MockBase/dav/" 'user' 'pw1' } }
    @{ Id = 'nextcloud'; Connect = { Connect-WPNextcloud "$MockBase/nc" } }
    @{ Id = 's3'; Connect = { $mock.FailNextS3Put = $true; Connect-WPS3 "$MockBase/s3" 'us-east-1' 'backups' 'AKTEST' 's3secret' $true } }
    @{ Id = 'onedrive'; Connect = { Connect-WPCloudOAuth 'onedrive' 30 } }
    @{ Id = 'googledrive'; Connect = { Connect-WPCloudOAuth 'googledrive' 30 } }
    @{ Id = 'dropbox'; Connect = { Connect-WPCloudOAuth 'dropbox' 30 } }
)
foreach ($pv in $providers) {
    if ($Only -and $pv.Id -notin $Only) { continue }
    "=== $($pv.Id) ==="
    try {
        $acct = & $pv.Connect
        Check 'connect' ([bool]$acct.Id) ; "  account: $($acct.Label)  free: $($acct.Free)"
        $dir = Get-WPCloudRemoteDir $acct 'TEST-PC'
        $r1 = Sync-WPCloudUpload $acct $stage $dir
        Check 'first upload verified' ($r1.Verified -and $r1.Uploaded -eq $files.Count) "uploaded $($r1.Uploaded) problems: $($r1.Problems -join '; ')"
        "  checks: $($r1.HashChecked) by checksum, $($r1.SizeOnly) by size only$(if ($r1.HashNote) { ' - ' + $r1.HashNote })"
        $r2 = Sync-WPCloudUpload $acct $stage $dir
        Check 'second run uploads nothing' ($r2.Verified -and $r2.Uploaded -eq 0 -and $r2.Skipped -eq $files.Count) "uploaded $($r2.Uploaded) skipped $($r2.Skipped)"
        # Change one file (same size, new content) and drop another: one upload, one removal.
        $chg = Join-Path $stage 'Configs\Git+Tools & More\.gitconfig'
        $bytes = [IO.File]::ReadAllBytes($chg); $bytes[0] = $bytes[0] -bxor 0x55; [IO.File]::WriteAllBytes($chg, $bytes)
        $gone = Join-Path $stage 'AppInventory.html'; $keep = [IO.File]::ReadAllBytes($gone); Remove-Item $gone
        $r3 = Sync-WPCloudUpload $acct $stage $dir
        Check 'change + prune' ($r3.Verified -and $r3.Uploaded -eq 1 -and $r3.Removed -eq 1) "uploaded $($r3.Uploaded) removed $($r3.Removed)"
        [IO.File]::WriteAllBytes($gone, $keep)
        $r4 = Sync-WPCloudUpload $acct $stage $dir
        Check 'restore file' ($r4.Verified -and $r4.Uploaded -eq 1) "uploaded $($r4.Uploaded) problems: $($r4.Problems -join '; ')"
        $found = @(Find-WPCloudBackups $acct)
        Check 'find backups' ($found.Count -eq 1 -and $found[0].Dir -eq $dir) "found $($found.Count): $($found | ForEach-Object Dir)"
        $dl = Join-Path $work "download-$($pv.Id)"
        if (Test-Path $dl) { [IO.Directory]::Delete($dl, $true) }
        $rd = Receive-WPCloudBackup $acct $dir $dl
        $got = Get-Tree $dl
        $same = ($got.Count -eq (Get-Tree $stage).Count) -and -not @((Get-Tree $stage).GetEnumerator() | Where-Object { $got[$_.Key] -ne $_.Value }).Count
        $diff = @((Get-Tree $stage).GetEnumerator() | Where-Object { $got[$_.Key] -ne $_.Value } | ForEach-Object Key) -join ', '
        Check 'download matches byte for byte' ($rd.Complete -and $same) "files $($got.Count) differ: $diff problems $($rd.Problems -join '; ')"
        $rd2 = Receive-WPCloudBackup $acct $dir $dl
        Check 'second download keeps intact files' ($rd2.Downloaded -eq 0 -and $rd2.Kept -eq $files.Count) "downloaded $($rd2.Downloaded)"
        # Damage a remote file: the next upload must notice (checksum providers) and the download must refuse it.
        $ns = @{ webdav = 'dav'; nextcloud = 'nc'; s3 = 's3'; onedrive = 'od'; googledrive = $null; dropbox = 'dbx' }[$pv.Id]
        if ($ns) {
            $mock.Corrupt($ns, "$dir/Installers/7-Zip/7z2501-x64.exe")
            $bad = Join-Path $dl 'Installers\7-Zip\7z2501-x64.exe'; Remove-Item $bad
            $rd3 = Receive-WPCloudBackup $acct $dir $dl
            Check 'corrupt download refused' ((-not $rd3.Complete) -and -not (Test-Path $bad)) "complete=$($rd3.Complete)"
        }
        if ($acct.Provider -in 'onedrive', 'googledrive', 'dropbox') {
            $s = Get-WPCloudSecret $acct; $s.expires = (Get-Date).AddHours(-1).ToString('o'); Set-WPCloudSecret $acct $s; Set-WPCloudAccount $acct
            Check 'token refresh' ((Get-WPCloudToken $acct) -eq 'at-2')
        }
    } catch { Check 'no exception' $false "$_ $($_.ScriptStackTrace)" }
    Get-Job | Remove-Job -Force
}
"--- accounts saved: $(@(Get-WPCloudAccounts).Count); secrets readable as text in file: $([bool]((Get-Content (Get-WPCloudAccountsPath) -Raw) -match 'pw1|app-pw|s3secret|at-1|rt-1'))"
"requests: $($mock.Requests)"
"RESULT: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
$mock.Stop()
