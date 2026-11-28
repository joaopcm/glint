# Native video editor, slice 1: raw capture and background render (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every recording is captured raw (screen without cursor, camera in its own file, an event log) into a project folder, and a background render produces the same MP4 users get today while the card shows "Rendering".

**Architecture:** LunettaCore gets plain value types for the project, the event log, output sizing, the project store and shared overlay style, so they test on Linux. LunettaCapture gets a cursor-off option and the first frame's host time. A new LunettaStudio package holds the Core Image frame renderer, the AVFoundation composition and the exporter, and an XPC service runs exports out of process. The app records the pieces, writes the project, and hands a `RenderJob` to the card.

**Tech Stack:** Swift 6, AppKit, ScreenCaptureKit, AVFoundation (AVAssetWriter, AVVideoCompositing, AVAssetReader), Core Image on Metal, NSXPCConnection, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-28-native-video-editor-design.md` (read decisions 1 to 15 and the Slices section before starting).

## Global Constraints

- macOS deployment target 15.0; packages use `swift-tools-version: 6.0` and `platforms: [.macOS(.v15)]`.
- No new third-party dependencies.
- LunettaCore must keep building and testing on Linux: no AppKit, AVFoundation, CoreImage or CoreMedia imports there.
- Output cap: any source bigger than 3840x2160 renders scaled to fit inside it, aspect kept, even dimensions; smaller sources keep their size. A setting turns the cap off (spec decision 5).
- Default render = today's look: no background, no zoom, system-size cursor, rings and keys only if they were on, camera following the bubble (decision 4). Window recordings keep macOS click circles and keep refusing Camera and Show Pressed Keys in slice 1.
- Closing a card never cancels its render (decision 6). A failed render shows its reason and offers Try Again. The raw screen file is never copied to the save folder as a fallback.
- Every budget failure names the budget, the limit and the ask.
- Zero code comments except a "why" the code can't carry; move existing comments with the code they explain.
- Commits: conventional style already in the repo (`feat(recording): ...`), no co-author lines.
- The filmed path stays in the code, reachable through the hidden `recordsRaw` default, until slice 2 ships.

## Review Focus

1. Two recordings stopped back to back while the first is still rendering: the second must not take the first one's file name, and both render, in order. Test lands in Task 4 (`reservedOutputFilesIncludeEveryUnrenderedProject`) and Task 8 (`aSecondRecordingDuringARenderGetsItsOwnName`).
2. Lunetta quits mid-render: no half-written MP4 appears in the save folder, and the render runs again at next launch. Tests in Task 10 (`aFailedExportLeavesNothingAtTheOutput`) and Task 12 (`pendingProjectsRenderAgainAtLaunch`).
3. A crash leaves the event log with a torn last line: the reader drops that line and the render still works. Test in Task 3 (`aTornLastLineIsDropped`).
4. A part without camera frames (camera unplugged mid-recording, or paused before the camera started): that part renders without the bubble and the render doesn't fail. Test in Task 9 (`aPartWithoutCameraRendersWithoutTheBubble`).
5. During a window recording, the window moves, or the pointer leaves it: the cursor tracks the window's frame, and it isn't drawn while the pointer is outside the window. Test in Task 9 (`theCursorFollowsAMovingWindowAndHidesOutsideIt`).

---

### Task 1: Shared overlay style in LunettaCore

The renderer must draw rings, keys and the bubble exactly as the on-screen overlays do, and it can't import the app. Move the values into one place both read.

**Files:**
- Create: `Packages/LunettaCore/Sources/LunettaCore/Recording/OverlayStyle.swift`
- Modify: `App/ClickRingOverlay.swift`, `App/KeystrokeOverlay.swift`, `App/CameraBubble.swift`, `App/ThumbnailPanel.swift:23-25`
- Test: `Packages/LunettaCore/Tests/LunettaCoreTests/OverlayStyleTests.swift`

**Interfaces:**
- Produces: `public enum OverlayStyle` with `enterDuration: Double = 0.25`, `exitDuration: Double = 0.2`, `easeOutControlPoints: (Double, Double, Double, Double) = (0.23, 1, 0.32, 1)`, `clickDiameter: Double = 36`, `clickFillAlpha: Double = 0.2`, `clickPulseDuration: Double { enterDuration + exitDuration }`, `clickStartScale: Double = 0.3`, `keysLinger: Double = 1.5`, `keysHeight: Double = 52`, `keysBottomInset: Double = 24`, `keysFontSize: Double = 22`, `keysCornerRadius: Double = 12`, `keysBackgroundAlpha: Double = 0.72`, `keysHorizontalPadding: Double = 28`, `bubbleBorderAlpha: Double = 0.25`, `bubbleBorderWidth: Double = 1`, `cameraMirrored: Bool = true`.

- [ ] **Step 1: Write the failing test** `theClickPulseLastsAThumbnailsEnterAndExit`: `#expect(OverlayStyle.clickPulseDuration == 0.45)`, plus `#expect(OverlayStyle.keysLinger == 1.5)`.
- [ ] **Step 2: Run** `(cd Packages/LunettaCore && swift test --filter OverlayStyleTests)`. Expected: FAIL, `OverlayStyle` not found.
- [ ] **Step 3: Create `OverlayStyle`** with the values above. Move the receipt comments with them (the 238 wpm linger reason from `KeystrokeOverlay`, the "light press" and "dark on any background" reasons stay where their code stays). Point `ThumbnailPresenter.enterDuration`, `exitDuration` and `easeOut`, `ClickRingOverlay.diameter`/`fillAlpha`, `KeystrokeOverlay.linger`/`height`/`bottomInset` and the font, corner, alpha and padding literals, and the bubble border literals at `OverlayStyle`.
- [ ] **Step 4: Run** the LunettaCore tests and `xcodegen generate && xcodebuild -scheme Lunetta -destination 'platform=macOS' test`. Expected: PASS, no behavior change.
- [ ] **Step 5: Commit** `refactor(recording): share overlay style values with LunettaCore`.

