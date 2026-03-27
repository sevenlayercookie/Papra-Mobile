//
//  PapraSharedSettings.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Foundation

enum PapraSharedSettings {
    nonisolated static let appGroupIdentifier = "group.sevenlayercookie.Papra-Mobile"
    nonisolated static let baseURLKey = "papra.baseURL"
    nonisolated static let apiTokenKey = "papra.apiToken"
    nonisolated static let organizationIDKey = "papra.organizationID"
    nonisolated static let customHeadersKey = "papra.customHeaders"
    nonisolated static let ocrLanguagesKey = "papra.ocrLanguages"
    nonisolated static let shortcutInboxFolderName = "ShortcutInbox"
    nonisolated static let shortcutMetadataSuffix = ".papra-metadata.json"

    nonisolated static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    nonisolated static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    nonisolated static func shortcutInboxURL() throws -> URL {
        guard let containerURL = sharedContainerURL() else {
            throw CocoaError(.fileNoSuchFile)
        }

        let inboxURL = containerURL.appendingPathComponent(shortcutInboxFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        return inboxURL
    }

    nonisolated static func shortcutMetadataURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + shortcutMetadataSuffix)
    }

    nonisolated static func isShortcutMetadataFile(_ fileURL: URL) -> Bool {
        fileURL.lastPathComponent.hasSuffix(shortcutMetadataSuffix)
    }
}

struct ShortcutInboxMetadata: Equatable, Sendable {
    let tagName: String?

    nonisolated init(tagName: String?) {
        self.tagName = tagName
    }

    nonisolated init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        tagName = object?["tagName"] as? String
    }

    nonisolated func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tagName": tagName as Any])
    }
}
