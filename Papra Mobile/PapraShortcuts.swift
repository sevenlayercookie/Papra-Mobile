//
//  PapraShortcuts.swift
//  Papra Mobile
//
//  Created by Codex.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

struct AddFileToPapraIntent: AppIntent {
    static let title: LocalizedStringResource = "Add File to Papra"
    static let description = IntentDescription("Queue a file for upload to Papra and open the app to finish processing.")
    static let openAppWhenRun = false

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Tag")
    var tagName: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let normalizedTagName = tagName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queuedItem = try ShortcutInboxWriter.store(file: file, tagName: normalizedTagName)

        if let configuration = PapraShortcutConfiguration.load() {
            do {
                let api = PapraAPI(configuration: configuration.configuration)
                let uploadedDocument = try await api
                    .uploadDocumentReturningDocument(
                        organizationID: configuration.organizationID,
                        fileURL: queuedItem.fileURL,
                        ocrLanguages: configuration.ocrLanguages
                    )
                if let tagName = normalizedTagName, !tagName.isEmpty {
                    try await applyTag(
                        named: tagName,
                        to: uploadedDocument.id,
                        api: api,
                        organizationID: configuration.organizationID
                    )
                }
                try? FileManager.default.removeItem(at: queuedItem.fileURL)
                if let metadataURL = queuedItem.metadataURL {
                    try? FileManager.default.removeItem(at: metadataURL)
                }
                return .result(dialog: "Added to Papra.")
            } catch {
                return .result(dialog: "Queued for upload in Papra.")
            }
        }

        return .result(dialog: "Queued for upload in Papra.")
    }
}

struct PapraShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddFileToPapraIntent(),
            phrases: [
                "Add file to \(.applicationName)",
                "Send file to \(.applicationName)"
            ],
            shortTitle: "Add File",
            systemImageName: "square.and.arrow.down.on.square"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .teal
    }
}

private enum ShortcutInboxWriter {
    nonisolated static func store(file: IntentFile, tagName: String?) throws -> StoredShortcutItem {
        let inboxURL = try PapraSharedSettings.shortcutInboxURL()
        let destinationURL = inboxURL.appendingPathComponent(uniqueFileName(for: file, in: inboxURL))
        try file.data.write(to: destinationURL, options: .atomic)

        let metadataURL: URL?
        if let tagName, !tagName.isEmpty {
            let metadata = ShortcutInboxMetadata(tagName: tagName)
            let data = try metadata.jsonData()
            let resolvedMetadataURL = PapraSharedSettings.shortcutMetadataURL(for: destinationURL)
            try data.write(to: resolvedMetadataURL, options: .atomic)
            metadataURL = resolvedMetadataURL
        } else {
            metadataURL = nil
        }

        return StoredShortcutItem(fileURL: destinationURL, metadataURL: metadataURL)
    }

    private nonisolated static func uniqueFileName(for file: IntentFile, in directoryURL: URL) -> String {
        let preferredExtension = file.type?.preferredFilenameExtension
        let rawFileName = file.filename.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedFileName: String
        if rawFileName.isEmpty {
            normalizedFileName = "File" + preferredPathExtension(from: preferredExtension)
        } else if URL(fileURLWithPath: rawFileName).pathExtension.isEmpty, let preferredExtension {
            normalizedFileName = rawFileName + "." + preferredExtension
        } else {
            normalizedFileName = rawFileName
        }

        let fileManager = FileManager.default
        let fileExtension = URL(fileURLWithPath: normalizedFileName).pathExtension
        let baseName = (normalizedFileName as NSString).deletingPathExtension

        var candidate = normalizedFileName
        var counter = 2
        while fileManager.fileExists(atPath: directoryURL.appendingPathComponent(candidate).path) {
            let suffix = " \(counter)"
            candidate = fileExtension.isEmpty ? baseName + suffix : baseName + suffix + "." + fileExtension
            counter += 1
        }

        return candidate
    }

    private nonisolated static func preferredPathExtension(from pathExtension: String?) -> String {
        guard let pathExtension, !pathExtension.isEmpty else { return "" }
        return "." + pathExtension
    }
}

private struct StoredShortcutItem {
    let fileURL: URL
    let metadataURL: URL?
}

private struct PapraShortcutConfiguration {
    let configuration: PapraConfiguration
    let organizationID: String
    let ocrLanguages: String?

    nonisolated static func load() -> PapraShortcutConfiguration? {
        let defaults = PapraSharedSettings.sharedDefaults
        let baseURL = defaults.string(forKey: PapraSharedSettings.baseURLKey) ?? ""
        let apiToken = defaults.string(forKey: PapraSharedSettings.apiTokenKey) ?? ""
        let organizationID = defaults.string(forKey: PapraSharedSettings.organizationIDKey) ?? ""
        let ocrLanguages = defaults.string(forKey: PapraSharedSettings.ocrLanguagesKey)
        let customHeaders = decodeCustomHeaders(from: defaults.string(forKey: PapraSharedSettings.customHeadersKey) ?? "[]")

        guard !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PapraShortcutConfiguration(
            configuration: PapraConfiguration(
                baseURL: baseURL,
                apiToken: apiToken,
                organizationID: organizationID,
                customHeaders: customHeaders
            ),
            organizationID: organizationID,
            ocrLanguages: ocrLanguages
        )
    }

    private nonisolated static func decodeCustomHeaders(from rawValue: String) -> [CustomHeader] {
        guard let data = rawValue.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CustomHeader].self, from: data)) ?? []
    }
}

private func applyTag(
    named rawTagName: String,
    to documentID: String,
    api: PapraAPI,
    organizationID: String
) async throws {
    let tagName = rawTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tagName.isEmpty else { return }

    let existingTags = try await api.tags(organizationID: organizationID)
    let tag: DocumentTag
    if let existingTag = existingTags.first(where: {
        $0.name.compare(tagName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) {
        tag = existingTag
    } else {
        tag = try await api.createTag(
            organizationID: organizationID,
            name: tagName,
            color: "#4B5563",
            description: nil
        )
    }

    try await api.addTagToDocument(organizationID: organizationID, documentID: documentID, tagID: tag.id)
}