### Task 2: Recording project model and output size

**Files:**
- Create: `Packages/LunettaCore/Sources/LunettaCore/Studio/RecordingProject.swift`, `Packages/LunettaCore/Sources/LunettaCore/Studio/RenderSize.swift`
- Modify: `Packages/LunettaCore/Sources/LunettaCore/Recording/RecordingPreflight.swift:3` (add `Codable` to `RecordingMode`), `Packages/LunettaCore/Sources/LunettaCore/Settings/LunettaSettings.swift` (add `Codable` to `VideoCodec` and `RecordingFrameRate`)
- Test: `Packages/LunettaCore/Tests/LunettaCoreTests/RecordingProjectTests.swift`, `.../RenderSizeTests.swift`

**Interfaces:**
- Produces:
  - `public struct PixelSize: Codable, Equatable, Hashable, Sendable { public var width: Int; public var height: Int }`
  - `public struct ProjectPart: Codable, Equatable, Sendable { public var screen: String; public var camera: String?; public var events: String; public var screenStartHostTime: Double; public var cameraStartHostTime: Double? }` (file names relative to the project folder; host times in seconds on the host clock)
  - `public struct ProjectOverlays: Codable, Equatable, Sendable { public var clicks: Bool; public var keys: Bool; public var camera: Bool; public var clickColorHex: String; public var cameraMirrored: Bool }`
  - `public struct ProjectOutput: Codable, Equatable, Sendable { public var file: URL; public var codec: VideoCodec; public var frameRate: RecordingFrameRate; public var capsToUHD: Bool }`
  - `public struct RecordingProject: Codable, Equatable, Sendable { public static let currentSchemaVersion = 1; public var schemaVersion: Int; public var id: UUID; public var createdAt: Date; public var mode: RecordingMode; public var region: CGRect; public var windowID: UInt32?; public var parts: [ProjectPart]; public var overlays: ProjectOverlays; public var output: ProjectOutput; public var renderedAt: Date?; public static func decode(_ data: Data, file: String) throws(ProjectError) -> RecordingProject; public func encoded() throws -> Data }` (`region` in AppKit global points: the area, or the window's frame at start)
  - `public enum ProjectError: LocalizedError, Equatable { case unsupportedVersion(found: Int, supported: Int, file: String); case unreadable(file: String, reason: String) }`
  - `public enum RenderSize { public static let uhd = PixelSize(width: 3840, height: 2160); public static func output(for source: PixelSize, capsToUHD: Bool) -> PixelSize }`

- [ ] **Step 1: Write failing tests**
  - `aProjectSurvivesARoundTrip`: encode then decode a project with two parts (second without camera), `#expect(decoded == project)`.
  - `aNewerSchemaSaysWhichVersionsAreInvolved`: JSON with `"schemaVersion": 2` throws `.unsupportedVersion(found: 2, supported: 1, file: "p.json")`, and its `errorDescription` contains "2", "1" and "p.json".
  - `garbageIsUnreadableAndNamesTheFile`: `Data("nope".utf8)` throws `.unreadable(file: "p.json", reason: _)`.
  - `RenderSize` cases (parameterized): `6016x3384 → 3840x2160`, `1994x1216 → 1994x1216`, `5120x1440 → 3840x1080`, `7680x4320 → 3840x2160`, `4001x2251 → 3838x2158` (fit, then round each side down to even), `6016x3384` with cap off `→ 6016x3384`.
- [ ] **Step 2: Run** `(cd Packages/LunettaCore && swift test --filter "RecordingProjectTests|RenderSizeTests")`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** `decode` reads `schemaVersion` first with a tiny `Decodable` probe so a future version reports `.unsupportedVersion` instead of a key error. `output` scales by `min(1, 3840/w, 2160/h)` and rounds each side down to even.
- [ ] **Step 4: Run** the same command. Expected: PASS. Also `swift test` on Linux CI stays green (no new imports).
- [ ] **Step 5: Commit** `feat(recording): add the recording project model and render size`.

### Task 3: Event log

**Files:**
- Create: `Packages/LunettaCore/Sources/LunettaCore/Studio/CaptureEventLog.swift`
- Test: `Packages/LunettaCore/Tests/LunettaCoreTests/CaptureEventLogTests.swift`

**Interfaces:**
- Produces:
  - `public enum CaptureEvent: Codable, Equatable, Sendable { case pointer(t: Double, x: Double, y: Double); case cursor(t: Double, image: String, hotspotX: Double, hotspotY: Double); case click(t: Double, x: Double, y: Double); case key(t: Double, label: String); case bubble(t: Double, frame: CGRect); case window(t: Double, frame: CGRect) }` (`t` host seconds; points in AppKit global coordinates; `image` is a cursor file name in the project's `cursors/` folder)
  - `public struct CursorShape: Equatable, Sendable { public let image: String; public let hotspot: CGPoint }`
  - `public struct CaptureEventLog: Equatable, Sendable { public init(_ events: [CaptureEvent]); public static func read(jsonLines: Data) -> CaptureEventLog; public func pointer(at t: Double) -> CGPoint?; public func cursor(at t: Double) -> CursorShape?; public func clicks(in range: ClosedRange<Double>) -> [(t: Double, point: CGPoint)]; public func key(at t: Double) -> (label: String, age: Double)?; public func bubbleFrame(at t: Double) -> CGRect?; public func windowFrame(at t: Double) -> CGRect? }`
  - `public final class CaptureEventWriter { public init(file: URL) throws; public func append(_ event: CaptureEvent) throws; public func close() throws }` (one JSON object per line, appended through a `FileHandle`)

- [ ] **Step 1: Write failing tests**
  - `pointerInterpolatesBetweenSamplesAndHoldsAfterTheLast`: samples at t=1 (0,0) and t=2 (10,20); `pointer(at: 1.5) == (5,10)`, `pointer(at: 3) == (10,20)`, `pointer(at: 0.5) == nil`.
  - `cursorBubbleAndWindowHoldTheirLastValue`: step semantics, nil before the first event.
  - `aKeyLingersForOverlayStyleKeysLingerPlusExit`: key at t=1; `key(at: 1.2)?.age == 0.2`; `key(at: 1 + OverlayStyle.keysLinger + OverlayStyle.exitDuration + 0.01) == nil`; a second key at t=1.5 replaces the first.
  - `clicksInARangeAreInclusive`.
  - `writtenLinesReadBack`: write 3 events through `CaptureEventWriter` to a temp file, `read` returns them in order.
  - `aTornLastLineIsDropped` (Review Focus 3): the last line cut mid-object reads as the events before it.
- [ ] **Step 2: Run** `(cd Packages/LunettaCore && swift test --filter CaptureEventLogTests)`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Keep each event kind in its own time-sorted array at init so lookups binary-search. `read` splits on newlines and skips lines that don't decode.
- [ ] **Step 4: Run** it again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): add the capture event log`.

### Task 4: Project store

**Files:**
- Create: `Packages/LunettaCore/Sources/LunettaCore/Studio/ProjectStore.swift`
- Test: `Packages/LunettaCore/Tests/LunettaCoreTests/ProjectStoreTests.swift`

**Interfaces:**
- Consumes: `RecordingProject`, `ProjectError` (Task 2).
- Produces: `public struct ProjectStore: Sendable { public init(root: URL); public func folder(for id: UUID) -> URL; public func create(_ project: RecordingProject) throws -> URL; public func save(_ project: RecordingProject) throws; public func load(_ id: UUID) throws(ProjectError) -> RecordingProject; public func pendingRenders() -> [RecordingProject]; public func reservedOutputFiles() -> Set<URL>; public func delete(_ id: UUID) throws; public func sweep(olderThan cutoff: Date) -> [UUID] }`. Layout: `<root>/<uuid>/project.json`, `part-<n>.screen.mp4`, `part-<n>.camera.mov`, `part-<n>.events.jsonl`, `cursors/<fingerprint>.png`. The app passes `~/Library/Application Support/Lunetta/Projects`.

- [ ] **Step 1: Write failing tests** on a temp root:
  - `aCreatedProjectLoadsBack`.
  - `pendingRendersAreTheUnrenderedOnesOldestFirst`.
  - `reservedOutputFilesIncludeEveryUnrenderedProject` (Review Focus 1).
  - `anUnreadableProjectIsSkippedNotFatal`: a folder with garbage `project.json` doesn't stop `pendingRenders()` from returning the others.
  - `sweepDeletesRenderedProjectsOlderThanTheCutoffAndKeepsUnrenderedOnes`: returns the deleted IDs.
- [ ] **Step 2: Run** `(cd Packages/LunettaCore && swift test --filter ProjectStoreTests)`. Expected: FAIL.
- [ ] **Step 3: Implement** with `FileManager`; `save` writes `project.json` atomically (`.atomic`).
- [ ] **Step 4: Run** it again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): store recording projects on disk`.

### Task 5: Cursor-off capture and the first frame's host time

**Files:**
- Modify: `Packages/LunettaCapture/Sources/LunettaCapture/ScreenRecording.swift`, `App/CaptureCoordinator.swift:95-98` (`ActiveRecording`), `App/SystemAdapters.swift:57`
- Test: `Packages/LunettaCapture/Tests/LunettaCaptureTests/RecordingOptionsTests.swift`

**Interfaces:**
- Produces: `RecordingOptions.capturesCursor: Bool` (init parameter, default `true`); `ScreenRecording.firstFrameHostTime() async -> Double?` (presentation time in seconds of the first complete frame; ScreenCaptureKit stamps samples on the host clock); `ActiveRecording` gains `func firstFrameHostTime() async -> Double?`.

- [ ] **Step 1: Write failing test** `rawRecordingsLeaveTheCursorOut`: `apply(RecordingOptions(codec: .h264, systemAudio: false, microphone: false, capturesCursor: false), to:)` gives `configuration.showsCursor == false`. Update `eachAudioToggleAddsOnlyItsOwnStream` to keep expecting `showsCursor` for the default.
- [ ] **Step 2: Run** `(cd Packages/LunettaCapture && swift test --filter RecordingOptionsTests)`. Expected: FAIL.
- [ ] **Step 3: Implement.** `apply` sets `showsCursor = options.capturesCursor`. `RecordingEvents` stores `CMSampleBufferGetPresentationTimeStamp(sample).seconds` when it sees the first complete frame. `ScreenRecording.firstFrameHostTime()` waits for `waitUntilFirstFrameOrEnd()` and returns it.
- [ ] **Step 4: Run** the package tests and the app tests (the coordinator's `FakeRecording` returns a fixed time). Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): record without the cursor and report the first frame's time`.

### Task 6: Overlays stay out of raw recordings, report what they show, and the camera records to a file

**Files:**
- Modify: `App/CaptureCoordinator.swift:55-80` (protocols), `App/KeystrokeOverlay.swift`, `App/ClickRingOverlay.swift`, `App/CameraBubble.swift`, `App/CaptureChrome.swift`
- Create: `App/Studio/CameraFileWriter.swift`
- Test: `AppTests/CameraFileWriterTests.swift`, existing coordinator fakes in `AppTests/CaptureCoordinatorTests.swift`

**Interfaces:**
- Produces:
  - `KeystrokeShowing.show(over: CGRect, excludedFromCapture: Bool, onKey: @escaping @MainActor (String) -> Void) throws`
  - `ClickShowing.show(over: CGRect, excludedFromCapture: Bool)`
  - `CameraShowing.show(over: CGRect, camera: CameraInput?, excludedFromCapture: Bool, onFrame: @escaping @MainActor (CGRect) -> Void) throws` (`onFrame` fires with the initial frame and on every drag and resize step, not just on mouse up)
  - `CameraShowing.startTake(to url: URL) throws` and `CameraShowing.endTake() async -> CameraTake?` with `struct CameraTake: Sendable { let url: URL; let startHostTime: Double }`
  - `CaptureChrome.mark(_:)` is how `excludedFromCapture` is applied; `CaptureChrome.unmark(_:)` added for when a panel goes.
  - `final class CameraFileWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate { init(url: URL, session: AVCaptureSession) throws; func finish() async -> CameraTake? }`: H.264 at the session's 1280x720 preset, `expectsMediaDataInRealTime = true`, session started at the first buffer, start time converted from `session.synchronizationClock` to the host clock with `CMSyncConvertTime`.

- [ ] **Step 1: Write failing tests**
  - `CameraFileWriterTests.aTakeStartsAtItsFirstBufferOnTheHostClock`: feed the writer three synthetic 1280x720 sample buffers stamped on the host clock (no real camera), finish, then check that the file has one video track of 3 frames and `startHostTime` equals the first buffer's time.
  - `aPanelShownOutOfTheCaptureIsChromeUntilItHides`: `ClickRingOverlay().show(over:excludedFromCapture: true)` puts its panel's window number in `CaptureChrome.windowIDs()`, and `hide()` takes it out. With `false` it never appears there.
  - Coordinator fakes record the `excludedFromCapture` they were shown with, and the existing overlay tests pass `false` (the coordinator test for `true` lands in Task 8).
- [ ] **Step 2: Run** `xcodebuild -scheme Lunetta -destination 'platform=macOS' test -only-testing:LunettaTests/CameraFileWriterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `KeystrokeOverlay.present` calls `onKey` with the label it shows. `CameraBubbleView.mouseDragged` reports frames through `onFrame` too. `CameraSession` gains an `AVCaptureVideoDataOutput` only while a take runs.
- [ ] **Step 4: Run** the full app test suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): keep overlays out of raw recordings and record the camera to a file`.

### Task 7: Event recorder

**Files:**
- Create: `App/Studio/EventRecorder.swift`, `App/Studio/CursorImageStore.swift`
- Test: `AppTests/EventRecorderTests.swift`

**Interfaces:**
- Consumes: `CaptureEvent`, `CaptureEventWriter` (Task 3).
- Produces:
  - `@MainActor final class EventRecorder { init(writer: CaptureEventWriter, cursors: CursorImageStore, windowID: UInt32?, now: @escaping () -> Double = CACurrentMediaTime, pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation }, cursor: @escaping () -> NSCursor? = { NSCursor.currentSystem }, windowFrame: @escaping (UInt32) -> CGRect? = EventRecorder.windowFrame); func start(); func tick(); func logKey(_ label: String); func logBubble(_ frame: CGRect); func stop() throws }`
  - `start()` adds global and local monitors for left, right and other mouse down (no permission needed) and a display link on the main screen (`NSScreen.displayLink(target:selector:)`) that calls `tick()`. `tick()` logs pointer, cursor and window frame only when they changed. `windowFrame` reads `CGWindowListCreateDescriptionFromArray` bounds and converts with `DisplayGeometry.appKitRect(fromTopLeftGlobal:mainDisplayHeight:)`.
  - `final class CursorImageStore { init(folder: URL); func name(for cursor: NSCursor) throws -> String }`: fingerprint = `Hasher` over the 1x `CGImage`'s bytes plus the hotspot, written as `cursors/<fingerprint>.png` once.

- [ ] **Step 1: Write failing tests** with injected closures and a temp writer:
  - `onlyChangesAreLogged`: three ticks with the same pointer log one `.pointer`.
  - `aNewCursorShapeWritesItsImageOnce`: the arrow, then the I-beam, then the arrow give 3 `.cursor` events and 2 PNG files.
  - `windowRecordingsLogTheWindowFrameWhenItMoves`.
  - `theHostClockMatchesScreenCaptureKitsClock`: `abs(CACurrentMediaTime() - CMClockGetTime(CMClockGetHostTimeClock()).seconds) < 0.001`. This is the receipt behind stamping events with `CACurrentMediaTime`.
- [ ] **Step 2: Run** `xcodebuild ... -only-testing:LunettaTests/EventRecorderTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it again. Expected: PASS. Then record a 60 s area recording by hand and note the recorder's CPU in Activity Monitor in the PR description (the receipt for running at display rate).
- [ ] **Step 5: Commit** `feat(recording): log pointer, cursor, clicks and window moves while recording`.

