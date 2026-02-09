---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics', 'step-03-create-stories', 'step-04-final-validation']
status: 'complete'
completedAt: '2026-02-06'
inputDocuments:
  - '_bmad-output/planning-artifacts/prd.md'
  - '_bmad-output/planning-artifacts/architecture.md'
---

# MacWhisperAuto - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for MacWhisperAuto, decomposing the requirements from the PRD and Architecture requirements into implementable stories.

## Requirements Inventory

### Functional Requirements

**Meeting Detection (FR1-FR9)**

- FR1: Detect active Microsoft Teams meetings via Teams Audio virtual device running state
- FR2: Confirm Teams meetings via IOPMAssertion ("Microsoft Teams Call in progress")
- FR3: Detect active Zoom meetings via CGWindowList window title matching
- FR4: Detect active Slack huddles via CGWindowList window title matching
- FR5: Detect active FaceTime calls via CoreAudio process-level mic identification on FaceTime PID combined with on-screen window presence
- FR6: Detect active Amazon Chime meetings via CGWindowList window title matching
- FR7: Detect browser-based meetings (Google Meet, Teams web, Zoom web, Slack web, Chime web) via signals from browser extension
- FR8: Gate CGWindowList polling to only run when relevant meeting apps are running
- FR9: Track running meeting apps via NSWorkspace notifications

**Meeting State Machine (FR10-FR13)**

- FR10: Apply configurable start debounce (default 5s) requiring consecutive signal confirmations before declaring a meeting active
- FR11: Apply configurable stop debounce (default 15s) requiring consecutive signal absence before declaring a meeting ended
- FR12: Handle meeting switchover by stopping the current recording and starting a new recording targeted at the newly detected platform's app
- FR13: Recover meeting state after sleep/wake by polling immediately on wake and acting on current signal state

**MacWhisper Automation (FR14-FR21)**

- FR14: Start a MacWhisper recording for a specific app by pressing the corresponding "Record [AppName]" button via accessibility automation
- FR15: Stop a MacWhisper recording by triggering the "Finish Recording" dialog from the active recording in MacWhisper's sidebar via accessibility automation
- FR16: Check whether MacWhisper is currently recording by inspecting the sidebar for an active recording row
- FR17: Launch MacWhisper automatically if not running when a meeting is detected
- FR18: Detect when MacWhisper is unresponsive (AX automation timeout) and alert the user
- FR19: Force-quit and relaunch MacWhisper at the user's request when unresponsive
- FR20: Record FaceTime calls via multi-step accessibility automation through MacWhisper's "App Audio" > "All System Audio" path when no per-app recording target exists
- FR21: Detect when expected MacWhisper accessibility elements are missing or changed and display an error state via the menu bar

**Menu Bar Interface (FR22-FR25)**

- FR22: Display current system state via menu bar icon (idle, detecting, recording, error)
- FR23: Show recent detection activity and signal log via menu bar popover
- FR24: Show which meeting is currently being recorded and on which platform
- FR25: Allow MacWhisper force-quit and relaunch from the menu bar when an error state is shown

**Permission & Lifecycle Management (FR26-FR29, FR42-FR43)**

- FR26: Check whether required permissions (Accessibility, Screen Recording) are granted
- FR27: Guide the user to grant missing permissions on first launch
- FR28: Detect when a previously granted permission has been revoked and alert the user
- FR29: Launch automatically at macOS login as a login item
- FR42: Display a positive operational readiness confirmation when all required permissions are granted, MacWhisper is accessible, and accessibility automation elements are verified
- FR43: Offer an optional first-run validation prompt that guides the user to join a test meeting and confirms the detection-to-recording loop works end-to-end

**Browser Extension (FR30-FR36, FR44)**

- FR30: Detect meeting tabs across all open browser tabs by matching URL patterns for supported platforms
- FR31: Perform deep DOM inspection of meeting tabs using textContent keyword scanning and CSS selector checks
- FR32: Report meeting detection and meeting-ended events to the host app via WebSocket
- FR33: Send periodic heartbeat messages (every 20s) containing the full list of active meetings
- FR34: Automatically reconnect to the host app WebSocket with exponential backoff after disconnection
- FR35: Survive service worker suspension and restore state from chrome.storage.local on wake
- FR36: Operate fully for native app meeting detection without the browser extension installed; browser-based meeting detection unavailable when extension is not connected
- FR44: Detect when the browser extension is not connected and display install guidance via the menu bar interface

**WebSocket Communication (FR37-FR38)**

- FR37: Run a WebSocket server on localhost for browser extension communication
- FR38: Reconstruct full browser meeting state from any single heartbeat message (stateless protocol)

**Logging & Diagnostics (FR39-FR41)**

