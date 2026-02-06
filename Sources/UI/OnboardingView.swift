import SwiftUI

struct OnboardingView: View {
    let permissionManager: PermissionManager
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var checkTimer: Timer?

    private var allGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacWhisperAuto Setup")
                .font(.headline)

            Text("The following permissions are required for meeting detection and recording automation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            PermissionRow(
                title: "Accessibility",
                description: "Required to control MacWhisper's recording buttons",
                isGranted: accessibilityGranted,
                action: {
                    permissionManager.promptAccessibility()
                    permissionManager.openAccessibilitySettings()
                }
            )

            PermissionRow(
                title: "Screen Recording",
                description: "Required to detect meeting windows by title",
                isGranted: screenRecordingGranted,
                action: {
                    permissionManager.openScreenRecordingSettings()
                }
            )

            if allGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All permissions granted. Ready to detect meetings.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                .padding(.top, 4)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { startPermissionPolling() }
        .onDisappear { stopPermissionPolling() }
    }

    // MARK: - Polling

    private func startPermissionPolling() {
        refreshPermissions()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refreshPermissions() }
        }
    }

    private func stopPermissionPolling() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func refreshPermissions() {
        let perms = permissionManager.checkAll()
        accessibilityGranted = perms[.accessibility] ?? false
        screenRecordingGranted = perms[.screenRecording] ?? false
    }
}

// MARK: - PermissionRow

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(isGranted ? .green : .red)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