### Task 8: The coordinator records raw into a project

**Files:**
- Modify: `App/CaptureCoordinator.swift` (session, `record`, `resume`, `endSegment`, `finish`, `discardRecording`, `startOverRecording`, `nextFileURL`), `Packages/LunettaCore/Sources/LunettaCore/Settings/LunettaSettings.swift`
- Test: `AppTests/CaptureCoordinatorTests.swift`, `Packages/LunettaCore/Tests/LunettaCoreTests/UserDefaultsStoreTests.swift` (or the settings test file in use)

**Interfaces:**
- Consumes: Tasks 2 to 7.
- Produces:
  - `LunettaSettings.recordsRaw: Bool` (hidden, default `true`) and `LunettaSettings.capsRenderToUHD: Bool` (default `true`).
  - `CaptureCoordinator.init` gains `projects: ProjectStore` and `onRecorded: @MainActor (RecordingProject, _ thumbnail: CGImage?) -> Void`. With `recordsRaw` on, a finished recording calls `onRecorded` instead of `onSaved`. The thumbnail is the first frame of part 1's screen file.
  - Each part writes `part-<n>.screen.mp4`, `part-<n>.camera.mov` (when the camera is on), `part-<n>.events.jsonl`, and its `ProjectPart` host times come from `firstFrameHostTime()` and `CameraTake.startHostTime`.
  - `RecordingOptions.capturesCursor = !settings.recordsRaw`. Window recordings keep `showsClicks` going to macOS, as today.

