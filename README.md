# DiskChrona

A macOS menu bar app that continuously records file size changes on your disk, so you can answer "what ate my disk space, and when?"

- The menu bar shows the net file size change per minute in real time; open it for the recent trend and the fastest-growing files
- **Overview**: free volume space over time, space changes stacked by location, growth hotspots, and locations being written right now
- **Ranking**: files or directories, measured by file size or allocated space, sorted by total growth or net change
- **Raw log**: every detected change, plus the full change history of any single file
- Monitors the whole disk; exclude high-churn directories such as caches, and optionally ignore system swap files
- Periods when the app was quit or paused show as gray gaps in the charts; changes made during a gap are recorded at the time they are detected after monitoring resumes
- "Copy AI analysis prompt" generates a prompt for a local AI agent to analyze the recorded database read-only

DiskChrona is built on FSEvents and only `lstat`s files. It **never reads file contents**, and all data stays on your Mac.

## Install

Requirements: macOS 15 or later, Apple Silicon (arm64).

1. Download `DiskChrona-<version>.dmg` from [Releases](../../releases)
2. Open the dmg and drag `DiskChrona.app` into Applications
3. First launch: the app is ad-hoc signed and not notarized, so macOS blocks it. Go to System Settings → Privacy & Security and click "Open Anyway", or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/DiskChrona.app
   ```

4. (Recommended) Allow DiskChrona under System Settings → Privacy & Security → Full Disk Access. Without it, changes in protected locations such as Mail and Messages are not counted. The app's Settings tab has a button that opens this pane.

DiskChrona lives in the menu bar only, with no Dock icon. Open the full window from the menu bar panel. Closing the window keeps monitoring in the background; launch at login can be turned on in Settings.

## Data

- Database: `~/Library/Application Support/DiskChrona/DiskChrona.sqlite` (SQLite, WAL mode)
- History is kept for 30 days with a 500 MiB size budget by default; the oldest records are trimmed when over budget. Both are adjustable in Settings
- Clearing history in Settings deletes all recorded changes; the monitored files themselves are never touched

## Build from source

Requires the Xcode 16 / Swift 6 toolchain.

```sh
./build-app.sh          # release build: build/DiskChrona.app and build/DiskChrona-<version>.dmg
./run.sh                # debug build and relaunch, for development
swift test              # run tests
```

The version number is `VERSION` in `build-app.sh`.
