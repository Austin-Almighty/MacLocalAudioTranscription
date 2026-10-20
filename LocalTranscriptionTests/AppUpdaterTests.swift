#if os(macOS)
import Foundation
import Testing
@testable import LocalTranscription

struct AppUpdaterTests {
    private func response(tag: String = "v1.1.0", draft: Bool = false, prerelease: Bool = false,
                          published: Bool = true, download: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "published_at": published ? "2026-10-20T00:00:00Z" as Any : NSNull(),
            "assets": [["name": AppRelease.assetName, "state": "uploaded",
                        "browser_download_url": download ?? "https://github.com/\(AppRelease.repository)/releases/download/\(tag)/\(AppRelease.assetName)"]]
        ])
    }

    @Test(arguments: [("v1.1.0", "1.0", true), ("v1.10.0", "1.9.9", true),
                      ("2.0", "1.99.99", true), ("v1.0.0", "1.0", false),
                      ("1.0", "1.0.0", false), ("v1.0.1", "2.0", false)])
    func comparesVersionsNumerically(tag: String, installed: String, newer: Bool) throws {
        let update = try AppRelease.availableUpdate(data: response(tag: tag), statusCode: 200, installedVersion: installed)
        #expect((update != nil) == newer)
        if let update { #expect(update.downloadURL?.host == "github.com") }
    }

    @Test(arguments: ["v1.1-beta", "v1..2", "v1.2.3.4", "v", "v1.-1", "v999999999999999999999999"])
    func rejectsInvalidVersions(tag: String) throws {
        let data = try response(tag: tag)
        #expect(throws: UpdateError.self) {
            try AppRelease.availableUpdate(data: data, statusCode: 200, installedVersion: "1.0")
        }
    }

    @Test func rejectsUnpublishedReleases() throws {
        for data in [try response(draft: true), try response(prerelease: true), try response(published: false)] {
            #expect(throws: UpdateError.self) {
                try AppRelease.availableUpdate(data: data, statusCode: 200, installedVersion: "1.0")
            }
        }
    }

    @Test(arguments: ["http://github.com/download.zip", "https://example.com/download.zip",
                      "https://github.com/another/repo/releases/download/v1.1.0/LocalTranscription-macOS-arm64.zip"])
    func rejectsUnofficialDownloads(url: String) throws {
        let data = try response(download: url)
        #expect(throws: UpdateError.self) {
            try AppRelease.availableUpdate(data: data, statusCode: 200, installedVersion: "1.0")
        }
    }

    @Test func rejectsMissingAssetsAndMalformedResponses() throws {
        for json in ["{}", "not JSON", "{\"tag_name\":\"v1.1.0\",\"draft\":false,\"prerelease\":false,\"published_at\":\"2026-10-20\",\"assets\":[]}"] {
            #expect(throws: (any Error).self) {
                try AppRelease.availableUpdate(data: Data(json.utf8), statusCode: 200, installedVersion: "1.0")
            }
        }
    }

    @Test(arguments: [404, 403, 429, 500])
    func reportsHTTPFailures(status: Int) {
        #expect(throws: UpdateError.self) {
            try AppRelease.availableUpdate(data: Data(), statusCode: status, installedVersion: "1.0")
        }
    }
}
#endif