- FR39: Log all detection signals, state transitions, and automation actions to the system log
- FR40: Write detection history to a rotating log file
- FR41: Log structured detection events (timestamp, platform, signal type, action taken, latency) to support sharing detection reliability evidence with the MacWhisper developer

### NonFunctional Requirements

**Performance (NFR1-NFR5)**

- NFR1: CGWindowList polling completes in < 2ms per call (benchmarked at 0.93ms)
- NFR2: CPU usage remains below 0.1% when no meeting apps are running
- NFR3: Meeting detection signal processing (from signal received to state machine evaluation) completes in < 100ms
- NFR4: MacWhisper AX automation (button press) completes in < 1 second, with 5-second timeout before declaring unresponsive
- NFR5: WebSocket heartbeat processing adds negligible overhead (< 1ms per message)

**Reliability (NFR6-NFR11)**

- NFR6: Automatic recovery from sleep/wake without user intervention
- NFR7: Browser extension reconnects to host app within 30 seconds of WebSocket server becoming available
- NFR8: AX element references re-queried before every automation action (never cached, never stale)
- NFR9: Continued operation if any single detection layer fails (graceful degradation per layer)
- NFR10: Log file rotation prevents unbounded disk usage (10MB cap)
- NFR11: Detect MacWhisper process restart and re-establish AX automation without user intervention

**Integration (NFR12-NFR16)**

- NFR12: MacWhisper AX automation applies a configurable messaging timeout to prevent hangs if MacWhisper is busy
- NFR13: WebSocket server accepts connections only from localhost (127.0.0.1) — no external network exposure
- NFR14: Handle malformed WebSocket messages without crashing (log and discard)
- NFR15: CoreAudio event processing does not block main thread or UI responsiveness
- NFR16: Alert user via menu bar error state if WebSocket server port (8765) is unavailable

### Additional Requirements

**From Architecture — Project Setup:**
- Manual Xcode project setup required (no starter template) — first implementation story
- Non-sandboxed entitlements: app-sandbox=false, network.server=true, network.client=true
- LSUIElement = true in Info.plist (menu bar only, no dock icon)
- AppDelegate-based lifecycle (replace default SwiftUI App entry point)

**From Architecture — Threading & Concurrency:**
- Hybrid threading model: @MainActor for state machine + UI, GCD dispatch queues for C API callbacks, dedicated serial queue for AX automation
- CoreAudio listeners on dedicated DispatchQueue
- CGWindowList polling on main run loop (sub-millisecond, safe)
- WebSocket on Network.framework managed queue
- All detection signals dispatch to @MainActor for state machine convergence

**From Architecture — Implementation Patterns (Enforced):**
- Protocol-based MeetingDetector with MeetingSignal type, coordinated by DetectionCoordinator
- Closure callbacks for detector → coordinator communication (not Combine, not delegates, not AsyncStream)
- Enum-based state machine with pure transition function returning (newState, [SideEffect]) — effects never executed inside transition
- DispatchSourceTimer for all timers (not Timer, not Task.sleep)
- AX element references re-queried before every automation action (never cached)
- @Observable AppState class for SwiftUI UI binding
- Unified DetectionLogger writing to both os_log and rotating JSON-lines file

**From Architecture — Integration Details:**
- Platform enum needs computed property for MacWhisper button names
- Sleep/wake hooks via NSWorkspace willSleep/didWake in AppDelegate
- Login item registration via SMAppService.mainApp.register()
- AXUIElementSetMessagingTimeout for MacWhisper messaging timeout
- WebSocket JSON message keys use snake_case (established in research protocol)

**From Architecture — Phased Delivery:**
- Phase 1 (MVP): Teams detection + state machine + AX automation + menu bar + permissions + logging (8 core files)
- Phase 2: Zoom, Slack, FaceTime, Chime detectors + CGWindowListScanner + AppMonitor
- Phase 3: WebSocket server + browser extension (manifest.json + background.js + content-script.js)

### FR Coverage Map

