---
stepsCompleted: ['step-01-init', 'step-02-discovery', 'step-03-success', 'step-04-journeys', 'step-05-domain', 'step-06-innovation', 'step-07-project-type', 'step-08-scoping', 'step-09-functional', 'step-10-nonfunctional', 'step-11-polish']
inputDocuments:
  - '_bmad-output/planning-artifacts/research/technical-macwhisper-accessibility-automation-research-2026-02-06.md'
  - '_bmad-output/planning-artifacts/research/browser-extension-meeting-detection-research-2026-02-06.md'
  - '_bmad-output/brainstorming/brainstorming-session-2026-02-06.md'
workflowType: 'prd'
documentCounts:
  briefs: 0
  research: 2
  brainstorming: 1
  projectDocs: 0
classification:
  projectType: desktop_app
  domain: general
  complexity: low
  projectContext: greenfield
---

# Product Requirements Document - MacWhisperAuto

**Author:** Cns
**Date:** 2026-02-06

## Executive Summary

MacWhisperAuto is a macOS menu bar utility that automatically detects online meetings and triggers MacWhisper recording via accessibility automation. It exists because MacWhisper's built-in meeting detection is broken (unreliable `lsof` UDP counting), and Cns needs every meeting recorded without thinking about it. The system uses layered signal fusion — NSWorkspace, CoreAudio, IOPMAssertion, CGWindowList, and a Chromium browser extension — to detect meetings across six platforms (Teams, Zoom, Slack, FaceTime, Chime, and browser-based Google Meet/Teams/Zoom/Slack/Chime). This is explicitly a stopgap: built in days, designed to be deleted when MacWhisper ships working detection.

## Success Criteria

### User Success

- Every meeting that MacWhisperAuto knows how to detect is recorded — **100% catch rate** for supported platforms
- Recording starts within **5 seconds** of meeting detection (2 consecutive signal confirmations)
- Recording stops **15 seconds** after meeting signals cease (graceful stop, no premature cutoff)
- Cns never has to think about whether a meeting is being recorded — the menu bar indicator is the only touchpoint
- False positives (unwanted recordings) are acceptable and trivially deletable

### Business Success

- **It works and gets out of the way.** No ongoing attention, no configuration fiddling, no babysitting
- Provides evidence (recording logs/stats) to share with MacWhisper developer as a prod to fix their built-in meeting detection
- When MacWhisper ships working detection, MacWhisperAuto can be cleanly uninstalled with zero residue
- Build time is measured in days, not weeks — this is a stopgap, not an investment

### Technical Success

- Survives sleep/wake cycles without intervention (stateless polling, self-healing)
- Runs as a menu bar app with near-zero CPU footprint when no meetings are active
- MacWhisper accessibility automation works reliably from background (proven in POC)
- Browser extension maintains WebSocket connection with automatic reconnection
- No permissions beyond Screen Recording, Accessibility, and browser extension install

### Measurable Outcomes

| Metric | Target |
|--------|--------|
| Meeting catch rate (supported platforms) | 100% |
| Start detection latency | ≤ 5 seconds |
| Stop detection grace period | 15 seconds |
| CPU usage (idle, no meetings) | < 0.1% |
| Recovery after sleep/wake | Automatic, no user action |
| False positive rate | Acceptable (any) |

## Product Scope

- **Phase 1 (MVP):** Teams native detection + MacWhisper automation + menu bar app — proves core loop
- **Phase 2:** Zoom, Slack, FaceTime, Chime native detection via CGWindowList + CoreAudio
- **Phase 3:** Chromium browser extension + WebSocket bridge for all web-based meetings

