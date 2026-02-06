import SwiftUI

struct ErrorView: View {
    let errorKind: ErrorKind
    let onForceQuit: (() -> Void)?
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Text("Error")
                    .font(.headline)
            }

            Text(errorKind.userDescription)
                .font(.body)

            HStack {
                if case .macWhisperUnresponsive = errorKind, let onForceQuit {
                    Button("Force Quit & Relaunch") {
                        onForceQuit()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }

                if let onRetry {
                    Button("Retry") {
                        onRetry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.05))
        .cornerRadius(8)
    }
}
