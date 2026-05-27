import SwiftUI

struct StatusMenuView: View {
    let appState: AppState
    var onForceQuitRelaunch: (() -> Void)?
    var onRetry: (() -> Void)?
    var onManualRecord: ((String) -> Void)?
    var onStopRecording: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            Divider()

            if let missingPlatform = appState.macWhisperMenuItemMissing {
                menuMismatchWarning(platform: missingPlatform)
                Divider()
            }

            if case .error(let errorKind) = appState.meetingState {
                ErrorView(
                    errorKind: errorKind,
                    onForceQuit: onForceQuitRelaunch,
                    onRetry: onRetry
                )
                Divider()
            }

            if case .recording(let platform) = appState.meetingState {
                recordingInfo(platform: platform)
                stopButton
                Divider()
            } else {
                recordButtons
                Divider()
            }

            activityLog

            Divider()

            footerControls
        }
        .padding(16)
        .frame(width: 320, height: 420)
    }

    // MARK: - Components

    private var statusHeader: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("MacWhisperAuto")
                    .font(.headline)
                Text(appState.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch appState.meetingState {
        case .idle:
            Image(systemName: "mic.circle")
                .font(.title)
                .foregroundStyle(.secondary)
        case .detecting:
            Image(systemName: "waveform.circle")
                .font(.title)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        case .recording:
            if appState.macWhisperObservedRecording {
                Image(systemName: "record.circle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            } else {
                Image(systemName: "record.circle")
                    .font(.title)
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.yellow)
        }
    }

    private func recordingInfo(platform: Platform) -> some View {
        let confirmed = appState.macWhisperObservedRecording
        return HStack {
            Image(systemName: confirmed ? "record.circle.fill" : "record.circle")
                .foregroundStyle(confirmed ? .red : .orange)
                .symbolEffect(.pulse)
            VStack(alignment: .leading) {
                Text(confirmed ? "Recording" : "Starting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(platform.displayName)
                    .font(.body)
                    .fontWeight(.medium)
            }
            Spacer()
        }
        .padding(8)
        .background((confirmed ? Color.red : Color.orange).opacity(0.1))
        .cornerRadius(8)
    }

    private func menuMismatchWarning(platform: Platform) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("MacWhisper menu may have changed")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("Couldn't find a '\(platform.displayName)' item under Record Meeting. See logs for the titles MacWhisper is exposing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.1))
        .cornerRadius(6)
    }

    private static let manualTargets: [(label: String, button: String)] = [
        ("Comet", "Record Comet"),
        ("Chrome", "Record Chrome"),
        ("Teams", "Record Teams"),
        ("Zoom", "Record Zoom"),
        ("Slack", "Record Slack"),
        ("System", "Record All System Audio"),
    ]

    private var recordButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Record")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
            ], spacing: 6) {
                ForEach(Self.manualTargets, id: \.button) { target in
                    Button(target.label) {
                        onManualRecord?(target.button)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption)
                }
            }
        }
    }

    private var stopButton: some View {
        Button {
            onStopRecording?()
        } label: {
            Label("Stop Recording", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.regular)
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Activity")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.recentActivity.isEmpty {
                Text("No activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.recentActivity) { entry in
                            ActivityRow(entry: entry)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private var footerControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !appState.extensionConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Browser extension not connected", systemImage: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Load the Extension folder as an unpacked extension in your Chromium browser (Comet) to detect browser-based meetings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.orange.opacity(0.05))
                .cornerRadius(6)
            }

            if appState.extensionVersionMismatch {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Extension v\(appState.extensionVersion ?? "?") does not match app v\(appState.appVersion)")
                        .font(.caption2)
                }
                .padding(8)
                .background(.orange.opacity(0.08))
                .cornerRadius(6)
            }

            if appState.appUpdateAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("v\(appState.latestReleaseVersion ?? "") available (you have v\(appState.appVersion))")
                        .font(.caption2)
                }
                .padding(8)
                .background(.blue.opacity(0.08))
                .cornerRadius(6)
            }

            HStack {
                Text("v\(appState.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: AppState.ActivityEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if let platform = entry.platform {
                Text(platform.rawValue)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
            }

            Text(entry.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
