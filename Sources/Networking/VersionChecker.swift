import Foundation

/// Checks the latest stable release version from GitHub.
/// Returns nil on any failure (no network, rate limited, no releases).
enum VersionChecker {
    private static let releasesURL = URL(string: "https://api.github.com/repos/chrisns/MacWhisperAuto/releases/latest")!

    static func fetchLatestVersion() async -> String? {
        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            // Strip "v" prefix if present
            return tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        } catch {
            DetectionLogger.shared.webSocket("Version check failed: \(error.localizedDescription)")
            return nil
        }
    }
}
