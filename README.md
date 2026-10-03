# Scoop Tray

A zero-dependency PowerShell system tray application that monitors your [Scoop](https://scoop.sh) buckets and installed apps for available updates.

---

## Features

| Capability | Detail |
|---|---|
| **Bucket check** | Fetches remote git refs for every local bucket and detects unpulled commits |
| **App check** | Compares each installed app's version against the latest manifest in its bucket |
| **Colour-coded icon** | Gray = idle, Yellow = bucket(s) behind, Green = up-to-date, Red = app(s) outdated |
| **Balloon notifications** | Pop-up when an update is found after each check |
| **Update Buckets** | Runs `scoop update` (pulls Scoop core + all buckets) in a visible window |
| **Update All Apps** | Runs `scoop update *` in a visible window |
| **Auto-check** | Configurable interval (15 min / 30 min / 1 h / 3 h / 6 h / disabled) |
| **Installed Apps viewer** | ListView showing every app, its installed version, latest version, and status |
| **Open Scoop Directory** | Opens your Scoop folder in Explorer |

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (built into Windows)
- [Scoop](https://scoop.sh) installed (default: `%USERPROFILE%\scoop`, or set `$env:SCOOP`)
- `git` available on `PATH` (needed for fetching remote bucket info — install with `scoop install git`)

---

## Quick start

```powershell
# Run directly (shows no console window thanks to -WindowStyle Hidden)
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File .\ScoopTray.ps1
```

Or double-click **`Start-ScoopTray.vbs`** — it launches the script with no console window.

### Auto-start with Windows

1. Press **Win + R**, type `shell:startup`, press Enter.
2. Copy a shortcut to `Start-ScoopTray.vbs` into that folder.

---

## Files

```
ScoopTray.ps1        ← main script (system tray app)
Start-ScoopTray.vbs  ← windowless launcher (double-click or add to Startup)
README.md
```

---

## Context menu reference

| Item | Action |
|---|---|
| *Last checked: HH:mm:ss* | Status header (non-clickable) |
| ⚠ N outdated app(s) | Expandable list of app → installed → latest |
| ↓ N bucket(s) behind | Expandable list of bucket names |
| **Check for Updates** / *Checking…* | Runs an immediate background check; label changes while running |
| **Update Buckets** / *Updating Buckets…* | `scoop update` — pulls latest manifests; label changes while running |
| **Update All Apps** / *Updating Apps…* | `scoop update *` — updates all apps; label changes while running |
| **Auto-check interval** | Sub-menu to set / disable the periodic check |
| **Open Scoop Directory** | Opens `%USERPROFILE%\scoop` in Explorer |
| **View Installed Apps** | Opens the app-list dialog |
| **Exit** | Removes the tray icon and exits |

---

## How it works

`ScoopTray.ps1` dot-sources the same library files that Scoop itself uses
(`lib/core.ps1`, `lib/buckets.ps1`, `lib/manifest.ps1`, `lib/versions.ps1`) from
your local Scoop installation so version comparisons are byte-for-byte identical
to what `scoop status` would report.

The background check runs in a separate **Runspace** so the UI thread is never
blocked. A lightweight `Timer` polls for completion and marshals the result back
to the UI thread before updating the icon and menu.

Actual update commands are spawned as a **separate process using the same PowerShell
host** that launched ScoopTray (ensuring the correct version and all built-in cmdlets
are available) with a visible console window so you can watch the progress in real
time. Once the process exits, a fresh check is triggered automatically.

While any operation is in progress (check or update) all three action menu items are
disabled and the active item's label changes to show what is running. The tray tooltip
also updates to show the currently running command.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Icon never turns green / always gray | Make sure `git` is on your PATH: `scoop install git` |
| "Scoop installation not found" | Set `$env:SCOOP` to your Scoop root, or check the path in `ScoopTray.ps1` |
| ExecutionPolicy error | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once |
| Buckets never show as behind | Ensure your machine has internet access and git can reach the remote |
