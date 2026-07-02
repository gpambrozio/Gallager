# E2E Video Recording (One-Take) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `./scripts/e2e-test.sh --record` records every scenario as one full-display video with burned-in step captions and a real-elapsed timecode, compresses dead time via ffmpeg, publishes the video content-addressed through `e2e-report.sh`, and lets the ClaudeSpyTestResults viewer play it with clickable step-seek chapters. (GitHub issue #621.)

**Architecture:** A `ScreenRecorder` actor (ScreenCaptureKit `SCStream` + `SCRecordingOutput`, macOS 15) is driven by a `RecordingCoordinator` that implements the existing `TestProgressReporter` protocol — recording starts on `scenarioStarted` and stops on `scenarioCompleted` (which the orchestrator fires on success *and* failure), so no orchestrator surgery is needed for capture. Step offsets are written to `timeline.json`. A stage-layout pass in the orchestrator translates instance-1 window moves and absolute-coordinate clicks into a second screen "lane" (moves only, never resizes) and pins the Simulator window top-right so all actors are visible in one take. A stdlib-only Python script post-processes each raw take with ffmpeg: burn labels first on the 1× timeline, then speed up / remove static spans, then emit `video.mp4` + `video.json` with seek chapters remapped through the edit list. `e2e-report.sh`'s inline Python is extracted to `scripts/e2e_report_build.py`, gains a content-addressed `store_artifact()`, and embeds a `video` field per scenario in `report.json`. The viewer (separate `ClaudeSpyTestResults` repo) renders a `<video>` with chapter buttons.

**Tech Stack:** Swift 6.3 / Swift Testing, ScreenCaptureKit (macOS 15), AVFoundation (test only), Python 3 stdlib + `unittest`, ffmpeg/ffprobe (brew), bash, vanilla-JS single-file viewer.

## Global Constraints

- Recording is **strictly opt-in** via `--record`; with the flag absent there must be **zero behavior change** (no stage layout, no reporters added, no new dependencies exercised).
- **Moves only, never resizes** any window — screenshot baselines depend on window size, not position.
- Package platform floor is `.macOS(.v15)` (already set in `ClaudeSpyPackage/Package.swift:519`) — `SCRecordingOutput` requires exactly macOS 15.0+.
- Swift tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), never XCTest. Python tests use stdlib `unittest`, runnable as `python3 <file>`.
- Swift concurrency only — actors for I/O, no GCD. All cross-boundary types `Sendable`.
- Python scripts are **stdlib only** (no pip installs).
- ffmpeg + ffprobe are required **only on machines that pass `--record`** (`brew install ffmpeg`); e2e-test.sh gates on them when the flag is set.
- Artifact names per scenario dir (fixed contract across tasks): `recording-raw.mov` (raw take), `timeline.json` (step offsets), `video.mp4` (published), `video.json` (published metadata). Intermediates `steps.ass`, `labeled.mov`, `retime-graph.txt` are deleted by the post-processor.
- A repo `PostToolUse` hook runs swiftformat on edited Swift files — don't fight its output.
- Commit style: short imperative subject, optionally `e2e:`-prefixed (matches `git log`), ending with the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

**Scope note:** Task 7 edits `index.html` in the **separate** `gpambrozio/ClaudeSpyTestResults` repository (cloned as a sibling of the main worktree — the same location `scripts/e2e-report.sh:17` computes). Everything else is in this repo. Tasks 1–4 are pure/unit-testable; Task 5 is the integration point that needs a GUI session with Accessibility + Screen Recording grants.

---

### Task 1: StageLayout geometry model

Pure geometry for window "lanes" — no AX/CG calls, fully unit-testable. Instance 0 keeps the canonical `(10, 10)` origin every scenario already uses (`Shortcut.openPanesWindow`, `ScenarioShortcuts.swift:39`). Instance N gets a side-by-side lane when the display is wide enough, else a staggered diagonal clamped on-screen.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/StageLayout.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/StageLayoutTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `StageLayout` struct with `init(display: CGSize)`, `laneOrigin(instance: Int, windowSize: CGSize) -> CGPoint`, `translation(instance: Int, windowSize: CGSize) -> CGVector`. Task 5 constructs it from `CGDisplayBounds(CGMainDisplayID()).size` and applies `translation(instance:)` to step coordinates.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/StageLayoutTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import ClaudeSpyE2ELib

@Suite("StageLayout")
struct StageLayoutTests {
    @Test("Instance 0 keeps the canonical origin")
    func instanceZero() {
        let layout = StageLayout(display: CGSize(width: 1_920, height: 1_080))
        #expect(layout.laneOrigin(instance: 0) == CGPoint(x: 10, y: 10))
        #expect(layout.translation(instance: 0) == .zero)
    }

    @Test("Wide display gives a full side-by-side lane to instance 1")
    func sideBySide() {
        let layout = StageLayout(display: CGSize(width: 2_600, height: 1_400))
        #expect(layout.laneOrigin(instance: 1) == CGPoint(x: 1_030, y: 10))
        #expect(layout.translation(instance: 1) == CGVector(dx: 1_020, dy: 0))
    }

    @Test("Narrow display staggers instance 1 diagonally, still fully on-screen")
    func staggered() {
        let layout = StageLayout(display: CGSize(width: 1_920, height: 1_080))
        let origin = layout.laneOrigin(instance: 1)
        // Not the canonical origin (that would fully occlude instance 0)...
        #expect(origin.x > 200)
        #expect(origin.y > 200)
        // ...and the 1000x600 window still fits on the display with margin.
        #expect(origin.x + 1_000 <= 1_920 - 10 + 0.5)
        #expect(origin.y + 600 <= 1_080 - 10 + 0.5)
    }