All three phases are committed development. See [Project Scoping & Phased Development](#project-scoping--phased-development) for detailed breakdown.

## User Journeys

### Journey 1: The Invisible Assistant (Happy Path)

Cns, senior technologist, back-to-back meetings all day.

It's 9:55am and Cns is wrapping up some code when a Teams notification pops up — standup in 5. He clicks Join. Within seconds, the menu bar icon shifts to indicate recording has started.

The standup runs 12 minutes. He clicks Leave. Fifteen seconds later, the menu bar icon returns to idle. MacWhisper has the recording, transcription is already processing. At no point did Cns open MacWhisper, click anything, or think about recording.

At 10:30 he joins a Google Meet in Comet via a calendar link. The browser extension detects the meeting tab, signals the host app, and recording starts against Comet's audio. He switches tabs to take notes. The meeting tab is in the background. Detection continues. Meeting ends an hour later — same seamless stop.

**Reveals:** Core detection loop, per-platform signal routing, MacWhisper AX automation start/stop, menu bar state indicator, browser extension WebSocket bridge.

### Journey 2: The Overlapping Day (Edge Cases)

Cns is 20 minutes into a Teams meeting, already recording. A colleague pings him on Slack for a quick huddle. He joins the huddle in a separate window.

MacWhisperAuto detects the new Slack meeting signal. It stops the Teams recording and immediately starts recording Slack. The Teams recording captures everything up to that moment. The Slack recording may include a few seconds of overlap from the tail end of the Teams call. Nothing is lost.

The Slack huddle wraps up in 5 minutes. MacWhisperAuto detects the huddle ended. No other meetings are active. The 15-second grace period expires and recording stops.

Later, his MacBook goes to sleep mid-afternoon with no meetings. He opens the lid at 4pm. The app wakes, polls immediately, finds no active meetings, and settles back to idle. State is clean. No intervention needed.

**Reveals:** Meeting switchover (stop first, start second), overlap-tolerant recording, sleep/wake recovery, stateless self-healing.

### Journey 3: First Launch (Setup & Onboarding)

Cns has just built the app. Time to get it running.

He launches MacWhisperAuto for the first time. The menu bar icon appears. A popover tells him two permissions are needed: Accessibility and Screen Recording. He clicks through to System Settings, grants both. The app confirms permissions are active.

MacWhisper is already running. MacWhisperAuto finds it via NSWorkspace, confirms accessibility access to its UI elements, and reports ready.

He opens Comet and loads the unpacked extension from the Extension folder. The extension's service worker boots, connects to `ws://127.0.0.1:8765`, and the host app logs the connection. Setup complete.

He joins a test Teams meeting to validate. The menu bar icon changes. MacWhisper starts recording. He leaves the meeting. Fifteen seconds later, recording stops. It works.

**Reveals:** Permission onboarding flow, readiness confirmation, MacWhisper discovery, extension install guidance, WebSocket handshake, first-run validation prompt.

### Journey 4: Why Didn't It Record? (Troubleshooting & Recovery)

Cns notices the menu bar icon didn't change during a Zoom call.

He clicks the menu bar icon to check status. The app shows recent detection activity — a log of signals received and actions taken. He sees: Zoom window detected, but CGWindowList returned empty title. Screen Recording permission was revoked after a macOS update.

He re-grants Screen Recording in System Settings, restarts the app, and joins another test call. This time it works.

**Scenario B: MacWhisper not running.** Cns joins a Teams meeting. MacWhisperAuto detects the meeting but finds MacWhisper isn't running. It launches MacWhisper automatically, waits for it to become ready, then triggers recording. Cns never notices.

**Scenario C: MacWhisper unresponsive.** During a meeting, the AX automation times out — MacWhisper is hung. The menu bar icon alerts Cns with a warning state. He clicks it and sees an option to force-quit and relaunch MacWhisper. He clicks it, MacWhisper restarts, and recording resumes.

**Reveals:** Detection logging, permission monitoring, auto-launch MacWhisper, force-quit recovery, user-serviceable diagnostics.

### Journey Requirements Summary

| Journey | Key Capabilities Revealed |
|---------|--------------------------|
| Invisible Assistant | Detection loop, per-platform routing, AX automation, menu bar indicator, extension bridge |
| Overlapping Day | Meeting switchover (stop/start), overlap-tolerant recording, sleep/wake recovery |
| First Launch | Permission onboarding, readiness confirmation, MacWhisper discovery, extension install guidance, WebSocket setup, first-run validation |
| Troubleshooting & Recovery | Detection logging, auto-launch, force-quit recovery, permission monitoring, diagnostics |

## Desktop App Specific Requirements

### Project-Type Overview

MacWhisperAuto is a single-user macOS menu bar utility. No cross-platform support, no distribution beyond the developer's own machine, no auto-update mechanism. It integrates deeply with macOS system APIs to detect meetings and automate a third-party application.

### Platform Support

- **macOS 26 (Tahoe)** — sole target, no backward compatibility
- **Single machine, single user** — no multi-user considerations
- **Non-sandboxed** — required for Accessibility and IOKit access
- **Distribution:** Local build, no App Store, no notarization needed for personal use
- **Update strategy:** Rebuild from source and relaunch

### System Integration

| Framework | Purpose | Permission Required |
|-----------|---------|-------------------|
| NSWorkspace | Track running apps, launch MacWhisper | None |
| CoreAudio | Teams Audio virtual device state, mic process identification, default input monitoring | None |
| IOKit (IOPMAssertion) | Teams power assertion detection | None |
| CGWindowList | Window title scanning for Zoom, Slack, Chime, browser meetings | Screen Recording |
| Accessibility (AX) | MacWhisper UI automation (start/stop recording), AXObserver for window events | Accessibility |
| Network.framework | WebSocket server for browser extension communication | None (localhost only) |
| AppKit (NSStatusBar) | Menu bar icon and popover UI | None |

### Entitlements

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

### Offline & Connectivity

- No internet connectivity required — all detection and automation is local
- The only network activity is a localhost WebSocket (`ws://127.0.0.1:8765`) for browser extension communication
- Meetings being recorded are online, but MacWhisperAuto itself has zero external network dependencies

### Implementation Considerations

- **AppKit + SwiftUI hybrid:** NSStatusBar/NSStatusItem for menu bar (full control), SwiftUI via NSHostingView for popover/settings
- **LSUIElement = true:** Menu bar only, no dock icon
- **No persistence layer:** No database, no config files beyond what macOS provides. State is ephemeral and reconstructed on each poll cycle
- **Logging:** `os_log` for runtime diagnostics (Console.app), rotating file log in `~/Library/Logs/MacWhisperAuto/` for detection history and MacWhisper developer evidence
- **Single process:** All detection, automation, and WebSocket serving runs in one process
- **WebSocket port:** `ws://127.0.0.1:8765`
- **AX timeout:** `AXUIElementSetMessagingTimeout` for MacWhisper messaging timeout
- **CoreAudio threading:** Dedicated dispatch queue for audio event listeners

## Project Scoping & Phased Development

### MVP Strategy & Philosophy

**MVP Approach:** Problem-solving MVP — prove the core detection-to-recording loop works end-to-end with the highest-frequency platform (Teams). All subsequent phases are committed development, not aspirational.

**Resource Requirements:** Solo developer (Cns), building in days not weeks. Swift for host app, JavaScript for extension.

### Phase 1: Core Loop (MVP)

**Goal:** Teams meetings auto-record without thinking about it.

**Core Journeys Supported:** Journey 1 (happy path — Teams only), Journey 3 (first launch — partial), Journey 4 (troubleshooting)

**Must-Have Capabilities:**
- macOS menu bar app with state indicator (idle / detecting / recording / error)
- Teams native detection via Teams Audio virtual device (event-driven) + IOPMAssertion polling (confirmation)
- MacWhisper accessibility automation: start recording, stop recording, check status
- Auto-launch MacWhisper if not running
- Debounce state machine (5s start, 15s stop)
- Meeting switchover logic (stop current, start new)
- Sleep/wake recovery via stateless polling
- Permission onboarding (Accessibility, Screen Recording)
- `os_log` diagnostics + rotating file log in `~/Library/Logs/MacWhisperAuto/`

### Phase 2: Native App Expansion

**Goal:** All native meeting apps detected. No browser work yet.

**Adds:**
- CGWindowList polling infrastructure (0.93ms per call, 3s interval)
- Zoom detection: window title "Zoom Meeting" / "Zoom Webinar"
- Slack detection: window with "huddle" in title
- FaceTime detection: CoreAudio process-level mic identification on FaceTime PID + on-screen window
- Chime detection: window title "Amazon Chime: Meeting Controls" (minimal investment — service ends Feb 20 2026)
- NSWorkspace gating: only poll CGWindowList when relevant apps are running

**Why this before browser:** Reuses the same host app infrastructure. Adding per-platform detectors is incremental — each is a small, testable unit. No new architecture needed.

### Phase 3: Browser Extension

**Goal:** Browser-based meetings (Google Meet, Teams web, Zoom web, Slack web, Chime web) detected via Chromium extension.

**Adds:**
- Network.framework WebSocket server in host app (`ws://127.0.0.1:8765`)
- Chromium MV3 extension: service worker + content scripts
- Two-tier detection: URL/title matching (cheap) then DOM keyword scanning (deep)
- 20-second heartbeat keepalive (doubles as state sync)
- Extension auto-reconnect with exponential backoff
- Per-platform content scripts with MutationObserver for Slack huddles
- Stateless heartbeat protocol — host app reconstructs state from any single message

**Why last:** Separate codebase (JavaScript), separate runtime (browser), requires WebSocket server infrastructure. Largest single piece of new architecture. By this point the host app's detection loop and MacWhisper automation are battle-tested.

### FaceTime Fallback (Phase 2 stretch)

- FaceTime has no per-app recording target in MacWhisper
- Fallback: multi-step AX automation through "App Audio" > "All System Audio" path
- More fragile than one-click shortcuts — acceptable given FaceTime call frequency
- Implement after core FaceTime detection works, treat as optional enhancement

### Risk Mitigation Strategy

**Technical Risks:**
- MacWhisper UI changes break AX automation — Menu bar error state alerts user; AX element queries are re-discovered each time (no cached references)
- Meeting platform UI changes break DOM detection — textContent keyword scanning is resilient; CSS selectors are supplementary
- Comet browser WebSocket compatibility unknown — Test early in Phase 3; HTTP polling fallback available

**Operational Risks:**
- MacWhisper ships working detection before we finish — Celebrate and delete. Every phase delivers standalone value, nothing is wasted
- macOS update breaks APIs — macOS 26 baseline, single-target, rebuild and fix

## Functional Requirements

### Meeting Detection

- **FR1:** Detect active Microsoft Teams meetings via Teams Audio virtual device running state
- **FR2:** Confirm Teams meetings via IOPMAssertion ("Microsoft Teams Call in progress")
- **FR3:** Detect active Zoom meetings via CGWindowList window title matching
- **FR4:** Detect active Slack huddles via CGWindowList window title matching
- **FR5:** Detect active FaceTime calls via CoreAudio process-level mic identification on FaceTime PID combined with on-screen window presence
- **FR6:** Detect active Amazon Chime meetings via CGWindowList window title matching
- **FR7:** Detect browser-based meetings (Google Meet, Teams web, Zoom web, Slack web, Chime web) via signals from browser extension
- **FR8:** Gate CGWindowList polling to only run when relevant meeting apps are running
- **FR9:** Track running meeting apps via NSWorkspace notifications

### Meeting State Machine

- **FR10:** Apply configurable start debounce (default 5s) requiring consecutive signal confirmations before declaring a meeting active
- **FR11:** Apply configurable stop debounce (default 15s) requiring consecutive signal absence before declaring a meeting ended
- **FR12:** Handle meeting switchover by stopping the current recording and starting a new recording targeted at the newly detected platform's app
- **FR13:** Recover meeting state after sleep/wake by polling immediately on wake and acting on current signal state

### MacWhisper Automation

- **FR14:** Start a MacWhisper recording for a specific app by pressing the corresponding "Record [AppName]" button via accessibility automation
- **FR15:** Stop a MacWhisper recording by pressing "Stop Recording" in the extras menu bar via accessibility automation
- **FR16:** Check whether MacWhisper is currently recording by inspecting the extras menu bar for a "Recording ..." menu item
- **FR17:** Launch MacWhisper automatically if not running when a meeting is detected
- **FR18:** Detect when MacWhisper is unresponsive (AX automation timeout) and alert the user
- **FR19:** Force-quit and relaunch MacWhisper at the user's request when unresponsive
- **FR20:** Record FaceTime calls via multi-step accessibility automation through MacWhisper's "App Audio" > "All System Audio" path when no per-app recording target exists
- **FR21:** Detect when expected MacWhisper accessibility elements are missing or changed and display an error state via the menu bar

### Menu Bar Interface

- **FR22:** Display current system state via menu bar icon (idle, detecting, recording, error)
- **FR23:** Show recent detection activity and signal log via menu bar popover
- **FR24:** Show which meeting is currently being recorded and on which platform
- **FR25:** Allow MacWhisper force-quit and relaunch from the menu bar when an error state is shown

### Permission & Lifecycle Management

- **FR26:** Check whether required permissions (Accessibility, Screen Recording) are granted
- **FR27:** Guide the user to grant missing permissions on first launch
- **FR28:** Detect when a previously granted permission has been revoked and alert the user
- **FR29:** Launch automatically at macOS login as a login item
- **FR42:** Display a positive operational readiness confirmation when all required permissions are granted, MacWhisper is accessible, and accessibility automation elements are verified
- **FR43:** Offer an optional first-run validation prompt that guides the user to join a test meeting and confirms the detection-to-recording loop works end-to-end

### Browser Extension

- **FR30:** Detect meeting tabs across all open browser tabs by matching URL patterns for supported platforms
- **FR31:** Perform deep DOM inspection of meeting tabs using textContent keyword scanning and CSS selector checks
- **FR32:** Report meeting detection and meeting-ended events to the host app via WebSocket
- **FR33:** Send periodic heartbeat messages (every 20s) containing the full list of active meetings
- **FR34:** Automatically reconnect to the host app WebSocket with exponential backoff after disconnection
- **FR35:** Survive service worker suspension and restore state from chrome.storage.local on wake
- **FR36:** Operate fully for native app meeting detection without the browser extension installed; browser-based meeting detection unavailable when extension is not connected
- **FR44:** Detect when the browser extension is not connected and display install guidance via the menu bar interface

### WebSocket Communication

- **FR37:** Run a WebSocket server on localhost for browser extension communication
- **FR38:** Reconstruct full browser meeting state from any single heartbeat message (stateless protocol)

### Logging & Diagnostics

- **FR39:** Log all detection signals, state transitions, and automation actions to the system log
- **FR40:** Write detection history to a rotating log file
- **FR41:** Log structured detection events (timestamp, platform, signal type, action taken, latency) to support sharing detection reliability evidence with the MacWhisper developer

## Non-Functional Requirements

### Performance

- **NFR1:** CGWindowList polling completes in < 2ms per call (benchmarked at 0.93ms)
- **NFR2:** CPU usage remains below 0.1% when no meeting apps are running
- **NFR3:** Meeting detection signal processing (from signal received to state machine evaluation) completes in < 100ms
- **NFR4:** MacWhisper AX automation (button press) completes in < 1 second, with 5-second timeout before declaring unresponsive
- **NFR5:** WebSocket heartbeat processing adds negligible overhead (< 1ms per message)

### Reliability

- **NFR6:** Automatic recovery from sleep/wake without user intervention
- **NFR7:** Browser extension reconnects to host app within 30 seconds of WebSocket server becoming available
- **NFR8:** AX element references re-queried before every automation action (never cached, never stale)
- **NFR9:** Continued operation if any single detection layer fails (graceful degradation per layer)
- **NFR10:** Log file rotation prevents unbounded disk usage (10MB cap)
- **NFR11:** Detect MacWhisper process restart and re-establish AX automation without user intervention

### Integration

- **NFR12:** MacWhisper AX automation applies a configurable messaging timeout to prevent hangs if MacWhisper is busy
- **NFR13:** WebSocket server accepts connections only from localhost (127.0.0.1) — no external network exposure
- **NFR14:** Handle malformed WebSocket messages without crashing (log and discard)
- **NFR15:** CoreAudio event processing does not block main thread or UI responsiveness
- **NFR16:** Alert user via menu bar error state if WebSocket server port (8765) is unavailable
