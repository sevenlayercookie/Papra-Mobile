//
//  ContentView.swift
//  Papra Mobile
//
//  Created by Harrison Rose on 3/24/26.
//

import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var isImporterPresented = false
    @State private var previewItem: PreviewItem?
    @State private var selectedDocumentID: String?
    @State private var documentPendingDeletion: Document?
    @State private var tagEditorTarget: TagEditorTarget?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .task {
            await model.bootstrap()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let fileURL = urls.first else { return }
            Task {
                await model.upload(fileURL: fileURL)
            }
        }
        .alert("Papra", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { _ in model.clearError() }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $previewItem) { previewItem in
            DocumentPreviewSheet(url: previewItem.url)
        }
        .sheet(item: $tagEditorTarget) { target in
            TagEditorSheet(
                model: model,
                documentID: target.documentID
            )
        }
        .confirmationDialog(
            "Delete this document?",
            isPresented: Binding(
                get: { documentPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        documentPendingDeletion = nil
                    }
                }
            ),
            presenting: documentPendingDeletion
        ) { document in
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteDocument(document)
                    if selectedDocumentID == document.id {
                        selectedDocumentID = nil
                    }
                    documentPendingDeletion = nil
                }
            }

            Button("Cancel", role: .cancel) {
                documentPendingDeletion = nil
            }
        } message: { document in
            Text(document.name)
        }
        .onChange(of: model.documents) { _, documents in
            if let selectedDocumentID, !documents.contains(where: { $0.id == selectedDocumentID }) {
                self.selectedDocumentID = nil
                model.selectedDocument = nil
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDocumentID) {
            configurationSection
            if model.isConfigured {
                organizationSection
                statusSection
                documentsSection
            }
        }
        .navigationTitle("Papra")
        .toolbar {
            if model.isConfigured {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Upload", systemImage: "arrow.up.doc")
                    }

                    Button {
                        Task {
                            do {
                                try await model.refreshDocuments()
                            } catch { }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .onChange(of: selectedDocumentID) { _, newValue in
            guard let newValue else {
                model.selectedDocument = nil
                return
            }

            if let existing = model.documents.first(where: { $0.id == newValue }) {
                model.selectedDocument = existing
            }

            Task {
                await model.loadDocumentDetail(documentID: newValue)
            }
        }
    }

    private var configurationSection: some View {
        Section("Connection") {
            TextField("https://api.papra.app", text: $model.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(model.currentKeyInfo != nil)

            SecureField("API Token", text: $model.apiToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(model.currentKeyInfo != nil)

            Button(model.currentKeyInfo == nil ? "Connect" : "Disconnect") {
                if model.currentKeyInfo == nil {
                    Task {
                        await model.bootstrap()
                    }
                } else {
                    model.disconnect()
                    selectedDocumentID = nil
                }
            }
            .disabled(model.currentKeyInfo == nil && model.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var organizationSection: some View {
        Section("Organization") {
            if model.organizations.isEmpty {
                Text("No organizations available.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Workspace", selection: Binding(
                    get: { model.selectedOrganizationID ?? "" },
                    set: { newValue in
                        Task { await model.selectOrganization(newValue) }
                    }
                )) {
                    ForEach(model.organizations) { organization in
                        Text(organization.name).tag(organization.id)
                    }
                }
                .pickerStyle(.menu)
            }

            TextField("OCR Languages (optional)", text: $model.ocrLanguages)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var statusSection: some View {
        Section("Overview") {
            if let currentKeyInfo = model.currentKeyInfo {
                Label(currentKeyInfo.name, systemImage: "key")
            }

            if let stats = model.stats {
                LabeledContent("Documents", value: "\(stats.documentsCount)")
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(stats.documentsSize), countStyle: .file))
            }

            if model.isLoading {
                ProgressView("Loading")
            } else if model.lastRefresh > .distantPast {
                LabeledContent("Updated", value: model.lastRefresh.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var documentsSection: some View {
        Section("Documents") {
            TextField("Search documents", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit {
                    Task {
                        await model.performSearch()
                    }
                }
                .onChange(of: model.searchQuery) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task {
                            await model.performSearch()
                        }
                    }
                }

            if model.documents.isEmpty && !model.isLoading {
                Text("No documents found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.documents) { document in
                    DocumentRow(document: document)
                        .contextMenu {
                            Button {
                                tagEditorTarget = TagEditorTarget(documentID: document.id)
                            } label: {
                                Label("Manage Tags", systemImage: "tag")
                            }

                            Button(role: .destructive) {
                                documentPendingDeletion = document
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                documentPendingDeletion = document
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .tag(Optional(document.id))
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if !model.isConfigured {
            ContentUnavailableView(
                "Connect to Papra",
                systemImage: "network",
                description: Text("Enter a base URL and API token, then choose an organization.")
            )
        } else if let selectedDocument = model.selectedDocument {
            DocumentDetailView(
                document: selectedDocument,
                onRefresh: {
                    await model.loadDocumentDetail(documentID: selectedDocument.id)
                },
                onManageTags: {
                    tagEditorTarget = TagEditorTarget(documentID: selectedDocument.id)
                },
                onDelete: {
                    documentPendingDeletion = selectedDocument
                },
                onPreview: {
                    do {
                        previewItem = PreviewItem(url: try await model.downloadSelectedDocumentFile())
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            )
        } else {
            ContentUnavailableView(
                "Choose a Document",
                systemImage: "doc.text",
                description: Text("Select a document from the sidebar to inspect metadata, OCR content, and the original file.")
            )
        }
    }
}

private struct TagEditorTarget: Identifiable {
    let documentID: String
    var id: String { documentID }
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DocumentRow: View {
    let document: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.name)
                .font(.headline)
                .lineLimit(2)

            HStack {
                if let updatedAt = document.updatedAt ?? document.createdAt {
                    Label(updatedAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                }

                if let size = document.size {
                    Label(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), systemImage: "internaldrive")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !document.tags.isEmpty {
                TagChipRow(tags: document.tags, font: .caption2.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DocumentDetailView: View {
    let document: Document
    let onRefresh: () async -> Void
    let onManageTags: () -> Void
    let onDelete: () -> Void
    let onPreview: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metadata
                contentSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(document.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await onPreview()
                    }
                } label: {
                    Label("View File", systemImage: "eye")
                }

                Button {
                    Task {
                        await onRefresh()
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Menu {
                    Button {
                        onManageTags()
                    } label: {
                        Label("Manage Tags", systemImage: "tag")
                    }

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var metadata: some View {
        GroupBox("Metadata") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("ID", value: document.id)

                if let fileName = document.fileName {
                    LabeledContent("File", value: fileName)
                }

                if let mimeType = document.mimeType {
                    LabeledContent("Type", value: mimeType)
                }

                if let size = document.size {
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }

                if let createdAt = document.createdAt {
                    LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                }

                if let updatedAt = document.updatedAt {
                    LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !document.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TagChipRow(tags: document.tags, font: .caption.weight(.medium))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contentSection: some View {
        GroupBox("Extracted Content") {
            if let content = document.content, !content.isEmpty {
                Text(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("This document does not currently expose OCR or extracted text in the API response.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TagChipRow: View {
    let tags: [DocumentTag]
    let font: Font

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    TagChip(tag: tag, font: font)
                }
            }
        }
    }
}

private struct TagChip: View {
    let tag: DocumentTag
    let font: Font

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tag.displayColor)
                .frame(width: 7, height: 7)

            Text(tag.name)
                .font(font)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct TagEditorSheet: View {
    @ObservedObject var model: AppModel
    let documentID: String

    @Environment(\.dismiss) private var dismiss

    @State private var editingTagID: String?
    @State private var tagName = ""
    @State private var tagColor = "#4B5563"
    @State private var tagDescription = ""

    private var document: Document? {
        model.documents.first(where: { $0.id == documentID }) ?? model.selectedDocument
    }

    var body: some View {
        NavigationStack {
            Form {
                if let document {
                    Section("Document") {
                        Text(document.name)
                            .font(.headline)
                    }
                }

                Section("Applied Tags") {
                    if model.availableTags.isEmpty {
                        Text("Create a tag to start organizing this document.")
                            .foregroundStyle(.secondary)
                    } else if let document {
                        ForEach(model.availableTags) { tag in
                            Button {
                                Task {
                                    await model.setTag(tag, on: document, isApplied: !isTagApplied(tag, to: document))
                                }
                            } label: {
                                HStack {
                                    TagChip(tag: tag, font: .body)
                                    Spacer()
                                    if isTagApplied(tag, to: document) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    startEditing(tag)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)

                                Button(role: .destructive) {
                                    Task {
                                        await model.deleteTag(tag)
                                        if editingTagID == tag.id {
                                            resetForm()
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section(editingTagID == nil ? "Create Tag" : "Edit Tag") {
                    TextField("Name", text: $tagName)
                    TextField("Color Hex", text: $tagColor)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Description", text: $tagDescription, axis: .vertical)
                        .lineLimit(2 ... 4)

                    HStack {
                        TagChip(
                            tag: DocumentTag(
                                id: "preview",
                                name: tagName.isEmpty ? "Preview" : tagName,
                                color: tagColor,
                                description: tagDescription.isEmpty ? nil : tagDescription
                            ),
                            font: .body
                        )
                        Spacer()
                    }

                    Button(editingTagID == nil ? "Create Tag" : "Save Changes") {
                        Task {
                            if let editingTagID {
                                await model.updateTag(
                                    tagID: editingTagID,
                                    name: tagName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    color: normalizedHexColor(tagColor),
                                    description: tagDescription.isEmpty ? nil : tagDescription
                                )
                            } else {
                                await model.createTag(
                                    name: tagName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    color: normalizedHexColor(tagColor),
                                    description: tagDescription.isEmpty ? nil : tagDescription
                                )
                            }
                            resetForm()
                        }
                    }
                    .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if editingTagID != nil {
                        Button("Cancel Editing", role: .cancel) {
                            resetForm()
                        }
                    }
                }
            }
            .navigationTitle("Manage Tags")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isTagApplied(_ tag: DocumentTag, to document: Document) -> Bool {
        document.tags.contains(where: { $0.id == tag.id })
    }

    private func startEditing(_ tag: DocumentTag) {
        editingTagID = tag.id
        tagName = tag.name
        tagColor = tag.color ?? "#4B5563"
        tagDescription = tag.description ?? ""
    }

    private func resetForm() {
        editingTagID = nil
        tagName = ""
        tagColor = "#4B5563"
        tagDescription = ""
    }

    private func normalizedHexColor(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#4B5563" }
        return trimmed.hasPrefix("#") ? trimmed.uppercased() : "#\(trimmed.uppercased())"
    }
}

#Preview {
    ContentView()
}

private struct DocumentPreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
private extension DocumentTag {
    var displayColor: Color {
        Color(hex: color) ?? .secondary
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }

        let red = CGFloat((value & 0xFF0000) >> 16) / 255
        let green = CGFloat((value & 0x00FF00) >> 8) / 255
        let blue = CGFloat(value & 0x0000FF) / 255

        self.init(uiColor: UIColor(red: red, green: green, blue: blue, alpha: 1))
    }
}

