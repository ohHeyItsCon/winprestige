# Changelog

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
