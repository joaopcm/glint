# slice 1 acceptance checklist

tasks 1 to 13 are on `feat/native-video-editor-plan` and every automated suite passes. what's left needs someone at the Mac: real recordings, dragging the bubble, comparing files in QuickTime. none of it ran unattended.

the numbers go in `docs/perf/2026-11-28-render.md`. the two `[TODO: measure ...]` markers in `docs/superpowers/specs/2026-11-28-native-video-editor-design.md` get replaced with them. commit with `docs(recording): record slice 1 measurements`.

## before anything else

- [ ] run the UI tests: `xcodegen generate && xcodebuild -scheme LunettaUI -destination 'platform=macOS' test`. they take over the keyboard and pointer, so they didn't run unattended. `recordsRaw` is on by default now, so any UI test that records goes through raw capture and the render service.
- [ ] `xcodebuild -scheme Lunetta -configuration Release build`, open the app, record 5 s, and check the card goes from "Rendering N%" to a playable MP4. that proves `LunettaRenderService.xpc` launches from the signed app.

## plan task 14

- [ ] side by side (step 1). run `defaults write com.joaopcm.lunetta recordsRaw -bool false` and record a 30 s area session: move the pointer across the area, click 5 times, type `hello world` with Show Pressed Keys on, camera on, drag the bubble once. run `defaults write com.joaopcm.lunetta recordsRaw -bool true` and record the same session again. compare both in QuickTime frame by frame at the clicks and the drag. durations should be within one frame, with rings, keys and bubble at the same times and places. measure the cursor's offset from the ScreenCaptureKit one at 5 frames and put the max in the perf doc.
- [ ] 6K frame timing (step 2, needs the 6K display). record 30 s of full-screen scrolling with `recordsRaw` false, list the frame timestamps (`ffprobe -show_frames` or an AVAssetReader script), and write down the longest gap and the share of 60 fps slots that are missing.
- [ ] raw size per minute (step 3). read the project folders under `~/Library/Application Support/Lunetta/Projects` from the recordings above, and write down MB per minute for screen, camera and events separately, for 6K full screen and for a 1080p area with camera.
- [ ] event recorder CPU (moved here from task 7). during a 60 s area recording, note Lunetta's CPU in Activity Monitor. it's the receipt for logging at display rate, and it goes in the PR description.

## things only a real recording can show

each one came out of a review and none of the tests can reach it.

- [ ] type in a text field without moving the mouse. macOS hides the cursor while you type, and ScreenCaptureKit leaves it out of the filmed file. the log has no "cursor hidden" event, so the raw render probably keeps drawing it. if it does, that needs a follow-up.
- [ ] window recording with Show Clicks on. the stream now runs with the cursor off, and I don't know if macOS still draws its click circles then. if they're gone, raw window recordings lose click feedback.
- [ ] resize the window during a window recording, and once more during a pause. the renderer maps by width only and sizes every part like part 1, so the cursor may land in the wrong place after a resize.
- [ ] pause and resume a few times with clicks. rings should line up within a frame at the start of every part. the log is anchored to the first frame the stream output sees, and `SCRecordingOutput` writes the file, so the two may not start on the same frame.
- [ ] end a recording with about 3 s of only pointer movement over a screen that doesn't change. with the cursor off, a still screen may produce no new frames, which could cut the tail.
- [ ] with the camera on, check the bubble is there from the first frame of every part. the camera output gets added per part, so the camera might start late.
- [ ] compare the rendered MP4's size per minute with the filmed one (the render sets no bitrate), check the audio (mic and system audio now get mixed into one track), and record a saturated color swatch to check color (output is tagged BT.709).

## while you're at it

- [ ] rerun `swift run -c release RenderBenchmark 6016x3384` on AC with the Mac idle. the 6K full-size H.264 case took 405.6 s on battery against the spike's 222.8 s. the memory peak sets the budget, so this only changes the time column.

## questions for you

- a pending project that fails every launch (say its media is gone) gets retried and toasted at every launch, forever, and nothing sweeps it. should it stop retrying after one failed launch, or should unrendered projects also be swept after 30 days?
- a crash mid-recording loses that recording, because `project.json` is only written at stop. orphan folders get swept after 30 days now. should we save the project as each part ends so it can be recovered?
