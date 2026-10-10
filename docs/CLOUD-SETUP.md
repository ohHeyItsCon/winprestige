# Cloud sign-in setup

WinPrestige signs in to OneDrive, Google Drive and Dropbox with each provider's standard browser sign-in (OAuth 2 authorization code with PKCE). The browser shows the provider's own page, WinPrestige catches the answer on `http://localhost` / `http://127.0.0.1`, and it never sees the user's password.

Each provider needs to know which app is asking, so WinPrestige ships with an app registration ID for each. These IDs are public identifiers, not secrets; every desktop app that uses these APIs embeds them. They go in [`data/cloud-apps.json`](../data/cloud-apps.json):

```json
{
  "onedrive":    { "clientId": "", "redirect": "http://localhost" },
  "googledrive": { "clientId": "", "clientSecret": "", "redirect": "http://127.0.0.1" },
  "dropbox":     { "appKey": "", "redirect": "http://127.0.0.1:47615/" }
}
```

While an ID is empty, the sign-in button says this copy isn't registered with that provider yet, and the other destinations (folders, synced folders, Nextcloud, WebDAV, S3) still work.

To try your own registration without editing the repo, put a copy of the file at `%LOCALAPPDATA%\WinPrestige\cloud-apps.json`; values there override the shipped ones.

Nextcloud, WebDAV and S3 need no registration.

## OneDrive (Microsoft Entra)

You need a Microsoft Entra tenant. A free Azure account creates one ("Default Directory").

1. Open the [Microsoft Entra admin center](https://entra.microsoft.com) > **Applications** > **App registrations** > **New registration**.
2. Name: `WinPrestige`.
3. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts**.
4. Redirect URI: platform **Public client/native (mobile & desktop)**, value `http://localhost`. Entra accepts any port on localhost for this platform, which is what WinPrestige uses.
5. Press **Register** and copy the **Application (client) ID** into `onedrive.clientId`.
6. **API permissions** > **Add a permission** > **Microsoft Graph** > **Delegated**: add `Files.ReadWrite.AppFolder` and `User.Read` (`offline_access` is requested at sign-in). None of these need admin consent.

WinPrestige only asks for its app folder (`Apps > WinPrestige` in the user's OneDrive), not the whole drive.

Work and school accounts: many organisations only allow consent to apps from a verified publisher. Personal Microsoft accounts are unaffected. [Publisher verification](https://learn.microsoft.com/entra/identity-platform/publisher-verification-overview) removes that limit.

## Google Drive (Google Cloud)

1. In the [Google Cloud console](https://console.cloud.google.com), create a project called `WinPrestige`.
2. **APIs & Services** > **Library**: enable the **Google Drive API**.
3. **Google Auth Platform** (OAuth consent screen): audience **External**, app name `WinPrestige`, your support email. Under **Data access**, add the scope `https://www.googleapis.com/auth/drive.file` ("See, edit, create and delete only the specific Google Drive files you use with this app"). It's a non-sensitive scope, so it doesn't need Google's security review.
4. **Clients** (Credentials) > **Create client** > application type **Desktop app**. Copy the **Client ID** and **Client secret** into `googledrive.clientId` and `googledrive.clientSecret`. Google documents that a desktop app's client secret isn't treated as confidential.
5. While the app is in **Testing**, only the test users you add can sign in, and their sign-in expires after 7 days. Press **Publish app** to move it to production for everyone.

With `drive.file`, WinPrestige can only see the files and folders it created. The backup goes to a `WinPrestige Backup` folder in My Drive.

## Dropbox (App Console)

1. In the [Dropbox App Console](https://www.dropbox.com/developers/apps), press **Create app**: **Scoped access**, **App folder**, name `WinPrestige`. The name has to be unique on Dropbox, and it becomes the folder name (`Apps > WinPrestige`).
2. **Permissions**: tick `files.metadata.read`, `files.content.read` and `files.content.write`, then **Submit**.
3. **Settings** > **OAuth 2**: add the redirect URI `http://127.0.0.1:47615/`, and set **Allow public clients (Implicit Grant & PKCE)** to **Allow**.
4. Copy the **App key** into `dropbox.appKey`. No app secret is needed with PKCE.
5. A new app is in development status and works for up to 50 users. Apply for production on the same page when you release.

If port 47615 is taken on a PC, sign-in can't receive the answer. To use another port, register it in step 3 and change `dropbox.redirect` to match.

## Testing

`tests\cloud\Test-CloudDestinations.ps1` runs every provider against a local mock (no accounts needed): sign-in, upload, verification, re-runs, pruning, download and damaged-file detection. It checks WinPrestige's side of each protocol; after registering, also try a real backup and a **Load from a cloud account** on each service.
