# Changelog

## Unreleased

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
