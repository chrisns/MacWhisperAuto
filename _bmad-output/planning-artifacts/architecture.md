---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
inputDocuments:
  - '_bmad-output/planning-artifacts/prd.md'
  - '_bmad-output/planning-artifacts/prd-validation-report.md'
  - '_bmad-output/planning-artifacts/research/technical-macwhisper-accessibility-automation-research-2026-02-06.md'
  - '_bmad-output/planning-artifacts/research/browser-extension-meeting-detection-research-2026-02-06.md'
  - '_bmad-output/brainstorming/brainstorming-session-2026-02-06.md'
workflowType: 'architecture'
lastStep: 8
status: 'complete'
completedAt: '2026-02-06'
project_name: 'MacWhisperAuto'
user_name: 'Cns'
date: '2026-02-06'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements (44 FRs across 8 subsystems):**

| Subsystem | FRs | Architectural Role |
|-----------|-----|-------------------|
| Meeting Detection | FR1-FR9 | Signal ingestion layer — 6 platforms, 4 detection mechanisms (CoreAudio, IOPMAssertion, CGWindowList, WebSocket) |
| State Machine | FR10-FR13 | Central orchestrator — debounce, switchover, sleep/wake recovery |
| MacWhisper Automation | FR14-FR21 | Action layer — AX automation start/stop, launch, error recovery, FaceTime fallback |
| Menu Bar Interface | FR22-FR25 | Presentation layer — state indicator, activity log, current meeting, force-quit |
| Permission & Lifecycle | FR26-FR29, FR42-FR43 | Bootstrap & health — permission checks, onboarding, readiness confirmation, login item |
| Browser Extension | FR30-FR36, FR44 | Remote signal source — tab monitoring, DOM inspection, reconnection, graceful degradation |
| WebSocket Communication | FR37-FR38 | Bridge protocol — localhost server, stateless heartbeat reconstruction |
| Logging & Diagnostics | FR39-FR41 | Observability — system log, rotating file log, structured evidence events |

**Non-Functional Requirements (16 NFRs):**

| Category | Key Constraints | Architectural Impact |
|----------|----------------|---------------------|
| Performance | CGWindowList <2ms, CPU <0.1% idle, signal processing <100ms, AX <1s | Polling budgets, gated detection, lightweight processing |
| Reliability | Sleep/wake auto-recovery, extension reconnect <30s, AX re-query always, graceful degradation, 10MB log cap | Stateless design, no cached references, per-layer independence |
| Integration | AX timeout config, localhost-only WebSocket, malformed message tolerance, CoreAudio off main thread, port conflict alerting | Threading discipline, defensive protocol handling, permission monitoring |

**Scale & Complexity:**

- Primary domain: macOS system integration / desktop utility
- Complexity level: Low-medium (single user, no persistence, no external network) with high integration complexity (7 macOS frameworks, 6 meeting platforms, browser extension)
- Estimated architectural components: ~8 (Detection Engine, State Machine, MacWhisper Controller, Menu Bar UI, Permission Manager, WebSocket Server, Logger, Browser Extension)

### Technical Constraints & Dependencies

- **macOS 26 (Tahoe) only** — no backward compatibility, enables macOS 14.2+ CoreAudio Process APIs
- **Non-sandboxed** — required for Accessibility and IOKit access
- **Single process** — all detection, automation, and serving in one process (no XPC, no helper)
- **No persistence** — state is ephemeral, reconstructed from live signals each poll cycle
- **Two codebases** — Swift (host app) and JavaScript (MV3 extension), connected by WebSocket
- **AppKit + SwiftUI hybrid** — NSStatusBar for menu bar control, SwiftUI for popover content
- **LSUIElement** — menu bar only, no dock icon
- **Permissions:** Accessibility (AX automation + AXObserver), Screen Recording (CGWindowList window titles)
- **External dependency: MacWhisper.app** — AX automation is the sole control interface; no API, no CLI, no AppleScript dictionary

### Cross-Cutting Concerns Identified

1. **Threading coordination** — CoreAudio callbacks on dedicated queue, WebSocket events on Network.framework queue, AX automation blocking calls, UI updates on main thread. All must converge safely on the state machine without blocking or racing.

2. **Permission lifecycle** — Accessibility and Screen Recording can be revoked at any time (especially after macOS updates). Detection layers must degrade gracefully when permissions are missing, and the UI must alert the user.

3. **Error recovery & self-healing** — Sleep/wake, MacWhisper crashes/restarts, extension disconnects, AX timeout. The stateless polling model is the primary recovery mechanism, but each failure mode needs explicit handling.

4. **Logging & observability** — Every detection signal, state transition, and automation action must be logged for both runtime diagnostics (os_log) and evidence collection (rotating file). Logging spans all components.

