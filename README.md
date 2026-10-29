# Personal Focus

A small macOS desktop app. It opens on a blue "Work log" folder; click it and today's note slides out. Add tasks, start a stopwatch on one, tick it off, and a Markdown daily log is appended to a folder you choose. It is not a task system: tasks typed here are local context for the log and aren't synced anywhere.

The window is a fixed 340 by 360, transparent around the folder and note, so it can sit on the desktop.

## Run it

Needs macOS 13+ and the Xcode Command Line Tools. No other dependencies.

```bash
cd personal-focus
./build.sh
open "build/Personal Focus.app"
```

Run the tests (all in disposable temp folders; never touches your real log):

```bash
./run-tests.sh
```

The default log folder is `~/Documents/Personal LLM Wiki/Work Log` (the author's Obsidian vault). Change it with the sliders icon on the folder, or edit `defaultLogs` in `Sources/App/main.swift`. The app never creates a missing folder, so if it's missing the entry stays unsaved with a clear error until you choose one.

## Using it

| To | Do |
|---|---|
| Open or close today's note | Click the folder, or the chevron in the note's header |
| Add a task | Type in "New task" at the bottom of the note, press Return |
| Start timing | Press play on a task. Starting another task saves the first session |
| Pause, resume, stop | Buttons on the running task |
| Mark done | Tick the circle, optionally add a note and work type, press Done |
| Log something already finished | "Log a finished task": date, minutes (blank = unknown), note, type |
| Change the log folder | Sliders icon on the folder |
| Move the window | Drag the folder or the note's header |
| Hide the window | Red or yellow button, or Cmd+W. **The timer keeps running** |
| Bring it back | Click the Dock icon or the menu bar item |
| Quit (stops the timer, saves the session) | Cmd+Q |

While a timer runs, the menu bar item shows the elapsed time. Stopping never completes a task. Closed, asleep or crashed time is never counted. "Done today" shows only today's finished tasks and starts empty each day; older days live in the log files.

## What gets written

One file per day, `YYYY-MM-DD.md`, only ever appended to. Each event is a block with a stable `event` id (used to make retries safe), the task id, type (`session`, `completion` or `retrospective`), work date, recorded time with UTC offset, start and end for sessions, active seconds (or `unknown`), time source (`measured`, `estimated`, `unknown`), completion yes/no, and optional work type and note. Multi-line text is written as an indented quote so it can't break the file's structure.

## Where things live

- `Sources/Core/` timer, events, safe appending, recovery (no UI code)
- `Sources/App/main.swift` window, web view, menu bar item and menu
- `ui/index.html` the folder and note UI
- `Tests/main.swift`, `fixtures/` tests and the messy-file fixture
- Recovery state: `~/Library/Application Support/Personal Focus/state.json` (created on first run)

## Test launch options

`--state-dir <dir> --log-dir <dir>` point the app at disposable folders. `--e2e <dir>` runs a scripted walkthrough, saves screenshots to `<dir>`, then quits.
