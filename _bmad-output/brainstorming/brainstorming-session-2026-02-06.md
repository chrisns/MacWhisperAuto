---
stepsCompleted: [1, 2, 3, 4]
inputDocuments: []
session_topic: 'Automated meeting detection and MacWhisper recording orchestration'
session_goals: 'Uncover blind spots and validate detection trigger strategies'
selected_approach: 'AI-Recommended Techniques'
techniques_used: ['Assumption Reversal', 'Chaos Engineering', 'Six Thinking Hats']
ideas_generated: [27]
session_active: false
workflow_completed: true
context_file: ''
---

# Brainstorming Session Results

**Facilitator:** Cns
**Date:** 2026-02-06

## Session Overview

**Topic:** Automated meeting detection and MacWhisper recording orchestration - building a system that detects active online meetings (via browser tabs, macOS window introspection, and property validation) and automatically controls MacWhisper.app recording lifecycle, with graceful handling of overlapping meetings.

**Goals:**
1. Surface things not yet considered - risks, edge cases, failure modes, alternative approaches
2. Stress-test whether proposed triggers (browser tab monitoring, macOS window title introspection, property validation) are the right signals to pursue

### Session Setup

- **Approach:** AI-Recommended Techniques
- **User Skill Level:** Technical (building macOS tooling, familiar with browser extensions, accessibility APIs)
- **Key Assumptions to Challenge:** Detection triggers, interaction mechanism with MacWhisper, meeting lifecycle boundaries

## Technique Selection

**Approach:** AI-Recommended Techniques
**Analysis Context:** Automated meeting detection with focus on uncovering blind spots and validating triggers

**Recommended Techniques:**

- **Assumption Reversal:** Challenge and flip every assumption about how meetings are detected and how MacWhisper should be controlled
- **Chaos Engineering:** Stress-test the design by deliberately breaking every component and interaction point
- **Six Thinking Hats:** Structured convergence to validate and prioritize trigger strategies through six analytical lenses

**AI Rationale:** User has existing mental model with specific trigger ideas - needs systematic assumption challenging before stress-testing, then structured validation to produce actionable research priorities.

## Technique Execution Results

### Technique 1: Assumption Reversal

**Interactive Focus:** Systematically identified and flipped 7 core assumptions about detection triggers, MacWhisper interaction, and meeting lifecycle.

**Key Findings:**