5. **MacWhisper coupling** — The entire action layer depends on MacWhisper's accessibility tree structure. AX element queries are re-discovered each time (never cached), but structural UI changes in MacWhisper would still break automation. This is the project's primary fragility.

## Starter Template Evaluation

### Primary Technology Domain

Native macOS system integration utility — Swift with AppKit+SwiftUI hybrid, plus Chromium MV3 browser extension in JavaScript. Two separate codebases in one repository.

### Starter Options Considered

**macOS Host App:**

The macOS desktop app ecosystem does not have a rich starter template culture comparable to web frameworks. Options are:

| Option | What It Provides | Fit |
|--------|-----------------|-----|
| Xcode macOS App template | Basic AppDelegate, window, SwiftUI entry point | Good — needs reconfiguration for menu bar app |
| Swift Package Manager CLI | Package.swift, no Xcode project | Poor — no entitlements, no Info.plist, no asset catalog |
| Manual Xcode project | Full control from line one | Best — menu bar apps need specific LSUIElement, entitlements, non-sandbox config that no template provides |

**Browser Extension:**

| Option | What It Provides | Fit |
|--------|-----------------|-----|
| Chrome Extension MV3 boilerplate generators | manifest.json, service worker skeleton | Marginal — our extension is simple enough that a manifest + 2 JS files covers it |
| Manual manifest + scripts | Full control, no generator overhead | Best — the research doc already contains a complete manifest.json and architecture |

### Selected Approach: Manual Project Setup (No External Starter)

**Rationale:**

1. **No suitable macOS menu bar app starter exists** — available templates target standard windowed apps, not LSUIElement menu bar utilities with non-sandboxed entitlements
2. **Zero external dependencies is a design principle** — introducing a generator/template tool contradicts the stopgap philosophy
3. **The research documents already contain the complete project skeleton** — file structure, entitlements, manifest.json, and architectural patterns are fully specified
4. **Two codebases are trivially small** — the host app is ~8 Swift source files across 5 directories; the extension is manifest.json + 2-3 JS files

**Initialization:**

```
# Xcode project creation (manual)
# 1. New > Project > macOS > App
# 2. Product Name: MacWhisperAuto
# 3. Interface: SwiftUI, Language: Swift
# 4. Uncheck: Include Tests (add later if needed)
# 5. Disable sandbox in Signing & Capabilities
# 6. Add entitlements file with non-sandbox + network server/client
# 7. Set LSUIElement = true in Info.plist
# 8. Replace SwiftUI App entry with AppDelegate-based lifecycle
```

### Architectural Decisions Established by Project Setup

**Language & Runtime:**
- Swift 6 (macOS 26 SDK), strict concurrency checking enabled
- JavaScript ES2022+ for browser extension (Chrome 116+ baseline)

**Build Tooling:**
- Xcode 18 (macOS 26 SDK) for host app — no SPM dependencies, no CocoaPods, no external build tools
- No build step for browser extension — plain JS loaded directly by Chrome

**Code Organization (from research doc):**
```
MacWhisperAuto/
├── Sources/
│   ├── App/           (AppDelegate, StatusBarController, Info.plist)
│   ├── Core/          (AppState, MeetingStateMachine, DebounceTimer)
│   ├── Detection/     (PlatformDetector protocol, per-platform detectors)
│   ├── Automation/    (MacWhisperController, AccessibilityHelper)
│   └── Networking/    (WebSocketServer, MessageProtocol)
├── Entitlements/
│   └── MacWhisperAuto.entitlements
├── Extension/
│   ├── manifest.json
│   ├── background.js
│   ├── content-script.js
│   └── icons/
└── Resources/
    └── Assets.xcassets (menu bar icons)
```

**Testing:** Deferred — stopgap project, POC scripts serve as validation. Unit tests may be added for the state machine if time permits.

**Note:** Project initialization (Xcode project creation + entitlements + Info.plist configuration) should be the first implementation story.

## Core Architectural Decisions

### Decision Priority Analysis

**Critical Decisions (Block Implementation):**
1. Threading & concurrency model — determines how all components interact safely
2. Detection architecture — defines the plugin interface for all 6 platforms
3. State machine design — the central orchestrator all code feeds into

**Important Decisions (Shape Architecture):**
4. AX automation execution pattern — affects reliability and UI responsiveness
5. Logging architecture — spans all components
6. Menu bar UI binding — determines SwiftUI/AppKit integration pattern

**Deferred Decisions (Post-MVP):**
- FaceTime multi-step AX automation path — Phase 2 stretch, depends on core automation working
- Browser extension reconnection tuning — Phase 3, tune exponential backoff in practice
- Log format for MacWhisper developer evidence — refine after collecting real data

### Threading & Concurrency

