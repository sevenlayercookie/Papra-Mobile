//
//  ContentView.swift
//  Papra Mobile
//
//  Created by Harrison Rose on 3/24/26.
//

import QuickLook
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var isImporterPresented = false
    @State private var isDocumentScannerPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isSettingsPresented = false
    @State private var previewItem: PreviewItem?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedDocumentID: String?
    @State private var documentPendingDeletion: Document?
    @State private var tagEditorTarget: TagEditorTarget?

    var body: some View {
        Group {
            if model.isConnected {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detailContent
                }
            } else {
                ConnectionGateView(model: model)
            }
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
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
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
        .sheet(isPresented: $isDocumentScannerPresented) {
            DocumentScannerSheet { result in
                isDocumentScannerPresented = false

                switch result {
                case let .success(fileURL):
                    Task {
                        await model.upload(fileURL: fileURL)
                    }
                case let .failure(error):
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .sheet(item: $tagEditorTarget) { target in
            TagEditorSheet(
                model: model,
                documentID: target.documentID
            )
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(model: model) {
                model.disconnect()
                selectedDocumentID = nil
                isSettingsPresented = false
            }
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
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importPhoto(from: newItem)
                selectedPhotoItem = nil
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDocumentID) {
            statusSection
            documentsSection
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    PapraBrandMark(size: 28)

                    Text("Papra Mobile")
                        .font(.headline.weight(.semibold))
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }

                    Button {
                        isPhotoPickerPresented = true
                    } label: {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        if VNDocumentCameraViewController.isSupported {
                            isDocumentScannerPresented = true
                        } else {
                            model.errorMessage = "Document scanning is not available on this device."
                        }
                    } label: {
                        Label("Scan Document", systemImage: "camera.viewfinder")
                    }
                } label: {
                    Label("Upload", systemImage: "arrow.up.doc")
                }

                Button {
                    Task {
                        await model.refreshSidebarContent()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
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
        .refreshable {
            await model.refreshSidebarContent()
        }
    }

    private var statusSection: some View {
        Section("Overview") {
            if let stats = model.stats {
                LabeledContent("Total Documents", value: "\(stats.documentsCount)")
                LabeledContent("Total library size", value: ByteCountFormatter.string(fromByteCount: Int64(stats.documentsSize), countStyle: .file))
            }

            if model.isLoading && model.stats == nil {
                ProgressView("Loading")
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

    private func importPhoto(from item: PhotosPickerItem) async {
        do {
            guard let pickedImage = try await item.loadTransferable(type: PickedImageFile.self) else {
                return
            }
            await model.upload(fileURL: pickedImage.url)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct ConnectionGateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    PapraBrandMark(size: 88)

                    VStack(alignment: .leading, spacing: 10) {
                    Text("Connect to Papra")
                        .font(.largeTitle.weight(.semibold))
                    Text("Enter your API token and verify the connection before accessing documents.")
                        .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    TextField("https://api.papra.app", text: $model.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)

                    SecureField("API Token", text: $model.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task {
                            await model.bootstrap()
                        }
                    } label: {
                        HStack {
                            if model.isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
                }
            }
            .padding(24)
            .frame(maxWidth: 520, maxHeight: .infinity, alignment: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Papra Mobile")
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onDisconnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        PapraBrandMark(size: 52)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Papra Mobile")
                                .font(.headline)
                            Text("Connection, organization, and library settings")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

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

                Section("Connection") {
                    TextField("https://api.papra.app", text: $model.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(model.isConnected)

                    SecureField("API Token", text: $model.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isConnected)

                    if let currentKeyInfo = model.currentKeyInfo {
                        Label(currentKeyInfo.name, systemImage: "key")
                    }

                    if model.lastRefresh > .distantPast {
                        LabeledContent("Updated", value: model.lastRefresh.formatted(date: .abbreviated, time: .shortened))
                    }

                    Button("Disconnect", role: .destructive) {
                        onDisconnect()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct TagEditorTarget: Identifiable {
    let documentID: String
    var id: String { documentID }
}

private struct PapraBrandMark: View {
    let size: CGFloat

    var body: some View {
        Image("PapraBrandTransparent")
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
    }
}

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let fileManager = FileManager.default
            let pathExtension = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let destinationURL = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: received.file, to: destinationURL)
            return Self(url: destinationURL)
        }
    }
}

private struct DocumentScannerSheet: UIViewControllerRepresentable {
    let onComplete: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onComplete: (Result<URL, Error>) -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)

            do {
                let fileURL = try makePDF(from: scan)
                onComplete(.success(fileURL))
            } catch {
                onComplete(.failure(error))
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
            onComplete(.failure(error))
        }

        private func makePDF(from scan: VNDocumentCameraScan) throws -> URL {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("scan-\(UUID().uuidString)")
                .appendingPathExtension("pdf")

            try renderer.writePDF(to: fileURL) { context in
                for pageIndex in 0 ..< scan.pageCount {
                    let image = scan.imageOfPage(at: pageIndex)
                    let pageRect = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: pageRect, pageInfo: [:])
                    image.draw(in: pageRect)
                }
            }

            return fileURL
        }
    }
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
        .refreshable {
            await onRefresh()
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