- [ ] **Step 1: Write failing tests** (new, alongside the existing ones, which run with `recordsRaw = false` so they keep covering the filmed path):
  - `aRawRecordingHandsOverAProjectWithItsParts`: record, pause, resume, stop. `onRecorded` gets a project with 2 parts and output file `Lunetta <date>.mp4` in the save folder, and nothing gets joined.
  - `aRawRecordingRecordsWithoutTheCursor`: the fake recorder saw `capturesCursor == false`.
  - `rawRecordingsShowOverlaysOutOfTheCapture`: the keys, rings and camera fakes were shown with `excludedFromCapture == true`; with `recordsRaw` off they get `false`.
  - `discardingARawRecordingDeletesItsProjectFolder` and `startOverDeletesTheOldProject`.
  - `aSecondRecordingDuringARenderGetsItsOwnName` (Review Focus 1): with a pending project reserving `Lunetta 2026-11-28 at 10.00.00.mp4`, the next recording at the same second gets `... (2).mp4`.
  - `cameraOnRecordsATakePerPart`.
- [ ] **Step 2: Run** `xcodebuild ... -only-testing:LunettaTests/CaptureCoordinatorTests`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** The session owns the project folder and an `EventRecorder` per part. `nextFileURL`'s `exists` also checks `projects.reservedOutputFiles()`. `finish` saves the project with `ProjectStore.save` before calling `onRecorded`, so a crash after stop still leaves a pending render.
- [ ] **Step 4: Run** the full app suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): record raw parts into a project`.

### Task 9: LunettaStudio frame renderer

**Files:**
- Create: `Packages/LunettaStudio/Package.swift`, `Packages/LunettaStudio/Sources/LunettaStudio/StudioFrameRenderer.swift`, `.../CursorImageLibrary.swift`, `.../ProjectTimeline.swift`
- Modify: `project.yml` (package, app dependency, `LunettaStudio/LunettaStudioTests` in the Lunetta scheme's tests)
- Test: `Packages/LunettaStudio/Tests/LunettaStudioTests/StudioFrameRendererTests.swift`, `.../ProjectTimelineTests.swift`

**Interfaces:**
- Consumes: `RecordingProject`, `CaptureEventLog`, `OverlayStyle`, `RenderSize`.
- Produces:
  - `struct ProjectTimeline: Sendable { init(project: RecordingProject, partDurations: [Double]); var duration: Double; func locate(_ t: Double) -> (part: Int, partTime: Double, hostTime: Double) }` (pure, maps composition time to a part and its host time)
  - `final class CursorImageLibrary: Sendable { init(folder: URL); func image(named: String) -> CIImage? }`
  - `final class StudioFrameRenderer: Sendable { init(project: RecordingProject, logs: [CaptureEventLog], cursors: CursorImageLibrary, sourceSize: PixelSize, outputSize: PixelSize); func frame(screen: CIImage, camera: CIImage?, part: Int, hostTime: Double) -> CIImage }`. Mapping: a global point `p` inside frame `F` (the area, or `windowFrame(at:)` for windows) lands at `(p - F.origin) * (sourceSize.width / F.width)` in source pixels, then scales by `outputSize / sourceSize`. Core Image and AppKit both put the origin at the bottom left, so there's no flip.

- [ ] **Step 1: Write failing tests.** Render to a `CGImage` with a CPU `CIContext` and probe pixels, using a solid gray 400x300 screen image, a solid red camera image and a 1-pixel-hotspot black 8x8 cursor PNG.
  - `theCursorLandsAtTheLoggedPointMinusItsHotspot`.
  - `theCameraIsAMirroredCircleWhereTheBubbleIs`: a red-left, blue-right camera image shows blue on the left inside the circle, and the pixels just outside the circle's bounding square corners stay gray.
  - `theCameraFollowsTheBubbleWhenItMoves`: bubble at A at t=1 and at B at t=2. Frames at 1.5 and 2.5 show it at A and B.
  - `aPartWithoutCameraRendersWithoutTheBubble` (Review Focus 4).
  - `keysShowWhileTheyLingerAndAreGoneAfter`: the capsule's dark pixels are present at age 0.5 and absent at age 1.8.
  - `aClickRingPulsesAndFades`: tinted at click+0.05, untinted at click+0.5.
  - `theCursorFollowsAMovingWindowAndHidesOutsideIt` (Review Focus 5).
  - `outputScalesTheWholeFrame`: a 6016x3384 source to 3840x2160 places the cursor at the scaled spot.
  - `ProjectTimelineTests.timeCrossesIntoTheNextPartAtItsBoundary`.
- [ ] **Step 2: Run** `(cd Packages/LunettaStudio && swift test)`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.** Draw rings as a radial disc tinted with `overlays.clickColorHex` at `OverlayStyle.clickFillAlpha`, scaled from `clickStartScale` to 1 and faded with the ease-out curve over `clickPulseDuration`. Draw the keys capsule with Core Text into a cached `CIImage` per label (`keysFontSize` semibold rounded, white, black at `keysBackgroundAlpha`, `keysCornerRadius`, `keysHorizontalPadding`, centered `keysBottomInset` above the region's bottom). Draw the camera aspect-filled into a circle with a `bubbleBorderWidth` white border at `bubbleBorderAlpha`.
- [ ] **Step 4: Run** it again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(studio): render a recording's frame from its raw pieces`.