**Decision:** Hybrid — @MainActor for state machine and UI, GCD dispatch queues for C API callbacks, dedicated serial queue for AX automation

**Rationale:** CoreAudio, IOKit, Accessibility, and CGWindowList are C-based frameworks that deliver callbacks on dispatch queues. Fighting Swift 6 strict concurrency to bridge these into pure actor isolation adds friction without value in a stopgap project. The state machine is @MainActor because it drives UI updates. AX automation runs on a dedicated serial queue to prevent UI blocking and serialise concurrent automation requests.

**Threading Map:**

| Component | Thread/Queue | Why |
|-----------|-------------|-----|
| CoreAudio listeners | Dedicated `DispatchQueue` (per research) | C API requirement |
| IOPMAssertion polling | Timer on main run loop or background queue | Lightweight, 3s interval |
| CGWindowList polling | Timer on main run loop | Sub-millisecond, safe on main |
| WebSocket server | Network.framework managed queue | Framework requirement |
| AX automation | Dedicated serial `DispatchQueue("ax")` | Blocking calls, must be off main |
| State machine | @MainActor | Drives UI, must be thread-safe |
| UI updates | @MainActor (main thread) | AppKit/SwiftUI requirement |

**Convergence pattern:** All detection signals dispatch to @MainActor to update the state machine. State machine transitions trigger side effects (AX automation, timer management) dispatched to appropriate queues. Results return to @MainActor.

### Detection Architecture

**Decision:** Protocol-based detectors with common `MeetingSignal` type, coordinated by a `DetectionCoordinator`

**Rationale:** Each detection layer (CoreAudio, IOPMAssertion, CGWindowList, WebSocket, NSWorkspace) operates independently with different mechanisms and permissions. A common protocol allows adding/removing detectors per phase without changing the state machine. The coordinator aggregates signals and feeds the state machine.

**Interface:**

```swift
protocol MeetingDetector {
    var isEnabled: Bool { get }
    func start()
    func stop()
    // Reports signals via callback to DetectionCoordinator
}

struct MeetingSignal {
    let platform: Platform
    let isActive: Bool
    let confidence: SignalConfidence  // .high, .medium, .low
    let source: SignalSource          // .coreAudio, .iopmAssertion, .cgWindowList, .webSocket, .nsWorkspace
    let timestamp: Date
}
```

**Affects:** All FR1-FR9 detection requirements, Phase 1-3 scoping (add detectors incrementally)

### State Machine

**Decision:** Enum-based finite state machine with explicit transition function

**Rationale:** Four states with compiler-enforced exhaustive transitions prevent invalid state combinations. Debounce timers are side effects of state transitions, not separate state. Meeting switchover is a compound transition: `recording(A) → idle → detecting(B)`.

**States:**

```swift
enum MeetingState {
    case idle
    case detecting(platform: Platform, since: Date)
    case recording(platform: Platform)
    case error(ErrorKind)
}
```

**Transition rules:**
- `idle` + signal(active) → `detecting(platform, now)`
- `detecting` + 5s elapsed with consistent signals → `recording(platform)` + trigger AX start
- `recording` + signal(inactive) → start 15s grace timer
- `recording` + 15s grace expired → `idle` + trigger AX stop
- `recording(A)` + signal(active, B) → `idle` + AX stop A, then `detecting(B)`
- Any state + AX timeout → `error(.macWhisperUnresponsive)`

**Affects:** FR10-FR13 (state machine), FR14-FR16 (automation triggers), FR22 (UI state display)

### AX Automation Execution

**Decision:** Dedicated serial dispatch queue for all accessibility automation calls

**Rationale:** AX calls are synchronous and can block for up to 5 seconds (timeout). A serial queue ensures: (1) UI thread never blocks, (2) concurrent automation requests are serialised (prevents race if meeting switchover triggers stop+start), (3) timeout is handled by AXUIElementSetMessagingTimeout without needing async cancellation.

**Pattern:**

```swift
private let axQueue = DispatchQueue(label: "com.macwhisperauto.ax-automation")

func startRecording(for platform: Platform) {
    axQueue.async { [weak self] in
        let result = self?.performAXStart(platform: platform)
        DispatchQueue.main.async {
            self?.handleAXResult(result)
        }
    }
}
```

**Affects:** FR14-FR21 (all MacWhisper automation), NFR4 (AX timeout), NFR8 (re-query always)

### Logging Architecture

**Decision:** Unified `DetectionLogger` that writes to both `os_log` and a rotating JSON-lines file

**Rationale:** Every detection event, state transition, and automation action must be logged to two destinations (FR39-FR41). A unified logger ensures consistency and prevents missed events. The file log uses JSON lines format for easy parsing when sharing evidence with the MacWhisper developer.