**[Detection #1]**: Two-Tier Detection Strategy
- Use window/tab titles as a fast, cheap first-pass filter, then validate with deeper content inspection (xpath/jquery for browsers, accessibility properties for native apps). Avoids expensive deep inspection on every window.

**[Detection #2]**: Tab Focus as Join Signal
- A meeting tab existing in background means meeting not yet joined. Active/focused tab with meeting URL is itself a strong join indicator. Tab state (focused vs background) is a free signal.

**[Detection #3]**: Iframe Presence as Meeting Indicator
- Meeting platforms embed their active meeting UI in iframes. The presence of specific iframes (by src domain or attributes) may be sufficient without inspecting iframe contents. Sidesteps cross-origin restrictions entirely.

**[Detection #4]**: Full Page textContent Keyword Scan
- Instead of brittle xpath selectors, scan `document.body.textContent` for meeting-state keywords ("Leave call", "Mute", participant names, duration timer). Resilient to DOM restructuring - text labels change less frequently than DOM structure.

**[Detection #5]**: Audio/Mic as Supplementary, Not Primary Signal
- Tab audio and mic capture are useful for initial confirmation but too intermittent for ongoing meeting-state indicators. Muted mics, webinar mode, and natural silence cause false "ended" signals.

**[Detection #6]**: Debounced End Detection
- Don't trigger stop-recording immediately when meeting signals disappear. Configurable grace period (e.g., 10-30 seconds) handles brief signal drops, accidental tab closures, or momentary disconnects.

**[Detection #7]**: Calendar as Optional Priming Layer, Not Primary
- Calendar can't identify which app/tab the meeting is in and completely misses ad-hoc calls. Tab/window detection must be the primary mechanism.

**[Detection #8]**: Minimal MacWhisper Interface
- MacWhisper only needs two commands: "record this app" and "stop recording." All intelligence about meeting detection lives entirely outside MacWhisper. Clean separation of concerns.

**[Detection #9]**: Background Tab Still = Active Meeting
- Once a meeting is joined in a browser tab, MacWhisper records the browser's audio regardless of which tab is focused. Detection must work on background tabs - this rules out Tampermonkey.

**[Detection #10]**: PiP/Multi-Window Behavior Needs POC
- Teams and Zoom may spawn PiP overlays or separate windows during meetings. How these manifest to macOS window APIs is unknown and must be explored empirically.

**[Architecture #1]**: Browser Extension Over Tampermonkey
- Tampermonkey can only inspect the active page. Browser extension content scripts can inspect all tabs' DOM, essential since meeting tabs will often be in background. Background-tab requirement forces this architecture decision.

### Technique 2: Chaos Engineering

**Interactive Focus:** Systematically attacked every component of the proposed design to find failure modes.

**Key Findings:**

| Component | Attack | Outcome |
|---|---|---|
| Browser service worker dies | Recording overruns | Acceptable - fail long |
| MacWhisper automation | Unknown if scriptable | **CRITICAL - POC first** |
| Platform UI changes | Detection breaks silently | Acceptable - menu bar indicator |
| False positive detection | Unwanted recordings | Acceptable - single user, delete |
| Sleep/wake | State confusion | Solved by stateless polling |
| Manual MacWhisper conflict | Error dialog | Acceptable edge case |
| Native app detection | Unknown signal depth | **Must explore empirically** |

**[Chaos #1]**: Service Worker Death = Recording Overrun
- If browser kills the extension's background process, MacWhisper keeps recording past meeting end. Worst case: extra unwanted audio. Recoverable. Failing "long" is better than failing "short."

**[Chaos #2]**: MacWhisper Automation is THE Critical Path Risk
- The entire project is worthless if MacWhisper can't be programmatically controlled. Must POC FIRST. Vectors to explore: AppleScript dictionary (.sdef), CLI arguments, URL scheme handlers, local network sockets/HTTP API, XPC services, accessibility tree UI automation.

**[Chaos #3]**: Platform UI Changes = Silent Detection Failure (Acceptable)
- MacWhisper's menu bar indicator provides human-in-the-loop observability. User will notice quickly if recording didn't start. Fix-forward by updating selectors.

**[Chaos #4]**: False Positive Recordings (Acceptable)
- Single-user device, work context, recordings are private and deletable. Low frequency, low impact.

**[Chaos #5]**: Sleep/Wake Recovery
- On wake, treat as a fresh state assessment. Poll immediately. If meeting tab still active - no action. If meeting ended during sleep - first poll triggers debounced stop.

**[Chaos #6]**: Manual MacWhisper Conflict (Acceptable Edge Case)
- If MacWhisper is already recording manually when automation triggers, it errors. User is at the machine and aware. Not worth engineering around.

**[Chaos #7]**: Native App Detection Strategy is Unknown
- Unlike browsers where DOM inspection is rich, native app introspection is an open question. Must be explored empirically through live meeting observation and API probing.

### Technique 3: Six Thinking Hats

**Interactive Focus:** Structured convergence across six analytical lenses.

**Key Findings:**

**White Hat (Facts):** Five unverified assumptions identified: MacWhisper is automatable, native apps expose useful state, meeting platforms have stable DOM signals, extension service workers maintain reliable polling, MacWhisper accepts app target programmatically.

**Red Hat (Gut Feel):** This is a stopgap, not a product. MacWhisper will eventually solve meeting detection. Don't over-engineer something designed to be thrown away.

**Yellow Hat (Benefits):** Core value = never miss a recording. Any automation, even flaky automation, is better than relying on human memory.

**Black Hat (Risks):** Primary risk stack: (1) MacWhisper not automatable, (2) MacWhisper updates break automation, (3) MacWhisper ships their own meeting detection, (4) reliability erosion. User actively monitors menu bar - automation dependency risk is negligible.

**Green Hat (Creative):** Detection is the hard problem, not execution. Execution layer is simple and swappable (Shortcuts, AppleScript, direct API). Audio device monitoring (CoreAudio) parked as future enhancement.

**Blue Hat (Process):** Architecture crystallised as host macOS app + browser extension. Host app is central orchestrator with local websocket. Six platform scope confirmed: Google Meet, Teams, Zoom, Slack, FaceTime, Chime.

**[Architecture #2]**: Chrome Extension First, Validate on Comet
- Build as Chromium extension (works across Chrome, Comet, Arc, Edge, Brave). Develop on Chrome for tooling convenience, validate on Comet for real usage.

**[Architecture #3]**: Stateless Polling Over Stateful Event Tracking
- Rather than tracking state transitions, poll repeatedly: "is there an active meeting RIGHT NOW?" Self-healing through sleep/wake/crashes. Eliminates state synchronization bugs.

**[Architecture #4]**: Host App as Central Orchestrator
- macOS application that: runs persistently, polls native app windows via macOS APIs, listens on local websocket for browser extension events, manages meeting state and debounce logic, sends start/stop commands to MacWhisper, ensures MacWhisper is running.

**[Architecture #5]**: Six Platform Scope
- Google Meet (browser), Teams (browser + native), Zoom (browser + native), Slack (browser + native), FaceTime (native only), Chime (browser + native). Detection strategy varies per platform.

## Idea Organization and Prioritization

### Thematic Organization

**Theme 1: Detection Strategy**

- Two-tier detection: title/URL filter then content validation (textContent, iframe presence)
- Tab focus as join signal; background tab DOM inspection for ongoing state
- textContent keyword scanning - resilient to DOM restructuring
- Iframe presence as meeting indicator - sidesteps cross-origin
- Audio/mic supplementary only - too intermittent for primary signal
- Stateless polling model - self-healing through sleep/wake/crashes
- Debounced end detection with configurable grace period

**Theme 2: Architecture**

- Host macOS app as central orchestrator
- Browser extension (not Tampermonkey) sends events via local websocket
- Chrome-first development, validate on Comet
- Minimal MacWhisper interface: {app_name, start, stop}
- Six platform scope: Google Meet, Teams, Zoom, Slack, FaceTime, Chime

**Theme 3: Critical Unknowns (Must POC)**

- MacWhisper automation vectors (AppleScript, CLI, URL schemes, sockets, XPC, accessibility)
- Native app introspection depth per platform
- PiP / multi-window behavior per platform

**Theme 4: Design Principles**

- Stopgap, not a product - designed to be thrown away
- Never miss a recording - the only metric
- Fail long over fail short
- Aggressive detection - false positives acceptable
- User is the monitoring system via menu bar indicator
- Don't over-engineer - hardcoded selectors for 6 platforms is fine
- Detection is the hard problem, execution is simple and swappable

### Prioritization Results

- **#1 Blocker:** MacWhisper automation - validate before any other work
- **#1 Platform Priority:** Teams native app (most frequent use)
- **Quick Win:** Host macOS app + Teams detection = first working end-to-end flow
- **Deferred:** Browser extension and web-based meeting detection (Phase 3)

## Prioritized Action Plan

### Phase 0: Validate or Die

1. **Explore MacWhisper automation vectors**
   - Check for `.sdef` AppleScript dictionary in app bundle
   - Try CLI arguments on the MacWhisper binary
   - Look for URL scheme handlers
   - Inspect for local network sockets / HTTP API
   - Examine XPC services in app bundle
   - Fall back to accessibility tree UI automation
   - _If none of these work, the project stops here_

2. **Live meeting native app observation - Teams first**
   - Join real meetings in Teams, then Zoom, Slack, FaceTime, Chime
   - Probe macOS accessibility APIs during active meetings
   - Document what each app exposes: window titles, UI elements, state indicators
   - Document PiP / multi-window behavior

### Phase 1: Minimal Viable Detection - Teams Native

3. **Build host macOS app** - persistent process, macOS window/accessibility polling, MacWhisper command sender
4. **Teams native app detection** - map window titles, accessibility tree, meeting vs chat distinction, active meeting state signals
5. **End-to-end flow:** detect Teams meeting -> start MacWhisper -> detect meeting end -> debounced stop

### Phase 2: Expand Native Apps

6. Add Zoom, Slack, FaceTime, Chime native app detection

### Phase 3: Browser Detection

7. **Build Chrome extension** - content scripts, textContent/iframe detection, websocket to host app
8. **Google Meet first** - map join/active/ended signals
9. Add Teams web, Zoom web, Slack web, Chime web
10. Validate on Comet browser

## Session Summary and Insights

**Key Achievements:**

- Validated two-tier detection strategy (title filter -> content validation) as sound
- Identified MacWhisper automation as the single critical-path risk
- Killed Tampermonkey as an option (background tab limitation)
- Established stateless polling as the core architectural pattern (self-healing)
- Crystallised host app + browser extension architecture with websocket communication
- Defined clear design principles: stopgap, never miss a recording, fail long, aggressive detection
- Produced a phased action plan prioritised by real usage (Teams native first)

**Creative Breakthroughs:**

- "This is a stopgap, not a product" - fundamentally changed build-vs-skip calculus for every decision
- "Any automation, even flaky automation, is better than human memory" - set the quality bar appropriately
- "The user IS the monitoring system" - eliminated need for automated health checks
- "Detection is the hard problem, execution is swappable" - cleanly separated concerns

**Session Reflections:**

The Assumption Reversal technique was particularly effective at surfacing the Tampermonkey limitation and the MacWhisper automation risk - both would have been costly discoveries later in development. Chaos Engineering confirmed that most failure modes are acceptable (fail long, delete unwanted recordings) and only two require investigation. Six Thinking Hats drove the pragmatic framing that keeps scope tight.
