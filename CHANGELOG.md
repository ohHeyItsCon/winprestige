# Changelog

## 1.3.0 (pre-release)

Not tested on a freshly reset PC yet: the Start and taskbar restore and the Steam queue in particular. Cloud sign-in is in beta.

- **Restore app settings only.** A new button on the Restore screen puts back the ticked app settings (and the Start and taskbar layout) without installing anything. Use it after installing the manual apps yourself, instead of running the whole restore again.
- **Open apps when it's done.** A restore option, plus an **Open installed apps** button, opens every ticked app that's installed, one after another and not as administrator, so you can sign in to them in one go.
- **Steam games go straight into Steam's download queue.** Steam's install window only lets you pick a drive for one game at a time, and it was replaced as soon as the next game arrived. Now WinPrestige closes Steam, adds back the library folders that are still on your drives (so games that survived the reset show up as installed), and queues every other ticked game in its old library. Games that were on the system drive go into a library you pick. Steam then opens on its Downloads page.
- **Vendor installers over the Microsoft Store.** For apps that came from the Store, WinPrestige now looks for the vendor's own installer in winget (same name, same publisher) and saves that instead, so the app comes back offline and without a Microsoft account. The Store is still used if that installer fails, and **Use the Store instead** in the details panel keeps an app on the Store. Older backups get the same check at restore time (**Vendor installer first**). The Store itself can't be downloaded from: winget only allows that for work or school admin accounts.
- **Start menu and taskbar.** A new extra saves the pinned apps and folders on Start and the pinned taskbar apps. It's restored last, after the apps, and only pins apps that are installed by then, in the same order; the rest are left off rather than showing as blank icons. The layout that was there before is saved in `%LOCALAPPDATA%\WinPrestige\undo\startlayout`.
- **Cloud sign-in is marked beta.** OneDrive, Google Drive and Dropbox show "(beta)" and suggest keeping a second copy of the backup. Sign-in now logs each step (browser answer received, sign-in accepted, folder reachable) and checks the folder can be opened straight away, so a missing permission shows up at sign-in instead of halfway through a backup. Errors name the setting to change for the usual registration mistakes (Dropbox permissions or PKCE, Entra redirect platform, Google test users). The Dropbox setup doc now gives the same redirect address as `cloud-apps.json`.
- **Zipped backups.** Windows' own Extract stops at paths over 260 characters, which deep settings folders often have. Load a `.zip` with the new **Zip** button or by dragging it onto the window: WinPrestige unzips it itself, long paths included, into a short folder (`WPRestore`) on a local drive. **Make a .zip copy** on the Ready to reset card zips a backup the same way.