**Structure:**
- **os_log:** subsystem `com.macwhisperauto`, categories: `detection`, `stateMachine`, `automation`, `webSocket`, `permissions`
- **File log:** `~/Library/Logs/MacWhisperAuto/detection.jsonl`, JSON lines, rotated at 10MB (NFR10)
- **Log entry:** `{ "ts": ISO8601, "cat": "detection", "platform": "teams", "signal": "coreAudio", "active": true, "action": "none", "state": "idle" }`

**Affects:** FR39-FR41 (logging), NFR10 (rotation cap)

### Menu Bar UI Binding

**Decision:** `@Observable` app state class, SwiftUI for popover content, imperative AppKit for status item icon

**Rationale:** macOS 26 fully supports Swift Observation framework. The `AppState` class (wrapping or exposing state machine state) is `@Observable @MainActor`. SwiftUI views in the popover observe it directly with zero boilerplate. The `NSStatusItem` button image is updated imperatively via a `withObservationTracking` observer or property `didSet`, since NSStatusItem doesn't support SwiftUI binding.

**Affects:** FR22-FR25 (menu bar UI), the presentation layer boundary

### Decision Impact Analysis

**Implementation Sequence:**
1. State machine (enum + transitions) — foundation everything feeds into
2. Detection protocol + coordinator — signal pipeline
3. Teams detector (CoreAudio + IOPMAssertion) — first concrete detector
4. AX automation queue + MacWhisper controller — action layer
5. Menu bar UI + AppState binding — user-visible layer
6. Logging infrastructure — observability across all components
7. CGWindowList detectors (Zoom, Slack, Chime) — Phase 2
8. WebSocket server + extension communication — Phase 3

**Cross-Component Dependencies:**
- State machine depends on nothing, everything depends on state machine
- Detection coordinator depends on state machine + detector protocol
- AX automation depends on state machine transitions (side effects)
- UI depends on state machine state (@Observable)
- Logger is called from all components but has no upstream dependencies

## Implementation Patterns & Consistency Rules

### Critical Conflict Points Identified

8 areas where AI agents could implement differently without explicit guidance. These patterns ensure any agent touching this codebase produces compatible code.

### Naming Patterns

**Swift Code (Host App):**
- Types: `PascalCase` — `MeetingStateMachine`, `TeamsDetector`, `MacWhisperController`
- Properties/functions: `camelCase` — `isRecording`, `startDetection()`, `handleSignal(_:)`
- Enum cases: `camelCase` — `.idle`, `.detecting`, `.recording`
- Constants: `camelCase` in type scope — `static let pollInterval: TimeInterval = 3.0`
- Protocols: `PascalCase`, noun or adjective — `MeetingDetector`, `Observable`
- File names: Match primary type — `MeetingStateMachine.swift`, `TeamsDetector.swift`
- One primary type per file (small helpers/extensions can coexist)

**JavaScript Code (Extension):**
- Variables/functions: `camelCase` — `activeMeetings`, `detectPlatformFromUrl()`
- Constants: `SCREAMING_SNAKE` — `MAX_RECONNECT_DELAY`, `KEEPALIVE_INTERVAL`
- Object keys in messages: `snake_case` — `{ "active_meetings": [], "tab_id": 123 }` (already established in research protocol)

**Logging:**
- os_log subsystem: `com.macwhisperauto`
- os_log categories: `detection`, `stateMachine`, `automation`, `webSocket`, `permissions`, `lifecycle`
- File log keys: `snake_case` — `{ "ts": "...", "cat": "detection", "platform": "teams" }`

### Structure Patterns

**Detector Organization:**
- One file per platform detector: `TeamsDetector.swift`, `ZoomDetector.swift`, `SlackDetector.swift`, etc.
- All detectors in `Sources/Detection/`
- Shared protocol and signal types in `Sources/Detection/MeetingDetector.swift`
- `DetectionCoordinator.swift` in `Sources/Core/` (it orchestrates, not detects)

**State Machine:**
- `MeetingState` enum and `MeetingStateMachine` class in `Sources/Core/MeetingStateMachine.swift`
- Side effects returned as values from transition function, not executed inside it
- Timers managed by the state machine class, not by individual detectors

**Automation:**
- `MacWhisperController.swift` — public interface for start/stop/check/launch
- `AccessibilityHelper.swift` — low-level AX element query and action utilities
- Both in `Sources/Automation/`

### Communication Patterns

