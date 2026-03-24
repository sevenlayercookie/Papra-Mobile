//
//  Models.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Foundation

struct APIKeyInfo: Decodable, Equatable {
    let id: String
    let name: String
    let permissions: [String]
}

struct Organization: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

struct DocumentTag: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let color: String?
    let description: String?
}

struct Document: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let content: String?
    let createdAt: Date?
    let updatedAt: Date?
    let fileName: String?
    let mimeType: String?
    let size: Int?
    let tags: [DocumentTag]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case content
        case createdAt
        case updatedAt
        case fileName
        case filename
        case originalFileName
        case originalFilename
        case mimeType
        case mimetype
        case size
        case fileSize
        case tags
    }

    init(
        id: String,
        name: String,
        content: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        tags: [DocumentTag] = []
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Document"
        content = try container.decodeIfPresent(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        fileName =
            try container.decodeIfPresent(String.self, forKey: .fileName) ??
            container.decodeIfPresent(String.self, forKey: .filename) ??
            container.decodeIfPresent(String.self, forKey: .originalFileName) ??
            container.decodeIfPresent(String.self, forKey: .originalFilename)
        mimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType) ??
            container.decodeIfPresent(String.self, forKey: .mimetype)
        size =
            try container.decodeIfPresent(Int.self, forKey: .size) ??
            container.decodeIfPresent(Int.self, forKey: .fileSize)
        tags = try container.decodeIfPresent([DocumentTag].self, forKey: .tags) ?? []
    }
}

struct OrganizationStats: Decodable, Equatable {
    let documentsCount: Int
    let documentsSize: Int
}

struct APIKeyResponse: Decodable {
    let apiKey: APIKeyInfo
}

struct OrganizationsResponse: Decodable {
    let organizations: [Organization]
}

struct DocumentsResponse: Decodable {
    let documents: [Document]
    let documentsCount: Int?
    let totalCount: Int?
}

struct DocumentResponse: Decodable {
    let document: Document
}

struct OrganizationStatsResponse: Decodable {
    let organizationStats: OrganizationStats
}

struct TagsResponse: Decodable {
    let tags: [DocumentTag]
}

struct TagResponse: Decodable {
    let tag: DocumentTag
}
