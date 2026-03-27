//
//  Models.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Foundation

struct CustomHeader: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct APIKeyInfo: Decodable, Equatable {
    let id: String
    let name: String
    let permissions: [String]
}

struct CurrentUser: Decodable, Equatable {
    let id: String
    let email: String
    let name: String
    let permissions: [String]
    let createdAt: Date?
    let updatedAt: Date?
    let twoFactorEnabled: Bool
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

struct CustomPropertyValue: Decodable, Equatable, Hashable, Identifiable {
    let key: String
    let name: String?
    let type: String?
    let displayOrder: Int?
    let stringValue: String?

    var id: String { key }

    init(key: String, name: String?, type: String?, displayOrder: Int?, stringValue: String?) {
        self.key = key
        self.name = name
        self.type = type
        self.displayOrder = displayOrder
        self.stringValue = stringValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder)

        if let string = try? container.decodeIfPresent(String.self, forKey: .value) {
            stringValue = string
        } else if let intValue = try? container.decodeIfPresent(Int.self, forKey: .value) {
            stringValue = String(intValue)
        } else if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: .value) {
            stringValue = doubleValue.formatted(.number)
        } else if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .value) {
            stringValue = boolValue ? "Yes" : "No"
        } else {
            stringValue = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case name
        case type
        case displayOrder
        case value
    }
}

struct PropertyDefinition: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let createdAt: Date?
    let updatedAt: Date?
    let organizationId: String?
    let name: String
    let key: String
    let description: String?
    let type: String
    let config: String?
    let displayOrder: Int
    let options: [String]
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
    let customProperties: [CustomPropertyValue]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case content
        case createdAt
        case updatedAt
        case fileName
        case filename
        case originalName
        case originalSize
        case originalFileName
        case originalFilename
        case originalFileSize
        case mimeType
        case mimetype
        case size
        case filesize
        case fileSize
        case documentSize
        case sizeInBytes
        case byteSize
        case tags
        case customProperties
        case metadata
        case file
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
        tags: [DocumentTag] = [],
        customProperties: [CustomPropertyValue] = []
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
        self.customProperties = customProperties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Document"
        content = try container.decodeIfPresent(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        let fileNameValue = try container.decodeIfPresent(String.self, forKey: .fileName)
        let filenameValue = try container.decodeIfPresent(String.self, forKey: .filename)
        let originalNameValue = try container.decodeIfPresent(String.self, forKey: .originalName)
        let originalFileNameValue = try container.decodeIfPresent(String.self, forKey: .originalFileName)
        let originalFilenameValue = try container.decodeIfPresent(String.self, forKey: .originalFilename)
        let directFileName = fileNameValue ?? filenameValue ?? originalNameValue ?? originalFileNameValue ?? originalFilenameValue
        let metadataFileName = Self.decodeNestedString(
            in: container,
            key: .metadata,
            matching: [.fileName, .filename, .originalName, .originalFileName, .originalFilename]
        )
        let nestedFileName = Self.decodeNestedString(
            in: container,
            key: .file,
            matching: [.fileName, .filename, .originalName, .originalFileName, .originalFilename]
        )
        fileName = directFileName ?? metadataFileName ?? nestedFileName

        let directMimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType) ??
            container.decodeIfPresent(String.self, forKey: .mimetype)
        let metadataMimeType = Self.decodeNestedString(in: container, key: .metadata, matching: [.mimeType, .mimetype])
        let nestedMimeType = Self.decodeNestedString(in: container, key: .file, matching: [.mimeType, .mimetype])
        mimeType = directMimeType ?? metadataMimeType ?? nestedMimeType

        let sizeKeys: [CodingKeys] = [.size, .fileSize, .filesize, .originalSize, .originalFileSize, .documentSize, .sizeInBytes, .byteSize]
        let directSize = Self.decodeInt(in: container, matching: sizeKeys)
        let metadataSize = Self.decodeNestedInt(in: container, key: .metadata, matching: sizeKeys)
        let nestedSize = Self.decodeNestedInt(in: container, key: .file, matching: sizeKeys)
        size = directSize ?? metadataSize ?? nestedSize
        tags = try container.decodeIfPresent([DocumentTag].self, forKey: .tags) ?? []
        customProperties = try container.decodeIfPresent([CustomPropertyValue].self, forKey: .customProperties) ?? []
    }

    private static func decodeInt(in container: KeyedDecodingContainer<CodingKeys>, matching keys: [CodingKeys]) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key),
               let parsedValue = Int(stringValue) {
                return parsedValue
            }
        }
        return nil
    }

    private static func decodeNestedInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        matching nestedKeys: [CodingKeys]
    ) -> Int? {
        guard let nestedContainer = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: key) else {
            return nil
        }
        return decodeInt(in: nestedContainer, matching: nestedKeys)
    }

    private static func decodeNestedString(
        in container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        matching nestedKeys: [CodingKeys]
    ) -> String? {
        guard let nestedContainer = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: key) else {
            return nil
        }

        for nestedKey in nestedKeys {
            if let value = try? nestedContainer.decodeIfPresent(String.self, forKey: nestedKey) {
                return value
            }
        }

        return nil
    }
}

struct OrganizationStats: Decodable, Equatable {
    let documentsCount: Int
    let documentsSize: Int
}

struct APIKeyResponse: Decodable {
    let apiKey: APIKeyInfo
}

struct CurrentUserResponse: Decodable {
    let user: CurrentUser
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

struct PropertyDefinitionsResponse: Decodable {
    let propertyDefinitions: [PropertyDefinition]
}