- FR1: Epic 1 — Teams Audio virtual device detection
- FR2: Epic 1 — Teams IOPMAssertion confirmation
- FR3: Epic 3 — Zoom CGWindowList detection
- FR4: Epic 3 — Slack CGWindowList detection
- FR5: Epic 3 — FaceTime CoreAudio + window detection
- FR6: Epic 3 — Chime CGWindowList detection
- FR7: Epic 4 — Browser extension meeting detection
- FR8: Epic 3 — CGWindowList polling gating
- FR9: Epic 3 — NSWorkspace app tracking
- FR10: Epic 1 — Start debounce (5s)
- FR11: Epic 1 — Stop debounce (15s)
- FR12: Epic 1 — Meeting switchover logic
- FR13: Epic 1 — Sleep/wake recovery
- FR14: Epic 1 — AX start recording
- FR15: Epic 1 — AX stop recording
- FR16: Epic 1 — AX check recording status
- FR17: Epic 1 — Auto-launch MacWhisper
- FR18: Epic 2 — MacWhisper unresponsive detection
- FR19: Epic 2 — Force-quit and relaunch MacWhisper
- FR20: Epic 3 — FaceTime fallback AX automation
- FR21: Epic 2 — AX element missing/changed error state
- FR22: Epic 1 — Menu bar state icon
- FR23: Epic 1 — Detection activity log popover
- FR24: Epic 1 — Current meeting display
- FR25: Epic 2 — Force-quit from menu bar
- FR26: Epic 1 — Permission checking
- FR27: Epic 1 — Permission onboarding guidance
- FR28: Epic 2 — Permission revocation detection
- FR29: Epic 1 — Login item at macOS startup
- FR30: Epic 4 — URL pattern tab matching
- FR31: Epic 4 — DOM keyword scanning
- FR32: Epic 4 — WebSocket meeting event reporting
- FR33: Epic 4 — Heartbeat keepalive (20s)
- FR34: Epic 4 — Extension auto-reconnect with backoff
- FR35: Epic 4 — Service worker suspension survival
- FR36: Epic 1 — Graceful degradation without extension
- FR37: Epic 4 — WebSocket server on localhost
- FR38: Epic 4 — Stateless heartbeat state reconstruction
- FR39: Epic 1 — System log (os_log)
- FR40: Epic 1 — Rotating file log
- FR41: Epic 1 — Structured detection evidence events
- FR42: Epic 1 — Operational readiness confirmation
- FR43: Epic 1 — First-run validation prompt
- FR44: Epic 4 — Extension install guidance

## Epic List

### Epic 1: Teams Meeting Auto-Recording (MVP)
Cns can launch the app, grant permissions, and have Teams meetings automatically detected and recorded by MacWhisper — end-to-end, without thinking about it. Includes first-run onboarding, operational readiness confirmation, and validation prompt.
**FRs covered:** FR1, FR2, FR10-FR17, FR22-FR24, FR26-FR27, FR29, FR36, FR39-FR43
**NFRs addressed:** NFR2, NFR3, NFR4, NFR6, NFR8, NFR10, NFR12, NFR15
**Journeys:** Journey 1 (Teams), Journey 3 (First Launch), Journey 4 (auto-launch)

### Epic 2: Error Recovery & Resilience
Cns can diagnose and recover from problems — MacWhisper unresponsive, permissions revoked, AX elements changed — without restarting the app or losing recordings.
**FRs covered:** FR18, FR19, FR21, FR25, FR28
**NFRs addressed:** NFR9, NFR11
**Journeys:** Journey 4 (Troubleshooting & Recovery)

### Epic 3: Native App Meeting Expansion
Cns has all native meeting apps (Zoom, Slack, FaceTime, Chime) auto-recorded, with intelligent polling that only activates when relevant apps are running.
**FRs covered:** FR3-FR6, FR8-FR9, FR20
**NFRs addressed:** NFR1
**Journeys:** Journey 1 (multi-platform), Journey 2 (overlapping meetings)

### Epic 4: Browser Meeting Detection
Cns has browser-based meetings (Google Meet, Teams web, Zoom web, Slack web, Chime web) auto-recorded via a Chromium extension that communicates with the host app over WebSocket.
**FRs covered:** FR7, FR30-FR35, FR37-FR38, FR44
**NFRs addressed:** NFR5, NFR7, NFR13, NFR14, NFR16
**Journeys:** Journey 1 (Google Meet in Comet), Journey 3 (extension install)

## Epic 1: Teams Meeting Auto-Recording (MVP)

Cns can launch the app, grant permissions, and have Teams meetings automatically detected and recorded by MacWhisper — end-to-end, without thinking about it. Includes first-run onboarding, operational readiness confirmation, and validation prompt.

### Story 1.1: Project Setup & Menu Bar App Shell

As a developer,
I want a properly configured Xcode project with menu bar app shell,
So that I have the correct foundation (entitlements, lifecycle, core types) for all subsequent development.

**Acceptance Criteria:**

**Given** a fresh Xcode project is created
**When** the app is built and launched
**Then** an NSStatusItem appears in the menu bar with an idle icon
**And** no Dock icon appears (LSUIElement = true)

**Given** the project is configured
**When** inspecting entitlements
**Then** app-sandbox is false, network.server is true, network.client is true

**Given** the AppDelegate-based lifecycle is set up
**When** the app launches
**Then** AppDelegate receives applicationDidFinishLaunching and creates the StatusBarController

**Given** core types are defined
**When** importing from any source file
**Then** Platform enum (.teams, .zoom, .slack, .faceTime, .chime, .browser), MeetingSignal, SignalConfidence, SignalSource, SideEffect, and TimerID are available

