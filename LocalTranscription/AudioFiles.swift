import Foundation
import UniformTypeIdentifiers

/// Sorts dropped or chosen files into recordings and everything else.
enum AudioFiles {
    static func partition(_ urls: [URL]) -> (audio: [URL], rejected: [URL]) {
        var audio: [URL] = [], rejected: [URL] = []
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
            if url.isFileURL, type?.conforms(to: .audio) == true {
                audio.append(url)
            } else {
                rejected.append(url)
            }
        }
        return (audio, rejected)
    }
}

/// Why a file can’t be transcribed before it is even opened.
enum ImportError: LocalizedError, Equatable {
    case notLocal, missing, folder, unreadable

    static func check(_ url: URL) throws {
        guard url.isFileURL else { throw ImportError.notLocal }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw ImportError.missing }
        guard !isFolder.boolValue else { throw ImportError.folder }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ImportError.unreadable }
    }

    var errorDescription: String? {
        switch self {
        case .notLocal: "Only files on this device can be transcribed."
        case .missing: "The file no longer exists. It may have been moved or deleted."
        case .folder: "It’s a folder, not an audio file."
        case .unreadable: "You don’t have permission to read it."
        }
    }
}
