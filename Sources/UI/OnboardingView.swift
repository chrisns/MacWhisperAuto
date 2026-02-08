import SwiftUI

struct OnboardingView: View {
    let permissionManager: PermissionManager
    @State private var screenRecordingGranted = false
    @State private var checkTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacWhisperAuto Setup")
                .font(.headline)

            Text(
                "Screen Recording permission improves meeting detection accuracy."
                + " Recording automation works without any permissions (via DYLD injection)."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            PermissionRow(
                title: "Screen Recording",
                description: "Recommended for window-title-based meeting detection",
                isGranted: screenRecordingGranted,
                action: {
                    permissionManager.openScreenRecordingSettings()
                }
            )

            if screenRecordingGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready to detect meetings and record automatically.")
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