### Story 1.2: Logging Infrastructure

As a developer,
I want unified logging to both os_log and a rotating file,
So that all detection events are observable in Console.app and preserved as evidence for the MacWhisper developer.

**Acceptance Criteria:**

**Given** DetectionLogger is initialised
**When** a log event is recorded
**Then** it appears in os_log under subsystem `com.macwhisperauto` with the correct category (detection, stateMachine, automation, webSocket, permissions, lifecycle)

**Given** DetectionLogger is writing to file
**When** a structured event is logged
**Then** a JSON-lines entry is appended to `~/Library/Logs/MacWhisperAuto/detection.jsonl` with fields: ts (ISO8601), cat, platform, signal, active, action, state

**Given** the log file exceeds 10MB
**When** the next log entry is written
**Then** the file is rotated (old file renamed/removed) and a new file is started (NFR10)

**Given** the log directory does not exist
**When** DetectionLogger initialises
**Then** the directory is created automatically

### Story 1.3: Permission Checking & Onboarding

As Cns,
I want the app to check permissions on launch and guide me to grant them,
So that I know exactly what's needed and can confirm the app is ready to work.

**Acceptance Criteria:**

**Given** the app launches for the first time without Accessibility permission
**When** the onboarding view is displayed
**Then** it explains why Accessibility is needed and provides a button to open System Settings > Privacy & Security > Accessibility

**Given** the app launches without Screen Recording permission
**When** the onboarding view is displayed
**Then** it explains why Screen Recording is needed and provides a button to open the relevant System Settings pane

**Given** both Accessibility and Screen Recording permissions are granted
**When** PermissionManager checks permissions
**Then** it returns true for both and the onboarding view is dismissed

**Given** all permissions are granted and MacWhisper is running and accessible
**When** the readiness check completes
**Then** a positive operational readiness confirmation is displayed (FR42)

**Given** permissions have not yet been granted
**When** the user clicks the menu bar icon
**Then** the popover shows the onboarding/permission guidance view instead of the normal status view

### Story 1.4: Meeting State Machine & App State

As a developer,
I want a pure state machine with debounce timers and observable app state,
So that meeting detection drives recording automation through well-defined, testable transitions.

**Acceptance Criteria:**

**Given** the state machine is in `.idle`
**When** an active MeetingSignal arrives
**Then** the state transitions to `.detecting(platform, since: now)` and a 5-second start debounce timer is scheduled (FR10)

**Given** the state machine is in `.detecting(teams)` and 5 seconds of consistent signals have elapsed
**When** the debounce timer fires
**Then** the state transitions to `.recording(teams)` and a `.startRecording(.teams)` side effect is returned (FR10)

**Given** the state machine is in `.recording(teams)`
**When** signals cease (isActive: false)
**Then** a 15-second grace timer is started (FR11)

**Given** the state machine is in `.recording(teams)` with a grace timer running
**When** the 15-second grace timer expires with no active signals
**Then** the state transitions to `.idle` and a `.stopRecording` side effect is returned (FR11)

**Given** the state machine is in `.recording(teams)`
**When** an active signal for a different platform (e.g., .slack) arrives
**Then** a `.stopRecording` side effect is returned, state transitions through `.idle` to `.detecting(slack)`, and a new 5-second debounce starts (FR12)

**Given** the system wakes from sleep
**When** NSWorkspace.didWakeNotification fires
**Then** all detectors poll immediately and the state machine evaluates current signal state (FR13)

**Given** AppState is @Observable and @MainActor
**When** the state machine transitions
**Then** AppState properties update and any observing SwiftUI views re-render

**Given** the transition function is called
**When** it returns (newState, [SideEffect])
**Then** no side effects are executed inside the function — they are returned as values only

**Given** any timer is needed
**When** it is created
**Then** DispatchSourceTimer is used (not Timer, not Task.sleep)

### Story 1.5: Teams Meeting Detection

As Cns,
I want Teams meetings detected automatically via audio device state and power assertions,
So that recording starts as soon as I join a Teams call.

**Acceptance Criteria:**

**Given** Microsoft Teams is running and a call begins
**When** the Teams Audio virtual device transitions to Running state
**Then** TeamsDetector emits a MeetingSignal(platform: .teams, isActive: true, confidence: .high, source: .coreAudio) via its closure callback (FR1)

**Given** Microsoft Teams has an active call
**When** IOPMCopyAssertionsByProcess() is polled
**Then** TeamsDetector detects the "Microsoft Teams Call in progress" assertion and emits a confirmation signal with source: .iopmAssertion (FR2)

**Given** TeamsDetector conforms to MeetingDetector protocol
**When** start() is called
**Then** CoreAudio property listeners are registered on a dedicated dispatch queue and IOPMAssertion polling begins

