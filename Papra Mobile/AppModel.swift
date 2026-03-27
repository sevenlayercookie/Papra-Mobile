//
//  AppModel.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @AppStorage(PapraSharedSettings.baseURLKey, store: PapraSharedSettings.sharedDefaults) private var storedBaseURL = ""
    @AppStorage(PapraSharedSettings.apiTokenKey, store: PapraSharedSettings.sharedDefaults) private var storedAPIToken = ""
    @AppStorage(PapraSharedSettings.organizationIDKey, store: PapraSharedSettings.sharedDefaults) private var storedOrganizationID = ""
    @AppStorage(PapraSharedSettings.customHeadersKey, store: PapraSharedSettings.sharedDefaults) private var storedCustomHeaders = "[]"
    @AppStorage(PapraSharedSettings.ocrLanguagesKey, store: PapraSharedSettings.sharedDefaults) private var storedOCRLanguages = ""

    @Published var baseURL = ""
    @Published var apiToken = ""
    @Published var customHeaders: [CustomHeader] = []
    @Published var organizations: [Organization] = []
    @Published var selectedOrganizationID: String?
    @Published var currentKeyInfo: APIKeyInfo?
    @Published var currentUser: CurrentUser?
    @Published var allDocuments: [Document] = []
    @Published var documents: [Document] = []
    @Published var selectedDocument: Document?
    @Published var availableTags: [DocumentTag] = []
    @Published var propertyDefinitions: [PropertyDefinition] = []
    @Published var stats: OrganizationStats?
    @Published var searchQuery = ""
    @Published var ocrLanguages = ""
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var errorMessage: String?
    @Published var lastRefresh = Date.distantPast
    private var isProcessingShortcutUploads = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        baseURL = storedBaseURL
        apiToken = storedAPIToken
        selectedOrganizationID = storedOrganizationID.isEmpty ? nil : storedOrganizationID
        customHeaders = decodeCustomHeaders(from: storedCustomHeaders)
        ocrLanguages = storedOCRLanguages
        setupPersistenceBindings()
    }

    var configuration: PapraConfiguration {
        PapraConfiguration(
            baseURL: baseURL,
            apiToken: apiToken,
            organizationID: selectedOrganizationID,
            customHeaders: normalizedCustomHeaders()
        )
    }

    var isConfigured: Bool {
        !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConnected: Bool {
        currentKeyInfo != nil
    }

    static func normalizedDocumentName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveConfiguration() {
        storedBaseURL = baseURL
        storedAPIToken = apiToken
        storedOrganizationID = selectedOrganizationID ?? ""
        storedCustomHeaders = encodeCustomHeaders(normalizedCustomHeaders())
        storedOCRLanguages = ocrLanguages
    }

    func clearError() {
        errorMessage = nil
    }

    func bootstrap() async {
        guard isConfigured else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            saveConfiguration()
            let api = PapraAPI(configuration: configuration)
            async let key = api.currentAPIKey()
            async let orgs = api.organizations()
            let (currentKeyInfo, organizations) = try await (key, orgs)
            self.currentKeyInfo = currentKeyInfo
            self.organizations = organizations

            do {
                self.currentUser = try await api.currentUser()
            } catch {
                // `/api/users/me` may require a browser-authenticated session instead of an API token.
                // Keep the app connected when token-based requests succeed and simply omit profile details.
                self.currentUser = nil
            }

            if selectedOrganizationID == nil || !organizations.contains(where: { $0.id == selectedOrganizationID }) {
                selectedOrganizationID = organizations.first?.id
            }

            saveConfiguration()
            try await refreshDocuments()
        } catch {
            clearSessionState(keepCredentials: true)
            errorMessage = error.localizedDescription
        }
    }

    func refreshDocuments() async throws {
        guard isConfigured, let organizationID = selectedOrganizationID else { return }
        isLoading = true
        defer {
            isLoading = false
            lastRefresh = Date()
        }

        let api = PapraAPI(configuration: configuration)
        async let documents = api.documents(organizationID: organizationID)
        async let stats = api.documentStatistics(organizationID: organizationID)
        async let tags = api.tags(organizationID: organizationID)

        do {
            let (loadedDocuments, loadedStats, loadedTags) = try await (documents, stats, tags)
            self.allDocuments = loadedDocuments
            self.documents = loadedDocuments
            self.stats = loadedStats
            self.availableTags = loadedTags
            do {
                let loadedPropertyDefinitions = try await api.customPropertyDefinitions(organizationID: organizationID)
                self.propertyDefinitions = loadedPropertyDefinitions.sorted { lhs, rhs in
                    if lhs.displayOrder == rhs.displayOrder {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.displayOrder < rhs.displayOrder
                }
            } catch {
                // Custom properties should enrich metadata when available, but must not block
                // normal token-authenticated document browsing when this endpoint is unavailable.
                self.propertyDefinitions = []
            }

            if let selectedDocument {
                self.selectedDocument = loadedDocuments.first(where: { $0.id == selectedDocument.id })
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func refreshSidebarContent() async {
        do {
            try await refreshDocuments()
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await performSearch()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectOrganization(_ organizationID: String) async {
        selectedOrganizationID = organizationID
        saveConfiguration()
        do {
            try await refreshDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func performSearch() async {
        guard let organizationID = selectedOrganizationID else { return }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            documents = allDocuments
            return
        }

        isLoading = true
        defer {
            isLoading = false
            lastRefresh = Date()
        }

        do {
            let results = try await PapraAPI(configuration: configuration)
                .searchDocuments(organizationID: organizationID, searchQuery: query)
            documents = results
        } catch {
            // If server-side search rejects the query, fall back to local filtering
            // so the list remains usable and other requests are unaffected.
            documents = allDocuments.filter { document in
                document.name.localizedCaseInsensitiveContains(query) ||
                (document.content?.localizedCaseInsensitiveContains(query) ?? false) ||
                document.tags.contains(where: { $0.name.localizedCaseInsensitiveContains(query) })
            }
        }
    }

    func loadDocumentDetail(documentID: String) async {
        guard let organizationID = selectedOrganizationID else { return }
        do {
            let document = try await PapraAPI(configuration: configuration)
                .document(organizationID: organizationID, documentID: documentID)
            let cachedDocument = documents.first(where: { $0.id == document.id })
                ?? allDocuments.first(where: { $0.id == document.id })
                ?? selectedDocument
            let mergedDocument = mergeDocumentMetadata(document, fallback: cachedDocument)
            selectedDocument = mergedDocument
            if let index = documents.firstIndex(where: { $0.id == mergedDocument.id }) {
                documents[index] = mergedDocument
            }
            if let index = allDocuments.firstIndex(where: { $0.id == mergedDocument.id }) {
                allDocuments[index] = mergedDocument
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSelectedDocument() async {
        guard let documentID = selectedDocument?.id else { return }
        await loadDocumentDetail(documentID: documentID)
    }

    func upload(fileURL: URL) async {
        guard let organizationID = selectedOrganizationID else {
            errorMessage = "Select an organization before uploading."
            return
        }

        isUploading = true
        defer { isUploading = false }

        let accessedSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await PapraAPI(configuration: configuration)
                .uploadDocument(
                    organizationID: organizationID,
                    fileURL: fileURL,
                    ocrLanguages: ocrLanguages
                )
            try await refreshDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameDocument(_ document: Document, to newName: String) async {
        guard let organizationID = selectedOrganizationID else { return }

        let trimmedName = Self.normalizedDocumentName(newName)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a file name."
            return
        }

        do {
            let updatedDocument = try await PapraAPI(configuration: configuration)
                .renameDocument(organizationID: organizationID, documentID: document.id, name: trimmedName)
            replaceDocument(updatedDocument)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func downloadSelectedDocumentFile() async throws -> URL {
        guard
            let organizationID = selectedOrganizationID,
            let selectedDocument
        else {
            throw PapraAPIError.invalidResponse
        }

        return try await PapraAPI(configuration: configuration)
            .downloadDocumentFile(organizationID: organizationID, document: selectedDocument)
    }

    func deleteDocument(_ document: Document) async {
        guard let organizationID = selectedOrganizationID else { return }

        do {
            try await PapraAPI(configuration: configuration)
                .deleteDocument(organizationID: organizationID, documentID: document.id)
            allDocuments.removeAll { $0.id == document.id }
            documents.removeAll { $0.id == document.id }
            if selectedDocument?.id == document.id {
                selectedDocument = nil
            }
            stats = stats.map {
                OrganizationStats(
                    documentsCount: max(0, $0.documentsCount - 1),
                    documentsSize: max(0, $0.documentsSize - (document.size ?? 0))
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        clearSessionState(keepCredentials: false)
        saveConfiguration()
    }

    func consumePendingShortcutFiles() async {
        guard isConfigured, selectedOrganizationID != nil, !isProcessingShortcutUploads else { return }

        let inboxURLs: [URL]
        do {
            inboxURLs = try FileManager.default.contentsOfDirectory(
                at: PapraSharedSettings.shortcutInboxURL(),
                includingPropertiesForKeys: nil
            ).filter { !PapraSharedSettings.isShortcutMetadataFile($0) }
        } catch {
            return
        }

        guard !inboxURLs.isEmpty else { return }

        isProcessingShortcutUploads = true
        isUploading = true
        defer {
            isProcessingShortcutUploads = false
            isUploading = false
        }

        var uploadedAnyFiles = false

        for fileURL in inboxURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                try await uploadShortcutFile(at: fileURL)
                try? FileManager.default.removeItem(at: fileURL)
                try? FileManager.default.removeItem(at: PapraSharedSettings.shortcutMetadataURL(for: fileURL))
                uploadedAnyFiles = true
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }

        if uploadedAnyFiles {
            do {
                try await refreshDocuments()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createTag(name: String, color: String, description: String?) async -> DocumentTag? {
        guard let organizationID = selectedOrganizationID else { return nil }

        do {
            let tag = try await PapraAPI(configuration: configuration)
                .createTag(organizationID: organizationID, name: name, color: color, description: description)
            availableTags.append(tag)
            availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return tag
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateTag(tagID: String, name: String, color: String, description: String?) async {
        guard let organizationID = selectedOrganizationID else { return }

        do {
            let updatedTag = try await PapraAPI(configuration: configuration)
                .updateTag(organizationID: organizationID, tagID: tagID, name: name, color: color, description: description)
            if let index = availableTags.firstIndex(where: { $0.id == tagID }) {
                availableTags[index] = updatedTag
                availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            replaceTagReferences(with: updatedTag)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTag(_ tag: DocumentTag) async {
        guard let organizationID = selectedOrganizationID else { return }

        do {
            try await PapraAPI(configuration: configuration)
                .deleteTag(organizationID: organizationID, tagID: tag.id)
            availableTags.removeAll { $0.id == tag.id }
            removeTagReferences(tagID: tag.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTag(_ tag: DocumentTag, on document: Document, isApplied: Bool) async {
        guard let organizationID = selectedOrganizationID else { return }

        do {
            let api = PapraAPI(configuration: configuration)
            if isApplied {
                try await api.addTagToDocument(organizationID: organizationID, documentID: document.id, tagID: tag.id)
                applyTag(tag, toDocumentID: document.id)
            } else {
                try await api.removeTagFromDocument(organizationID: organizationID, documentID: document.id, tagID: tag.id)
                removeTag(tagID: tag.id, fromDocumentID: document.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearSessionState(keepCredentials: Bool) {
        organizations = []
        selectedOrganizationID = nil
        currentKeyInfo = nil
        currentUser = nil
        allDocuments = []
        documents = []
        selectedDocument = nil
        availableTags = []
        propertyDefinitions = []
        stats = nil
        searchQuery = ""
        ocrLanguages = ""
        lastRefresh = .distantPast

        if !keepCredentials {
            baseURL = ""
            apiToken = ""
        }
    }

    private func applyTag(_ tag: DocumentTag, toDocumentID documentID: String) {
        allDocuments = allDocuments.map { document in
            guard document.id == documentID else { return document }
            return updatedDocumentByApplyingTag(tag, to: document)
        }
        updateDocument(documentID: documentID) { document in
            updatedDocumentByApplyingTag(tag, to: document)
        }
    }

    private func removeTag(tagID: String, fromDocumentID documentID: String) {
        allDocuments = allDocuments.map { document in
            guard document.id == documentID else { return document }
            return updatedDocumentByRemovingTag(tagID: tagID, from: document)
        }
        updateDocument(documentID: documentID) { document in
            updatedDocumentByRemovingTag(tagID: tagID, from: document)
        }
    }

    private func replaceTagReferences(with tag: DocumentTag) {
        allDocuments = allDocuments.map { document in
            guard document.tags.contains(where: { $0.id == tag.id }) else { return document }
            let updatedTags = document.tags.map { $0.id == tag.id ? tag : $0 }
            return rebuiltDocument(from: document, tags: updatedTags)
        }
        documents = documents.map { document in
            guard document.tags.contains(where: { $0.id == tag.id }) else { return document }
            let updatedTags = document.tags.map { $0.id == tag.id ? tag : $0 }
            return rebuiltDocument(from: document, tags: updatedTags)
        }

        if let selectedDocument, selectedDocument.tags.contains(where: { $0.id == tag.id }) {
            let updatedTags = selectedDocument.tags.map { $0.id == tag.id ? tag : $0 }
            self.selectedDocument = rebuiltDocument(from: selectedDocument, tags: updatedTags)
        }
    }

    private func removeTagReferences(tagID: String) {
        allDocuments = allDocuments.map { document in
            guard document.tags.contains(where: { $0.id == tagID }) else { return document }
            return rebuiltDocument(from: document, tags: document.tags.filter { $0.id != tagID })
        }
        documents = documents.map { document in
            guard document.tags.contains(where: { $0.id == tagID }) else { return document }
            return rebuiltDocument(from: document, tags: document.tags.filter { $0.id != tagID })
        }

        if let selectedDocument, selectedDocument.tags.contains(where: { $0.id == tagID }) {
            self.selectedDocument = rebuiltDocument(
                from: selectedDocument,
                tags: selectedDocument.tags.filter { $0.id != tagID }
            )
        }
    }

    private func updateDocument(documentID: String, transform: (Document) -> Document) {
        if let index = documents.firstIndex(where: { $0.id == documentID }) {
            let updatedDocument = transform(documents[index])
            documents[index] = updatedDocument
            if selectedDocument?.id == documentID {
                selectedDocument = updatedDocument
            }
        }
    }

    private func replaceDocument(_ document: Document) {
        let cachedDocument = allDocuments.first(where: { $0.id == document.id })
            ?? documents.first(where: { $0.id == document.id })
            ?? selectedDocument
        let mergedDocument = mergeDocumentMetadata(document, fallback: cachedDocument)

        if let index = allDocuments.firstIndex(where: { $0.id == document.id }) {
            allDocuments[index] = mergedDocument
        }
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = mergedDocument
        }
        if selectedDocument?.id == document.id {
            selectedDocument = mergedDocument
        }
    }

    private func updatedDocumentByApplyingTag(_ tag: DocumentTag, to document: Document) -> Document {
        guard !document.tags.contains(where: { $0.id == tag.id }) else { return document }
        var updatedTags = document.tags + [tag]
        updatedTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return rebuiltDocument(from: document, tags: updatedTags)
    }

    private func updatedDocumentByRemovingTag(tagID: String, from document: Document) -> Document {
        rebuiltDocument(from: document, tags: document.tags.filter { $0.id != tagID })
    }

    private func rebuiltDocument(from document: Document, tags: [DocumentTag]) -> Document {
        Document(
            id: document.id,
            name: document.name,
            content: document.content,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt,
            fileName: document.fileName,
            mimeType: document.mimeType,
            size: document.size,
            tags: tags,
            customProperties: document.customProperties
        )
    }

    private func mergeDocumentMetadata(_ document: Document, fallback: Document?) -> Document {
        guard let fallback else { return document }

        return Document(
            id: document.id,
            name: document.name,
            content: document.content ?? fallback.content,
            createdAt: document.createdAt ?? fallback.createdAt,
            updatedAt: document.updatedAt ?? fallback.updatedAt,
            fileName: document.fileName ?? fallback.fileName,
            mimeType: document.mimeType ?? fallback.mimeType,
            size: document.size ?? fallback.size,
            tags: document.tags.isEmpty ? fallback.tags : document.tags,
            customProperties: document.customProperties.isEmpty ? fallback.customProperties : document.customProperties
        )
    }

    private func uploadShortcutFile(at fileURL: URL) async throws {
        guard let organizationID = selectedOrganizationID else { return }

        let api = PapraAPI(configuration: configuration)
        let uploadedDocument = try await api
            .uploadDocumentReturningDocument(
                organizationID: organizationID,
                fileURL: fileURL,
                ocrLanguages: ocrLanguages
            )
        if let tagName = shortcutMetadata(for: fileURL)?.tagName {
            try await applyShortcutTag(named: tagName, to: uploadedDocument.id, api: api, organizationID: organizationID)
        }
    }

    private func normalizedCustomHeaders() -> [CustomHeader] {
        customHeaders.filter { !$0.trimmedName.isEmpty && !$0.trimmedValue.isEmpty }
    }

    private func decodeCustomHeaders(from rawValue: String) -> [CustomHeader] {
        guard let data = rawValue.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CustomHeader].self, from: data)) ?? []
    }

    private func encodeCustomHeaders(_ headers: [CustomHeader]) -> String {
        guard let data = try? JSONEncoder().encode(headers),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func shortcutMetadata(for fileURL: URL) -> ShortcutInboxMetadata? {
        let metadataURL = PapraSharedSettings.shortcutMetadataURL(for: fileURL)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? ShortcutInboxMetadata(data: data)
    }

    private func applyShortcutTag(
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

    private func setupPersistenceBindings() {
        Publishers.CombineLatest3($baseURL, $apiToken, $selectedOrganizationID)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                self?.saveConfiguration()
            }
            .store(in: &cancellables)

        $customHeaders
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveConfiguration()
            }
            .store(in: &cancellables)
    }
}