    @Test("Tiny display clamps to the margin instead of going off-screen")
    func tinyDisplayClamps() {
        let layout = StageLayout(display: CGSize(width: 1_024, height: 640))
        let origin = layout.laneOrigin(instance: 1)
        #expect(origin.x >= 10)
        #expect(origin.y >= 10)
        #expect(origin.x + 1_000 <= 1_024)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter StageLayoutTests`
Expected: FAIL to compile — `cannot find 'StageLayout' in scope`.

- [ ] **Step 3: Implement StageLayout**

Create `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/StageLayout.swift`:

```swift
import CoreGraphics
import Foundation

/// Computes best-effort non-overlapping screen positions ("lanes") for the
/// windows visible in a recorded scenario, so a single full-display take
/// shows every mac instance with minimal occlusion (issue #621).
///
/// Pure geometry — no AX or CoreGraphics window calls — so it is unit-testable.
/// Coordinates are top-left-origin screen points, matching what
/// `macMoveWindow` / AX `kAXPositionAttribute` expect.
public struct StageLayout: Sendable {
    /// The display being recorded, in points.
    public let display: CGSize

    /// The window size scenarios standardize on (`Shortcut.openPanesWindow`).
    public static let defaultWindowSize = CGSize(width: 1_000, height: 600)
    /// The origin scenarios standardize on for instance 0.
    public static let defaultOrigin = CGPoint(x: 10, y: 10)
    /// Margin kept from display edges.
    static let margin: CGFloat = 10
    /// Horizontal gap between side-by-side lanes.
    static let gap: CGFloat = 20

    public init(display: CGSize) {
        self.display = display
    }

    /// Top-left origin for the given instance's window lane.
    ///
    /// Instance 0 keeps the canonical (10, 10) so its baselines and popover
    /// geometry are untouched. Instance N prefers a full side-by-side lane to
    /// the right; on displays too narrow for that it falls back to a
    /// staggered diagonal offset clamped fully on-screen — occlusion is
    /// minimized, not eliminated.
    public func laneOrigin(
        instance: Int,
        windowSize: CGSize = StageLayout.defaultWindowSize
    ) -> CGPoint {
        guard instance > 0 else { return Self.defaultOrigin }
        let n = CGFloat(instance)

        let sideBySideX = Self.defaultOrigin.x + n * (windowSize.width + Self.gap)
        if sideBySideX + windowSize.width + Self.margin <= display.width {
            return CGPoint(x: sideBySideX, y: Self.defaultOrigin.y)
        }

        let x = min(
            display.width - windowSize.width - Self.margin,
            Self.defaultOrigin.x + n * display.width * 0.42
        )
        let y = min(
            display.height - windowSize.height - Self.margin,
            Self.defaultOrigin.y + n * display.height * 0.42
        )
        return CGPoint(x: max(x, Self.margin), y: max(y, Self.margin))
    }

    /// Translation applied to a scenario's absolute coordinates (window
    /// moves, CG clicks, drags) for the given instance. Zero for instance 0,
    /// so unrecorded geometry is bit-identical.
    public func translation(
        instance: Int,
        windowSize: CGSize = StageLayout.defaultWindowSize
    ) -> CGVector {
        let origin = laneOrigin(instance: instance, windowSize: windowSize)
        return CGVector(
            dx: origin.x - Self.defaultOrigin.x,
            dy: origin.y - Self.defaultOrigin.y
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter StageLayoutTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/StageLayout.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/StageLayoutTests.swift
git commit -m "e2e: StageLayout lane geometry for recorded runs (#621)"
```

---

### Task 2: ScreenRecorder (ScreenCaptureKit one-take capture)

An actor recording the main display to H.264 `.mov` at ≤15 fps, 1× point resolution (mirrors the `sips` DPI normalization screenshots already do — `MacOSDriver.swift:908`). Behind a `ScreenRecording` protocol so Task 3's coordinator is testable with a fake.

The real recorder needs Screen Recording TCC permission and a GUI session, which unit-test runners may lack — so its test is env-gated and run manually (the e2e machinery already gates the same permission in `scripts/e2e-test.sh:277`).

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Utilities/ScreenRecorder.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/ScreenRecorderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol ScreenRecording: Sendable { func start(outputURL: URL) async throws; func stop() async }` and `actor ScreenRecorder: ScreenRecording`. Task 3 injects `any ScreenRecording`; Task 5 constructs the real `ScreenRecorder()`.

- [ ] **Step 1: Write the (gated) failing test**

Create `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/ScreenRecorderTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import ClaudeSpyE2ELib

@Suite("ScreenRecorder integration")
struct ScreenRecorderTests {
    /// Requires a GUI session + Screen Recording permission for the test
    /// runner, so it only runs when explicitly requested:
    ///   E2E_RECORDING_TESTS=1 swift test --package-path ClaudeSpyPackage \
    ///     --filter ScreenRecorderTests
    @Test(
        "Records the main display to a playable movie",
        .enabled(if: ProcessInfo.processInfo.environment["E2E_RECORDING_TESTS"] == "1")
    )
    func recordsMainDisplay() async throws {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory() + "recorder-test-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ScreenRecorder()
        try await recorder.start(outputURL: url)
        try await Task.sleep(for: .seconds(2))
        await recorder.stop()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.size] as? Int ?? 0) > 10_000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 1.0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `E2E_RECORDING_TESTS=1 swift test --package-path ClaudeSpyPackage --filter ScreenRecorderTests`
Expected: FAIL to compile — `cannot find 'ScreenRecorder' in scope`.

- [ ] **Step 3: Implement ScreenRecorder**

Create `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Utilities/ScreenRecorder.swift`:

```swift
import CoreGraphics
import CoreMedia
import Foundation
import Logging
@preconcurrency import ScreenCaptureKit

/// Abstraction over screen recording so `RecordingCoordinator` can be unit
/// tested with a fake recorder.
public protocol ScreenRecording: Sendable {
    /// Start recording the main display to the given file URL.
    func start(outputURL: URL) async throws
    /// Stop capturing and finalize the recording file. Safe to call when not
    /// recording (no-op).
    func stop() async
}

/// Records the main display to an H.264 `.mov` via ScreenCaptureKit
/// (`SCStream` + `SCRecordingOutput`, macOS 15+).
///
/// Frame rate is capped at 15 fps and the stream is configured at 1x point
/// resolution (not retina pixels) — the take feeds an ffmpeg post-processing
/// pass, so capture favors small files over fidelity. This mirrors the sips
/// DPI normalization the screenshot path applies.
public actor ScreenRecorder: ScreenRecording {
    public enum RecordingError: Error {
        case noDisplay
        case alreadyRecording
    }

    private let logger = Logger(label: "e2e.screen-recorder")
    private var stream: SCStream?
    /// Retained because SCStream/SCRecordingOutput hold their delegate weakly.
    private var delegateBox: RecorderDelegate?

    public init() {}

    public func start(outputURL: URL) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else {
            throw RecordingError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // SCDisplay width/height are points — capturing at that size records
        // 1x instead of retina pixels.
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.showsCursor = true
        config.queueDepth = 6

        let delegate = RecorderDelegate(logger: logger)
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)

        let recordConfig = SCRecordingOutputConfiguration()
        recordConfig.outputURL = outputURL
        recordConfig.outputFileType = .mov
        recordConfig.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordConfig, delegate: delegate)

        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        delegateBox = delegate
        logger.info("Recording started → \(outputURL.path)")
    }

    public func stop() async {
        guard let stream else { return }
        do {
            // Stopping capture finalizes the SCRecordingOutput file.
            try await stream.stopCapture()
        } catch {
            logger.warning("stopCapture failed (file may still be finalized): \(error)")
        }
        self.stream = nil
        delegateBox = nil
        logger.info("Recording stopped")
    }
}

private final class RecorderDelegate: NSObject, SCStreamDelegate, SCRecordingOutputDelegate,
    @unchecked Sendable {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("SCStream stopped with error: \(error)")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        logger.error("SCRecordingOutput failed: \(error)")
    }
}
```

- [ ] **Step 4: Verify build + run the gated test from a permissioned terminal**

Run: `swift build --package-path ClaudeSpyPackage --target ClaudeSpyE2ELib`
Expected: builds clean.

Then, from a local terminal that has Screen Recording permission (same grant e2e-test.sh checks):

Run: `E2E_RECORDING_TESTS=1 swift test --package-path ClaudeSpyPackage --filter ScreenRecorderTests`
Expected: PASS. Also verify without the env var: `swift test --package-path ClaudeSpyPackage --filter ScreenRecorderTests` → test is SKIPPED (so CI unit-test runs never need the permission).

If the test fails with a TCC/permission error rather than an assertion: the invoking terminal lacks Screen Recording — grant it in System Settings › Privacy & Security › Screen & System Audio Recording and re-run. Do not weaken the assertions.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Utilities/ScreenRecorder.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/ScreenRecorderTests.swift
git commit -m "e2e: ScreenCaptureKit one-take ScreenRecorder (#621)"
```

---

### Task 3: ScenarioTimeline + RecordingCoordinator reporter

The reporter that owns the per-scenario recording lifecycle and the step timeline. It plugs into the existing `TestProgressReporter` fan-out (`CompositeReporter`) — recording starts on `scenarioStarted`, steps are timestamped on `stepStarted`/`stepCompleted`/`stepFailed`, and the take is stopped + `timeline.json` written on `scenarioCompleted`, which `TestOrchestrator.run` calls on **both** the success path (`TestOrchestrator.swift:274`) and the fatal-failure path (`TestOrchestrator.swift:252`) — that's what makes finalization reliable on failure.

Post-processing is injected as a closure so tests don't need ffmpeg; the production closure (built in this task, wired in Task 5) runs the Task 4 script via `nice` in a detached utility task, and `printSummary` awaits all encodes so the process doesn't exit with ffmpeg mid-flight.

Also refactors the orchestrator's private `sanitizeForPath` into `static func scenarioDirName(for:)` so the coordinator derives the identical per-scenario directory.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/ScenarioTimeline.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/RecordingCoordinator.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift:137` and `:1620-1625` (sanitizeForPath → static scenarioDirName)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/RecordingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ScreenRecording` (Task 2), `TestProgressReporter` / `TestOrchestrator.ScenarioResult` (existing).
- Produces:
  - `struct ScenarioTimeline: Codable, Sendable` — fields `scenarioName: String`, `recordingStartedAt: Date`, `testStartOffset: Double?`, `steps: [Step]` (`Step`: `stepNumber: Int`, `description: String`, `start: Double`, `end: Double?`, `status: String`), `failedStep: Int?`, `duration: Double?`. JSON encoded with `.iso8601` dates — Task 4's script reads exactly these keys.
  - `actor RecordingCoordinator: TestProgressReporter` with `init(screenshotsDir: String, recorder: any ScreenRecording, postProcessor: PostProcessor?)` where `typealias PostProcessor = @Sendable (URL, URL) async -> Void` (args: raw take URL, timeline URL).
  - `static func makeFFmpegPostProcessor(mode: String, keepRaw: Bool) -> PostProcessor`.
  - `TestOrchestrator.scenarioDirName(for name: String) -> String` (static, internal).

- [ ] **Step 1: Write the failing tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/RecordingCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeSpyE2ELib

/// Fake recorder that tracks calls and creates the output file.
actor FakeRecorder: ScreenRecording {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private var failOnStart = false

    func setFailOnStart() { failOnStart = true }

    func start(outputURL: URL) async throws {
        if failOnStart { throw ScreenRecorder.RecordingError.noDisplay }
        startedURLs.append(outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("fake".utf8))
    }

    func stop() async { stopCount += 1 }
}

/// Collects post-processor invocations across concurrency boundaries.
actor PostProcessCalls {
    private(set) var calls: [(raw: URL, timeline: URL)] = []
    func record(raw: URL, timeline: URL) { calls.append((raw, timeline)) }
}

@Suite("RecordingCoordinator")
struct RecordingCoordinatorTests {
    private func result(name: String, failedStep: Int? = nil) -> TestOrchestrator.ScenarioResult {
        TestOrchestrator.ScenarioResult(
            scenarioName: name,
            success: failedStep == nil,
            failedStep: failedStep,
            error: nil,
            duration: 1,
            steps: []
        )
    }

    @Test("Scenario dir name matches the orchestrator's sanitizer")
    func scenarioDirName() {
        #expect(TestOrchestrator.scenarioDirName(for: "Two Mac Pairing") == "two-mac-pairing")
        #expect(TestOrchestrator.scenarioDirName(for: "OTEL: Usage (Overview)!") == "otel-usage-overview")
    }

    @Test("Writes timeline.json with per-step offsets, stops recorder, invokes post-processor")
    func fullLifecycle() async throws {
        let dir = NSTemporaryDirectory() + "rc-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let recorder = FakeRecorder()
        let calls = PostProcessCalls()

        let coordinator = RecordingCoordinator(
            screenshotsDir: dir,
            recorder: recorder,
            postProcessor: { raw, timeline in await calls.record(raw: raw, timeline: timeline) }
        )

        await coordinator.scenarioStarted("Video Demo", totalSteps: 2)
        await coordinator.stepStarted(1, totalSteps: 2, description: "first step")
        await coordinator.stepCompleted(1, screenshot: nil)
        await coordinator.stepStarted(2, totalSteps: 2, description: "second step")
        await coordinator.stepFailed(2, error: "boom", screenshot: nil, failureScreenshots: [])
        await coordinator.scenarioCompleted(result(name: "Video Demo", failedStep: 2))
        await coordinator.printSummary([])

        let timelineURL = URL(fileURLWithPath: "\(dir)/video-demo/timeline.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let timeline = try decoder.decode(
            ScenarioTimeline.self,
            from: Data(contentsOf: timelineURL)
        )

        #expect(timeline.scenarioName == "Video Demo")
        #expect(timeline.testStartOffset != nil)
        #expect(timeline.duration != nil)
        #expect(timeline.failedStep == 2)
        #expect(timeline.steps.count == 2)
        #expect(timeline.steps[0].status == "passed")
        #expect(timeline.steps[1].status == "failed")
        #expect(timeline.steps.allSatisfy { $0.end != nil && $0.end! >= $0.start })

        #expect(await recorder.stopCount == 1)
        let recorded = await calls.calls
        #expect(recorded.count == 1)
        #expect(recorded[0].raw.lastPathComponent == "recording-raw.mov")
        #expect(recorded[0].timeline.lastPathComponent == "timeline.json")
    }

    @Test("Recorder start failure degrades gracefully — no timeline, no post-processing, no crash")
    func startFailure() async throws {
        let dir = NSTemporaryDirectory() + "rc-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let recorder = FakeRecorder()
        await recorder.setFailOnStart()
        let calls = PostProcessCalls()

        let coordinator = RecordingCoordinator(
            screenshotsDir: dir,
            recorder: recorder,
            postProcessor: { raw, timeline in await calls.record(raw: raw, timeline: timeline) }
        )

        await coordinator.scenarioStarted("Video Demo", totalSteps: 1)
        await coordinator.stepStarted(1, totalSteps: 1, description: "only step")
        await coordinator.stepCompleted(1, screenshot: nil)
        await coordinator.scenarioCompleted(result(name: "Video Demo"))
        await coordinator.printSummary([])

        let timelinePath = "\(dir)/video-demo/timeline.json"
        #expect(!FileManager.default.fileExists(atPath: timelinePath))
        #expect(await recorder.stopCount == 0)
        #expect(await calls.calls.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter RecordingCoordinatorTests`
Expected: FAIL to compile — `cannot find 'RecordingCoordinator'`, `'ScenarioTimeline'`, and `type 'TestOrchestrator' has no member 'scenarioDirName'`.

- [ ] **Step 3: Refactor sanitizeForPath into a static scenarioDirName**

In `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift`, replace (around line 1620):

```swift
    /// Convert a scenario name into a safe directory name
    private func sanitizeForPath(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
```

with:

```swift
    /// Convert a scenario name into a safe directory name. Static so
    /// `RecordingCoordinator` (and the report pipeline) can derive the same
    /// per-scenario directory the orchestrator writes screenshots into.
    static func scenarioDirName(for name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
```

and update the single call site (line 137):

```swift
        let scenarioDirName = Self.scenarioDirName(for: scenario.name)
```

- [ ] **Step 4: Implement ScenarioTimeline**

Create `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/ScenarioTimeline.swift`:

```swift
import Foundation

/// Per-scenario step timing relative to the start of the screen recording.
///
/// Written as `timeline.json` next to the raw take by `RecordingCoordinator`
/// and consumed by `e2e_video_postprocess.py` (step caption windows, the
/// timecode's recording→test-start offset, and seek chapters).
public struct ScenarioTimeline: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public let stepNumber: Int
        public let description: String
        /// Seconds from recording start to when the step began.
        public var start: Double
        /// Seconds from recording start to when the step finished.
        /// `nil` only while the step is still running.
        public var end: Double?
        /// "passed" | "failed"
        public var status: String
    }

    public let scenarioName: String
    /// Wall-clock time the recording started (ISO8601) for log correlation.
    public let recordingStartedAt: Date
    /// Seconds from recording start to the scenario's first step — the
    /// recording→test-start delta the burned-in timecode subtracts.
    public var testStartOffset: Double?
    public var steps: [Step]
    public var failedStep: Int?
    /// Total recorded duration in seconds, set when recording stops.
    public var duration: Double?
}
```

- [ ] **Step 5: Implement RecordingCoordinator**

Create `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/RecordingCoordinator.swift`:

```swift
import Foundation
import Logging

/// A `TestProgressReporter` that records each scenario as a full-display
/// video and writes a `timeline.json` of per-step offsets, then hands the
/// finished take to an ffmpeg post-processing pass (issue #621).
///
/// Capture starts on `scenarioStarted` and is stopped/finalized on
/// `scenarioCompleted` — which the orchestrator calls on success AND on
/// fatal failure — so the take is finalized reliably either way.
///
/// Recording failures are deliberately non-fatal: a scenario without video
/// still runs and reports normally (best-effort, never perturbs tests).
public actor RecordingCoordinator: TestProgressReporter {
    /// Post-processes a finished take. Injected so tests can stub it; the
    /// production value runs `e2e_video_postprocess.py` — see
    /// `makeFFmpegPostProcessor`. Arguments: (rawTakeURL, timelineURL).
    public typealias PostProcessor = @Sendable (URL, URL) async -> Void

    private let logger = Logger(label: "e2e.recording")
    private let screenshotsDir: String
    private let recorder: any ScreenRecording
    private let postProcessor: PostProcessor?
    private let clock = ContinuousClock()

    private var recordingStart: ContinuousClock.Instant?
    private var timeline: ScenarioTimeline?
    private var currentScenarioDir: String?
    /// Encodes run concurrently with subsequent scenarios (off the hot path,
    /// at low priority); `printSummary` awaits them all before the process exits.
    private var postProcessingTasks: [Task<Void, Never>] = []

    public init(
        screenshotsDir: String,
        recorder: any ScreenRecording,
        postProcessor: PostProcessor?
    ) {
        self.screenshotsDir = screenshotsDir
        self.recorder = recorder
        self.postProcessor = postProcessor
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        let dir = "\(screenshotsDir)/\(TestOrchestrator.scenarioDirName(for: name))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rawURL = URL(fileURLWithPath: "\(dir)/recording-raw.mov")
        try? FileManager.default.removeItem(at: rawURL)

        do {
            try await recorder.start(outputURL: rawURL)
        } catch {
            logger.error("Could not start recording for '\(name)': \(error) — scenario runs unrecorded")
            return
        }
        recordingStart = clock.now
        currentScenarioDir = dir
        timeline = ScenarioTimeline(
            scenarioName: name,
            recordingStartedAt: Date(),
            testStartOffset: nil,
            steps: [],
            failedStep: nil,
            duration: nil
        )
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        guard timeline != nil, let start = recordingStart else { return }
        let offset = elapsed(since: start)
        if timeline?.testStartOffset == nil {
            timeline?.testStartOffset = offset
        }
        timeline?.steps.append(ScenarioTimeline.Step(
            stepNumber: stepNumber,
            description: description,
            start: offset,
            end: nil,
            status: "passed"
        ))
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        closeCurrentStep(status: "passed")
    }

    public func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async {
        closeCurrentStep(status: "failed")
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        guard var timeline, let start = recordingStart, let dir = currentScenarioDir else { return }
        self.timeline = nil
        recordingStart = nil
        currentScenarioDir = nil

        await recorder.stop()
        timeline.duration = elapsed(since: start)
        timeline.failedStep = result.failedStep

        let rawURL = URL(fileURLWithPath: "\(dir)/recording-raw.mov")
        let timelineURL = URL(fileURLWithPath: "\(dir)/timeline.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(timeline).write(to: timelineURL)
        } catch {
            logger.error("Could not write timeline.json for '\(result.scenarioName)': \(error)")
            return
        }

        if let postProcessor {
            let task = Task.detached(priority: .utility) {
                await postProcessor(rawURL, timelineURL)
            }
            postProcessingTasks.append(task)
        }
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        guard !postProcessingTasks.isEmpty else { return }
        logger.info("Waiting for \(postProcessingTasks.count) video encode(s) to finish…")
        for task in postProcessingTasks {
            await task.value
        }
        postProcessingTasks.removeAll()
    }

    // MARK: - Production post-processor

    /// Builds the production post-processor: runs the bundled
    /// `e2e_video_postprocess.py` under `nice` so encodes never compete with
    /// the scenario that's already running. On any failure the raw take and
    /// timeline are left in place and the error is logged.
    public static func makeFFmpegPostProcessor(mode: String, keepRaw: Bool) -> PostProcessor {
        { rawURL, timelineURL in
            let logger = Logger(label: "e2e.video-postprocess")
            guard
                let script = Bundle.module.url(
                    forResource: "e2e_video_postprocess",
                    withExtension: "py",
                    subdirectory: "Scripts"
                )
            else {
                logger.error("e2e_video_postprocess.py not found in bundle — raw take kept")
                return
            }
            var args = [
                "-n", "10", "python3", script.path,
                "--raw", rawURL.path,
                "--timeline", timelineURL.path,
                "--mode", mode,
            ]
            if keepRaw {
                args.append("--keep-raw")
            }
            do {
                let runner = ProcessRunner()
                let result = try await runner.runOrThrow("/usr/bin/nice", arguments: args)
                let summary = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("Post-processed \(rawURL.deletingLastPathComponent().lastPathComponent): \(summary)")
            } catch {
                logger.error("Video post-processing failed for \(rawURL.path): \(error) — raw take kept")
            }
        }
    }

    // MARK: - Helpers

    private func closeCurrentStep(status: String) {
        guard timeline != nil, let start = recordingStart, timeline?.steps.isEmpty == false else { return }
        let offset = elapsed(since: start)
        let lastIndex = timeline!.steps.count - 1
        timeline?.steps[lastIndex].end = offset
        timeline?.steps[lastIndex].status = status
    }

    private func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = clock.now - start
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
```

Note: `ProcessRunner` is the existing actor in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Utilities/ProcessRunner.swift` (same `runOrThrow(_:arguments:)` the orchestrator uses). If its init or method labels differ, match the existing call sites, e.g. `TestOrchestrator.swift:854`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter RecordingCoordinatorTests`
Expected: PASS (3 tests).

Also run the full E2E-lib unit suite to catch the sanitizeForPath refactor:

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyE2ETests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/ScenarioTimeline.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/RecordingCoordinator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyE2ETests/RecordingCoordinatorTests.swift
git commit -m "e2e: RecordingCoordinator reporter + per-step timeline.json (#621)"
```

---

### Task 4: ffmpeg post-processing script

Stdlib-only Python that turns `recording-raw.mov` + `timeline.json` into `video.mp4` + `video.json`:

1. `freezedetect` finds static spans > 0.5 s (small noise tolerance for cursor blink/AA).
2. **Labels burn first, on the 1× timeline** — an ASS subtitle ribbon ("Step 14/31 — …") from the timeline, plus a `drawtext` timecode showing real elapsed time since test start (`%{pts:hms:OFFSET}` with OFFSET = −testStartOffset) — so both labels stay truthful through retimed spans.
3. Retiming: per-segment `trim` + `setpts` + `concat`; sped segments get a visible `>> 8x` indicator (ASCII stand-in for ⏩ so no font surprises); `remove` mode keeps only the first 0.25 s of each frozen span.
4. `video.json` carries the published duration and per-step seek offsets remapped through the edit list — exactly what the viewer needs for chapter seeking.

The script lives in the lib's bundled `Scenarios/Scripts/` directory (already a `.copy` resource in `Package.swift`, same mechanism as `fake_editor.py`) so `Bundle.module` finds it at runtime; its filename uses underscores so the unit tests can import it as a module.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/Scripts/e2e_video_postprocess.py`
- Test: `scripts/tests/test_e2e_video_postprocess.py`

**Interfaces:**
- Consumes: `timeline.json` (Task 3's `ScenarioTimeline` JSON: `steps[].stepNumber/description/start/end/status`, `testStartOffset`, `duration`), `recording-raw.mov`.
- Produces: `video.mp4` and `video.json` in the raw take's directory. `video.json` schema (read by Task 6): `{"mode": "speedup"|"remove", "durationSeconds": float, "rawDurationSeconds": float, "sizeBytes": int, "steps": [{"stepNumber": int, "description": str, "status": str, "start": float}]}` where `start` is the **published** (post-compression) offset. CLI: `python3 e2e_video_postprocess.py --raw PATH --timeline PATH [--mode speedup|remove] [--speedup 8] [--freeze-min 0.5] [--freeze-noise -60dB] [--keep-raw]`. Deletes the raw take on success unless `--keep-raw`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_e2e_video_postprocess.py`:

```python
#!/usr/bin/env python3
"""Unit tests for e2e_video_postprocess.py — pure functions only, no ffmpeg.

Run: python3 scripts/tests/test_e2e_video_postprocess.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "ClaudeSpyPackage", "Sources", "ClaudeSpyE2ELib", "Scenarios", "Scripts",
))
import e2e_video_postprocess as vp


class ParseFreezedetect(unittest.TestCase):
    STDERR = """
[freezedetect @ 0x600] lavfi.freezedetect.freeze_start: 2.5
[freezedetect @ 0x600] lavfi.freezedetect.freeze_duration: 3.0
[freezedetect @ 0x600] lavfi.freezedetect.freeze_end: 5.5
[freezedetect @ 0x600] lavfi.freezedetect.freeze_start: 9.0
"""

    def test_closed_and_unclosed_spans(self):
        spans = vp.parse_freezedetect(self.STDERR, duration=12.0)
        self.assertEqual(spans, [(2.5, 5.5), (9.0, 12.0)])

    def test_no_freezes(self):
        self.assertEqual(vp.parse_freezedetect("frame=  42 fps=15", 10.0), [])


class BuildEditList(unittest.TestCase):
    def test_speedup_mode(self):
        segments = vp.build_edit_list([(2.0, 5.0)], 10.0, mode="speedup", speedup=8.0)
        self.assertEqual(segments, [(0.0, 2.0, 1.0), (2.0, 5.0, 8.0), (5.0, 10.0, 1.0)])

    def test_remove_mode_keeps_head(self):
        segments = vp.build_edit_list([(2.0, 5.0)], 10.0, mode="remove")
        self.assertEqual(segments, [(0.0, 2.0, 1.0), (2.0, 2.25, 1.0), (5.0, 10.0, 1.0)])

    def test_freeze_at_start_and_end(self):
        segments = vp.build_edit_list(
            [(0.0, 3.0), (8.0, 10.0)], 10.0, mode="speedup", speedup=4.0
        )
        self.assertEqual(
            segments, [(0.0, 3.0, 4.0), (3.0, 8.0, 1.0), (8.0, 10.0, 4.0)]
        )

    def test_no_freezes_single_segment(self):
        self.assertEqual(vp.build_edit_list([], 7.0), [(0.0, 7.0, 1.0)])


class RemapTime(unittest.TestCase):
    SEGMENTS = [(0.0, 2.0, 1.0), (2.0, 5.0, 8.0), (5.0, 10.0, 1.0)]

    def test_before_freeze_is_identity(self):
        self.assertAlmostEqual(vp.remap_time(1.0, self.SEGMENTS), 1.0)

    def test_inside_sped_span(self):
        self.assertAlmostEqual(vp.remap_time(4.0, self.SEGMENTS), 2.0 + 2.0 / 8.0)

    def test_after_sped_span(self):
        self.assertAlmostEqual(vp.remap_time(7.0, self.SEGMENTS), 2.0 + 3.0 / 8.0 + 2.0)

    def test_dropped_region_maps_to_cut_point(self):
        segments = [(0.0, 2.0, 1.0), (5.0, 10.0, 1.0)]  # (2, 5) removed entirely
        self.assertAlmostEqual(vp.remap_time(3.5, segments), 2.0)

    def test_published_duration(self):
        self.assertAlmostEqual(vp.published_duration(self.SEGMENTS), 2.0 + 0.375 + 5.0)


class BuildAss(unittest.TestCase):
    TIMELINE = {
        "scenarioName": "Demo",
        "testStartOffset": 0.4,
        "duration": 10.0,
        "steps": [
            {"stepNumber": 1, "description": "Tap 'New Session'",
             "start": 0.5, "end": 4.0, "status": "passed"},
            {"stepNumber": 2, "description": "Type {weird} text",
             "start": 4.0, "end": None, "status": "failed"},
        ],
    }

    def test_dialogue_lines(self):
        ass = vp.build_ass(self.TIMELINE, 1920, 1080)
        self.assertIn("PlayResX: 1920", ass)
        self.assertIn("Dialogue: 0,0:00:00.50,0:00:04.00,Step,,0,0,0,,Step 1/2", ass)
        # Braces are ASS override control chars — they must never survive.
        self.assertNotIn("{weird}", ass)
        self.assertIn("(weird)", ass)
        # A nil end falls back to the scenario duration.
        self.assertIn("Dialogue: 0,0:00:04.00,0:00:10.00,Step,,0,0,0,,", ass)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 scripts/tests/test_e2e_video_postprocess.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'e2e_video_postprocess'`.

- [ ] **Step 3: Implement the script**

Create `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/Scripts/e2e_video_postprocess.py`:

```python
#!/usr/bin/env python3
"""Post-process a raw E2E scenario screen recording into the published artifact.

Pipeline (issue #621):
  1. Detect static spans with ffmpeg freezedetect (noise tolerance absorbs
     cursor blink / antialiasing shimmer).
  2. Burn labels FIRST, on the 1x timeline: an ASS step-caption ribbon built
     from timeline.json plus a drawtext timecode of real elapsed time since
     test start — so both stay truthful after retiming.
  3. Retime: speed up static spans (default 8x, with a visible ">> 8x"
     indicator) or remove them (--mode remove keeps the first 0.25s of each).
  4. Write video.mp4 + video.json (published duration and per-step seek
     offsets remapped through the edit list) next to the raw take, deleting
     the raw take unless --keep-raw.

Requires ffmpeg + ffprobe with the freezedetect, ass, and drawtext filters
(`brew install ffmpeg`). Python stdlib only. Unit tests:
scripts/tests/test_e2e_video_postprocess.py.
"""
import argparse
import json
import os
import re
import subprocess
import sys

FREEZE_START_RE = re.compile(r"freeze_start:\s*([0-9.]+)")
FREEZE_END_RE = re.compile(r"freeze_end:\s*([0-9.]+)")
FONT = "fontfile=/System/Library/Fonts/Menlo.ttc"


# ---------------------------------------------------------------- pure logic

def parse_freezedetect(stderr_text, duration):
    """Return [(start, end)] freeze spans parsed from ffmpeg's freezedetect
    stderr. An unclosed final span (video ends while frozen) extends to
    `duration`."""
    spans, start = [], None
    for line in stderr_text.splitlines():
        m = FREEZE_START_RE.search(line)
        if m:
            start = float(m.group(1))
            continue
        m = FREEZE_END_RE.search(line)
        if m and start is not None:
            spans.append((start, float(m.group(1))))
            start = None
    if start is not None and duration - start > 0.01:
        spans.append((start, duration))
    return spans


def build_edit_list(freezes, duration, mode="speedup", speedup=8.0,
                    keep_removed_head=0.25):
    """Return the retained edit list [(start, end, speed)] covering the take.

    speed == 1.0 plays in real time; > 1.0 is a sped-up span. In remove mode
    only the first `keep_removed_head` seconds of each frozen span are kept
    (at 1x) so the settled state stays visible; raw time not covered by any
    tuple is dropped entirely."""
    segments, cursor = [], 0.0
    for fs, fe in sorted(freezes):
        fs, fe = max(fs, 0.0), min(fe, duration)
        if fe <= cursor:
            continue
        fs = max(fs, cursor)
        if fs - cursor > 0.01:
            segments.append((cursor, fs, 1.0))
        if mode == "remove":
            head_end = min(fs + keep_removed_head, fe)
            if head_end - fs > 0.01:
                segments.append((fs, head_end, 1.0))
        else:
            segments.append((fs, fe, speedup))
        cursor = fe
    if duration - cursor > 0.01:
        segments.append((cursor, duration, 1.0))
    if not segments:
        # Degenerate take (entirely frozen + removed) — keep something playable.
        segments = [(0.0, min(duration, keep_removed_head), 1.0)]
    return segments


def remap_time(t, segments):
    """Map a raw-take timestamp to the published (retimed) timeline. A
    timestamp inside a dropped region maps to the cut point."""
    acc = 0.0
    for a, b, speed in segments:
        if t >= b:
            acc += (b - a) / speed
        elif t > a:
            return acc + (t - a) / speed
        else:
            break
    return acc


def published_duration(segments):
    return sum((b - a) / speed for a, b, speed in segments)


def ass_time(t):
    t = max(t, 0.0)
    hours = int(t // 3600)
    minutes = int(t % 3600 // 60)
    seconds = t % 60
    return f"{hours}:{minutes:02d}:{seconds:05.2f}"


def ass_escape(text):
    """Strip ASS control characters ({ } start override blocks) and newlines."""
    return (text.replace("\\", "")
            .replace("{", "(").replace("}", ")")
            .replace("\n", " "))


def build_ass(timeline, width, height, max_desc=90):
    """Build an ASS subtitle document with one bottom-ribbon Dialogue per step."""
    steps = timeline["steps"]
    total = len(steps)
    duration = timeline.get("duration") or 0.0
    lines = [
        "[Script Info]",
        "ScriptType: v4.00+",
        f"PlayResX: {width}",
        f"PlayResY: {height}",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
        "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding",
        "Style: Step,Menlo,22,&H00FFFFFF,&H000000FF,&H00000000,&H90000000,"
        "0,0,0,0,100,100,0,0,3,6,0,2,20,20,16,1",
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
        "Effect, Text",
    ]
    for i, step in enumerate(steps):
        start = step["start"]
        end = step.get("end")
        if end is None:
            end = steps[i + 1]["start"] if i + 1 < len(steps) else duration
        desc = ass_escape(step["description"])[:max_desc]
        marker = "[FAILED] " if step.get("status") == "failed" else ""
        text = f"{marker}Step {step['stepNumber']}/{total} — {desc}"
        lines.append(
            f"Dialogue: 0,{ass_time(start)},{ass_time(end)},Step,,0,0,0,,{text}"
        )
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------- ffmpeg

def run_checked(cmd, cwd):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"FAILED ({result.returncode}): {' '.join(cmd)}\n"
                 f"{result.stderr[-4000:]}")
    return result


def probe(raw, cwd):
    out = run_checked(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height:format=duration",
         "-of", "json", raw],
        cwd,
    ).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    return float(data["format"]["duration"]), int(stream["width"]), int(stream["height"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True, help="Path to recording-raw.mov")
    parser.add_argument("--timeline", required=True, help="Path to timeline.json")
    parser.add_argument("--mode", choices=["speedup", "remove"], default="speedup")
    parser.add_argument("--speedup", type=float, default=8.0)
    parser.add_argument("--freeze-min", type=float, default=0.5,
                        help="Minimum static-span length to compress (seconds)")
    parser.add_argument("--freeze-noise", default="-60dB",
                        help="freezedetect noise tolerance (cursor blink/AA)")
    parser.add_argument("--keep-raw", action="store_true",
                        help="Keep recording-raw.mov after a successful encode")
    args = parser.parse_args()

    work_dir = os.path.dirname(os.path.abspath(args.raw))
    raw = os.path.basename(args.raw)
    with open(args.timeline) as f:
        timeline = json.load(f)

    duration, width, height = probe(raw, work_dir)

    # 1. Static-span detection.
    freeze_result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", raw,
         "-vf", f"freezedetect=n={args.freeze_noise}:d={args.freeze_min}",
         "-map", "0:v", "-f", "null", "-"],
        cwd=work_dir, capture_output=True, text=True,
    )
    freezes = parse_freezedetect(freeze_result.stderr, duration)
    segments = build_edit_list(freezes, duration, mode=args.mode,
                               speedup=args.speedup)

    # 2. Burn labels on the 1x timeline (before any retiming, so the timecode
    #    keeps showing true wall-clock time inside compressed spans).
    with open(os.path.join(work_dir, "steps.ass"), "w") as f:
        f.write(build_ass(timeline, width, height))
    offset = -(timeline.get("testStartOffset") or 0.0)
    timecode = (f"drawtext={FONT}:fontsize=20:fontcolor=white:box=1:"
                "boxcolor=black@0.55:boxborderw=6:x=w-tw-14:y=12:"
                f"text='%{{pts\\:hms\\:{offset:.3f}}}'")
    run_checked(
        ["ffmpeg", "-y", "-hide_banner", "-i", raw,
         "-vf", f"ass=steps.ass,{timecode}",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "labeled.mov"],
        work_dir,
    )

    # 3. Retime through the edit list (trim/setpts per segment, concat).
    chains, labels = [], []
    for i, (a, b, speed) in enumerate(segments):
        chain = (f"[0:v]trim=start={a:.3f}:end={b:.3f},"
                 f"setpts=(PTS-STARTPTS)/{speed:g},fps=15")
        if speed > 1:
            chain += (f",drawtext={FONT}:fontsize=28:fontcolor=white:box=1:"
                      "boxcolor=black@0.55:boxborderw=6:x=14:y=12:"
                      f"text='>> {speed:g}x'")
        chains.append(chain + f"[v{i}]")
        labels.append(f"[v{i}]")
    graph = (";".join(chains) + ";" + "".join(labels)
             + f"concat=n={len(segments)}:v=1:a=0[out]")
    with open(os.path.join(work_dir, "retime-graph.txt"), "w") as f:
        f.write(graph)
    run_checked(
        ["ffmpeg", "-y", "-hide_banner", "-i", "labeled.mov",
         "-filter_complex_script", "retime-graph.txt", "-map", "[out]",
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", "video.mp4"],
        work_dir,
    )

    # 4. Published metadata — seek chapters remapped through the edit list.
    video_json = {
        "mode": args.mode,
        "durationSeconds": round(published_duration(segments), 3),
        "rawDurationSeconds": round(duration, 3),
        "sizeBytes": os.path.getsize(os.path.join(work_dir, "video.mp4")),
        "steps": [
            {
                "stepNumber": s["stepNumber"],
                "description": s["description"],
                "status": s.get("status", "passed"),
                "start": round(remap_time(s["start"], segments), 3),
            }
            for s in timeline["steps"]
        ],
    }
    with open(os.path.join(work_dir, "video.json"), "w") as f:
        json.dump(video_json, f, indent=2)

    # 5. Cleanup.
    for name in ("steps.ass", "retime-graph.txt", "labeled.mov"):
        try:
            os.remove(os.path.join(work_dir, name))
        except FileNotFoundError:
            pass
    if not args.keep_raw:
        os.remove(os.path.join(work_dir, raw))

    print(f"video.mp4: {video_json['sizeBytes']} bytes, "
          f"{video_json['durationSeconds']}s published / "
          f"{video_json['rawDurationSeconds']}s raw, "
          f"{len(freezes)} static span(s), "
          f"raw {'kept' if args.keep_raw else 'deleted'}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 scripts/tests/test_e2e_video_postprocess.py`
Expected: PASS — `Ran 12 tests … OK`.

- [ ] **Step 5: Smoke-test the full pipeline against a real screen recording**

```bash
cd /private/tmp && mkdir -p vidsmoke && cd vidsmoke
# 12s screen recording with a deliberate static tail (stop interacting after ~4s)
screencapture -v -V 12 recording-raw.mov
cat > timeline.json <<'EOF'
{
  "scenarioName": "Smoke",
  "recordingStartedAt": "2026-07-01T00:00:00Z",
  "testStartOffset": 0.3,
  "duration": 12.0,
  "failedStep": null,
  "steps": [
    {"stepNumber": 1, "description": "Move the mouse around", "start": 0.4, "end": 4.0, "status": "passed"},
    {"stepNumber": 2, "description": "Hold still (static span)", "start": 4.0, "end": 12.0, "status": "passed"}
  ]
}
EOF
python3 <repo>/ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/Scripts/e2e_video_postprocess.py \
    --raw recording-raw.mov --timeline timeline.json --keep-raw
open video.mp4
```

Expected: `video.mp4` plays; the step ribbon appears at the bottom; the timecode runs top-right; the static tail is visibly sped up with a `>> 8x` badge; `video.json` shows `durationSeconds` < `rawDurationSeconds`; the printed summary reports ≥ 1 static span. If ffmpeg errors on the `ass` filter, the local ffmpeg lacks libass — `brew install ffmpeg` and re-run (the Task 5 gate makes this a hard requirement only under `--record`).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/Scripts/e2e_video_postprocess.py \
        scripts/tests/test_e2e_video_postprocess.py
git commit -m "e2e: ffmpeg post-processing — labels, dead-time compression, seek chapters (#621)"
```

---

### Task 5: Wire `--record` end-to-end (CLI, orchestrator stage layout, Simulator placement, e2e-test.sh)

Connects everything: the `--record` flag flows `e2e-test.sh` → `ClaudeSpyE2E` → `RecordingCoordinator` + orchestrator stage layout. The stage layout **translates** instance-N absolute coordinates (`macMoveWindow`, `macClickAtPoint`, `macDrag`) by the lane vector — deterministic and synchronous with step execution, so no window ever moves while a step is mid-interaction. The Simulator window is pinned top-right after `launchIOSApp`. (Settings windows opened via `macOpenSettings` stay centered — accepted residual occlusion; the Panes windows where terminal action happens are all positioned via `macMoveWindow` and therefore covered.)

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift` (flags at ~line 68, reporters at ~117, orchestrator init at ~134)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift` (init ~104, `.macMoveWindow` case at 797, `.macClickAtPoint` at 822, `.macDrag` at 825, `.launchIOSApp` at 468)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Drivers/Simulator/SimulatorDriver.swift` (add `positionWindowTopRight`)
- Modify: `scripts/e2e-test.sh` (arg parsing ~line 43, prerequisite gate after the permission checks ~line 413, E2E_ARGS ~line 586)

**Interfaces:**
- Consumes: `StageLayout` (Task 1), `ScreenRecorder` (Task 2), `RecordingCoordinator` + `makeFFmpegPostProcessor` (Task 3), bundled script (Task 4).
- Produces: `TestOrchestrator.init(..., stageLayoutEnabled: Bool = false, ...)`; `SimulatorDriver.positionWindowTopRight(displayWidth: Int) async`; CLI flags `--record`, `--record-mode speedup|remove`, `--record-keep-raw` on both `ClaudeSpyE2E` and `e2e-test.sh`. After this task a recorded run drops `video.mp4` + `video.json` + `timeline.json` into `<screenshotsDir>/<scenario>/`.

- [ ] **Step 1: Add stage layout to TestOrchestrator**

In `TestOrchestrator.swift`, add `import CoreGraphics` below `import Foundation` (line 1–2 area), add a stored property next to `skipComparison` (~line 29):

```swift
    /// Lane geometry applied when a recorded run needs every instance visible
    /// in one full-display take (issue #621). `nil` (the default) means
    /// coordinates pass through untouched — zero behavior change unrecorded.
    private let stageLayout: StageLayout?
```

extend the initializer signature (after `skipComparison: Bool = false`):

```swift
        skipComparison: Bool = false,
        stageLayoutEnabled: Bool = false,
        gallagerStateRootBase: String? = nil,
        reporter: (any TestProgressReporter)? = nil
```

and in the init body:

```swift
        self.stageLayout = stageLayoutEnabled
            ? StageLayout(display: CGDisplayBounds(CGMainDisplayID()).size)
            : nil
```

Add two private helpers near `macDriver(for:)` (~line 1316):

```swift
    /// Translate scenario-authored absolute coordinates into the instance's
    /// stage lane. Identity when stage layout is off or for instance 0.
    private func staged(x: Int, y: Int, instance: Int) -> (x: Int, y: Int) {
        guard let stageLayout else { return (x, y) }
        let t = stageLayout.translation(instance: instance)
        return (x + Int(t.dx), y + Int(t.dy))
    }

    private func staged(x: Double, y: Double, instance: Int) -> (x: Double, y: Double) {
        guard let stageLayout else { return (x, y) }
        let t = stageLayout.translation(instance: instance)
        return (x + t.dx, y + t.dy)
    }
```

Update the three coordinate cases in `executeStep`:

```swift
        case let .macMoveWindow(x, y, instance):
            let p = staged(x: x, y: y, instance: instance)
            try await macDriver(for: instance).moveWindow(x: p.x, y: p.y)
```

```swift
        case let .macClickAtPoint(x, y, instance):
            let p = staged(x: x, y: y, instance: instance)
            try await macDriver(for: instance).clickAtScreenPoint(x: p.x, y: p.y)
```

```swift
        case let .macDrag(fromX, fromY, toX, toY, instance):
            let from = staged(x: fromX, y: fromY, instance: instance)
            let to = staged(x: toX, y: toY, instance: instance)
            try await macDriver(for: instance)
                .drag(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)
```

And at the end of the `.launchIOSApp` case (after `simulatorDriver.launchApp(...)`):

```swift
            if let stageLayout {
                await simulatorDriver.positionWindowTopRight(
                    displayWidth: Int(stageLayout.display.width)
                )
            }
```

- [ ] **Step 2: Add Simulator window placement to SimulatorDriver**

In `SimulatorDriver.swift`, add (near the other public app-lifecycle methods, using the driver's existing `ProcessRunner` property — match the property name used by e.g. `bootSimulator`):

```swift
    /// Move the Simulator window to the top-right corner of the recorded
    /// display so it doesn't cover the mac window lanes during recorded runs
    /// (issue #621). Best-effort: placement failures never fail a step.
    public func positionWindowTopRight(displayWidth: Int, margin: Int = 10) async {
        let script = """
        tell application "System Events"
            tell process "Simulator"
                set {w, h} to size of window 1
                set position of window 1 to {\(displayWidth) - w - \(margin), \(margin)}
            end tell
        end tell
        """
        _ = try? await processRunner.run("osascript", arguments: ["-e", script])
    }
```

If `SimulatorDriver` exposes a dedicated AppleScript helper instead of raw `processRunner.run`, use that helper — follow the pattern of its existing osascript call sites.

- [ ] **Step 3: Add the CLI flags and wire the coordinator in ClaudeSpyE2ECommand**

In `ClaudeSpyE2ECommand.swift`, after the `--list-scenarios` flag (~line 70):

```swift
    @Flag(name: .long, help: "Record each scenario as a full-display video (requires ffmpeg)")
    var record = false

    @Option(name: .long, help: "Dead-time handling for recorded videos: speedup (default) or remove")
    var recordMode = "speedup"

    @Flag(name: .long, help: "Keep the raw take (recording-raw.mov) after post-processing")
    var recordKeepRaw = false
```

At the top of `run()` (after the `listScenarios` early return), validate the mode:

```swift
        guard ["speedup", "remove"].contains(recordMode) else {
            print("ERROR: --record-mode must be 'speedup' or 'remove'")
            throw ExitCode.failure
        }
```

Change the reporter assembly (~line 117) so the recorder is first in the fan-out (recording starts before other reporters print):

```swift
        var reporters: [any TestProgressReporter] = []
        if record {
            reporters.append(RecordingCoordinator(
                screenshotsDir: screenshotsDir,
                recorder: ScreenRecorder(),
                postProcessor: RecordingCoordinator.makeFFmpegPostProcessor(
                    mode: recordMode,
                    keepRaw: recordKeepRaw
                )
            ))
        }
        reporters.append(TerminalReporter())
```

And pass the stage-layout switch to the orchestrator (~line 134):

```swift
        let orchestrator = TestOrchestrator(
            iosAppPath: iosAppPath,
            macOSAppPath: macosAppPath,
            simulatorName: simName,
            screenshotsDir: screenshotsDir,
            baselinesDir: baselinesDir,
            tmuxSocket: tmuxSocket,
            e2eRunnerPath: e2eRunnerPath,
            skipComparison: noCompare,
            stageLayoutEnabled: record,
            gallagerStateRootBase: gallagerStateRoot,
            reporter: reporter
        )
```

Also print the recording status in the startup banner (after the "Compare:" line):

```swift
        fputs("  Recording:   \(record ? "enabled (\(recordMode))" : "disabled")\n", stderr)
```

- [ ] **Step 4: Add the flags and prerequisite gate to e2e-test.sh**

In `scripts/e2e-test.sh`: add to the config block (~line 38):

```bash
RECORD=false
RECORD_MODE=""
RECORD_KEEP_RAW=false
```

Add to the argument parser (before the `-h|--help` case):

```bash
        --record)
            RECORD=true
            shift
            ;;
        --record-mode)
            RECORD_MODE="$2"
            shift 2
            ;;
        --record-keep-raw)
            RECORD_KEEP_RAW=true
            shift
            ;;
```

Add `--record` lines to the help text:

```bash
            echo "  --record           Record each scenario as a video (requires ffmpeg)"
            echo "  --record-mode MODE Dead-time handling: speedup (default) or remove"
            echo "  --record-keep-raw  Keep raw takes after post-processing"
```

Inside the existing `if [ "$LIST_SCENARIOS" != true ]; then` permission block (after the Screen Recording check, ~line 412), add the ffmpeg gate:

```bash
    if [ "$RECORD" = true ]; then
        step "Checking video recording prerequisites"
        if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
            fail "ffmpeg/ffprobe not found — install with: brew install ffmpeg"
            exit 1
        fi
        for filter in freezedetect drawtext ass; do
            if ! ffmpeg -hide_banner -filters 2>/dev/null | grep -qw "$filter"; then
                fail "ffmpeg is missing the '$filter' filter — reinstall with: brew install ffmpeg"
                exit 1
            fi
        done
        ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"
    fi
```

And extend the run-arg assembly (after the `--json-output` block, ~line 610):

```bash
if [ "$RECORD" = true ]; then
    E2E_ARGS+=(--record)
fi

if [ -n "$RECORD_MODE" ]; then
    E2E_ARGS+=(--record-mode "$RECORD_MODE")
fi

if [ "$RECORD_KEEP_RAW" = true ]; then
    E2E_ARGS+=(--record-keep-raw)
fi
```

(`scripts/e2e-report.sh` needs no change for pass-through — its `*)` case already forwards unknown args to e2e-test.sh.)

- [ ] **Step 5: Build everything and run the existing unit suite**

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyE2ETests`
Expected: PASS (no regressions from the orchestrator changes).

Run: `bash -n scripts/e2e-test.sh`
Expected: no syntax errors.

- [ ] **Step 6: Verify unrecorded behavior is unchanged (regression guard)**

Run: `./scripts/e2e-test.sh --scenario "Cursor Style Changes"`
Expected: scenario PASSES exactly as on main; no `recording-raw.mov`/`video.mp4` anywhere under the screenshots dir (`find "${TMPDIR:-/tmp}/claudespy-e2e/e2e-screenshots" -name '*.mov' -o -name '*.mp4'` returns nothing).

- [ ] **Step 7: Verify a recorded single-instance scenario end-to-end**

Run: `./scripts/e2e-test.sh --skip-build --record --record-keep-raw --scenario "Cursor Style Changes"`
Expected: scenario PASSES; then

```bash
ls "${TMPDIR:-/tmp}/claudespy-e2e/e2e-screenshots/cursor-style-changes/"
```

shows `recording-raw.mov`, `timeline.json`, `video.mp4`, `video.json` plus the usual PNGs. `open …/video.mp4` — confirm: step ribbon matches the running step, timecode counts real elapsed time, waits are sped up with the `>> 8x` badge, and `video.json`'s `durationSeconds` is meaningfully smaller than `rawDurationSeconds` on this wait-heavy scenario.

- [ ] **Step 8: Verify the two-Mac stage layout**

Run: `./scripts/e2e-test.sh --skip-build --record --scenario "Two Mac Pairing"`
Expected: scenario PASSES (translated clicks still land); in the video both Gallager windows are visible simultaneously — instance 1 in its lane, not stacked on instance 0 — with at most corner overlap on a small display. Baseline screenshots still pass (windows were moved, never resized).

Then re-run the same scenario 2 more times to check for stage-layout-induced flakiness (per the "no new flakes" acceptance criterion).

- [ ] **Step 9: Verify Simulator placement**

Run any iOS-involving scenario recorded, e.g.: `./scripts/e2e-test.sh --skip-build --record --scenario "New Terminal"`
Expected: PASSES; in the video the Simulator window sits top-right and does not cover the Mac window at (10, 10).

- [ ] **Step 10: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Drivers/Simulator/SimulatorDriver.swift \
        scripts/e2e-test.sh
git commit -m "e2e: --record flag, stage-layout lanes, Simulator placement (#621)"
```

---

### Task 6: Publish videos through the report pipeline

Extract `e2e-report.sh`'s inline Python heredoc (lines 293–412) into `scripts/e2e_report_build.py` so the artifact-store logic is unit-testable, generalize `store_image()` into content-addressed `store_artifact()`, and attach a `video` field per scenario when `video.mp4`/`video.json` exist in that scenario's screenshots dir.

**Files:**
- Create: `scripts/e2e_report_build.py`
- Modify: `scripts/e2e-report.sh:293-412` (replace heredoc with a script invocation)
- Test: `scripts/tests/test_e2e_report_build.py`

**Interfaces:**
- Consumes: `video.json` schema from Task 4; env vars `e2e-report.sh` already exports (`REPORT_DIR`, `IMAGES_DIR`, `SCREENSHOTS_DIR`, `BASELINES_DIR`, `BRANCH`, …).
- Produces: `report.json` scenarios may carry `"video": {"hash": str, "duration": float, "mode": str, "steps": [{"stepNumber", "description", "status", "start"}]}`; videos stored as `images/<sha256>.mp4`. Functions `store_artifact(src_path, ext, images_dir)`, `scenario_dir_name(name)`, `attach_video(scenario, screenshots_dir, images_dir)` (Task 7's viewer reads the `video` field).

- [ ] **Step 1: Write the failing tests**

Create `scripts/tests/test_e2e_report_build.py`:

```python
#!/usr/bin/env python3
"""Unit tests for e2e_report_build.py.

Run: python3 scripts/tests/test_e2e_report_build.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e_report_build as rb


class ScenarioDirName(unittest.TestCase):
    def test_mirrors_swift_sanitizer(self):
        # Must stay in sync with TestOrchestrator.scenarioDirName(for:).
        self.assertEqual(rb.scenario_dir_name("Two Mac Pairing"), "two-mac-pairing")
        self.assertEqual(rb.scenario_dir_name("OTEL: Usage (Overview)!"), "otel-usage-overview")


class StoreArtifact(unittest.TestCase):
    def test_content_addressed_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "video.mp4")
            with open(src, "wb") as f:
                f.write(b"fake-video-bytes")
            images = os.path.join(tmp, "images")
            os.makedirs(images)
            sha = rb.store_artifact(src, ".mp4", images)
            self.assertTrue(os.path.isfile(os.path.join(images, f"{sha}.mp4")))
            # Idempotent — same content, same hash, no error on re-store.
            self.assertEqual(sha, rb.store_artifact(src, ".mp4", images))

    def test_missing_source_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(rb.store_artifact(os.path.join(tmp, "nope.mp4"), ".mp4", tmp))


class AttachVideo(unittest.TestCase):
    def test_attaches_hash_duration_and_chapters(self):
        with tempfile.TemporaryDirectory() as tmp:
            images = os.path.join(tmp, "images")
            os.makedirs(images)
            sdir = os.path.join(tmp, "shots", "video-demo")
            os.makedirs(sdir)
            with open(os.path.join(sdir, "video.mp4"), "wb") as f:
                f.write(b"vid")
            meta = {
                "durationSeconds": 12.3,
                "mode": "speedup",
                "steps": [{"stepNumber": 1, "start": 0.5,
                           "description": "d", "status": "passed"}],
            }
            with open(os.path.join(sdir, "video.json"), "w") as f:
                json.dump(meta, f)

            scenario = {"scenarioName": "Video Demo"}
            rb.attach_video(scenario, os.path.join(tmp, "shots"), images)

            self.assertIn("video", scenario)
            self.assertEqual(scenario["video"]["duration"], 12.3)
            self.assertEqual(scenario["video"]["mode"], "speedup")
            self.assertEqual(scenario["video"]["steps"][0]["start"], 0.5)
            stored = os.path.join(images, scenario["video"]["hash"] + ".mp4")
            self.assertTrue(os.path.isfile(stored))

    def test_no_video_files_is_a_noop(self):
        scenario = {"scenarioName": "Video Demo"}
        with tempfile.TemporaryDirectory() as tmp:
            rb.attach_video(scenario, tmp, tmp)
        self.assertNotIn("video", scenario)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 scripts/tests/test_e2e_report_build.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'e2e_report_build'`.

- [ ] **Step 3: Create scripts/e2e_report_build.py**

Port the heredoc **verbatim in behavior**, restructured into functions. The screenshot-processing branches (`process_screenshot`, `process_failure_screenshot`) are copied unchanged from `e2e-report.sh:330-385` except `store_image(p)` becomes `store_artifact(p, ".png", images_dir)`:

```python
#!/usr/bin/env python3
"""Build report.json for an E2E run: run metadata + scenario results with
content-addressed screenshot and video artifacts.

Extracted from the inline heredoc in e2e-report.sh so the artifact-store and
video-merge logic is unit-testable (scripts/tests/test_e2e_report_build.py).
Reads the same environment variables e2e-report.sh has always exported.
"""
import hashlib
import json
import os
import shutil
import sys


def store_artifact(src_path, ext, images_dir):
    """Compute SHA-256, copy to <images_dir>/<hash><ext> if absent, return hash."""
    if not src_path or not os.path.isfile(src_path):
        return None
    h = hashlib.sha256()
    with open(src_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    sha = h.hexdigest()
    dest = os.path.join(images_dir, f"{sha}{ext}")
    if not os.path.exists(dest):
        shutil.copy2(src_path, dest)
    return sha


def scenario_dir_name(name):
    """Mirror TestOrchestrator.scenarioDirName(for:) — MUST stay in sync."""
    return "".join(
        c for c in name.lower().replace(" ", "-") if c.isalnum() or c in "-_"
    )


def attach_video(scenario, screenshots_dir, images_dir):
    """Attach a content-addressed video + seek chapters when the recording
    pipeline left video.mp4/video.json in the scenario's screenshots dir."""
    sdir = os.path.join(screenshots_dir, scenario_dir_name(scenario.get("scenarioName", "")))
    video_path = os.path.join(sdir, "video.mp4")
    meta_path = os.path.join(sdir, "video.json")
    if not (os.path.isfile(video_path) and os.path.isfile(meta_path)):
        return
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except Exception as e:
        print(f"Warning: unreadable {meta_path}: {e}", file=sys.stderr)
        return
    sha = store_artifact(video_path, ".mp4", images_dir)
    if not sha:
        return
    scenario["video"] = {
        "hash": sha,
        "duration": meta.get("durationSeconds"),
        "mode": meta.get("mode"),
        "steps": meta.get("steps", []),
    }


def process_screenshot(ss, screenshots_dir, baselines_dir, images_dir):
    """Convert a path-based screenshot dict to hash-based fields."""
    label = ss.get("label", "")
    passed = ss.get("passed", True)
    baseline_created = ss.get("baselineCreated", False)
    diff_percentage = ss.get("diffPercentage")

    actual_path = ss.get("actualPath") or os.path.join(screenshots_dir, f"{label}.png")
    baseline_path = ss.get("baselinePath") or os.path.join(baselines_dir, f"{label}.png")
    diff_path = ss.get("diffPath")

    actual_hash = store_artifact(actual_path, ".png", images_dir)
    baseline_hash = store_artifact(baseline_path, ".png", images_dir)
    diff_hash = store_artifact(diff_path, ".png", images_dir) if diff_path else None

    if passed and not baseline_created and diff_percentage is not None:
        image_hash = baseline_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None
    elif not passed:
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = diff_hash
    elif baseline_created:
        image_hash = actual_hash
        result_baseline_hash = actual_hash
        result_diff_hash = None
    else:
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None

    return {
        "label": label,
        "imageHash": image_hash,
        "baselineHash": result_baseline_hash,
        "diffHash": result_diff_hash,
        "diffPercentage": diff_percentage,
        "passed": passed,
        "baselineCreated": baseline_created,
    }


def process_failure_screenshot(fs, images_dir):
    """Convert a path-based failure screenshot dict to a hash-based field."""
    target = fs.get("target", "")
    path = fs.get("path")
    image_hash = store_artifact(path, ".png", images_dir) if path else None
    return {
        "target": target,
        "imageHash": image_hash,
    }


def main():
    metadata = {
        "branch": os.environ["BRANCH"],
        "commit": os.environ["COMMIT"],
        "commitFull": os.environ["COMMIT_FULL"],
        "commitMessage": os.environ["COMMIT_MSG"],
        "prNumber": os.environ["PR_NUMBER"] or None,
        "prUrl": os.environ["PR_URL"] or None,
        "prTitle": os.environ["PR_TITLE"] or None,
        "timestamp": os.environ["TIMESTAMP"],
        "date": os.environ["DATE_DISPLAY"],
        "folder": os.environ["RESULT_FOLDER"],
        "allPassed": os.environ["ALL_PASSED"] == "true",
        "buildFailed": os.environ["BUILD_FAILED"] == "true",
    }

    report_dir = os.environ["REPORT_DIR"]
    images_dir = os.environ["IMAGES_DIR"]
    screenshots_dir = os.environ["SCREENSHOTS_DIR"]
    baselines_dir = os.environ["BASELINES_DIR"]

    results = []
    try:
        with open(os.path.join(report_dir, "results.json")) as f:
            results = json.load(f)
    except Exception as e:
        print(f"Warning: could not read results.json: {e}", file=sys.stderr)

    for scenario in results:
        for step in scenario.get("steps", []):
            ss = step.get("screenshot")
            if ss:
                step["screenshot"] = process_screenshot(
                    ss, screenshots_dir, baselines_dir, images_dir
                )
            failures = step.get("failureScreenshots") or []
            if failures:
                step["failureScreenshots"] = [
                    process_failure_screenshot(f, images_dir) for f in failures
                ]
        attach_video(scenario, screenshots_dir, images_dir)

    report = {"metadata": metadata, "scenarios": results}
    with open(os.path.join(report_dir, "report.json"), "w") as f:
        json.dump(report, f, indent=2)

    image_count = len(os.listdir(images_dir)) if os.path.isdir(images_dir) else 0
    video_count = sum(1 for s in results if s.get("video"))
    print(f"Report written to report.json ({image_count} artifacts in "
          f"content-addressed store, {video_count} video(s))")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 scripts/tests/test_e2e_report_build.py`
Expected: PASS — `Ran 5 tests … OK`.

- [ ] **Step 5: Swap the heredoc in e2e-report.sh**

In `scripts/e2e-report.sh`, replace the entire `python3 << 'PYEOF' … PYEOF` block (lines 293–412) — keeping every `VAR="$VAL" \` env line above it exactly as is — so the invocation ends with:

```bash
BASELINES_DIR="$BASELINES_DIR" \
python3 "$SCRIPT_DIR/e2e_report_build.py"
```

Run: `bash -n scripts/e2e-report.sh`
Expected: no syntax errors.

- [ ] **Step 6: End-to-end report verification with a recorded scenario**

Run a single-scenario recorded report against a throwaway results repo:

```bash
mkdir -p /private/tmp/fake-results && git -C /private/tmp/fake-results init -q
./scripts/e2e-report.sh --results-dir /private/tmp/fake-results --results-repo /private/tmp/fake-results \
    --skip-build --record --scenario "Cursor Style Changes"
```

Expected: the run completes; `jq '.scenarios[0].video' /private/tmp/fake-results/results/*/report.json` shows `hash`, `duration`, `mode`, and a non-empty `steps` array; `ls /private/tmp/fake-results/images/*.mp4` shows exactly one video. (The push step will warn about the fake remote — that's fine.)

- [ ] **Step 7: Commit**

```bash
git add scripts/e2e_report_build.py scripts/e2e-report.sh scripts/tests/test_e2e_report_build.py
git commit -m "e2e report: content-addressed store_artifact + per-scenario video field (#621)"
```

---

### Task 7: Results viewer — video player with step-seek chapters (external repo)

Teach `index.html` in the **ClaudeSpyTestResults** repo to render `scenario.video`: a `<video>` element sourced from the CAS plus a clickable chapter list that seeks to each step's published offset, with failed steps highlighted. This repo has no test framework — verification is `serve.sh` + browser against the report published in Task 6.

**Files (in `git@github.com:gpambrozio/ClaudeSpyTestResults.git`, cloned at the sibling path `../ClaudeSpyTestResults` that `e2e-report.sh:17` computes):**
- Modify: `index.html` (CSS block ~line 200, `renderDetail` scenario-body assembly ~line 433, helpers ~line 485)

**Interfaces:**
- Consumes: `report.json` scenarios' `video` field (Task 6): `{hash, duration, mode, steps: [{stepNumber, description, status, start}]}`; video file at `images/<hash>.mp4`.
- Produces: user-facing playback + chapter seek. No downstream consumers.

- [ ] **Step 1: Clone the results repo if not already present**

```bash
[ -d ../ClaudeSpyTestResults/.git ] || git clone git@github.com:gpambrozio/ClaudeSpyTestResults.git ../ClaudeSpyTestResults
cd ../ClaudeSpyTestResults && git checkout main && git pull
```

- [ ] **Step 2: Add the CSS**

In `index.html`, insert before the `.pr-link` rule (~line 201):

```css
  /* Scenario video (issue #621) */
  .video-section {
    padding: 12px 16px;
    border-top: 1px solid var(--border);
    background: rgba(255, 255, 255, 0.02);
  }
  .video-section video {
    width: 100%;
    max-height: 70vh;
    background: black;
    border-radius: 6px;
  }
  .video-meta { font-size: 12px; color: var(--text-muted); margin: 6px 0; }
  .chapters {
    margin-top: 8px;
    display: flex;
    flex-direction: column;
    gap: 2px;
    max-height: 240px;
    overflow-y: auto;
  }
  .chapter {
    display: flex;
    gap: 8px;
    align-items: baseline;
    font-family: monospace;
    font-size: 12px;
    color: var(--text);
    background: none;
    border: none;
    text-align: left;
    padding: 3px 6px;
    border-radius: 4px;
    cursor: pointer;
  }
  .chapter:hover { background: rgba(88, 166, 255, 0.1); }
  .chapter .t { color: var(--text-muted); min-width: 52px; }
  .chapter.failed { color: var(--red); }
```

- [ ] **Step 3: Render the video section and seek helpers**

In `renderDetail`, right after `html += '<div class="scenario-body">';` (~line 433), add:

```js
      // Recorded one-take video with step-seek chapters (issue #621)
      if (scenario.video && scenario.video.hash) {
        html += renderVideo(scenario);
      }
```

Add these functions next to `escapeHtml` (~line 485):

```js
function renderVideo(scenario) {
  const v = scenario.video;
  const vid = 'video-' + scenario.scenarioName.replace(/[^a-zA-Z0-9]/g, '-');
  let h = '<div class="video-section">';
  h += `<video id="${vid}" controls preload="metadata" src="images/${v.hash}.mp4"></video>`;
  const durationLabel = v.duration != null ? formatDuration(v.duration) : '';
  const modeLabel = v.mode === 'remove' ? 'static spans removed' : 'static spans sped up';
  h += `<div class="video-meta">${durationLabel} &middot; ${modeLabel} &middot; click a step to seek</div>`;
  const steps = v.steps || [];
  if (steps.length) {
    h += '<div class="chapters">';
    for (const s of steps) {
      const failed = s.status === 'failed';
      h += `<button class="chapter${failed ? ' failed' : ''}" onclick="seekVideo('${vid}', ${s.start})">`
        + `<span class="t">${formatChapterTime(s.start)}</span>`
        + `<span>${failed ? '&#10007; ' : ''}Step ${s.stepNumber} &mdash; ${escapeHtml(s.description || '')}</span>`
        + '</button>';
    }
    h += '</div>';
  }
  h += '</div>';
  return h;
}

function seekVideo(id, t) {
  const v = document.getElementById(id);
  if (!v) return;
  v.currentTime = t;
  v.play();
}

function formatChapterTime(s) {
  const min = Math.floor(s / 60);
  const sec = Math.floor(s % 60);
  return `${min}:${sec.toString().padStart(2, '0')}`;
}
```

- [ ] **Step 4: Verify in the browser**

```bash
cd ../ClaudeSpyTestResults && ./serve.sh
```

Open the served URL, navigate to the run published in Task 6 Step 6 (re-run that step against the real results repo first if the fake-repo report isn't available here — or copy `/private/tmp/fake-results/results` and `/private/tmp/fake-results/images` into the clone temporarily). Expected:
- The recorded scenario shows a playing video above its steps.
- Clicking a chapter seeks the video to that step (spot-check: the burned-in step ribbon at that position names the same step — this validates the edit-list remap).
- A failed step (if present) renders red with an ✗.
- Non-recorded scenarios and old reports render exactly as before (no `video` field → no section).

- [ ] **Step 5: Commit and push the viewer**

```bash
cd ../ClaudeSpyTestResults
git add index.html
git commit -m "Viewer: play scenario videos with step-seek chapters (ClaudeSpy #621)"
git push origin main
```

---

### Task 8: Documentation + acceptance verification

Document the feature and run the acceptance checklist from issue #621 that isn't already covered by Task 5/6 verification steps.

**Files:**
- Modify: `docs/e2e-testing.md` (add a "Recording runs as video" section)
- Modify: `CLAUDE.md` (append one line to the E2E testing doc bullet)

**Interfaces:**
- Consumes: everything above. Produces: docs; no code consumers.

- [ ] **Step 1: Add the docs section to docs/e2e-testing.md**

Append a section (adapt placement to the doc's structure — near the "running tests" material):

```markdown
## Recording runs as video (`--record`)

`./scripts/e2e-test.sh --record` records each scenario as ONE full-display
take (issue #621): ScreenCaptureKit captures the main display at ≤15 fps / 1x,
started on `scenarioStarted` and finalized on `scenarioCompleted` (success or
failure) by `RecordingCoordinator`, a `TestProgressReporter`.

- **Stage layout:** with `--record`, the orchestrator translates instance-N
  `macMoveWindow` / `macClickAtPoint` / `macDrag` coordinates into a per-
  instance screen lane (side-by-side on wide displays, staggered diagonal on
  laptops) so multi-instance scenarios are visible in one frame. Windows are
  MOVED, never resized — baselines are unaffected. The Simulator window is
  pinned top-right. Instance 0 is never touched.
- **Post-processing:** `e2e_video_postprocess.py` (bundled resource) burns a
  step-caption ribbon + a real-elapsed timecode on the 1x timeline, then
  compresses static spans > 0.5s (`--record-mode speedup` (default, visible
  `>> 8x` badge) or `remove`). Requires `brew install ffmpeg` — gated by
  e2e-test.sh. `--record-keep-raw` keeps `recording-raw.mov` for timing
  disputes (the published video is retimed; the burned-in timecode is the
  wall-clock reference).
- **Artifacts** per scenario dir: `timeline.json` (raw step offsets),
  `video.mp4`, `video.json` (published duration + remapped seek chapters).
  `e2e-report.sh` stores the video content-addressed (`images/<sha>.mp4`) and
  embeds a `video` field in `report.json`; the ClaudeSpyTestResults viewer
  plays it with clickable step-seek chapters.
- **Caveats:** records the whole desktop — prefer CI VMs over personal
  machines; incidental system UI can appear; occlusion is minimized, not
  guaranteed zero, on small displays. Recording every scenario adds ~GBs per
  full run to the results repo — keep it opt-in.
```

- [ ] **Step 2: Update the CLAUDE.md doc pointer**

In `CLAUDE.md`, extend the E2E testing reference line:

```markdown
- **E2E testing:** `docs/e2e-testing.md` - Test framework, running tests, writing scenarios, video recording (`--record`, issue #621)
```

- [ ] **Step 3: Acceptance sweep (issue #621 checklist)**

Work through the issue's acceptance criteria, noting each result:

1. **Video per scenario, finalized on failure:** run a recorded scenario known to fail (temporarily edit any scenario to assert a wrong string, or pick a currently-red one): `./scripts/e2e-test.sh --skip-build --record --scenario "<name>"` → `video.mp4` exists and the failing step renders as `[FAILED]` in the ribbon. Revert any temporary edit.
2. **Two-Mac occlusion + baselines unaffected:** covered by Task 5 Step 8 — confirm it was checked.
3. **Simulator placement:** covered by Task 5 Step 9.
4. **Seek accuracy:** covered by Task 7 Step 4 (chapter click lands on the frame whose burned ribbon names that step).
5. **Dead-time compression with size reduction:** compare `rawDurationSeconds` vs `durationSeconds` and `ls -l` of raw vs published on a wait-heavy scenario (Task 5 Step 7 output) — record the numbers in the PR description.
6. **Timecode truthful through compressed spans:** with `--record-keep-raw`, pick a step that follows a sped-up span; the published video's timecode at that step must match the raw take's wall clock at the same step boundary (±1s).
7. **Content-addressed publish + viewer seek:** Task 6 Step 6 + Task 7 Step 4.
8. **No perturbation:** on the CI VM, run the full suite recorded once (`./scripts/e2e-test.sh --record`) and compare pass/fail against the latest unrecorded run of the same commit. Any scenario that fails only under `--record` is a stage-layout bug to fix before merge (likely suspects: popover-direction changes from a lane move — fix by adjusting that instance's lane, never by resizing).

- [ ] **Step 4: Commit**

```bash
git add docs/e2e-testing.md CLAUDE.md
git commit -m "docs: e2e video recording (--record) reference (#621)"
```

- [ ] **Step 5: Open the PR**

```bash
git push -u origin HEAD
gh pr create --title "E2E: record scenario runs as one-take video (#621)" --body "..."
```

Include in the body: the acceptance-sweep results (esp. criteria 5, 6, 8 numbers), a link to a published recorded run in ClaudeSpyTestResults, and `Closes #621`. Then work through the pr-checklist hook's items (docs and e2e items are already covered by Task 8).

---

## Self-Review Notes

- **Spec coverage:** capture (Task 2/3), stage layout incl. moves-only + Simulator (Task 1/5), timeline (Task 3), post-processing with labels-before-retiming + freeze compression + ⏩-equivalent indicator (Task 4), ffmpeg dependency gate (Task 5), publishing via `store_artifact` + `video` field (Task 6), viewer with remapped step-seek (Task 7), opt-in storage policy + raw-take opt-in (`--record`, `--record-keep-raw`; failed-only publishing was considered and deliberately deferred — recording itself is opt-in), accepted tradeoffs documented (Task 8). All 8 acceptance criteria mapped in Task 8 Step 3.
- **Known risk called out:** moving instance-1 windows can flip popover anchoring direction near screen edges, which would change what a popover screenshot captures. Acceptance criterion 8 (recorded full run on a VM) is the guard; the fix lever is lane placement, never resizing.
- **Type consistency:** `ScreenRecording.start(outputURL:)/stop()`, `RecordingCoordinator.PostProcessor = (URL, URL) async -> Void` (raw, timeline), `TestOrchestrator.scenarioDirName(for:)`, `video.json` keys (`durationSeconds`, `steps[].start` published) match between Tasks 3→4→6→7.