**Given** a Teams call ends
**When** the Teams Audio virtual device transitions to not-Running
**Then** TeamsDetector emits MeetingSignal(platform: .teams, isActive: false) (FR1)

**Given** DetectionCoordinator receives signals from TeamsDetector
**When** a signal arrives on the CoreAudio callback queue
**Then** DetectionCoordinator dispatches to @MainActor and feeds the state machine

**Given** CoreAudio event listeners are registered
**When** events fire
**Then** they do not block the main thread (NFR15)

### Story 1.6: MacWhisper Accessibility Automation

As Cns,
I want MacWhisper to start and stop recording automatically,
So that I never have to open MacWhisper or click any buttons myself.

**Acceptance Criteria:**

**Given** the state machine emits a `.startRecording(.teams)` side effect
**When** MacWhisperController handles it
**Then** it finds the "Record Teams" button in MacWhisper's main window via AX and presses it (FR14)
**And** the action executes on the dedicated serial AX queue, not on main thread

**Given** the state machine emits a `.stopRecording` side effect
**When** MacWhisperController handles it
**Then** it finds the active recording in MacWhisper's sidebar, triggers the "Finish Recording" dialog, and presses the "Finish" button (FR15)

**Given** MacWhisperController needs to check recording status
**When** checkRecordingStatus() is called
**Then** it inspects the sidebar for an active recording row under "Active Recordings" and returns the current state (FR16)

**Given** a meeting is detected and MacWhisper is not running
**When** the automation is triggered
**Then** MacWhisper is launched via NSWorkspace, the controller waits for it to become accessible, then starts recording (FR17)

**Given** AX automation is about to act on an element
**When** the element is accessed
**Then** it is re-queried fresh — never using a cached reference (NFR8)

**Given** MacWhisperController is initialised
**When** AXUIElementSetMessagingTimeout is configured
**Then** a 5-second timeout is applied to prevent hangs (NFR4, NFR12)

**Given** an AX action completes (success or failure)
**When** the result is returned
**Then** it is dispatched to @MainActor as appropriate and logged via DetectionLogger

### Story 1.7: Menu Bar State Display & Activity Log

As Cns,
I want the menu bar icon to show what's happening and a popover to show details,
So that I can tell at a glance whether a meeting is being recorded and review recent activity.

**Acceptance Criteria:**

**Given** the state machine is in `.idle`
**When** the menu bar icon is rendered
**Then** it displays the idle icon variant (FR22)

**Given** the state machine transitions to `.detecting(teams)`
**When** the icon is updated
**Then** it displays the detecting icon variant (FR22)

**Given** the state machine transitions to `.recording(teams)`
**When** the icon is updated
**Then** it displays the recording icon variant (FR22)

**Given** the state machine transitions to `.error`
**When** the icon is updated
**Then** it displays the error icon variant (FR22)

**Given** a meeting is being recorded
**When** Cns clicks the menu bar icon
**Then** the popover shows which meeting platform is currently being recorded (FR24)

**Given** detection signals have been received
**When** Cns opens the popover
**Then** recent detection activity is displayed as a chronological signal log (FR23)

**Given** AppState is @Observable
**When** state machine transitions occur
**Then** StatusMenuView re-renders automatically via SwiftUI observation

### Story 1.8: End-to-End Integration & Lifecycle

As Cns,
I want the app to wire everything together, start at login, survive sleep/wake, and let me validate it works,
So that once set up, I never think about it again.

**Acceptance Criteria:**

**Given** the app launches
**When** AppDelegate.applicationDidFinishLaunching fires
**Then** all components (DetectionLogger, PermissionManager, DetectionCoordinator, TeamsDetector, MacWhisperController, StatusBarController, AppState) are created and wired together

**Given** Cns enables "Launch at Login"
**When** the setting is toggled
**Then** SMAppService.mainApp.register() is called and the app launches automatically at next login (FR29)

**Given** the Mac goes to sleep
**When** NSWorkspace.willSleepNotification fires
**Then** detection timers are suspended gracefully

**Given** the Mac wakes from sleep
**When** NSWorkspace.didWakeNotification fires
**Then** all detectors poll immediately and the state machine evaluates current signal state (FR13, NFR6)

**Given** the browser extension is not installed
**When** the app is running
**Then** all native app detection works normally — browser-based meeting detection is simply unavailable (FR36)

**Given** it is first launch and all permissions are granted
**When** readiness is confirmed
**Then** an optional first-run validation prompt is offered, guiding Cns to join a test Teams meeting and confirming the detection-to-recording loop works end-to-end (FR43)

## Epic 2: Error Recovery & Resilience

Cns can diagnose and recover from problems — MacWhisper unresponsive, permissions revoked, AX elements changed — without restarting the app or losing recordings.

