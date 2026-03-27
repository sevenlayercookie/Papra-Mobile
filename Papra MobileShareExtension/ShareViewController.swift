//
//  ShareViewController.swift
//  Papra MobileShareExtension
//
//  Created by Codex.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let closeButton = UIButton(type: .system)
    private var didStartUpload = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !didStartUpload else { return }
        didStartUpload = true

        Task {
            await uploadSharedItems()
        }
    }

    private func configureUI() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Preparing upload..."
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.startAnimating()

        closeButton.setTitle("Close", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(closeExtension), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func closeExtension() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @MainActor
    private func setStatus(_ text: String, showsClose: Bool = false, isLoading: Bool = false) {
        statusLabel.text = text
        closeButton.isHidden = !showsClose
        if isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    private func uploadSharedItems() async {
        guard let configuration = PapraShareConfiguration.load() else {
            await setStatus("Open Papra Mobile and connect an API token plus organization before using Share Sheet.", showsClose: true)
            return
        }

        do {
            let fileURLs = try await SharedItemLoader.loadFileURLs(from: extensionContext)
            guard !fileURLs.isEmpty else {
                await setStatus("No supported files were provided to the share extension.", showsClose: true)
                return
            }

            await setStatus("Uploading to Papra...", isLoading: true)
            let uploader = PapraShareUploader(configuration: configuration)
            try await uploader.upload(files: fileURLs)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            await setStatus(error.localizedDescription, showsClose: true)
        }
    }
}

private struct PapraShareConfiguration {
    let baseURL: String
    let apiToken: String
    let organizationID: String

    static func load() -> PapraShareConfiguration? {
        let defaults = UserDefaults(suiteName: PapraSharedSettings.appGroupIdentifier)
        let baseURL = defaults?.string(forKey: PapraSharedSettings.baseURLKey) ?? ""
        let apiToken = defaults?.string(forKey: PapraSharedSettings.apiTokenKey) ?? ""
        let organizationID = defaults?.string(forKey: PapraSharedSettings.organizationIDKey) ?? ""

        guard !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !organizationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PapraShareConfiguration(
            baseURL: baseURL,
            apiToken: apiToken,
            organizationID: organizationID
        )
    }
}

private enum SharedItemLoader {
    static func loadFileURLs(from extensionContext: NSExtensionContext?) async throws -> [URL] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var fileURLs: [URL] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if let fileURL = try await loadFileURL(from: provider) {
                    fileURLs.append(fileURL)
                }
            }
        }

        return fileURLs
    }

    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        let candidateTypes: [UTType] = [.fileURL, .item, .data]

        for type in candidateTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if type == .fileURL {
                if let url = try await loadURL(for: type, provider: provider) {
                    return url
                }
            } else if let url = try await loadFileRepresentation(for: type, provider: provider) {
                return url
            }
        }

        return nil
    }

    private static func loadURL(for type: UTType, provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadFileRepresentation(for type: UTType, provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { temporaryURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let temporaryURL else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let destinationURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(temporaryURL.pathExtension)
                    try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private struct PapraShareUploader {
    let configuration: PapraShareConfiguration

    func upload(files: [URL]) async throws {
        for fileURL in files {
            try await upload(fileURL: fileURL)
        }
    }

    private func upload(fileURL: URL) async throws {
        let baseURLString = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBaseURL = baseURLString.isEmpty ? "https://api.papra.app" : baseURLString
        guard let url = URL(string: rawBaseURL + "/api/organizations/\(configuration.organizationID)/documents") else {
            throw ShareUploadError.invalidConfiguration
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        request.httpBody = multipartBody(
            boundary: boundary,
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType
        )

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw describeTransportError(error, request: request)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ShareUploadError.invalidServerResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ShareUploadError.serverError(
                describeHTTPStatus(httpResponse.statusCode, data: data, request: request)
            )
        }
    }

    private func responsePreview(from data: Data) -> String? {
        guard let rawText = String(data: data, encoding: .utf8) else { return nil }
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let singleLineText = trimmedText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let preview = String(singleLineText.prefix(160))
        return preview == singleLineText ? preview : "\(preview)..."
    }

    private func decodeErrorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ""
        }

        for key in ["message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }

        return ""
    }

    private func describeHTTPStatus(_ statusCode: Int, data: Data, request: URLRequest) -> String {
        let endpoint = request.url?.path ?? "the upload endpoint"
        let responseMessage = decodeErrorMessage(from: data)

        switch statusCode {
        case 401:
            return "Authentication failed for \(endpoint). Reconnect Papra Mobile and verify the API token."
        case 403:
            return "Upload was denied for \(endpoint). The API token may be missing document permissions."
        case 404:
            return "Papra could not find \(endpoint). Check the selected organization and base URL."
        case 502, 503, 504:
            return "Papra is currently unavailable for \(endpoint) (status \(statusCode)). Try again in a moment."
        default:
            if !responseMessage.isEmpty {
                return "Upload failed for \(endpoint) with status \(statusCode): \(responseMessage)"
            }
            if let preview = responsePreview(from: data) {
                return "Upload failed for \(endpoint) with status \(statusCode). Server response: \(preview)"
            }
            return "Upload failed for \(endpoint) with status \(statusCode)."
        }
    }

    private func describeTransportError(_ error: Error, request: URLRequest) -> ShareUploadError {
        let host = request.url?.host ?? "the server"

        guard let urlError = error as? URLError else {
            return .transport(error.localizedDescription)
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return .transport("No internet connection. Check your network and try again.")
        case .timedOut:
            return .transport("The request to \(host) timed out. Check the server and try again.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .transport("Could not reach \(host). Check the Papra base URL and server availability.")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return .transport("A secure connection to \(host) could not be established. Check the server's TLS configuration.")
        default:
            return .transport(urlError.localizedDescription)
        }
    }

    private func multipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")

        return body
    }
}

private enum ShareUploadError: LocalizedError {
    case invalidConfiguration
    case invalidServerResponse
    case serverError(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Papra connection settings are missing or invalid."
        case .invalidServerResponse:
            return "Papra returned an invalid response."
        case let .serverError(message), let .transport(message):
            return message
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

private enum PapraSharedSettings {
    static let appGroupIdentifier = "group.sevenlayercookie.Papra-Mobile"
    static let baseURLKey = "papra.baseURL"
    static let apiTokenKey = "papra.apiToken"
    static let organizationIDKey = "papra.organizationID"
}