### Task 10: Composition, compositor and exporter

**Files:**
- Create: `Packages/LunettaStudio/Sources/LunettaStudio/ProjectComposition.swift`, `.../StudioCompositor.swift`, `.../ProjectExporter.swift`, `.../MemoryBudget.swift`
- Test: `Packages/LunettaStudio/Tests/LunettaStudioTests/ProjectExporterTests.swift` (writes its fixtures with `AVAssetWriter` at test time: two 2 s, 30 fps, 320x240 parts with a 1 kHz audio track, a 160x120 camera clip, and logs)

**Interfaces:**
- Consumes: Task 9.
- Produces:
  - `struct ProjectComposition { static func make(project: RecordingProject, folder: URL) async throws -> ProjectComposition; let asset: AVComposition; let videoComposition: AVVideoComposition; let audioMix: AVAudioMix?; let outputSize: PixelSize }`. It lays parts back to back, puts each part's camera at `cameraStartHostTime - screenStartHostTime`, and makes one `StudioInstruction` per part carrying its track IDs.
  - `final class StudioCompositor: NSObject, AVVideoCompositing`: 420v (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) in and out, renders with one Metal `CIContext` into `renderContext.newPixelBuffer()`.
  - `enum ProjectExporter { static func export(_ composition: ProjectComposition, codec: VideoCodec, frameRate: RecordingFrameRate, to url: URL, scratch: URL, budget: MemoryBudget, progress: @Sendable (Double) -> Void) async throws(RenderError) }`. It writes to `scratch` (inside the project folder) and moves to `url` only after `finishWriting` completes. Audio goes through `AVAssetReaderAudioMixOutput` to AAC.
  - `enum RenderError: LocalizedError, Equatable { case missingMedia(file: String); case readerFailed(String); case writerFailed(String); case overMemoryBudget(limitMB: Int, usedMB: Int, output: PixelSize) }`
  - `struct MemoryBudget: Sendable { static let unlimited: MemoryBudget; let limitMB: Int; func check(output: PixelSize, footprintMB: () -> Int = MemoryBudget.currentFootprintMB) throws(RenderError) }` in `Packages/LunettaStudio/Sources/LunettaStudio/MemoryBudget.swift`, checked by the exporter every 30 frames. `currentFootprintMB` reads `task_vm_info.phys_footprint`. Task 11 adds the measured `.render` value.

