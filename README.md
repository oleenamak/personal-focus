# Personal Focus

A small macOS desktop app: type a task on a red typewriter, start a stopwatch, cross it off, and a Markdown daily log is appended to a folder you choose. It is not a task system: tasks typed here are local context for the log and aren't synced anywhere.

## Run it

Needs macOS 13+ and the Xcode Command Line Tools (already installed). No other dependencies.

```bash
cd personal-focus
./build.sh
open "build/Personal Focus.app"
```

Run the tests (all in disposable temp folders; never touches your real log):

```bash
./run-tests.sh
```

The default log folder is `~/Documents/Personal LLM Wiki/Work Log` (the author's Obsidian vault; change it by clicking the folder name on the paper, or edit `defaultLogs` in `Sources/App/main.swift`). The app never creates a missing folder, so if it's ever missing the entry stays unsaved with a clear error until you click the folder name at the top right of the paper and choose one. Nothing has been written to that folder by the build or the tests.

## Using it

| To | Do |
|---|---|
| Add a task | Type on the paper's last line, press Return |
| Start timing | Press the play button on a task (one at a time) |
| Pause, resume, stop | Buttons in the strip on the paper while a task is running |
| Mark done | Tick the box, optionally add a note and work type, press Cross off |
| Log something already finished | "Log a finished task": date, minutes (blank = unknown), note, type |
| Change the log folder | Click the folder name on the paper |
| Move the window | Drag the typewriter body |
| Quit | Cmd+Q |

Stopping never completes a task. Closed, asleep or crashed time is never counted.

## What gets written

One file per day, `YYYY-MM-DD.md`, only ever appended to. See `sample-output/` for real output. Each event is a block with a stable `event` id (used to make retries safe), the task id, type (`session`, `completion` or `retrospective`), work date, recorded time with UTC offset, start and end for sessions, active seconds (or `unknown`), time source (`measured`, `estimated`, `unknown`), completion yes/no, and optional work type and note. Multi-line text is written as an indented quote so it can't break the file's structure.

## Where things live

- `Sources/Core/` timer, events, safe appending, recovery (no UI code)
- `Sources/App/main.swift` window and web view
- `ui/index.html` the typewriter UI
- `Tests/main.swift`, `fixtures/` tests and the messy-file fixture
- Recovery state: `~/Library/Application Support/Personal Focus/state.json` (created on first run)

## Test launch options

`--state-dir <dir> --log-dir <dir>` point the app at disposable folders. `--e2e <dir>` runs a scripted walkthrough, saves screenshots to `<dir>`, then quits.