### Story 2.1: MacWhisper Unresponsive Detection & Recovery

As Cns,
I want to be alerted when MacWhisper is unresponsive and be able to force-quit and relaunch it,
So that a hung MacWhisper doesn't silently prevent my meetings from being recorded.

**Acceptance Criteria:**

**Given** MacWhisperController sends an AX action to MacWhisper
**When** the action does not complete within 5 seconds (AXUIElementSetMessagingTimeout)
**Then** an AXError.timeout is returned and the state machine transitions to `.error(.macWhisperUnresponsive)` (FR18)

**Given** the state machine is in `.error(.macWhisperUnresponsive)`
**When** Cns clicks the menu bar icon
**Then** the popover displays the error state with a "Force Quit & Relaunch MacWhisper" button (FR25)

**Given** Cns clicks "Force Quit & Relaunch MacWhisper"
**When** the action is triggered
**Then** MacWhisper is force-terminated via NSRunningApplication.forceTerminate(), relaunched via NSWorkspace, and the controller waits for it to become accessible before resuming (FR19)

**Given** MacWhisper has been relaunched after force-quit
**When** AX accessibility is re-established
**Then** the state machine clears the error state and resumes detection from current signal state

**Given** a meeting was active when MacWhisper became unresponsive
**When** MacWhisper is relaunched and a meeting is still detected
**Then** recording is started automatically for the active meeting

### Story 2.2: Permission Revocation Detection

As Cns,
I want to be alerted if macOS revokes my permissions (e.g., after an OS update),
So that I can re-grant them before missing a recording.

**Acceptance Criteria:**

**Given** Accessibility permission was previously granted
**When** PermissionManager detects it has been revoked (periodic check)
**Then** the state machine transitions to `.error(.permissionDenied(.accessibility))` and the menu bar shows the error icon (FR28)

**Given** Screen Recording permission was previously granted
**When** PermissionManager detects it has been revoked
**Then** the state machine transitions to `.error(.permissionDenied(.screenRecording))` and the menu bar shows the error icon (FR28)

**Given** a permission has been revoked
**When** Cns clicks the menu bar icon
**Then** the popover shows which permission was revoked and provides a button to open the relevant System Settings pane

**Given** a revoked permission is re-granted
**When** PermissionManager detects the permission is restored
**Then** the error state is cleared and detection resumes normally

### Story 2.3: AX Element Change Detection & Graceful Degradation

As Cns,
I want the app to detect when MacWhisper's UI has changed or when MacWhisper restarts mid-session,
So that I'm informed of problems and the app recovers automatically when possible.

**Acceptance Criteria:**

**Given** MacWhisperController queries for the "Record [AppName]" button
**When** the expected AX element is not found
**Then** an `.error(.axElementNotFound)` state is set and the menu bar shows the error icon with a description of what's missing (FR21)

**Given** MacWhisperController queries for the active recording in the sidebar or the "Finish" button
**When** the expected AX element structure has changed
**Then** an `.error(.axElementNotFound)` state is set and logged with the element description for diagnostics (FR21)

**Given** MacWhisper was running and crashes or is quit by the user
**When** NSWorkspace detects MacWhisper is no longer running
**Then** the app detects the process exit and clears any stale AX state (NFR11)

**Given** MacWhisper restarts (manually or after crash) while a meeting is active
**When** MacWhisper becomes accessible again
**Then** AX automation is re-established and recording resumes for the active meeting without user intervention (NFR11)

**Given** any single detection layer fails (e.g., CoreAudio error, CGWindowList permission issue)
**When** other detection layers are still functional
**Then** the app continues operating with the remaining layers — the failed layer produces no signals but does not crash or block other layers (NFR9)

## Epic 3: Native App Meeting Expansion

Cns has all native meeting apps (Zoom, Slack, FaceTime, Chime) auto-recorded, with intelligent polling that only activates when relevant apps are running.

### Story 3.1: CGWindowList Polling Infrastructure & App Monitoring

As a developer,
I want shared CGWindowList scanning infrastructure gated by app monitoring,
So that window-title-based detection is efficient and only runs when relevant apps are present.

**Acceptance Criteria:**

**Given** AppMonitor is started
**When** a meeting app (Zoom, Slack, Chime) launches
**Then** AppMonitor detects it via NSWorkspace.didLaunchApplicationNotification and enables the corresponding detector (FR9)

**Given** a meeting app is terminated
**When** NSWorkspace.didTerminateApplicationNotification fires
**Then** AppMonitor disables the corresponding detector and CGWindowList polling stops for that app (FR9)

**Given** no relevant meeting apps are running
**When** CGWindowListScanner evaluates whether to poll
**Then** no CGWindowList calls are made and CPU usage remains near zero (FR8, NFR2)

