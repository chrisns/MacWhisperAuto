# MacWhisperAuto

A macOS menu bar app that automatically detects meetings across multiple platforms and triggers [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper) to record them.

MacWhisper's built-in meeting detection relies on counting UDP sockets with `lsof` -- but it's unreliable and frequently misses meetings. MacWhisperAuto is a stopgap that sits in the menu bar, watches for meetings through multiple independent signal sources, and controls MacWhisper recording via DYLD injection. It is designed to be thrown away once MacWhisper fixes their detection.

## Features

- **Multi-platform detection**: Microsoft Teams, Zoom, Slack huddles, Amazon Chime, FaceTime, and browser-based meetings (Google Meet and others)
- **Layered signal fusion**: Combines network, audio, power assertion, window list, and browser extension signals -- any single source is enough to detect a meeting
- **No special permissions for primary detection**: Network UDP socket counting works with zero extra permissions for native apps
- **Automatic recording**: Starts and stops MacWhisper recording without user intervention, via injected dylib and Unix socket IPC
- **Menu bar UI**: Shows current state (idle, detecting, recording, error) with a popover for activity history
- **Stateless polling**: Self-heals through sleep/wake cycles; no persistent state to corrupt
- **State machine with debounce**: 5-second start debounce prevents false positives; 15-second grace period prevents premature stop on transient signal loss
- **Fail long over fail short**: Would rather record a few extra seconds than miss audio. Errors don't stop an active recording
- **Login item**: Registers itself to launch at login automatically
- **Browser extension**: MV3 Chromium extension detects web-based meetings via DOM inspection and communicates over a local WebSocket

## Supported Platforms

| Platform | Native App Detection | Browser Detection |
|---|---|---|
| Microsoft Teams | Network UDP, CoreAudio, IOPMAssertion, CGWindowList | Content script |
| Zoom | Network UDP, CGWindowList | Content script |
| Slack | Network UDP, CGWindowList | Content script |
| Amazon Chime | Network UDP, CGWindowList | Content script |
| FaceTime | IOPMAssertion + CGWindowList | N/A |
| Google Meet | N/A | Content script |

## How Detection Works

### Network UDP Socket Counting (primary, no permissions)

During a call, meeting apps open many UDP sockets for RTP/SRTP media streams. Idle, they have very few. MacWhisperAuto runs `lsof -a -i UDP -n -P -c <process>` every 3 seconds and counts the sockets. If the count exceeds a threshold (e.g. 3 for Teams, 2 for Zoom), a meeting is active. This requires no special permissions.

### CoreAudio Virtual Device (Teams-specific, event-driven)

Microsoft Teams installs a "Microsoft Teams Audio" virtual audio device. MacWhisperAuto listens for `kAudioDevicePropertyDeviceIsRunningSomewhere` changes -- when Teams starts a call the device toggles to running, providing an instant event-driven signal.

### IOPMAssertion (Teams and FaceTime)

Teams creates a "Microsoft Teams Call in progress" power assertion during calls. FaceTime holds a `PreventUserIdleSystemSleep` assertion. These are checked every 3 seconds via `IOPMCopyAssertionsByProcess()` with no special permissions.

### CGWindowList (all native apps, needs Screen Recording)

A single `CGWindowListCopyWindowInfo` call per 3-second cycle (completes in under 2ms with `.optionOnScreenOnly`) is distributed to all detectors. Each detector checks for platform-specific window title patterns:

- **Teams**: Window title ends with "| Microsoft Teams" and does not start with known non-meeting prefixes (Chat, Calendar, etc.)
- **Zoom**: Window title contains "Zoom Meeting" or "Zoom Webinar"
- **Slack**: Window title contains "huddle" (case-insensitive)
- **Chime**: Window title is "Amazon Chime: Meeting Controls"
- **FaceTime**: FaceTime window visible on layer 0 (combined with IOPMAssertion for positive detection)

### Browser Extension (web meetings via WebSocket)

A Chromium MV3 extension injects content scripts into meeting pages. The content scripts inspect the DOM for platform-specific indicators (mute buttons, call controls, participant lists) and report to the service worker, which maintains a WebSocket connection to `ws://127.0.0.1:8765`. The host app receives heartbeats every 20 seconds with the full list of active meetings. Supported web platforms: Google Meet, Teams Web, Zoom Web, Slack Web, Chime Web.

## How Recording Works (DYLD Injection)

MacWhisper has no AppleScript dictionary, no CLI, and no usable URL scheme. MacWhisperAuto uses DYLD injection to control it from inside its own process:

1. **Prepare**: On first launch, copies MacWhisper.app to `~/Library/Application Support/MacWhisperAuto/Injectable/`, re-signs it ad-hoc with `com.apple.security.cs.allow-dyld-environment-variables`, and compiles an Objective-C dylib from embedded source
2. **Launch**: Runs the re-signed copy with `DYLD_INSERT_LIBRARIES` pointing to the dylib
3. **Control**: The dylib creates a Unix socket at `/tmp/macwhisper_control.sock` and accepts commands:
   - `ax_record Record <Platform>` -- presses per-app recording buttons via in-process AX (no TCC permission needed)
   - `ax_status` -- scans the AX tree for "Active Recordings" to check recording state
   - `stop` -- calls `stopRecordingMeeting` on MacWhisper's `StatusBarItemManager` via ObjC runtime
   - `dismiss` -- breaks modal dialogs (e.g. "Move to Applications") via `[NSApp abortModal]`

