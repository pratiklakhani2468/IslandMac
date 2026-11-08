# IslandMac

A small black "island" that floats at the top of your Mac's screen and grows on demand: clock, battery, Music controls, quick-launch apps, file search, a quick terminal, and drag-and-drop file conversion.

![Demo](docs/demo.gif)

> IslandMac is an independent project. It is not affiliated with, endorsed by, or sponsored by Apple Inc. "Dynamic Island", "Mac", "MacBook", "macOS", "Music" and "Finder" are trademarks of Apple Inc.

## Features

### The island

- **Three sizes.** A small pill at rest, a slightly larger pill when the pointer is near, and an expanded panel when you rest the pointer on it (about 0.2 s) or click it. It collapses when the pointer leaves.
- **Pages.** The expanded island opens a Dropped Files shelf, a Calendar, File Search and a Quick Launch editor. The island grows and shrinks to fit each page.
- **Always there.** It sits above the menu bar, on every Space, and never takes keyboard focus unless you open a page that needs typing. There is no Dock icon.
- **Right-click menu:** Settings…, Quick Terminal, Quit.

### What the island shows

- **Clock.** The time in the pill; the full date and your quick-launch apps when expanded. Uses your locale and 12/24-hour setting.
- **Battery** (Macs with an internal battery). A short moment when you plug in, unplug, or the battery finishes charging, with the time to full or remaining once macOS reports it. At 20% or lower on battery the pill turns amber and shows the percentage; at 10% or lower it turns red.
- **Now Playing (Music.app).** Artwork, title, artist, a progress bar, play/pause, previous, next, and seeking, shown in the expanded island while Music has a track loaded. It works with **Music.app only**; other players are not supported.
- **Volume feedback.** When the output volume or mute changes, the island briefly shows a speaker and the level.
- **Quick Launch.** Up to six app icons in the expanded island, ranked by how often you launch them (from Spotlight's use counts, Finder first). You can add, remove and reorder them; your list is saved.
- **Calendar.** A month grid for browsing dates, with a Today button. It does not read your Calendar events.
- **File Search.** Opened with the magnifier button. Type a few words ("budget pdf from documents"); results come from Spotlight and are ranked locally on name, folder and file type. Up and Down choose, Return opens with the default app, Escape closes. It only looks at file names, never contents.

### Quick Terminal

Run short shell commands from the island. Open it with **⌃⌥T** (changeable in Settings) or the right-click menu.

- Commands run in your login shell (`/bin/zsh -l -c`), so `PATH` matches Terminal (Homebrew and so on).
- Output streams in live, with stderr in red and ANSI colours rendered; only the last ~500 lines are kept.
- Shows a green check or a red ✕ with the exit code, and has a Stop button (interrupt, then terminate, then kill).
- `cd` is handled inside the app and the folder carries over to the next command; it starts in your home folder.
- Commands that need a real terminal (`sudo`, `ssh`, `vim`, `top`, a bare `ollama run`, …) aren't run. You get "Needs a full terminal" and an **Open in Terminal** button that opens Terminal.app with the command typed in, ready to run.
- Risky commands (`rm -r`, `sudo`, disk erase, `shutdown`, `curl … | sh`, writing to system folders, and similar) ask for confirmation first, with the risky part highlighted.
- Up and Down step through history (saved locally, 300 commands; **Clear History** is in Settings). Buttons copy or clear the output.
- If a command is still running when you close the island, the pill shows a small spinner, then a brief "Done" or "Failed" when it ends.

### Dropping files

- **Drop zone.** As soon as you start dragging a file anywhere on screen, a drop zone (about 380×150 pt) appears below the island, so you don't have to drag to the very top edge. It grows and brightens as the file gets close, and accepts the drop anywhere inside it. It folds away if you cancel or drop somewhere else.
- **Convert or keep.** Dropping opens the converter (below). **Keep in shelf** puts the file in the Dropped Files shelf instead.
- **Dropped Files shelf.** A list for the current session: open a file, reveal it in Finder, or remove it from the list. The list is in memory only, and IslandMac never moves, renames or deletes the originals.

### Global hotkeys

| Shortcut | Action |
|---|---|
| ⌃⌥T | Open or close Quick Terminal (changeable in Settings) |
| ⌃⌥⌘Q | Quit IslandMac |

## File conversion

Drop a file and the island shows its thumbnail, name and details, and a button for each thing that can really be done to that kind of file. There is nothing to type. A button that needs a setting opens its choices in place (Compress → Light / Medium / Strong, Resolution → 1080p / 720p / 480p). Number keys (1, 2, 3…) press the buttons. Progress is shown in the island, then **Show in Finder** (or Return) when it's done.

| File | Buttons |
|---|---|
| **PDF** | Word, PNG, JPG, Compress |
| **PNG** | JPG, Compress |
| **JPG** | PNG, Compress |
| **HEIC** | JPG, PNG, Compress |
| **Other pictures** (TIFF, BMP, still GIF, …) | PNG, JPG |
| **Video** | MP4 (not shown for MP4 files), GIF, Compress, Remove audio (only if it has sound), Resolution (sizes the video is already at or below are greyed out) |
| **Animated GIF** | MP4, Compress |
| **Audio** | M4A (for M4A files: Compress) |
| **Documents** (Word, ODT, RTF, TXT, Markdown) | PDF |
| **Presentations and sheets** (PPT/PPTX, XLS/XLSX, ODP, ODS, CSV) | PDF, with LibreOffice only |
| **Anything else, and folders** | "This file type isn't supported yet" |

### Details

- **Compress keeps the format.** Compressing never changes the file type; converting only happens when you tap a format button.
  - **PNG** stays PNG. Light is lossless. Medium reduces to a 256-colour palette and Strong to 128 colours (a median-cut quantizer written for this project), then everything is deflated at maximum compression. Transparency is kept.
  - **JPG and HEIC** stay JPG and HEIC, re-encoded at about 90% (Light), 80% (Medium) and 65% (Strong) quality, with metadata kept.
  - **Video** stays MP4 or MOV (re-encoded as H.264 + AAC); Medium also limits it to 1080p and Strong to 720p.
  - **Animated GIF**, **M4A** and **PDF** stay the same format too (PDF compression re-saves images as screen-resolution JPEG and has no levels).
  - If the result isn't at least 5% smaller, no file is saved and the island says "Already well compressed". The result line shows the change, for example `1.8 MB → 420 KB · 77% smaller`.
- **PDF → Word** writes a `.docx` from each page's text, in order, with page breaks. A PDF with no extractable text (a scan) is not converted: the island says "This PDF is scanned. Text can't be extracted." There is no OCR. Each line in the PDF becomes its own line in Word, since PDFs don't record paragraphs.
- **PDF → PNG/JPG** makes one picture for a one-page PDF. For several pages it makes a folder named after the PDF with one image per page.
- **Video → MP4** copies the picture without re-encoding where the format allows (the sound is re-encoded to AAC only when MP4 can't hold it; if the streams can't be copied at all it re-encodes). **Remove audio** copies the picture too. **Resolution** only scales down. **Video → GIF** is limited to about 75 seconds.
- **Documents → PDF** uses macOS's own text system by default (simple layout). If [LibreOffice](https://www.libreoffice.org) is installed (in `/Applications` or `~/Applications`), it is used instead, at much better fidelity and with PowerPoint and Excel support.
- **Output location.** The result is saved next to the original under a free name (`clip.gif`, then `clip 2.gif`; compressed or resized files get a suffix like `photo (compressed).jpg` or `clip (720p).mov`). Originals are never overwritten, and nothing half-written is left behind if you cancel.
- **Offline.** All conversion runs on your Mac using macOS frameworks (AVFoundation, ImageIO, PDFKit, AppKit) and the zlib that ships with macOS. IslandMac contains no networking code and makes no network requests, and there is no AI of any kind. (Commands you type into Quick Terminal can of course use the network if the command does.)
- **Batches.** Dropping several files applies the chosen action to all that support it; the buttons are based on the first file.

## Requirements

- **macOS 14 (Sonoma) or later.** This is the minimum the package and `Info.plist` declare. It has been developed and tested on macOS 27 only; older releases are untested.
- **Xcode 16 or later** (a Swift 6 toolchain) to build it. Everything else is built into macOS; there are no third-party dependencies.
- **Works with or without a notch.** The code doesn't detect or depend on a notch. It draws a floating black panel centred at the top of the main display (the one with the menu bar), above the menu bar, and ignores other displays. Development and testing have been on a 1920×1080 display; how it sits next to a physical notch hasn't been verified.
- A Mac with an internal battery is needed only for the battery features. Now Playing needs Music.app.

## Build and run

```bash
git clone https://github.com/pratiklakhani2468/IslandMac.git
cd IslandMac
scripts/run.sh
```

`scripts/run.sh` builds a release binary, wraps it in `build/IslandMac.app`, signs it, stops any running copy, launches it in the background and prints what is running. Output goes to `build/islandmac.log`.

- It signs with your Apple Development certificate if you have one, and ad-hoc otherwise. With ad-hoc signing macOS may ask for the permissions below again after each rebuild.
- If only the Command Line Tools are selected and they lack SwiftUI's macro plugin, the script builds against the macOS 26 SDK that is also included. Selecting a full Xcode (`xcode-select -s /Applications/Xcode.app`) avoids this.
- `swift build -c release` also works, but it produces a bare executable rather than an app bundle. Use `scripts/run.sh` so the Music permission prompt and the app's Info.plist are in place.
- To quit: right-click the island and choose Quit IslandMac, or press **⌃⌥⌘Q**.
- Developer flags, passed through by the script: `--state resting|hover|expanded` pins the island in one state; `--simulate-drag <seconds>` plays a scripted file drag and logs how responsive the main thread stayed.

### Permissions

IslandMac asks for as little as possible. macOS asks the first time each is needed (the exact prompts are macOS's own):

- **Automation → Music.** To read the current track and send play, pause, skip and seek. Asked once, when Music is running.
- **Files & Folders (Desktop, Documents, Downloads).** When you open File Search, and macOS may ask again when you convert a file that lives in one of those folders (the result is saved next to it).
- **Automation → Terminal.** Only if you use Quick Terminal's **Open in Terminal**. If you decline, the command is copied to your clipboard instead.

It does not ask for Accessibility, Calendar, Contacts, Location, Camera, Microphone or Screen Recording. It is not sandboxed, because Quick Terminal runs shell commands.

## Project structure

```
Package.swift                  Swift package (macOS 14, links the system zlib)
scripts/run.sh                 Build, bundle, sign and launch the app
Sources/CZlib/                 Module map exposing macOS's zlib to Swift
Sources/IslandMac/
  main.swift                   Entry point (menu-bar-less accessory app, quit hotkey)
  IslandController.swift       The floating panel: pointer tracking, drag detection, hotkeys, menu
  IslandState.swift            The island's states and the activity shown at home
  IslandGeometry.swift         All sizes, shapes, layout constants and animations
  IslandView.swift, HomeLayer.swift   SwiftUI content for each state and the home layout
  IdleClockView.swift, BatteryViews.swift, PowerSource.swift   Clock, battery and charging
  NowPlaying.swift, MediaPlayerView.swift, EqualizerView.swift Music.app integration and player
  SystemVolume.swift, VolumeFeedbackView.swift                 Volume feedback
  QuickLaunchApps.swift, QuickLaunchView.swift, QuickLaunchEditView.swift   App launcher
  CalendarPageView.swift       Month grid
  FileSearch.swift, SearchPageView.swift     Spotlight-based file search
  QuickTerminal.swift, QuickTerminalPageView.swift   Terminal page, history, confirmations
  ShellCommand.swift           Reads a command to find `cd`, interactive and risky ones
  ShellProcess.swift           Runs the login shell; streams output; ANSI decoding
  DropTargetView.swift         The drop zone and the drop confirmation
  DroppedFiles.swift, DroppedFilesView.swift   The session shelf
  Converter.swift, ConvertPageView.swift       Converter state and its panel
  ConversionActions.swift      Which buttons each file type gets, and what each does
  ConversionEngines.swift      Video, audio, GIF, image, PDF and document conversion
  PNGCompressor.swift          PNG quantizer and writer
  GlobalHotKeys.swift          System-wide hotkeys
  AppSettings.swift, SettingsWindow.swift   Settings
```

## License

MIT. See [LICENSE](LICENSE).
