#if os(macOS)
import AppKit
import Foundation
import Observation

struct AppRelease: Decodable {
    static let repository = "Austin-Almighty/MacLocalAudioTranscription"
    static let assetName = "LocalTranscription-macOS-arm64.zip"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let state: String
        let browser_download_url: URL
    }

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }

    var downloadURL: URL? {
        let expected = "https://github.com/\(Self.repository)/releases/download/\(tag_name)/\(Self.assetName)"
        return assets.first {
            $0.name == Self.assetName && $0.state == "uploaded"
                && $0.browser_download_url.absoluteString == expected
        }?.browser_download_url
    }

    static func availableUpdate(data: Data, statusCode: Int, installedVersion: String) throws -> AppRelease? {
        guard statusCode != 404 else { throw UpdateError.noRelease }
        guard statusCode != 403 && statusCode != 429 else { throw UpdateError.rateLimited }
        guard statusCode == 200 else { throw UpdateError.server(statusCode) }
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard !release.draft, !release.prerelease, release.published_at != nil else {
            throw UpdateError.noRelease
        }
        let installed = try versionComponents(installedVersion)
        let latest = try versionComponents(release.version)
        guard installed.lexicographicallyPrecedes(latest) else { return nil }
        guard release.downloadURL != nil else { throw UpdateError.missingDownload }
        return release
    }

    private static func versionComponents(_ version: String) throws -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { throw UpdateError.invalidVersion }
        let numbers = try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { throw UpdateError.invalidVersion }
            return number
        }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

enum UpdateError: LocalizedError {
    case noRelease, rateLimited, missingDownload, invalidVersion, server(Int)

    var errorDescription: String? {
        switch self {
        case .noRelease: "No official release is available yet. Please try again after the first release is published."
        case .rateLimited: "GitHub is temporarily limiting update checks. Please try again later."
        case .missingDownload: "A newer release exists, but its Mac download is not available yet. Please try again later."
        case .invalidVersion: "The release version could not be read. Please check the official releases page."
        case .server(let status): "The update server returned HTTP \(status). Please try again later."
        }
    }
}

@MainActor
@Observable
final class AppUpdater {
    private(set) var isChecking = false

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var alert = NSAlert()
        do {
            guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                throw UpdateError.invalidVersion
            }
            var request = URLRequest(url: AppRelease.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if let release = try AppRelease.availableUpdate(data: data, statusCode: response.statusCode, installedVersion: installed) {
                alert.messageText = "Local Transcription \(release.version) Is Available"
                alert.informativeText = "You have version \(installed). Download the new version, open the ZIP file, and replace the app in Applications. If you installed with Homebrew, use brew update followed by brew upgrade --cask local-transcription instead."
                alert.addButton(withTitle: "Download Update")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn, let url = release.downloadURL {
                    if !NSWorkspace.shared.open(url) {
                        throw URLError(.cannotOpenFile)
                    }
                }
                return
            }
            alert.messageText = "You’re Up to Date"
            alert.informativeText = "Local Transcription \(installed) is the latest official version."
        } catch {
            alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unable to Check for Updates"
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
