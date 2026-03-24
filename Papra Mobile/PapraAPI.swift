//
//  PapraAPI.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Foundation
import UniformTypeIdentifiers

enum PapraAPIError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, String)
    case missingFileName

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid Papra API base URL."
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .httpStatus(code, message):
            return message.isEmpty ? "Request failed with status \(code)." : message
        case .missingFileName:
            return "Choose a file with a valid name."
        }
    }
}

struct PapraConfiguration: Equatable {
    var baseURL: String
    var apiToken: String
    var organizationID: String?

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedToken: String {
        apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PapraAPI {
    let configuration: PapraConfiguration

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let rawBaseURL = configuration.trimmedBaseURL.isEmpty ? "https://api.papra.app" : configuration.trimmedBaseURL
        guard var components = URLComponents(string: rawBaseURL) else {
            throw PapraAPIError.invalidBaseURL
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + normalizedPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw PapraAPIError.invalidBaseURL
        }
        return url
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        contentType: String? = "application/json"
    ) throws -> URLRequest {
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.trimmedToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decodeErrorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        for key in ["message", "error", "detail"] {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PapraAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw PapraAPIError.httpStatus(httpResponse.statusCode, decodeErrorMessage(from: data))
        }
        return try decoder.decode(T.self, from: data)
    }

    private func sendWithoutBodyResponse(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PapraAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw PapraAPIError.httpStatus(httpResponse.statusCode, decodeErrorMessage(from: data))
        }
    }

    private func makeJSONRequest<T: Encodable>(
        path: String,
        method: String,
        body: T
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func currentAPIKey() async throws -> APIKeyInfo {
        let request = try makeRequest(path: "/api/api-keys/current")
        return try await send(request, as: APIKeyResponse.self).apiKey
    }

    func organizations() async throws -> [Organization] {
        let request = try makeRequest(path: "/api/organizations")
        return try await send(request, as: OrganizationsResponse.self).organizations
    }

    func documents(organizationID: String) async throws -> [Document] {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents",
            queryItems: [URLQueryItem(name: "pageSize", value: "100")]
        )
        return try await send(request, as: DocumentsResponse.self).documents
    }

    func searchDocuments(organizationID: String, searchQuery: String) async throws -> [Document] {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents/search",
            queryItems: [
                URLQueryItem(name: "searchQuery", value: searchQuery),
                URLQueryItem(name: "pageIndex", value: "0"),
                URLQueryItem(name: "pageSize", value: "100")
            ]
        )
        return try await send(request, as: DocumentsResponse.self).documents
    }

    func document(organizationID: String, documentID: String) async throws -> Document {
        let request = try makeRequest(path: "/api/organizations/\(organizationID)/documents/\(documentID)")
        return try await send(request, as: DocumentResponse.self).document
    }

    func documentStatistics(organizationID: String) async throws -> OrganizationStats {
        let request = try makeRequest(path: "/api/organizations/\(organizationID)/documents/statistics")
        return try await send(request, as: OrganizationStatsResponse.self).organizationStats
    }

    func uploadDocument(
        organizationID: String,
        fileURL: URL,
        ocrLanguages: String?
    ) async throws {
        let fileName = fileURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw PapraAPIError.missingFileName
        }

        let boundary = UUID().uuidString
        var request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents",
            method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)"
        )

        let fileData = try Data(contentsOf: fileURL)
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType,
            ocrLanguages: ocrLanguages?.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        try await sendWithoutBodyResponse(request)
    }

    func downloadDocumentFile(organizationID: String, document: Document) async throws -> URL {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents/\(document.id)/file",
            contentType: nil
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PapraAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw PapraAPIError.httpStatus(httpResponse.statusCode, decodeErrorMessage(from: data))
        }

        let fallbackExtension = UTType(mimeType: document.mimeType ?? "")?.preferredFilenameExtension
        let sourceExtension = URL(fileURLWithPath: document.fileName ?? "").pathExtension
        let resolvedExtension = sourceExtension.isEmpty ? fallbackExtension ?? "bin" : sourceExtension
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(document.name.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension(resolvedExtension)

        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    func deleteDocument(organizationID: String, documentID: String) async throws {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents/\(documentID)",
            method: "DELETE",
            contentType: nil
        )
        try await sendWithoutBodyResponse(request)
    }

    func tags(organizationID: String) async throws -> [DocumentTag] {
        let request = try makeRequest(path: "/api/organizations/\(organizationID)/tags")
        return try await send(request, as: TagsResponse.self).tags
    }

    func createTag(
        organizationID: String,
        name: String,
        color: String,
        description: String?
    ) async throws -> DocumentTag {
        let request = try makeJSONRequest(
            path: "/api/organizations/\(organizationID)/tags",
            method: "POST",
            body: TagPayload(
                name: name,
                color: color,
                description: description?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        return try await send(request, as: TagResponse.self).tag
    }

    func updateTag(
        organizationID: String,
        tagID: String,
        name: String,
        color: String,
        description: String?
    ) async throws -> DocumentTag {
        let request = try makeJSONRequest(
            path: "/api/organizations/\(organizationID)/tags/\(tagID)",
            method: "PUT",
            body: TagPayload(
                name: name,
                color: color,
                description: description?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        return try await send(request, as: TagResponse.self).tag
    }

    func deleteTag(organizationID: String, tagID: String) async throws {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/tags/\(tagID)",
            method: "DELETE",
            contentType: nil
        )
        try await sendWithoutBodyResponse(request)
    }

    func addTagToDocument(
        organizationID: String,
        documentID: String,
        tagID: String
    ) async throws {
        let request = try makeJSONRequest(
            path: "/api/organizations/\(organizationID)/documents/\(documentID)/tags",
            method: "POST"
            ,
            body: DocumentTagAssignmentPayload(tagID: tagID)
        )
        try await sendWithoutBodyResponse(request)
    }

    func removeTagFromDocument(
        organizationID: String,
        documentID: String,
        tagID: String
    ) async throws {
        let request = try makeRequest(
            path: "/api/organizations/\(organizationID)/documents/\(documentID)/tags/\(tagID)",
            method: "DELETE",
            contentType: nil
        )
        try await sendWithoutBodyResponse(request)
    }

    private func makeMultipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        ocrLanguages: String?
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        if let ocrLanguages, !ocrLanguages.isEmpty {
            body.append("--\(boundary)\(lineBreak)")
            body.append("Content-Disposition: form-data; name=\"ocrLanguages\"\(lineBreak)\(lineBreak)")
            body.append("\(ocrLanguages)\(lineBreak)")
        }

        body.append("--\(boundary)\(lineBreak)")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        body.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(fileData)
        body.append(lineBreak)
        body.append("--\(boundary)--\(lineBreak)")

        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

private struct TagPayload: Encodable {
    let name: String
    let color: String
    let description: String?
}

private struct DocumentTagAssignmentPayload: Encodable {
    let tagID: String

    enum CodingKeys: String, CodingKey {
        case tagID = "tagId"
    }
}