**Given** one or more relevant apps are running
**When** CGWindowListScanner polls on its 3-second interval
**Then** CGWindowListCopyWindowInfo is called with .optionOnScreenOnly and completes in < 2ms (FR8, NFR1)

**Given** CGWindowListScanner returns window information
**When** results are processed
**Then** each registered detector receives the window list and matches against its title patterns

**Given** CGWindowListScanner is implemented
**When** multiple detectors need window data in the same poll cycle
**Then** a single CGWindowList call serves all detectors (no redundant calls)

### Story 3.2: Zoom, Slack & Chime Detection

As Cns,
I want Zoom meetings, Slack huddles, and Chime meetings detected automatically,
So that all my native app meetings are recorded without thinking about it.

**Acceptance Criteria:**

**Given** Zoom is running and a meeting is active
**When** CGWindowListScanner finds a window with title matching "Zoom Meeting" or "Zoom Webinar"
**Then** ZoomDetector emits MeetingSignal(platform: .zoom, isActive: true, confidence: .high, source: .cgWindowList) (FR3)

**Given** Zoom meeting ends
**When** the matching window title is no longer present
**Then** ZoomDetector emits MeetingSignal(platform: .zoom, isActive: false) (FR3)

**Given** Slack is running and a huddle is active
**When** CGWindowListScanner finds a window with "huddle" in the title
**Then** SlackDetector emits MeetingSignal(platform: .slack, isActive: true, confidence: .high, source: .cgWindowList) (FR4)

**Given** the Slack huddle ends
**When** the matching window is no longer present
**Then** SlackDetector emits MeetingSignal(platform: .slack, isActive: false) (FR4)

**Given** Amazon Chime is running and a meeting is active
**When** CGWindowListScanner finds a window with title "Amazon Chime: Meeting Controls"
**Then** ChimeDetector emits MeetingSignal(platform: .chime, isActive: true, confidence: .high, source: .cgWindowList) (FR6)

**Given** the Chime meeting ends
**When** the matching window is no longer present
**Then** ChimeDetector emits MeetingSignal(platform: .chime, isActive: false) (FR6)

**Given** all three detectors conform to MeetingDetector protocol
**When** signals are emitted
**Then** they use closure callbacks to DetectionCoordinator, consistent with the Teams detector pattern

### Story 3.3: FaceTime Detection & Fallback Recording

As Cns,
I want FaceTime calls detected and recorded via the "All System Audio" fallback,
So that even without a per-app MacWhisper target, my FaceTime calls are captured.

**Acceptance Criteria:**

**Given** FaceTime is running and a call is active
**When** CoreAudio kAudioProcessPropertyIsRunningInput identifies FaceTime's PID as using the microphone
**Then** FaceTimeDetector checks for an on-screen FaceTime window via CGWindowList (FR5)

**Given** FaceTime PID is using the mic and an on-screen window is present
**When** both conditions are true
**Then** FaceTimeDetector emits MeetingSignal(platform: .faceTime, isActive: true, confidence: .high, source: .coreAudio) (FR5)

**Given** the FaceTime call ends
**When** either the mic is released or the window disappears
**Then** FaceTimeDetector emits MeetingSignal(platform: .faceTime, isActive: false) (FR5)

**Given** the state machine emits `.startRecording(.faceTime)`
**When** MacWhisperController handles it
**Then** it navigates MacWhisper's AX tree through "App Audio" to "All System Audio" and starts recording via multi-step accessibility automation (FR20)

**Given** the multi-step AX navigation for FaceTime
**When** any step in the sequence fails (element not found, action timeout)
**Then** an error is logged, the state machine receives the failure, and the menu bar shows an error state

**Given** FaceTime detection uses CoreAudio process-level identification
**When** the mic listener fires
**Then** it runs on a dedicated dispatch queue and does not block the main thread

## Epic 4: Browser Meeting Detection

Cns has browser-based meetings (Google Meet, Teams web, Zoom web, Slack web, Chime web) auto-recorded via a Chromium extension that communicates with the host app over WebSocket.

### Story 4.1: WebSocket Server in Host App

As a developer,
I want a localhost WebSocket server that receives and processes browser extension messages,
So that the host app can detect browser-based meetings reported by the extension.

**Acceptance Criteria:**

**Given** the app launches
**When** WebSocketServer starts
**Then** it listens on `ws://127.0.0.1:8765` using Network.framework NWListener with NWProtocolWebSocket (FR37)

**Given** the WebSocket server is running
**When** a connection attempt comes from a non-localhost address
**Then** the connection is rejected — only 127.0.0.1 connections are accepted (NFR13)

**Given** the extension sends a heartbeat message containing the full list of active meetings
**When** ExtensionMessageHandler parses it
**Then** the complete browser meeting state is reconstructed from that single message — no dependency on prior messages (FR38)