**Detector → Coordinator (Signal Reporting):**
- **Pattern: Closure callback** — each detector receives a `onSignal: (MeetingSignal) -> Void` closure at init
- NOT delegates (too heavy for this), NOT Combine (unnecessary dependency), NOT AsyncStream (C API callbacks don't compose well)
- Detectors call the closure from whatever queue they're on; the coordinator dispatches to @MainActor

```swift
// Pattern: Detector reports via closure
class TeamsDetector: MeetingDetector {
    private let onSignal: (MeetingSignal) -> Void

    init(onSignal: @escaping (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    // Called from CoreAudio callback queue
    private func handleAudioDeviceChange(isRunning: Bool) {
        onSignal(MeetingSignal(
            platform: .teams,
            isActive: isRunning,
            confidence: .high,
            source: .coreAudio,
            timestamp: Date()
        ))
    }
}
```

**State Machine → Side Effects:**
- Transition function returns `(newState, [SideEffect])` — effects are dispatched by the caller, not inside the state machine
- Side effect enum: `.startRecording(Platform)`, `.stopRecording`, `.startTimer(duration, id)`, `.cancelTimer(id)`, `.logTransition(from, to)`

```swift
// Pattern: Pure transition function
func transition(from state: MeetingState, on signal: MeetingSignal) -> (MeetingState, [SideEffect]) {
    switch (state, signal.isActive) {
    case (.idle, true):
        return (.detecting(platform: signal.platform, since: signal.timestamp),
                [.startTimer(duration: 5.0, id: .startDebounce)])
    // ... exhaustive cases
    }
}
```

**AX Results → State Machine:**
- AX completion dispatches result to @MainActor as `MeetingSignal` with source `.axAutomation`
- Success/failure both reported — the state machine handles both

### Error Handling Patterns

**Swift Error Strategy:**
- **AX automation:** Returns `Result<Void, AXError>` — callers pattern-match on success/failure
- **Detection layers:** Never throw — log errors and continue. A failed detector doesn't crash the app; it produces no signals (graceful degradation per NFR9)
- **WebSocket:** Log and discard malformed messages (NFR14). Connection errors trigger reconnection, not crashes
- **Permission checks:** Return `Bool` — the UI layer translates to user-facing guidance

**Error types:**

```swift
enum AXError: Error {
    case macWhisperNotRunning
    case elementNotFound(description: String)
    case actionFailed(element: String, action: String)
    case timeout
}

enum AppError {
    case permissionDenied(Permission)
    case macWhisperUnresponsive
    case webSocketPortUnavailable
}
```

**Anti-pattern:** Never use `try!` or `fatalError()` in production code. Never silently swallow errors — always log before discarding.

### Timer Patterns

**Decision:** `DispatchSourceTimer` for all timers (debounce, polling, grace periods)

**Rationale:** Consistent with the GCD-based threading model. `Timer` requires a run loop (fragile on background threads). `Task.sleep` doesn't integrate with the GCD callback pattern.

```swift
// Pattern: Debounce timer
private var debounceTimer: DispatchSourceTimer?

func startDebounce(duration: TimeInterval, id: TimerID) {
    cancelTimer(id: id)
    let timer = DispatchSourceTimer.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + duration)
    timer.setEventHandler { [weak self] in
        self?.handleTimerFired(id: id)
    }
    timer.resume()
    debounceTimer = timer
}
```

### Access Control Patterns

- Types intended for cross-module use: not applicable (single module)
- Default: `internal` (Swift default) — don't add explicit `internal`
- Mark implementation details `private` — AX helper internals, timer storage, callback plumbing
- Mark protocol conformance methods as required by protocol (no extra access modifier)
- **Never use `open`** — no subclassing design in this project
- **Never use `public`** — single target, no framework

### os_log Level Guidelines

| Level | When to Use | Example |
|-------|------------|---------|
| `.debug` | Detailed signal values, timer ticks, AX element queries | "CoreAudio device 121 isRunning: true" |
| `.info` | State transitions, detection events, connection events | "State: idle → detecting(teams)" |
| `.default` | Automation actions, recording start/stop | "Started recording for Teams" |
| `.error` | Failures that affect functionality | "AX timeout: MacWhisper unresponsive" |
| `.fault` | Should never happen (programming errors) | "State machine in invalid state" |

### Enforcement Guidelines

**All AI Agents MUST:**
1. Follow the closure callback pattern for detector → coordinator communication
2. Return side effects from state machine transitions — never execute effects inside the transition function
3. Run AX automation on the dedicated serial queue, never on main
4. Log every detection signal and state transition to both os_log and file logger
5. Re-query AX elements before every automation action — never cache element references
6. Use `DispatchSourceTimer` for all timers, never `Timer` or `Task.sleep`
7. Handle all errors gracefully — no `try!`, no `fatalError()`, no silent swallowing

**Anti-Patterns (Never Do):**
- Combine publishers for detector communication (over-engineered for closures)
- Caching AX element references across calls (they go stale)
- Blocking main thread for AX calls or network operations
- Using `async/await` to bridge C API callbacks (friction without value)
- Adding external SPM/CocoaPods dependencies
- Creating test targets without being asked (stopgap project)

## Project Structure & Boundaries

### Complete Project Directory Structure

```
MacWhisperAuto/
├── MacWhisperAuto.xcodeproj/
├── MacWhisperAuto/
│   ├── Info.plist
│   ├── MacWhisperAuto.entitlements
│   │
│   ├── Sources/
│   │   ├── App/
│   │   │   ├── AppDelegate.swift              # NSApplicationDelegate, app lifecycle, wires components
│   │   │   └── StatusBarController.swift       # NSStatusItem management, icon updates, popover hosting
│   │   │
│   │   ├── Core/
│   │   │   ├── AppState.swift                  # @Observable @MainActor — shared state for UI binding
│   │   │   ├── MeetingStateMachine.swift       # MeetingState enum, transition function, side effects
│   │   │   ├── DetectionCoordinator.swift      # Collects signals from all detectors, feeds state machine
│   │   │   ├── Platform.swift                  # Platform enum (.teams, .zoom, .slack, .faceTime, .chime, .browser)
│   │   │   └── Types.swift                     # MeetingSignal, SignalConfidence, SignalSource, SideEffect, TimerID
│   │   │
│   │   ├── Detection/
│   │   │   ├── MeetingDetector.swift           # MeetingDetector protocol definition
│   │   │   ├── AppMonitor.swift                # NSWorkspace observer — tracks running meeting apps (FR8-FR9)
│   │   │   ├── TeamsDetector.swift             # CoreAudio virtual device + IOPMAssertion (FR1-FR2)
│   │   │   ├── ZoomDetector.swift              # CGWindowList "Zoom Meeting" title match (FR3)
│   │   │   ├── SlackDetector.swift             # CGWindowList "huddle" title match (FR4)
│   │   │   ├── FaceTimeDetector.swift          # CoreAudio process-level mic + on-screen window (FR5)
│   │   │   ├── ChimeDetector.swift             # CGWindowList "Amazon Chime: Meeting Controls" (FR6)
│   │   │   └── CGWindowListScanner.swift       # Shared CGWindowList polling infrastructure (FR3-FR6, FR8)
│   │   │
│   │   ├── Automation/
│   │   │   ├── MacWhisperController.swift      # Start/stop/check recording, launch, force-quit (FR14-FR21)
│   │   │   └── AccessibilityHelper.swift       # Low-level AX element query, action, timeout utilities
│   │   │
│   │   ├── Networking/
│   │   │   ├── WebSocketServer.swift           # Network.framework NWListener + NWProtocolWebSocket (FR37)
│   │   │   └── ExtensionMessageHandler.swift   # Parse/route extension messages, heartbeat state reconstruction (FR38)
│   │   │
│   │   ├── Permissions/
│   │   │   └── PermissionManager.swift         # AX + Screen Recording check/prompt, revocation detection (FR26-FR28)
│   │   │
│   │   ├── Logging/
│   │   │   └── DetectionLogger.swift           # Unified os_log + rotating JSON-lines file logger (FR39-FR41)
│   │   │
│   │   └── UI/
│   │       ├── StatusMenuView.swift            # SwiftUI popover: state display, activity log, controls (FR22-FR25)
│   │       ├── OnboardingView.swift            # Permission guidance, readiness confirmation (FR27, FR42-FR43)
│   │       └── ErrorView.swift                 # Error state display, force-quit option (FR25, FR18-FR19)
│   │
│   └── Resources/
│       └── Assets.xcassets/
│           ├── AppIcon.appiconset/
│           └── StatusBarIcons/                 # idle, detecting, recording, error icon variants
│
├── Extension/
│   ├── manifest.json                           # MV3 manifest (FR30-FR36)
│   ├── background.js                           # Service worker: tabs API, WebSocket client, state management
│   ├── content-script.js                       # DOM inspection, MutationObserver, keyword scanning
│   └── icons/
│       ├── icon16.png
│       ├── icon48.png
│       └── icon128.png
│
├── poc/                                        # Existing POC scripts (reference, not shipped)
│   ├── dump-ax-tree.swift
│   ├── trigger-record.swift
│   ├── stop-record.swift
│   └── explore-app-audio.swift
│
└── .gitignore
```

### Architectural Boundaries

**Boundary 1: Detection → Core (Signal Boundary)**
- Detectors produce `MeetingSignal` values via closure callbacks
- Detectors know nothing about the state machine, UI, or automation
- `DetectionCoordinator` is the sole consumer of detector signals
- Direction: Detection → Core (one-way)

**Boundary 2: Core → Automation (Side Effect Boundary)**
- State machine produces `[SideEffect]` values from transitions
- `DetectionCoordinator` dispatches side effects to `MacWhisperController`
- Automation knows nothing about detection or state — it executes commands
- Direction: Core → Automation (one-way, results return as signals)

**Boundary 3: Core → UI (Observation Boundary)**
- `AppState` (@Observable) exposes state machine state to SwiftUI
- UI reads state but never writes to state machine directly
- User actions (force-quit, retry) dispatch through `AppDelegate` to appropriate handler
- Direction: Core → UI (read-only observation) + UI → AppDelegate (user actions)

**Boundary 4: Extension ↔ Networking (WebSocket Boundary)**
- Browser extension communicates exclusively via JSON messages over WebSocket
- `ExtensionMessageHandler` parses messages into `MeetingSignal` values
- Host app sends acks and config via `WebSocketServer`
- Direction: Bidirectional, but stateless — any single heartbeat reconstructs full state

**Boundary 5: Logging (Cross-Cutting, No Boundary)**
- `DetectionLogger` is injected into all components
- Every component logs; no component depends on log output
- Logger has zero upstream dependencies

### Requirements to Structure Mapping

| FR Category | Primary Files | Phase |
|-------------|--------------|-------|
| FR1-FR2: Teams Detection | `TeamsDetector.swift` | 1 |
| FR3: Zoom Detection | `ZoomDetector.swift`, `CGWindowListScanner.swift` | 2 |
| FR4: Slack Detection | `SlackDetector.swift`, `CGWindowListScanner.swift` | 2 |
| FR5: FaceTime Detection | `FaceTimeDetector.swift` | 2 |
| FR6: Chime Detection | `ChimeDetector.swift`, `CGWindowListScanner.swift` | 2 |
| FR7: Browser Detection | `Extension/background.js`, `Extension/content-script.js` | 3 |
| FR8-FR9: App Gating | `AppMonitor.swift`, `CGWindowListScanner.swift` | 2 |
| FR10-FR13: State Machine | `MeetingStateMachine.swift`, `Types.swift` | 1 |
| FR14-FR21: MacWhisper Automation | `MacWhisperController.swift`, `AccessibilityHelper.swift` | 1 |
| FR22-FR25: Menu Bar UI | `StatusBarController.swift`, `StatusMenuView.swift` | 1 |
| FR26-FR29, FR42-FR43: Permissions | `PermissionManager.swift`, `OnboardingView.swift` | 1 |
| FR30-FR36, FR44: Browser Extension | `Extension/*` | 3 |
| FR37-FR38: WebSocket Server | `WebSocketServer.swift`, `ExtensionMessageHandler.swift` | 3 |
| FR39-FR41: Logging | `DetectionLogger.swift` | 1 |

### Data Flow

```
┌─────────────────────────────────────────────────────────┐
│                    Browser Extension                     │
│  background.js ←→ content-script.js                     │
└────────────────────────┬────────────────────────────────┘
                         │ WebSocket (JSON messages)
                         ▼
┌─────────────────────────────────────────────────────────┐
│                     Host App                             │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ AppMonitor   │  │TeamsDetector │  │ WebSocket     │  │
│  │ (NSWorkspace)│  │(CoreAudio+   │  │ Server        │  │
│  │              │  │ IOPMAssertion│  │ (Network.fw)  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬────────┘  │
│         │                 │                  │           │
│         │    MeetingSignal closures          │           │
│         ▼                 ▼                  ▼           │
│  ┌──────────────────────────────────────────────────┐   │
│  │          DetectionCoordinator (@MainActor)        │   │
│  └──────────────────────┬───────────────────────────┘   │
│                         │ signal                         │
│                         ▼                                │
│  ┌──────────────────────────────────────────────────┐   │
│  │       MeetingStateMachine (@MainActor)            │   │
│  │  transition(state, signal) → (newState, effects)  │   │
│  └──────────┬────────────────────────┬──────────────┘   │
│             │ side effects           │ @Observable       │
│             ▼                        ▼                   │
│  ┌────────────────────┐   ┌─────────────────────┐       │
│  │ MacWhisperController│   │ AppState → SwiftUI  │       │
│  │ (serial AX queue)  │   │ StatusMenuView      │       │
│  └────────────────────┘   └─────────────────────┘       │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  DetectionLogger (os_log + file) — all components │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Development Workflow

**Build:** Xcode 18 → Build & Run (Cmd+R). No pre-build steps, no code generation, no dependency fetch.

**Extension Development:** Edit JS files in `Extension/`, reload unpacked extension in Comet via `comet://extensions`.

**Debugging:** Console.app for os_log output (filter subsystem `com.macwhisperauto`). JSON log file at `~/Library/Logs/MacWhisperAuto/detection.jsonl`.

**Distribution:** Build in Xcode, copy `.app` to `/Applications`. Copy `Extension/` folder for browser extension side-loading.

## Architecture Validation Results

### Coherence Validation

**Decision Compatibility:** PASS
- All technology choices (Swift 6, @MainActor, GCD, @Observable, Network.framework) are mutually compatible
- No version conflicts — single SDK target (macOS 26)
- Threading model (hybrid @MainActor + GCD) is consistent across all decisions
- No contradictory decisions found

**Pattern Consistency:** PASS
- Closure callback pattern used uniformly for all inter-component communication
- DispatchSourceTimer used exclusively for all timing needs
- Error handling follows layer-appropriate strategy (Result for AX, log-and-continue for detection)
- Naming conventions are domain-consistent (Swift, JavaScript, JSON)

**Structure Alignment:** PASS
- Project structure directly supports all architectural boundaries
- Each boundary has clear file-level separation
- Data flow diagram matches directory organization
- FR mapping is complete with no orphan files

### Requirements Coverage Validation

**Functional Requirements:** 44/44 covered (100%)
- Every FR maps to at least one file in the project structure
- All three phases (MVP, Native Expansion, Browser Extension) have clear file targets
- Cross-cutting FRs (logging, permissions) have dedicated components

**Non-Functional Requirements:** 16/16 covered (100%)
- All performance targets have architectural support (gated polling, dedicated queues, benchmarked operations)
- All reliability requirements addressed (stateless design, graceful degradation, re-query pattern)
- All integration requirements specified (localhost binding, timeout config, thread isolation)

### Implementation Readiness Validation

**Decision Completeness:** PASS
- 6 core decisions documented with rationale and code examples
- Threading map covers every component
- State machine transitions explicitly specified
- Interface contracts defined in Swift (protocol, struct, enum)

**Structure Completeness:** PASS
- 22 Swift source files specified across 7 directories
- 4 extension files specified
- Every file annotated with purpose and FR mapping
- Directory layout matches architectural boundaries

**Pattern Completeness:** PASS
- 8 conflict points identified and resolved
- Code examples provided for all major patterns (detector callback, state transition, AX dispatch, timer management)
- 7 enforcement rules with explicit anti-patterns
- os_log level guidelines with concrete examples

### Gap Analysis Results

**Critical Gaps:** 0 — No blocking issues found

**Minor Gaps (4):**
1. Platform-to-MacWhisper button name mapping — add as computed property on `Platform` enum
2. Sleep/wake notification hooks — use NSWorkspace willSleep/didWake in AppDelegate
3. FaceTime multi-step AX path — explicitly deferred to Phase 2 stretch
4. Login item registration — SMAppService.mainApp.register() in AppDelegate

All minor gaps are implementation details, not architectural decisions. They do not block implementation.

### Architecture Completeness Checklist

**Requirements Analysis**
- [x] Project context thoroughly analysed (44 FRs, 16 NFRs, 8 subsystems)
- [x] Scale and complexity assessed (low-medium with high integration complexity)
- [x] Technical constraints identified (macOS 26, non-sandboxed, single process, no persistence)
- [x] Cross-cutting concerns mapped (threading, permissions, recovery, logging, MacWhisper coupling)

**Architectural Decisions**
- [x] Critical decisions documented: threading, detection architecture, state machine
- [x] Important decisions documented: AX execution, logging, UI binding
- [x] Technology stack fully specified (Swift 6, AppKit+SwiftUI, Network.framework, MV3 JS)
- [x] Integration patterns defined (closure callbacks, side effects, @Observable)

**Implementation Patterns**
- [x] Naming conventions established (Swift, JavaScript, JSON, os_log)
- [x] Structure patterns defined (one file per detector, one type per file)
- [x] Communication patterns specified (closure callbacks, side effect returns)
- [x] Process patterns documented (error handling, timer management, access control)

**Project Structure**
- [x] Complete directory structure defined (22 Swift files, 4 extension files)
- [x] Component boundaries established (5 boundaries with data flow directions)
- [x] Integration points mapped (detector→coordinator→state machine→automation/UI)
- [x] Requirements to structure mapping complete (44 FRs → specific files and phases)

### Architecture Readiness Assessment

**Overall Status:** READY FOR IMPLEMENTATION

**Confidence Level:** High

**Key Strengths:**
- Clean separation of concerns with well-defined boundaries
- State machine is the single source of truth — everything feeds in, everything flows out
- Protocol-based detection enables incremental Phase 1→2→3 delivery
- Stateless design provides inherent self-healing through any disruption
- Every FR has a concrete file target and phase assignment

**Areas for Future Enhancement:**
- FaceTime multi-step AX fallback path (Phase 2 stretch, deferred)
- Browser extension reconnection tuning (Phase 3, tune empirically)
- Evidence log format refinement (post-data-collection)
- Potential for unit testing the state machine transition function (pure function, highly testable)