- **Cloud accounts as a destination.** The Backup screen's destination is now a list: a drive, USB or NAS folder; a synced folder on this PC; or a cloud account. OneDrive, Google Drive and Dropbox sign in through the browser (OAuth with PKCE; WinPrestige only gets its own app folder). For home servers there's Nextcloud (browser sign-in with an app password), any WebDAV server (ownCloud, Synology, QNAP, Seafile, pCloud, Koofr and others) and any S3-compatible storage (MinIO, Garage, Backblaze B2, Wasabi, Cloudflare R2, AWS S3). Self-signed certificates can be trusted after you check them. Tokens and passwords are stored encrypted for your Windows account.
- **Uploaded and verified.** A cloud backup is built on this PC, uploaded (big installers in chunks, each retried if the connection drops), and then checked file by file against the sizes and checksums the server reports. The Ready to reset card only says verified when everything matches. Later backups upload only what changed and remove what's gone. A checksum list saved with the backup lets a restore detect any file that changed in the cloud since.
- **Load from a cloud account** on the Restore screen: sign in, pick a backup from the list (each PC has its own folder), and WinPrestige downloads it, checks every file and loads it. Interrupted downloads pick up where they stopped.
- **App settings follow their app.** Ticking an app on the Apps tab ticks its settings on the App settings tab, and unticking it unticks them. You can still untick settings on their own; ticking an app's settings adds the app to the backup. Private data and settings over 1 GB still start unticked, and entries that don't belong to one app (SSH keys, VST plugins, folders you added) are chosen on their own.
- Fixed: Elgato Wave Link 3.3 failed to restore on a fresh PC ("depends on a framework that could not be found"). winget's manifest lists Windows App Runtime 1.8, but the package needs 2.x. Backups now read the frameworks an MSIX package itself asks for and save those. A restore that still hits a missing framework installs it (from the backup, or winget when it's available) and tries again; if it can't, it says to run the backup again.
- When an app didn't install, the log line for its settings says so, so "settings restored" isn't mistaken for the app being installed.
- **Queue ticked games in Steam** opens one game at a time. Steam replaces its install window when the next game arrives, so the button turns into "Next game: ..." and waits until you've clicked Install.
- The log explains a cloud sign-in that can't start because the app isn't registered with that provider, instead of showing an internal code.
- `tools\Test-RestoreInSandbox.ps1` works without `-BackupPath`, to rehearse loading a backup from a cloud account inside Windows Sandbox.
- Synced-folder detection also finds iCloud Drive, Nextcloud and ownCloud desktop, Box, Synology Drive, Proton Drive, MEGA, pCloud Drive and Seafile folders.
- Fixed: "I've checked it's online" for a synced folder wasn't remembered after closing WinPrestige.
- `docs/CLOUD-SETUP.md` explains the OneDrive, Google Drive and Dropbox app registrations; `tests/cloud` tests every provider against a local mock.
- **Synced folders as a destination.** OneDrive, Google Drive for desktop and Dropbox folders are detected and offered next to NAS shares and drives. WinPrestige writes to them like any folder and says plainly that it can't see whether the upload has finished: after the backup it asks you to check the folder on the web or another device, remembers when you confirm, and explains how to get the backup back after the reset. Backups in synced folders are also found automatically after a reset.
- **Ready to reset.** After a backup, a summary shows saved installers, online installs, manual actions, app settings, extras and problems (such as installer files missing from the backup), checked against the files in the folder. It's saved as `Ready to reset.html` in the backup.
- **Restore check.** After installing, WinPrestige checks what Windows actually lists. Apps whose installer exited cleanly but that Windows doesn't list are reported as not found instead of installed. The summary and a restore report show installed, already installed, manual and failed apps, and settings in place or to check.
- **Safe reruns and settings undo.** App settings that already match the backup are left alone on a repeat restore. Before replacing settings, WinPrestige saves what was there; **Revert** on the Restore screen (or `Restore-Config.ps1 -Revert`) puts it back.
- **App lists.** **Export app list...** saves the ticked apps (names and install sources only) to set up another PC; load the file on the Restore screen.

