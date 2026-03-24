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

    @Published var baseURL = ""
    @Published var apiToken = ""
    @Published var organizations: [Organization] = []
    @Published var selectedOrganizationID: String?
    @Published var currentKeyInfo: APIKeyInfo?
    @Published var allDocuments: [Document] = []
    @Published var documents: [Document] = []
    @Published var selectedDocument: Document?
    @Published var availableTags: [DocumentTag] = []
    @Published var stats: OrganizationStats?
    @Published var searchQuery = ""
    @Published var ocrLanguages = ""
    @Published var isLoading = false
    @Published var isUploading = false
    @Published var errorMessage: String?
    @Published var lastRefresh = Date.distantPast

    init() {
        baseURL = storedBaseURL
        apiToken = storedAPIToken
        selectedOrganizationID = storedOrganizationID.isEmpty ? nil : storedOrganizationID
    }

    var configuration: PapraConfiguration {
        PapraConfiguration(
            baseURL: baseURL,
            apiToken: apiToken,
            organizationID: selectedOrganizationID
        )
    }

    var isConfigured: Bool {
        !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConnected: Bool {
        currentKeyInfo != nil
    }

    func saveConfiguration() {
        storedBaseURL = baseURL
        storedAPIToken = apiToken
        storedOrganizationID = selectedOrganizationID ?? ""
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

            if let selectedDocument {
                self.selectedDocument = loadedDocuments.first(where: { $0.id == selectedDocument.id })
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
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
            selectedDocument = document
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index] = document
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func createTag(name: String, color: String, description: String?) async {
        guard let organizationID = selectedOrganizationID else { return }

        do {
            let tag = try await PapraAPI(configuration: configuration)
                .createTag(organizationID: organizationID, name: name, color: color, description: description)
            availableTags.append(tag)
            availableTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
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
        allDocuments = []
        documents = []
        selectedDocument = nil
        availableTags = []
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
            tags: tags
        )
    }
}