- [ ] **Step 1: Write failing tests**
  - `overTheBudgetNamesTheBudgetTheLimitAndTheAsk`: `MemoryBudget(limitMB: 100).check(output: .init(width: 3840, height: 2160), footprintMB: { 150 })` throws `.overMemoryBudget(limitMB: 100, usedMB: 150, output: 3840x2160)`, and its message contains "render memory budget", "100 MB", "150 MB" and "3840x2160".
  - `anExportHasBothPartsBackToBackAtTheChosenFrameRate`: duration 4 s ± 1 frame, nominal frame rate 30 (from `frameRate: .thirty`), one audio track.
  - `progressGoesFromZeroToOne`: monotonic, last value 1.
  - `aFailedExportLeavesNothingAtTheOutput` (Review Focus 2): delete part 2's screen file. The export throws `.missingMedia(file: "part-2.screen.mp4")` and nothing exists at `url`.
  - `aFrameFromTheExportShowsTheCursor`: pull a frame at 1 s with `AVAssetImageGenerator` and probe the cursor pixel.
- [ ] **Step 2: Run** `(cd Packages/LunettaStudio && swift test --filter ProjectExporterTests)`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it again. Expected: PASS.
- [ ] **Step 5: Commit** `feat(studio): export a project to MP4`.

### Task 11: Memory budget, measured

