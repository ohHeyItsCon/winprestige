# Changelog

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