The dylib also auto-dismisses MacWhisper's broken meeting detection dialogs before pressing recording buttons, and handles the case where a false-positive recording is already active (stops it first).

## Architecture

```
Extension/                  # MV3 Chromium browser extension
  background.js             # Service worker: WebSocket client, tab tracking
  content-script.js         # DOM-based meeting detection per platform
  manifest.json

Sources/
  App/
    main.swift              # Entry point (NSApplication)
    AppDelegate.swift       # Wires everything together, system notifications
    StatusBarController.swift # Menu bar item + popover
  Core/
    Types.swift             # MeetingSignal, MeetingState, SideEffect, ErrorKind
    Platform.swift          # Supported platforms + bundle IDs
    MeetingStateMachine.swift # Pure state machine (idle -> detecting -> recording)
    DetectionCoordinator.swift # Dispatches signals, executes side effects
    AppState.swift          # Observable UI state
  Detection/
    MeetingDetector.swift   # Protocol
    TeamsDetector.swift     # CoreAudio + IOPM + Network UDP + CGWindowList
    ZoomDetector.swift      # Network UDP + CGWindowList
    SlackDetector.swift     # Network UDP + CGWindowList
    ChimeDetector.swift     # Network UDP + CGWindowList
    FaceTimeDetector.swift  # IOPM + CGWindowList
    CGWindowListScanner.swift # Shared window list poller, distributes to consumers
    AppMonitor.swift        # NSWorkspace launch/terminate notifications
  Automation/
    InjectedMacWhisperController.swift # Controls MacWhisper via DYLD injection + Unix socket IPC
    AXError.swift              # Error types for automation operations
  Networking/
    WebSocketServer.swift   # Network.framework WebSocket on 127.0.0.1:8765
    ExtensionMessageHandler.swift # Parses extension JSON into MeetingSignals
  Permissions/
    PermissionManager.swift # Checks Screen Recording permission
  Logging/
    DetectionLogger.swift   # os_log + JSONL file logger (~10MB rotation)
  UI/
    StatusMenuView.swift    # Main popover view
    OnboardingView.swift    # Permission setup flow
    ErrorView.swift         # Error display with recovery actions
```

The state machine is pure -- it returns side effects (`startRecording`, `stopRecording`, `startTimer`, `cancelTimer`, `logTransition`) rather than executing them. The `DetectionCoordinator` dispatches those effects to the appropriate subsystem.

## Requirements

- **macOS 26 (Tahoe)** or later
- **MacWhisper** installed (bundle ID `com.goodsnooze.MacWhisper`)
- **Xcode / Swift 6** toolchain (for building from source)

## Installation

### Build from Source

```bash
git clone https://github.com/chrisns/MacWhisperAuto.git
cd MacWhisperAuto
./scripts/build.sh
```

This compiles a release build, creates an `.app` bundle at `build/MacWhisperAuto.app`, and signs it ad-hoc with the required entitlements. Run it with:

```bash
open build/MacWhisperAuto.app
```

Alternatively, for a debug build:

```bash
swift build
```

The debug binary will be at `.build/debug/MacWhisperAuto` but won't have the `.app` bundle structure or entitlements (fine for development, but macOS may not grant permissions correctly without the bundle).

### Browser Extension Setup

1. Open your Chromium-based browser (Chrome, Arc, Comet, Brave, Edge, etc.)
2. Navigate to `chrome://extensions`
3. Enable **Developer mode**
4. Click **Load unpacked**
5. Select the `Extension/` directory from this project
6. The extension icon should appear. It connects automatically to the host app via WebSocket on `127.0.0.1:8765`

The extension is only needed for browser-based meetings (primarily Google Meet). Native app detection works without it.

## Permissions

MacWhisperAuto needs one macOS permission. On first launch, an onboarding screen guides you through granting it.

### Screen Recording (recommended)

Used by `CGWindowListCopyWindowInfo` to read window titles from other applications. Without this, window-title-based detection won't work, but network UDP detection and other signals will still function.

Grant in **System Settings > Privacy & Security > Screen Recording**.

## Logging

Logs are written to two destinations:

- **os_log** (Console.app): Filter by subsystem `com.macwhisperauto` with categories: `detection`, `stateMachine`, `automation`, `webSocket`, `permissions`, `lifecycle`
- **JSONL file**: `~/Library/Logs/MacWhisperAuto/detection.jsonl` (rotated at 10MB)

## Configuration

There is no configuration UI or config file. Thresholds and intervals are compile-time constants:

| Parameter | Value | Location |
|---|---|---|
| Poll interval (detectors) | 3 seconds | Each detector class |
| Start debounce | 5 seconds | `MeetingStateMachine.swift` |
| Stop grace period | 15 seconds | `MeetingStateMachine.swift` |
| Teams UDP threshold | 3 sockets | `TeamsDetector.swift` |
| Zoom/Slack/Chime UDP threshold | 2 sockets | Respective detector classes |
| WebSocket port | 8765 | `WebSocketServer.swift` |
| Extension heartbeat interval | 20 seconds | `Extension/background.js` |
| Permission poll interval | 30 seconds | `AppDelegate.swift` |

To change any of these, edit the source and rebuild.

## License

MIT
