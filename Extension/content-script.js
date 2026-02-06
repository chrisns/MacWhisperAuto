// content-script.js - MacWhisperAuto DOM-based meeting detection

const LOG_PREFIX = '[MacWhisperAuto]';
const CHECK_INTERVAL_MS = 3000;
const MUTATION_DEBOUNCE_MS = 1000;
const INITIAL_CHECK_DELAY_MS = 2000;

// --- Logging ---

function log(...args) {
  console.log(LOG_PREFIX, ...args);
}

function warn(...args) {
  console.warn(LOG_PREFIX, ...args);
}

// --- Platform Detectors ---

const PLATFORM_DETECTORS = {
  google_meet: {
    urlPattern: /meet\.google\.com/,
    detect() {
      // Meeting code in URL is the primary signal
      if (!/\/[a-z]{3}-[a-z]{4}-[a-z]{3}/.test(location.pathname)) return false;

      // Check for meeting controls (mic/camera buttons indicate active call)
      const hasMeetingCode = !!document.querySelector('[data-meeting-code]');
      const hasParticipant = !!document.querySelector('[data-participant-id]');
      const hasMuteButton = !!document.querySelector(
        '[data-is-muted], [aria-label*="microphone" i], [aria-label*="Turn off mic" i], [aria-label*="Turn on mic" i]'
      );
      const hasCallControls = !!document.querySelector(
        '[aria-label*="Leave call" i], [aria-label*="End call" i]'
      );

      // Active meeting = URL matches AND we see call controls or participant indicators
      const isActive = hasMeetingCode || hasParticipant || hasMuteButton || hasCallControls;
      return isActive;
    }
  },

  teams_web: {
    urlPattern: /teams\.microsoft\.com/,
    detect() {
      // Look for in-call indicators
      const hasCallControls = !!document.querySelector(
        '[data-tid="call-controls"], [id="call-controls"]'
      );
      const hasMuteIndicator = document.body.innerText?.includes("You're muted") ?? false;
      const hasCallTimer = !!document.querySelector('[data-tid="call-duration"]');
      const hasHangUp = !!document.querySelector(
        '[aria-label*="Hang up" i], [aria-label*="Leave" i], [data-tid="hangup-btn"]'
      );
      const hasCallingScreen = !!document.querySelector(
        '#calling-screen, [data-tid="calling-screen"]'
      );

      return hasCallControls || hasMuteIndicator || hasCallTimer || hasHangUp || hasCallingScreen;
    }
  },

  zoom_web: {
    urlPattern: /zoom\.us\/(j|wc)\//,
    detect() {
      // Zoom web client indicators
      const hasFooter = !!document.querySelector('#wc-footer, .meeting-client');
      const hasMuteBtn = !!document.querySelector(
        '[aria-label*="mute" i], [aria-label*="Mute" i], .join-audio-container'
      );
      const hasVideoBtn = !!document.querySelector(
        '[aria-label*="video" i], [aria-label*="Stop Video" i], [aria-label*="Start Video" i]'
      );
      const hasParticipants = !!document.querySelector(
        '[aria-label*="Participants" i], .participants-section-container'
      );

      return hasFooter || (hasMuteBtn && hasVideoBtn) || hasParticipants;
    }
  },

  slack_huddle: {
    urlPattern: /app\.slack\.com/,
    detect() {
      // Slack huddle indicators - the UI is highly dynamic
      const hasHuddleControls = !!document.querySelector(
        '[data-qa="huddle_mini_player"], [data-qa="huddle-controls"], .p-huddle_sidebar'
      );
      const hasHuddleText = document.body.innerText?.includes('In a huddle') ?? false;
      const hasMicControl = !!document.querySelector(
        '[aria-label*="huddle" i][aria-label*="mic" i], [data-qa="huddle-mic-button"]'
      );

      return hasHuddleControls || hasHuddleText || hasMicControl;
    }
  },

  chime_web: {
    urlPattern: /app\.chime\.aws/,
    detect() {
      // Chime web meeting indicators
      const hasMeetingControls = !!document.querySelector(
        '[data-testid="meeting-controls"], .meeting-controls'
      );
      const hasMuteBtn = !!document.querySelector(
        '[aria-label*="Mute" i], [data-testid="mute-button"]'
      );
      const hasVideoBtn = !!document.querySelector(
        '[aria-label*="Video" i], [data-testid="video-button"]'
      );
      const hasEndBtn = !!document.querySelector(
        '[aria-label*="Leave" i], [aria-label*="End" i], [data-testid="end-meeting-button"]'
      );

      return hasMeetingControls || hasEndBtn || (hasMuteBtn && hasVideoBtn);
    }
  }
};

// --- State ---

let currentPlatform = null;
let lastReportedActive = null;
let mutationDebounceTimer = null;
let periodicCheckTimer = null;
let observer = null;
let consecutiveInactiveChecks = 0;
const INACTIVE_THRESHOLD = 3; // Require 3 consecutive inactive checks (~9s) before reporting ended

