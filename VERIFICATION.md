# Personal Focus: verification report

Built 2026-10-28. Native Swift app (Swift 5.10, Command Line Tools only) with a transparent web view for the UI. No third-party dependencies.

## Result

- **88 of 88 logic tests pass** (`./run-tests.sh`, full output in `build/test-output.txt`).
- **Scripted UI walkthrough passed** in the real app against disposable folders. It ran 8 times; the first run had an unexplained anomaly (see the known gaps) and the 7 later runs all gave identical results.
- **Nothing was written to your live log or live recovery file.** Confirmed afterwards: the recovery folder `~/Library/Application Support/Personal Focus/` does not exist, and your `Work Log/` folder (created by you afterwards) is empty.

## Changes from the brief, per your direction

- The 25-minute Pomodoro and 5-minute break are gone. Starting a task runs a stopwatch with pause, resume and stop. Because there is no expiry, the brief's "expiry boundary" checks no longer apply.
- Typewriter UI on a transparent background replaces the original design; there is no cat.

## Acceptance checks

| Brief check | Result |
|---|---|
| 60s run, 120s pause, 30s run, stop = 90s, incomplete; stopped and suspended time add nothing | Pass. UI snapshot shows 90 before stop; log shows 90, `complete: no`. An hour asleep adds 0. |
| Stop never completes; second session on same task; completion later adds 0 s; completing while running logs once; double-click harmless | Pass |
| Retrospective: 12 min = 720 estimated; blank = unknown; 0 stays 0; invalid rejected with no append | Pass. Rejected: `-5`, `abc`, `1e3`, `12 min`, `NaN`, `1441`, `--3`, impossible and future dates, unknown work type, empty text. Also confirmed in the real UI (typing `abc` shows the error and adds no event). |
| Six-feature walkthrough | Pass in both the logic tests and the real app. Sample: `sample-output/app-walkthrough-2026-10-28.md` |
| Safe appends on a file with unrelated text and special characters | Pass. Original bytes unchanged; every event id exactly once; a note containing `# heading` and a forged `- event:` line stays inside a quote; 80 concurrent appends all present once. |
| Retry after an ambiguous failure (written, but reported failed) | Pass. Retry does not duplicate. |
| External change | Pass. Text appended outside the app is fine. Editing earlier text, or a change during the save itself, appends nothing, keeps the entry pending, and leaves your edit intact; pressing Retry then saves. |
| Failure and recovery | Pass. Missing folder, unwritable folder and an interrupted save all keep the entry pending with a visible error; retry saves exactly once. A save that can't be read back is not reported as saved. Pending entries survive a restart and keep the same id. |
| Restart and suspend | Pass. Crash recovery returns the timer paused at the last checkpoint and says up to N minutes since then may be missing. Clean quit restores the exact seconds with no warning. An hour of downtime counts as zero. Checkpoints are written at most every 5 seconds (12 writes in 62 s). |
| Midnight and dates | Pass. A 23:50 session that ends at 00:20 is filed under its start date. Offsets are -05:00 before and -06:00 after the 1 Nov DST change. |

## Known gaps and honest limits

- **Real sleep and wake were not tested.** Sleep is simulated by calling the same handler the app uses for macOS's sleep notification. The timer also uses a clock that does not advance during sleep, which is a second safeguard.
- **One unexplained early run.** My very first scripted run logged a 1-second session instead of about 4. I couldn't reproduce it in the 7 later runs (all logged 4 seconds) and didn't find the cause. I think it was my test script's timing, but I haven't proven that.
- **Not tested by automation:** dragging the window by the typewriter, resizing the borderless window by its edges, the folder chooser dialog, and the Cmd+Q path with a real running timer. Try these by hand.
- **No delete.** A task typed by mistake can only leave the page by being crossed off, which logs it. Say if you want a discard button that logs nothing.
- **No bell sound**, only a "ding" text flash.
- **No close button.** Quit with Cmd+Q.
- **Unsigned.** The app is ad-hoc signed for local use only; no installer, notarization or launch at login, as the brief says.
- **The live folder is untested.** `Work Log/` exists and is writable, but no real entry has been saved there yet.
- **Additions I made that the brief didn't specify:** minutes are capped at 1440; a finished-task date can't be in the future; tasks are limited to 200 characters; if the recovery file is unreadable it is kept aside as `state.unreadable-*.json` rather than deleted.

## Not done, awaiting your authorization

A smoke test against your live log folder. The brief requires your explicit OK for that write.

## Files

The two folders below are kept on the author's machine and are not part of the public repo.

- `screenshots/`: walkthrough screenshots. The `.on-desktop.png` versions sit the transparent window on a plain backdrop so it is easier to see.
- `sample-output/`: `engine-test-2026-10-28.md` from the logic tests and `app-walkthrough-2026-10-28.md` from the real app.