**Files:**
- Create: `Packages/LunettaStudio/Sources/RenderBenchmark/main.swift` (executable target), `docs/perf/2026-11-28-render.md`
- Modify: `Packages/LunettaStudio/Sources/LunettaStudio/MemoryBudget.swift`, `Packages/LunettaStudio/Package.swift`
- Test: `Packages/LunettaStudio/Tests/LunettaStudioTests/MemoryBudgetTests.swift`

**Interfaces:**
- Consumes: `MemoryBudget`, `ProjectExporter` (Task 10).
- Produces: `MemoryBudget.render`, the budget every real render uses.

- [ ] **Step 1: Write failing test** `theRenderBudgetIsATripwireAboveTheMeasuredPeak`: `#expect(MemoryBudget.render.limitMB > 0)` and `#expect(MemoryBudget.render.limitMB != MemoryBudget.unlimited.limitMB)`.
- [ ] **Step 2: Run** it. Expected: FAIL, `render` not found.
- [ ] **Step 3: Implement the `RenderBenchmark` executable.** It builds a synthetic 60 s, 60 fps project at a given size (same content generator as the spike in the spec's appendix), exports it at full size and capped to 4K with HEVC and H.264, and prints wall time and peak `phys_footprint`.
- [ ] **Step 4: Measure** on a Mac with a 6K display: `swift run -c release RenderBenchmark 6016x3384` and `... 1920x1080`. Write the table and the machine into `docs/perf/2026-11-28-render.md`. Set `MemoryBudget.render.limitMB` to twice the largest measured peak, and put a one-line receipt comment on it pointing at that doc. If the 6K peak is still above 1 GB, stop and report back before going on: the YUV pipeline didn't fix the spike's memory problem.
- [ ] **Step 5: Run** `(cd Packages/LunettaStudio && swift test)`. Expected: PASS. Commit `feat(studio): measure and enforce the render memory budget`.

### Task 12: Render service, queue and resume

**Files:**
- Create: `RenderService/main.swift`, `RenderService/RenderService.swift`, `RenderService/Info.plist`, `App/Studio/RenderServiceProtocol.swift` (compiled into both targets), `App/Studio/RenderQueue.swift`
- Modify: `project.yml` (an `xpc-service` target `LunettaRenderService` depending on LunettaStudio, embedded in the app, with the app's signing settings), `App/LunettaApp.swift` (wire the store, queue and resume)
- Test: `AppTests/RenderQueueTests.swift`

**Interfaces:**
- Consumes: `ProjectStore` (Task 4), `ProjectExporter`, `MemoryBudget.render` (Tasks 10 and 11), `CaptureCompressor.compress` (existing).
- Produces:
  - `@objc protocol RenderServiceProtocol { func render(projectFolder: URL, reply: @escaping (NSError?) -> Void) }` and `@objc protocol RenderProgressReceiving { func progress(_ fraction: Double) }` (the app exports the second on the connection).
  - `enum RenderPhase: Equatable { case queued, rendering(Double), compressing, done(CompressionResult?), failed(String) }`
  - `@MainActor @Observable final class RenderJob { let project: RecordingProject; private(set) var phase: RenderPhase; func retry(); func finished() async }`
  - `@MainActor final class RenderQueue { init(store: ProjectStore, settings: LunettaSettings, render: @escaping (URL, @escaping @Sendable (Double) -> Void) async throws -> Void = RenderQueue.renderInService, compress: @escaping @Sendable (URL) async throws -> CompressionResult? = CaptureCompressor.compress); func enqueue(_ project: RecordingProject) -> RenderJob; func resumePending() -> [RenderJob] }`. Jobs run one at a time in enqueue order. Success saves `renderedAt` and then compresses if Compress after capture is on. A failure lands in `.failed(message)` with the error's description.

- [ ] **Step 1: Write failing tests** with an injected `render` closure:
  - `jobsRunOneAtATimeInOrder`.
  - `successMarksTheProjectRenderedThenCompressesWhenOn`: the phases go `queued → rendering → compressing → done`, and `renderedAt` is set.
  - `aFailureSaysWhyAndRetryRunsAgain`.
  - `pendingProjectsRenderAgainAtLaunch` (Review Focus 2): a store with one unrendered project gives one job from `resumePending()`.
- [ ] **Step 2: Run** `xcodebuild ... -only-testing:LunettaTests/RenderQueueTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `renderInService` opens an `NSXPCConnection(serviceName: "com.joaopcm.lunetta.render")` per job and invalidates it afterwards, so the service process can exit and give its memory back. The service loads the project, builds the composition and calls `ProjectExporter.export` with `MemoryBudget.render`. At launch, `AppState` calls `resumePending()`, then shows a toast "Rendered <file name>" (or the failure message) when each finishes. It also runs `store.sweep(olderThan:)` with a 30-day cutoff on `renderedAt` (decided with João, see the end of this plan).
- [ ] **Step 4: Run** the full app suite, then `xcodebuild -scheme Lunetta -configuration Release build` and check that `Lunetta.app/Contents/XPCServices/LunettaRenderService.xpc` exists and passes `codesign --verify`. Expected: both pass.
- [ ] **Step 5: Commit** `feat(recording): render recordings in a background service`.

### Task 13: The card waits on the render

**Files:**
- Modify: `App/ThumbnailPanel.swift` (`show`, `finish`, `handle`, `ThumbnailItem`, `ThumbnailView` status capsule and a Try Again control), `App/LunettaApp.swift` (`onRecorded` → `queue.enqueue` → `thumbnail.show`), `App/Settings/CaptureSettingsView.swift` (a "Limit recordings to 4K" toggle bound to `capsRenderToUHD`), `README.md` (features: rendering after stop, the 4K limit)
- Test: `AppTests/ThumbnailCardTests.swift`, `AppTests/ThumbnailUploadTests.swift`

**Interfaces:**
- Consumes: `RenderJob`, `RenderPhase` (Task 12).
- Produces: `ThumbnailPresenter.show(_ url: URL, precomputedThumbnail: CGImage?, render: RenderJob)`. `ThumbnailView.Action.retryRender` (`readsTheFile == false`). `ThumbnailItem.actionsAfterCompression` is renamed `actionsWhenFileIsReady` and is used for both phases.

- [ ] **Step 1: Write failing tests**
  - `aRenderingCardSaysSoWithItsProgress`: phase `.rendering(0.42)` shows "Rendering 42%".
  - `copyWaitsForTheRenderThenRuns`.
  - `closingARenderingCardLeavesTheRenderRunning`: the job still reaches `.done`.
  - `uploadAfterCaptureWaitsForTheRender`.
  - `aFailedRenderShowsWhyAndTryAgainRetries`.
  - `compressionAfterTheRenderShowsCompressingThenTheSummary`.
- [ ] **Step 2: Run** `xcodebuild ... -only-testing:LunettaTests/ThumbnailCardTests -only-testing:LunettaTests/ThumbnailUploadTests`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Observe `job.phase` with `withObservationTracking`, the same way layout settings are observed. Reuse the compression capsule for "Rendering N%". In `.failed`, the capsule reads "Couldn't render" with a Try Again button, and the full message goes through `showError`.
- [ ] **Step 4: Run** the full app suite and `xcodebuild -scheme LunettaUI -destination 'platform=macOS' test` locally. Expected: PASS.
- [ ] **Step 5: Commit** `feat(recording): show the render on the card and wait for it`.

### Task 14: Real-Mac acceptance and the spec's open measurements

**Files:**
- Modify: `docs/perf/2026-11-28-render.md`, `docs/superpowers/specs/2026-11-28-native-video-editor-design.md` (replace the two `[TODO: measure ...]` markers with the numbers and links)

- [ ] **Step 1: Side by side.** With `defaults write com.joaopcm.lunetta recordsRaw -bool false`, record a 30 s scripted area session: pointer moves across the area, clicks 5 times, types "hello world" with Show Pressed Keys on, camera on, the bubble dragged once. Then record it again with `recordsRaw` true. Compare the two in QuickTime frame by frame at the clicks and the drag. Expected: durations within one frame, and rings, keys and bubble at the same times and places. Measure the cursor's offset from ScreenCaptureKit's at 5 frames, and record the max in the perf doc.
- [ ] **Step 2: 6K frame timing** (spec open question 2). Record 30 s of full-screen scrolling on the 6K display with the filmed path, then list the frame timestamps with `ffprobe -show_frames` or an AVAssetReader script. Record the longest gap and the share of 60 fps slots that are missing.
- [ ] **Step 3: Raw size per minute** (spec open question 1). Read the project folder sizes from Steps 1 and 2 and record the MB per minute for screen, camera and events separately.
- [ ] **Step 4:** Fill in the spec's TODO markers from these numbers. Commit `docs(recording): record slice 1 measurements`.

---

## Slices 2 and 3 (outline; planned in detail after slice 1 lands)

**Slice 2, editor shell and trim.** An Edit action on video cards (`ThumbnailView.Action.edit`), Edit on Upload History rows (the history record gains an optional project ID), and Open With Lunetta for `.mp4` (a `CFBundleDocumentTypes` viewer entry plus the MP4's `com.joaopcm.lunetta.project` extended attribute, written by the queue after each render). The editor window lives in LunettaStudio: preview through `AVPlayer` with the same `ProjectComposition`, play and scrub, trim handles that store `trim: ClosedRange<Double>` in the project (schema version 2, with a migration test from version 1), and Save, which re-renders into the same file and uploads again behind the same link. Projects whose raw media is gone open with the cursor and camera sections disabled, with the reason shown (decision 14). Removing the filmed path happens here.

**Slice 3, cuts and speed.** The project gains `clips: [Clip]` (a source range plus a speed), and `ProjectTimeline` maps output time through them. Split at the playhead, delete a clip, change a clip's speed (0.25x to 4x, where audio above 2x is muted, a choice the slice 3 plan needs to confirm), a frame strip from `AVAssetImageGenerator`, a waveform from the audio track, and undo and redo over project snapshots. Pauses arrive as cuts between clips (decision 11).

## Decided with João (2026-11-28)

1. Rendered projects are swept 30 days after they were rendered (`store.sweep(olderThan: now - 30 days)` at launch, Task 12).
2. The "Limit recordings to 4K" toggle goes in Capture settings, next to codec and frame rate (Task 13).
3. Renders resumed after a relaunch get a toast when they finish, not a card (Task 12).