- **App icons.** The scan finds each app's real icon (from its uninstall entry, its Start Menu shortcut, its exe, or its Store package logo) and shows it on the Apps, App settings and Restore screens, with the coloured monogram as a fallback. Icons are cached and saved into the backup, so a freshly reset PC sees them on the Restore screen before anything is installed. Demo mode borrows icons from this PC when the same app is installed.
- Elgato Wave Link 3 settings are now backed up. Wave Link 3 installs as a Windows package and keeps your mixes and mic filter chains in `AppData\Local\Packages\Elgato.WaveLink_...\LocalState`; only the old Wave Link folder was saved before.
- New **VST audio plugins** entry backs up `Common Files\VST3`, `VST2`, `CLAP` and the usual `VSTPlugins` folders and puts them back, so Wave Link filters, OBS and Voicemod find their plugins (ReaPlugs, Voxengo SPAN, Elgato's own filters and others that have no installer to save).
- Installers winget can't download while WinPrestige runs as administrator (MSIX packages such as Wave Link 3 and Elgato Studio failed with "Access is denied") are now fetched from the same official URL in winget's manifest and kept only if the SHA-256 matches. Their package dependencies, such as Windows App Runtime and VCLibs, are saved too.
- Restore installs packages shipped as a zip of MSIX files (how winget delivers VCLibs), and treats "a newer version is already installed" as done.

## 1.2.1

- Fixed: app settings that include registry keys (7-Zip, Elgato Stream Deck, PuTTY and others) showed as failed after restoring, and their user-folder path fixes were skipped. The settings themselves were copied; `reg.exe` reports success on its error output, which the restore script mistook for a failure.
- Background services are paused while their app's settings are copied back, then started again: FanControl, NZXT CAM, Logitech G HUB, Elgato Wave Link, SteelSeries GG and Corsair iCUE. This stops them from relaunching the app or writing over the restored files mid-copy.
- Every restored settings file is checked afterwards: it has to exist with the same size as in the backup, and saved registry keys have to exist. The Restore screen shows "checked and in place", or a yellow "Check ..." note naming the first file that didn't land.
- WinPrestige restores settings with its own, newest restore script, so backups made with older versions get these fixes too (including the background services, which older backups didn't record).
- Running `Restore-Config.cmd` on its own keeps the administrator window open at the end so you can read the result.
- `tools\Test-RestoreInSandbox.ps1` tries a restore inside Windows Sandbox, a throwaway copy of Windows, without touching your PC.
- Adobe presets: the note now points to Photoshop's Migrate Presets for newer versions.

## 1.2.0

- Faster batch restore: shared runtimes first, then simple silent installers three at a time, then winget, Store and interactive installs, and MSI-based installers one by one at the end. Installers that clash get retried on their own. A new **Install several at once** switch turns this off.
- A fresh copy of WinPrestige finds backups on other drives, USB drives, mapped network shares, and Desktop, Documents and Downloads, and offers **Restore everything** or **Review first**. First-time users without a backup get a **Find my backup...** prompt.
- Restores survive restarts: progress is saved after every app, WinPrestige reopens after sign-in, and **Continue restore** picks up with what's left.
- Recent and found backups appear as one-click chips on the Restore screen.
- Drag a backup folder onto the window to load it. This works even though WinPrestige runs as administrator, which normally blocks drag-and-drop from Explorer. On the App settings step, dropped folders and files are added to the backup.

## 1.1.0

- New logo and app icon.
- Redesigned interface: navy theme with the logo's teal-to-lilac colours, a Back up / Restore switch, numbered backup steps with a Next button, monogram tiles for every app, one checkbox per group (with a partial state), and summary cards with progress bars.
- The HTML report matches the new look.
- Animations: sliding toggle switches and Back up / Restore switch, checkboxes that pop in, growing step underline, button hover and press effects, loading circles while scanning, downloading and installing, smooth progress bars with a shimmer while the total isn't known, and page fade-ins.

## 1.0.1

- Settings folders over 1 GB now start unticked as intended. Before, they were ticked when their size was already known.
- Demo mode (`WinPrestige.exe -Demo`): a made-up PC for screenshots and videos. Nothing on your PC is read or changed.
- README screenshots.
- Wording fix in restore messages.

## 1.0.0

First release.

- Scans installed programs from the registry, winget and the Microsoft Store, and sorts them into apps, launchers, Store apps, drivers, runtimes, bundled components, games and Windows built-ins.
- Skips games but keeps launchers, including games that install their own launcher (VALORANT, League of Legends).
- Finds official installers through winget, with a publisher check so copycat Store listings aren't picked.
- Saves the latest installers to any folder or NAS share, and only re-downloads when there's a newer version.
- Backs up settings for about 50 apps (OBS, FanControl, Stream Deck, iCUE, G HUB, SteelSeries GG and more), plus custom folders.
- Extras: fonts, environment variables, Wi-Fi profiles, drivers and user folders.
- Restores everything silently, falls back to winget online when a saved installer fails, and fixes paths if your user folder changes.
- HTML and CSV report of every app and where to get it.
