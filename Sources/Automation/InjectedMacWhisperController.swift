import AppKit
import Foundation

/// Error types specific to the injection approach.
enum InjectionError: Error, CustomStringConvertible, Sendable {
    case macWhisperNotInstalled
    case compileFailed(String)
    case copyFailed(String)
    case resignFailed(String)

    var description: String {
        switch self {
        case .macWhisperNotInstalled: "MacWhisper not installed at /Applications/MacWhisper.app"
        case .compileFailed(let msg): "Dylib compilation failed: \(msg)"
        case .copyFailed(let msg): "Failed to copy MacWhisper: \(msg)"
        case .resignFailed(let msg): "Failed to re-sign MacWhisper: \(msg)"
        }
    }
}

/// Controls MacWhisper recording via DYLD injection and Unix socket IPC.
///
/// Instead of the external Accessibility API, this approach:
/// 1. Creates a re-signed copy of MacWhisper that accepts DYLD injection
/// 2. Injects a dylib that exposes a Unix socket control interface
/// 3. Sends commands via the socket to control recording
///
/// The injected dylib provides two recording mechanisms:
/// - **Start**: Internal AX button press (`ax_record Record Teams`) - bypasses
///   MacWhisper's broken meeting detection dialogs by pressing per-app buttons directly
/// - **Stop**: ObjC method invocation (`stopRecordingMeeting`) on `StatusBarItemManager`
///   found via SwiftUI delegate chain traversal
/// - **Status**: Internal AX tree scan for "Active Recordings" heading
///
/// Advantages over external Accessibility API:
/// - No Accessibility permission needed (in-process AX is unrestricted)
/// - Direct button press bypasses detection confirmation dialogs
/// - No window focus manipulation
///
/// Disadvantages:
/// - Requires running a modified (ad-hoc signed) copy of MacWhisper
/// - Must re-prepare after MacWhisper updates
/// - Two copies of MacWhisper on disk
final class InjectedMacWhisperController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macwhisperauto.injection")
    private let socketPath = "/tmp/macwhisper_control.sock"
    private let realBundleID = "com.goodsnooze.MacWhisper"
    private let supportDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("MacWhisperAuto/Injectable")
    }

    private var injectableAppPath: String {
        supportDir.appendingPathComponent("MacWhisper.app").path
    }
    private var dylibPath: String {
        supportDir.appendingPathComponent("mw_inject.dylib").path
    }
    private var dylibSourcePath: String {
        supportDir.appendingPathComponent("mw_inject.m").path
    }
    private var entitlementsPath: String {
        supportDir.appendingPathComponent("inject-entitlements.plist").path
    }
    private var binaryPath: String {
        supportDir.appendingPathComponent("MacWhisper.app/Contents/MacOS/MacWhisper").path
    }

    var isPrepared: Bool {
        FileManager.default.fileExists(atPath: injectableAppPath)
            && FileManager.default.fileExists(atPath: dylibPath)
    }

    // MARK: - Public API (same interface as MacWhisperController)

    /// Start recording for a platform via internal AX button press.
    /// Sends `ax_record Record <Platform>` which presses the per-app button in MacWhisper,
    /// bypassing the broken detection confirmation dialogs.
    func startRecording(
        for platform: Platform,
        completion: @escaping @Sendable (Result<Void, AXError>) -> Void
    ) {
        queue.async { [self] in
            let result = performStartRecording(platform: platform)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stop recording via socket command.
    func stopRecording(completion: @escaping @Sendable (Result<Void, AXError>) -> Void) {
        queue.async { [self] in
            let result = performStopRecording()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Check if MacWhisper is actively recording by scanning the AX tree.
    func checkRecordingStatus(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let response = sendSocketCommand("ax_status")
            let recording = response == "OK:recording"
            DispatchQueue.main.async { completion(recording) }
        }
    }

    /// Ensure the injectable MacWhisper is prepared and running.
    /// Prepares (copy + resign + compile) if needed, then launches with injection.
    func launchIfNeeded(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            let result = performLaunchIfNeeded()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Force-quit the injectable MacWhisper process.
    func forceQuit() -> Bool {
        // Kill by bundle ID - both real and injectable share the same ID
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: realBundleID)
        var killed = false
        for app in apps where app.bundleURL?.path.contains("Injectable") == true {
            app.forceTerminate()
            killed = true
        }
        return killed
    }

    /// Force-quit and relaunch the injectable MacWhisper.
    func forceQuitAndRelaunch(completion: @escaping @Sendable (Bool) -> Void) {
        DetectionLogger.shared.automation(
            "Force quitting injectable MacWhisper for relaunch", action: "forceQuitRelaunch"
        )
        _ = forceQuit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            launchIfNeeded(completion: completion)
        }
    }

    /// Prepare injection environment in background (call early, e.g., on app launch).
    func prepareInBackground() {
        queue.async { [self] in
            if isPrepared {
                DetectionLogger.shared.automation("Injection already prepared", action: "prepare")
                return
            }
            let result = performPrepare()
            switch result {
            case .success:
                DetectionLogger.shared.automation("Injection prepared successfully", action: "prepare")
            case .failure(let error):
                DetectionLogger.shared.error(.automation, "Injection preparation failed: \(error)")
            }
        }
    }

    // MARK: - Private: Preparation

    private func performPrepare() -> Result<Void, InjectionError> {
        DetectionLogger.shared.automation("Preparing injection environment", action: "prepare")

        // Create support directory
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.copyFailed("Cannot create support dir: \(error)"))
        }

        // Write dylib source
        do {
            try Self.dylibSource.write(toFile: dylibSourcePath, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.compileFailed("Cannot write dylib source: \(error)"))
        }

        // Write entitlements
        do {
            try Self.entitlementsPlist.write(
                toFile: entitlementsPath, atomically: true, encoding: .utf8
            )
        } catch {
            return .failure(.resignFailed("Cannot write entitlements: \(error)"))
        }

        // Compile dylib
        let compileResult = shell(
            "clang -dynamiclib -framework Foundation -framework AppKit -framework ApplicationServices"
            + " -o '\(dylibPath)' '\(dylibSourcePath)' 2>&1"
        )
        guard compileResult.status == 0 else {
            return .failure(.compileFailed(compileResult.output))
        }
        DetectionLogger.shared.automation("Dylib compiled", action: "prepare")

        // Check real MacWhisper is installed
        guard FileManager.default.fileExists(atPath: "/Applications/MacWhisper.app") else {
            return .failure(.macWhisperNotInstalled)
        }

        // Remove old injectable copy if present
        if FileManager.default.fileExists(atPath: injectableAppPath) {
            try? FileManager.default.removeItem(atPath: injectableAppPath)
        }

        // Copy MacWhisper.app
        let copyResult = shell(
            "/bin/cp -R '/Applications/MacWhisper.app' '\(injectableAppPath)' 2>&1"
        )
        guard copyResult.status == 0 else {
            return .failure(.copyFailed(copyResult.output))
        }
        DetectionLogger.shared.automation("MacWhisper copied to injectable path", action: "prepare")

        // Re-sign with injection entitlements (ad-hoc, strips hardened runtime)
        let signResult = shell(
            "codesign --force --deep --sign -"
            + " --entitlements '\(entitlementsPath)' '\(injectableAppPath)' 2>&1"
        )
        guard signResult.status == 0 else {
            return .failure(.resignFailed(signResult.output))
        }
        DetectionLogger.shared.automation("Injectable MacWhisper signed", action: "prepare")

        return .success(())
    }

    // MARK: - Private: Launch

    private func performLaunchIfNeeded() -> Bool {
        // Already running? Check socket
        if let response = sendSocketCommand("ping"), response.contains("pong") {
            DetectionLogger.shared.automation(
                "Injectable MacWhisper already running (socket responsive)", action: "launch"
            )
            return waitForManager()
        }

        // Prepare if needed
        if !isPrepared {
            let prepResult = performPrepare()
            if case .failure(let error) = prepResult {
                DetectionLogger.shared.error(.automation, "Prepare failed during launch: \(error)")
                return false
            }
        }

        // Kill real MacWhisper if running (can't have two instances)
        let realApps = NSRunningApplication.runningApplications(withBundleIdentifier: realBundleID)
        for app in realApps {
            DetectionLogger.shared.automation(
                "Killing MacWhisper (PID \(app.processIdentifier)) before injection launch",
                action: "launch"
            )
            app.forceTerminate()
        }
        if !realApps.isEmpty {
            Thread.sleep(forTimeInterval: 1.5)
        }

        // Clean up old socket
        unlink(socketPath)

        // Launch injectable copy with dylib injection
        let launchResult = shell(
            "DYLD_INSERT_LIBRARIES='\(dylibPath)' '\(binaryPath)'"
            + " > /dev/null 2>&1 &\necho $!"
        )
        guard launchResult.status == 0 else {
            DetectionLogger.shared.error(
                .automation,
                "Failed to launch injectable MacWhisper: \(launchResult.output)"
            )
            return false
        }

        let pid = launchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        DetectionLogger.shared.automation("Launched injectable MacWhisper (PID \(pid))", action: "launch")

        // Wait for socket to become ready (dylib has 4s startup delay)
        for attempt in 1...20 {
            Thread.sleep(forTimeInterval: 1.0)
            if let response = sendSocketCommand("ping"), response.contains("pong") {
                DetectionLogger.shared.automation(
                    "Socket ready after \(attempt)s", action: "launch"
                )
                return waitForManager()
            }
        }

        DetectionLogger.shared.error(.automation, "Timed out waiting for injection socket")
        return false
    }

    /// Wait for the injected dylib to cache the StatusBarItemManager.
    private func waitForManager() -> Bool {
        for attempt in 1...20 {
            if let status = sendSocketCommand("status"), status.contains("ready") {
                DetectionLogger.shared.automation(
                    "Manager cached and ready (attempt \(attempt))", action: "launch"
                )
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Socket works but manager not cached - might still work later
        DetectionLogger.shared.automation(
            "Socket ready but manager not yet cached - proceeding anyway", action: "launch"
        )
        return true
    }

    // MARK: - Private: Recording Control

    private func performStartRecording(platform: Platform) -> Result<Void, AXError> {
        // Dismiss any modal dialogs first (e.g. "Move to Applications" alert)
        // so AX commands can execute on the main thread
        _ = sendSocketCommand("dismiss")
        Thread.sleep(forTimeInterval: 0.5)

        // If MacWhisper is already recording (e.g. false-positive from broken detection),
        // stop it first - MacWhisper won't start a new recording while one is active
        if let status = sendSocketCommand("ax_status"), status == "OK:recording" {
            DetectionLogger.shared.automation(
                "Stopping existing recording before starting \(platform.displayName)",
                action: "startRecording"
            )
            _ = sendSocketCommand("stop")
            Thread.sleep(forTimeInterval: 1.0)
        }

        let buttonName = platform.macWhisperButtonName
        // ax_record auto-dismisses detection dialogs before pressing the button
        guard let response = sendSocketCommand("ax_record \(buttonName)") else {
            return .failure(.timeout)
        }
        if response == "OK:pressed" {
            // Verify recording actually started (button press can silently fail
            // if MacWhisper's detection state blocks it)
            Thread.sleep(forTimeInterval: 2.0)
            if let status = sendSocketCommand("ax_status"), status == "OK:recording" {
                DetectionLogger.shared.automation(
                    "Recording started for \(platform.displayName) via AX button '\(buttonName)'",
                    action: "startRecording"
                )
                return .success(())
            }
            // Recording didn't start despite button press - try once more after dismiss
            DetectionLogger.shared.automation(
                "Button pressed but recording not active - retrying for \(platform.displayName)",
                action: "startRecording"
            )
            _ = sendSocketCommand("dismiss")
            Thread.sleep(forTimeInterval: 0.5)
            _ = sendSocketCommand("ax_record \(buttonName)")
            Thread.sleep(forTimeInterval: 2.0)
            if let status = sendSocketCommand("ax_status"), status == "OK:recording" {
                DetectionLogger.shared.automation(
                    "Recording started on retry for \(platform.displayName)",
                    action: "startRecording"
                )
                return .success(())
            }
            return .failure(.actionFailed(element: buttonName, action: "ax_record", code: -2))
        }
        if response == "ERR:not_found" {
            return .failure(.elementNotFound(description: "Button '\(buttonName)' not found in AX tree"))
        }
        if response.contains("timeout") {
            return .failure(.timeout)
        }
        return .failure(
            .actionFailed(element: buttonName, action: "ax_record", code: -1)
        )
    }

    private func performStopRecording() -> Result<Void, AXError> {
        // Check if actually recording first to avoid triggering MacWhisper's error alert
        if let statusResponse = sendSocketCommand("ax_status"), statusResponse == "OK:idle" {
            DetectionLogger.shared.automation(
                "Skipping stop - MacWhisper not recording (ax_status=idle)", action: "stopRecording"
            )
            return .success(())
        }

        guard let response = sendSocketCommand("stop") else {
            return .failure(.timeout)
        }
        if response.hasPrefix("OK:") {
            DetectionLogger.shared.automation("Recording stopped via injection", action: "stopRecording")
            return .success(())
        }
        return .failure(
            .actionFailed(element: "injection-socket", action: "stop", code: -1)
        )
    }

    // MARK: - Private: Unix Socket Communication

    private func sendSocketCommand(_ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strlcpy(dest, socketPath, 104)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        guard connectResult == 0 else {
            close(fd)
            return nil
        }

        // 20s timeout (server allows up to 15s for start/stop)
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Send command
        let msg = (command + "\n").utf8CString
        msg.withUnsafeBufferPointer { buf in
            // Don't send the null terminator
            _ = Darwin.write(fd, buf.baseAddress!, buf.count - 1)
        }

        // Read response (server closes connection after responding)
        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = Darwin.read(fd, &buffer, 255)
        close(fd)

        guard bytesRead > 0 else { return nil }
        return String(bytes: buffer[0..<bytesRead], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Shell Execution

    private func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    // MARK: - Embedded Resources

    // swiftlint:disable line_length

    /// The Objective-C dylib source that gets injected into MacWhisper.
    /// Creates a Unix socket at /tmp/macwhisper_control.sock and exposes:
    /// - `ax_record <ButtonDesc>` - press a recording button by AX description
    /// - `ax_status` - check if actively recording via AX tree scan
    /// - `stop` - call stopRecordingMeeting via ObjC runtime
    /// - `ping` / `status` - liveness and manager readiness checks
    static let dylibSource = #"""
    #import <Foundation/Foundation.h>
    #import <AppKit/AppKit.h>
    #import <ApplicationServices/ApplicationServices.h>
    #import <objc/runtime.h>
    #import <sys/socket.h>
    #import <sys/stat.h>
    #import <sys/un.h>
    #import <unistd.h>

    #define SOCKET_PATH "/tmp/macwhisper_control.sock"
    #define MAX_AX_DEPTH 30

    static CFTypeRef g_retainedManager = NULL;
    static NSString *g_managerClassName = nil;

    static id getManager(void) {
        return g_retainedManager ? (__bridge id)g_retainedManager : nil;
    }

    static void cacheManager(void) {
        if (g_retainedManager) return;

        @autoreleasepool {
            @try {
                id delegate = [NSApp delegate];
                if (!delegate) { NSLog(@"[MW_INJECT] No delegate"); return; }

                Ivar iv1 = class_getInstanceVariable([delegate class], "appDelegate");
                if (!iv1) { NSLog(@"[MW_INJECT] No appDelegate ivar"); return; }
                id realDel = object_getIvar(delegate, iv1);
                if (!realDel) { NSLog(@"[MW_INJECT] appDelegate is nil"); return; }

                Ivar iv2 = class_getInstanceVariable([realDel class], "statusBarItemManager");
                if (!iv2) { NSLog(@"[MW_INJECT] No statusBarItemManager ivar"); return; }
                id mgr = object_getIvar(realDel, iv2);
                if (!mgr) { NSLog(@"[MW_INJECT] statusBarItemManager is nil"); return; }

                g_managerClassName = [NSStringFromClass([mgr class]) copy];
                g_retainedManager = CFBridgingRetain(mgr);
                NSLog(@"[MW_INJECT] Cached: %@ at %p", g_managerClassName, mgr);

                BOOL hasStart = [mgr respondsToSelector:@selector(startRecordingMeeting:)];
                BOOL hasStop = [mgr respondsToSelector:@selector(stopRecordingMeeting)];
                NSLog(@"[MW_INJECT] startRecordingMeeting: %@, stopRecordingMeeting: %@",
                      hasStart ? @"YES" : @"NO", hasStop ? @"YES" : @"NO");
            } @catch (NSException *e) {
                NSLog(@"[MW_INJECT] cacheManager exception: %@", e);
            }
        }
    }

    // --- AX Tree Traversal (in-process, no TCC needed) ---

    static BOOL pressButtonByDescription(AXUIElementRef element, NSString *targetDesc, int depth) {
        if (depth > MAX_AX_DEPTH) return NO;

        CFTypeRef role = NULL;
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role);

        if (role && CFEqual(role, CFSTR("AXButton"))) {
            CFTypeRef desc = NULL;
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute, &desc);
            if (desc) {
                if ([(__bridge NSString *)desc isEqualToString:targetDesc]) {
                    AXError err = AXUIElementPerformAction(element, kAXPressAction);
                    NSLog(@"[MW_INJECT] AXPress '%@' result: %d", targetDesc, (int)err);
                    CFRelease(desc);
                    CFRelease(role);
                    return (err == kAXErrorSuccess);
                }
                CFRelease(desc);
            }
        }
        if (role) CFRelease(role);

        CFTypeRef children = NULL;
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children);
        if (children) {
            CFIndex count = CFArrayGetCount(children);
            for (CFIndex i = 0; i < count; i++) {
                AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
                if (pressButtonByDescription(child, targetDesc, depth + 1)) {
                    CFRelease(children);
                    return YES;
                }
            }
            CFRelease(children);
        }
        return NO;
    }

    static BOOL findTextInTree(AXUIElementRef element, NSString *needle, int depth) {
        if (depth > MAX_AX_DEPTH) return NO;

        // Check all text-bearing attributes: value, title, and description
        CFStringRef attrs[] = { kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute };
        for (int a = 0; a < 3; a++) {
            CFTypeRef val = NULL;
            AXUIElementCopyAttributeValue(element, attrs[a], &val);
            if (val && CFGetTypeID(val) == CFStringGetTypeID()) {
                if ([(__bridge NSString *)val containsString:needle]) { CFRelease(val); return YES; }
            }
            if (val) CFRelease(val);
        }

        CFTypeRef children = NULL;
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children);
        if (children) {
            CFIndex count = CFArrayGetCount(children);
            for (CFIndex i = 0; i < count; i++) {
                AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
                if (findTextInTree(child, needle, depth + 1)) { CFRelease(children); return YES; }
            }
            CFRelease(children);
        }
        return NO;
    }

    // --- Dialog Dismissal ---

    static BOOL pressButtonByTitle(AXUIElementRef element, NSString *targetTitle, int depth) {
        if (depth > MAX_AX_DEPTH) return NO;

        CFTypeRef role = NULL;
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role);

        if (role && CFEqual(role, CFSTR("AXButton"))) {
            CFTypeRef title = NULL;
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &title);
            if (title) {
                if ([(__bridge NSString *)title isEqualToString:targetTitle]) {
                    AXError err = AXUIElementPerformAction(element, kAXPressAction);
                    NSLog(@"[MW_INJECT] AXPress title '%@' result: %d", targetTitle, (int)err);
                    CFRelease(title);
                    CFRelease(role);
                    return (err == kAXErrorSuccess);
                }
                CFRelease(title);
            }
        }
        if (role) CFRelease(role);

        CFTypeRef children = NULL;
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children);
        if (children) {
            CFIndex count = CFArrayGetCount(children);
            for (CFIndex i = 0; i < count; i++) {
                AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
                if (pressButtonByTitle(child, targetTitle, depth + 1)) {
                    CFRelease(children);
                    return YES;
                }
            }
            CFRelease(children);
        }
        return NO;
    }

    static int dismissDetectionDialogs(AXUIElementRef app) {
        int dismissed = 0;
        CFTypeRef windowsRef = NULL;
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsRef);
        if (!windowsRef) return 0;

        CFIndex count = CFArrayGetCount(windowsRef);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windowsRef, i);

            // Check if this window contains detection-related text
            BOOL isDetection = findTextInTree(win, @"Detected", 3)
                            || findTextInTree(win, @"Finish Recording", 3);
            if (isDetection) {
                // Press "Close" button to dismiss detection dialog
                if (pressButtonByDescription(win, @"Close", 0)) {
                    NSLog(@"[MW_INJECT] Dismissed detection dialog");
                    dismissed++;
                }
                continue;
            }

            // Check for "Move to Applications" alert
            BOOL isMoveAlert = findTextInTree(win, @"Move to Applications", 3);
            if (isMoveAlert) {
                if (pressButtonByTitle(win, @"Do Not Move", 0)) {
                    NSLog(@"[MW_INJECT] Dismissed app translocation alert");
                    dismissed++;
                }
            }
        }
        CFRelease(windowsRef);
        return dismissed;
    }

    // --- Socket Command Handler ---

    static void handleClient(int clientFd) {
        char buf[256] = {0};
        ssize_t n = read(clientFd, buf, sizeof(buf) - 1);
        if (n <= 0) { close(clientFd); return; }
        while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';

        NSLog(@"[MW_INJECT] cmd: %s", buf);
        const char *response = "ERR:unknown\n";

        if (strcmp(buf, "ping") == 0) {
            response = "OK:pong\n";
            write(clientFd, response, strlen(response));
            close(clientFd);
            return;
        }

        if (strcmp(buf, "status") == 0) {
            if (!g_retainedManager) cacheManager();
            response = g_retainedManager ? "OK:ready\n" : "ERR:no_manager\n";
            write(clientFd, response, strlen(response));
            close(clientFd);
            return;
        }

        __block const char *result = "ERR:fail\n";
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        // dismiss: Close modal dialogs via NSApp APIs (no AX, no main thread dependency)
        if (strcmp(buf, "dismiss") == 0) {
            // Stop any active modal session to unblock the main run loop
            [NSApp performSelectorOnMainThread:@selector(abortModal) withObject:nil waitUntilDone:NO
                modes:@[NSModalPanelRunLoopMode, NSDefaultRunLoopMode]];
            usleep(200000); // 200ms for modal to dismiss
            const char *resp = "OK:dismissed\n";
            write(clientFd, resp, strlen(resp));
            NSLog(@"[MW_INJECT] dismiss: abortModal sent");
            close(clientFd);
            return;
        }
        // AX commands dispatch to main thread. If modal is active they'll block,
        // so caller should send "dismiss" first.
        if (strncmp(buf, "ax_record ", 10) == 0) {
            NSString *buttonDesc = [NSString stringWithUTF8String:buf + 10];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    AXUIElementRef app = AXUIElementCreateApplication(getpid());

                    // Auto-dismiss blocking detection dialogs first
                    int dismissed = dismissDetectionDialogs(app);
                    if (dismissed > 0) {
                        NSLog(@"[MW_INJECT] ax_record: dismissed %d dialogs", dismissed);
                    }

                    BOOL pressed = pressButtonByDescription(app, buttonDesc, 0);
                    CFRelease(app);
                    result = pressed ? "OK:pressed\n" : "ERR:not_found\n";
                    NSLog(@"[MW_INJECT] ax_record '%@': %s", buttonDesc, pressed ? "pressed" : "not found");
                } @catch (NSException *e) {
                    NSLog(@"[MW_INJECT] ax_record exception: %@", e);
                    result = "ERR:exception\n";
                }
                dispatch_semaphore_signal(sem);
            });
        }
        else if (strcmp(buf, "ax_status") == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    AXUIElementRef app = AXUIElementCreateApplication(getpid());
                    BOOL recording = findTextInTree(app, @"Active Recordings", 0);
                    CFRelease(app);
                    result = recording ? "OK:recording\n" : "OK:idle\n";
                } @catch (NSException *e) {
                    NSLog(@"[MW_INJECT] ax_status exception: %@", e);
                    result = "ERR:exception\n";
                }
                dispatch_semaphore_signal(sem);
            });
        }
        else if (strcmp(buf, "stop") == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    id mgr = getManager();
                    if (!mgr) { result = "ERR:no_mgr\n"; }
                    else {
                        SEL sel = @selector(stopRecordingMeeting);
                        NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
                        if (!sig) { result = "ERR:no_sig\n"; }
                        else {
                            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                            [inv setTarget:mgr];
                            [inv setSelector:sel];
                            [inv invoke];
                            NSLog(@"[MW_INJECT] stopRecordingMeeting OK");
                            result = "OK:stop\n";
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[MW_INJECT] stop exception: %@", e);
                    result = "ERR:exception\n";
                }
                dispatch_semaphore_signal(sem);
            });
        }
        else {
            write(clientFd, "ERR:unknown\n", 12);
            close(clientFd);
            return;
        }

        long rc = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
        if (rc != 0) result = "ERR:timeout\n";

        write(clientFd, result, strlen(result));
        close(clientFd);
    }

    __attribute__((constructor))
    static void inject_init(void) {
        NSLog(@"[MW_INJECT] Active, PID %d", getpid());

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            sleep(4);

            unlink(SOCKET_PATH);
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            if (fd < 0) return;

            struct sockaddr_un addr = {};
            addr.sun_family = AF_UNIX;
            strlcpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path));
            if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return; }
            chmod(SOCKET_PATH, 0777);
            listen(fd, 5);
            NSLog(@"[MW_INJECT] Socket ready");

            dispatch_async(dispatch_get_main_queue(), ^{ cacheManager(); });

            while (1) {
                int c = accept(fd, NULL, NULL);
                if (c < 0) continue;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    @autoreleasepool { handleClient(c); }
                });
            }
        });
    }
    """#

    /// Entitlements plist that allows DYLD injection into the re-signed MacWhisper copy.
    static let entitlementsPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.cs.allow-dyld-environment-variables</key>
        <true/>
        <key>com.apple.security.cs.disable-library-validation</key>
        <true/>
        <key>com.apple.security.get-task-allow</key>
        <true/>
        <key>com.apple.security.device.audio-input</key>
        <true/>
        <key>com.apple.security.personal-information.calendars</key>
        <true/>
    </dict>
    </plist>
    """

    // swiftlint:enable line_length
}