function isContextValid() {
  try {
    return !!chrome.runtime?.id;
  } catch {
    return false;
  }
}

function teardown() {
  warn('Extension context invalidated — stopping content script');
  if (periodicCheckTimer) { clearInterval(periodicCheckTimer); periodicCheckTimer = null; }
  if (mutationDebounceTimer) { clearTimeout(mutationDebounceTimer); mutationDebounceTimer = null; }
  if (observer) { observer.disconnect(); observer = null; }
}

// --- Platform Detection ---

function detectPlatform() {
  const url = location.href;
  for (const [platform, detector] of Object.entries(PLATFORM_DETECTORS)) {
    if (detector.urlPattern.test(url)) {
      return platform;
    }
  }
  return null;
}

// --- Meeting Check ---

function checkMeetingActive(platform) {
  const detector = PLATFORM_DETECTORS[platform];
  if (!detector) return false;

  try {
    return detector.detect();
  } catch (err) {
    warn(`Detection error for ${platform}:`, err.message);
    return false;
  }
}

// --- Reporting ---

function reportMeetingStatus(platform, isActive) {
  if (isActive) {
    consecutiveInactiveChecks = 0;
  } else {
    consecutiveInactiveChecks++;
    // Don't report inactive until threshold reached (prevents DOM flicker)
    if (consecutiveInactiveChecks < INACTIVE_THRESHOLD) return;
  }

  // Only report on state changes to avoid spamming
  if (isActive === lastReportedActive) return;
  lastReportedActive = isActive;

  const message = {
    type: isActive ? 'meeting_detected' : 'meeting_ended',
    platform,
    url: location.href,
    title: document.title,
    timestamp: new Date().toISOString()
  };

  log(isActive ? 'Meeting detected:' : 'Meeting ended:', platform);

  if (!isContextValid()) { teardown(); return; }
  chrome.runtime.sendMessage(message, (response) => {
    if (chrome.runtime.lastError) {
      if (chrome.runtime.lastError.message?.includes('context invalidated')) { teardown(); return; }
      warn('Failed to send message to service worker:', chrome.runtime.lastError.message);
    }
  });
}

// --- Periodic Status Report ---
// Sends full status even if unchanged, so the service worker can reconstruct state
// after a restart. This uses 'meeting_status' type to distinguish from event reports.

function sendPeriodicStatus(platform) {
  const isActive = checkMeetingActive(platform);

  if (isActive) {
    consecutiveInactiveChecks = 0;
  } else {
    consecutiveInactiveChecks++;
  }

  // Don't report inactive unless threshold reached (prevents DOM flicker false negatives)
  const reportActive = isActive || consecutiveInactiveChecks < INACTIVE_THRESHOLD;

  const message = {
    type: 'meeting_status',
    platform,
    is_active: reportActive,
    url: location.href,
    title: document.title,
    timestamp: new Date().toISOString()
  };

  if (!isContextValid()) { teardown(); return; }
  chrome.runtime.sendMessage(message, (response) => {
    if (chrome.runtime.lastError) {
      if (chrome.runtime.lastError.message?.includes('context invalidated')) { teardown(); return; }
      warn('Periodic status send failed:', chrome.runtime.lastError.message);
    }
  });
}

// --- Mutation Handling ---

function onDomMutation() {
  if (!isContextValid()) { teardown(); return; }
  if (mutationDebounceTimer) return;
  mutationDebounceTimer = setTimeout(() => {
    mutationDebounceTimer = null;
    if (currentPlatform) {
      const isActive = checkMeetingActive(currentPlatform);
      reportMeetingStatus(currentPlatform, isActive);
    }
  }, MUTATION_DEBOUNCE_MS);
}

// --- Initialization ---

function init() {
  currentPlatform = detectPlatform();
  if (!currentPlatform) {
    log('No matching meeting platform detected for URL:', location.href);
    return;
  }

  log(`Platform detected: ${currentPlatform}`);

  // MutationObserver for dynamic DOM changes
  observer = new MutationObserver(onDomMutation);
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'style', 'aria-label', 'data-meeting-code', 'data-is-muted', 'data-tid']
  });

  // Periodic full-state report (heartbeat-style, so service worker recovers after restart)
  periodicCheckTimer = setInterval(() => {
    sendPeriodicStatus(currentPlatform);
  }, CHECK_INTERVAL_MS);

  // Initial check after a short delay to let the page fully render
  setTimeout(() => {
    const isActive = checkMeetingActive(currentPlatform);
    reportMeetingStatus(currentPlatform, isActive);
    log('Initial check complete, active:', isActive);
  }, INITIAL_CHECK_DELAY_MS);
}

// --- Start ---

log('Content script loaded for:', location.href);
init();