**Given** ExtensionMessageHandler receives a parsed meeting signal
**When** the signal is processed
**Then** it is converted to a MeetingSignal(platform: .browser, source: .webSocket) and forwarded to DetectionCoordinator via closure callback

**Given** the extension sends a malformed JSON message
**When** ExtensionMessageHandler attempts to parse it
**Then** the message is logged and discarded without crashing (NFR14)

**Given** WebSocket heartbeat messages arrive every 20 seconds
**When** they are processed
**Then** processing completes in < 1ms per message (NFR5)

**Given** port 8765 is already in use by another process
**When** WebSocketServer fails to bind
**Then** the state machine transitions to `.error(.webSocketPortUnavailable)` and the menu bar shows an error state (NFR16)

### Story 4.2: Browser Extension Core & Tab Detection

As Cns,
I want a Chromium extension that monitors all my browser tabs for meeting URLs,
So that browser-based meetings are detected regardless of which tab is active.

**Acceptance Criteria:**

**Given** the extension is loaded in Comet as an unpacked MV3 extension
**When** the service worker boots
**Then** it queries all open tabs and checks URLs against supported platform patterns (FR30)

**Given** a new tab is opened or an existing tab navigates
**When** the URL matches a supported meeting platform pattern (Google Meet, Teams web, Zoom web, Slack web, Chime web)
**Then** the tab is flagged as a potential meeting tab for deeper inspection (FR30, FR7)

**Given** the URL patterns for supported platforms
**When** matching is performed
**Then** patterns cover: `meet.google.com/*`, `teams.microsoft.com/*`, `*.zoom.us/j/*`, `app.slack.com/huddle/*`, `app.chime.aws/*` (and equivalent variations)

**Given** a tab that was previously flagged as a meeting tab
**When** the user navigates away from the meeting URL
**Then** the tab is removed from the potential meeting list

**Given** the extension manifest.json
**When** it is configured
**Then** it declares MV3 format, required permissions (tabs, storage), and content script matches for supported meeting domains

### Story 4.3: DOM Inspection & Meeting Event Reporting

As Cns,
I want the extension to deeply inspect meeting tabs and report meeting status to the host app,
So that only actual active meetings (not just open URLs) trigger recording.

**Acceptance Criteria:**

**Given** a tab is flagged as a potential meeting tab
**When** the content script is injected
**Then** it performs textContent keyword scanning for platform-specific meeting indicators (e.g., "You are in a call", "Meeting in progress", participant counts) (FR31)

**Given** textContent scanning confirms an active meeting
**When** CSS selector checks corroborate (e.g., meeting control buttons visible)
**Then** a meeting-detected event is sent to the service worker (FR31)

**Given** the service worker receives a meeting-detected event
**When** a WebSocket connection to the host app is active
**Then** it sends a meeting detection message with tab_id, platform, and URL to the host app (FR32)

**Given** a meeting ends (content script detects meeting indicators removed)
**When** the change is detected
**Then** a meeting-ended event is sent to the host app via WebSocket (FR32)

**Given** the service worker has active meeting state
**When** 20 seconds have elapsed since the last heartbeat
**Then** a heartbeat message containing the full list of active meetings is sent to the host app (FR33)

**Given** a Slack huddle is active
**When** the content script monitors the page
**Then** it uses MutationObserver to detect huddle UI changes in real-time rather than polling

### Story 4.4: Extension Resilience & Install Guidance

As Cns,
I want the extension to survive disconnections and suspensions, and the host app to guide me if it's not installed,
So that browser meeting detection is reliable and I know how to set it up.

**Acceptance Criteria:**

**Given** the WebSocket connection to the host app is lost
**When** the service worker detects disconnection
**Then** it begins automatic reconnection with exponential backoff (starting at 1s, capping at 30s) (FR34)

**Given** the WebSocket server becomes available after being down
**When** the extension's reconnection attempt succeeds
**Then** the connection is re-established within 30 seconds and full meeting state is sent as a heartbeat (FR34, NFR7)

**Given** Chrome suspends the MV3 service worker due to inactivity
**When** the service worker is re-awakened (by alarm, tab event, or message)
**Then** it restores active meeting state from chrome.storage.local and re-establishes the WebSocket connection (FR35)

**Given** active meetings existed before service worker suspension
**When** state is restored from chrome.storage.local
**Then** the restored state matches what was persisted and a heartbeat is sent to the host app

**Given** no browser extension has connected to the WebSocket server
**When** Cns clicks the menu bar icon
**Then** the popover includes a section indicating the browser extension is not connected and provides guidance on how to install it (FR44)

**Given** the browser extension connects for the first time
**When** the WebSocket handshake completes
**Then** the install guidance is dismissed and the extension connection status is shown as active
