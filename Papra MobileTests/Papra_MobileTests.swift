//
//  Papra_MobileTests.swift
//  Papra MobileTests
//
//  Created by Harrison Rose on 3/24/26.
//

import Foundation
import Testing
@testable import Papra_Mobile

struct Papra_MobileTests {
    @MainActor
    @Test func documentDecodingSupportsCommonPapraFields() throws {
        let json = """
        {
          "document": {
            "id": "doc_123",
            "name": "Invoice April",
            "content": "line item data",
            "createdAt": "2026-03-24T12:00:00Z",
            "updatedAt": "2026-03-25T08:30:00Z",
            "originalFilename": "invoice-april.pdf",
            "mimetype": "application/pdf",
            "fileSize": 4096,
            "tags": [
              {
                "id": "tag_1",
                "name": "Finance",
                "color": "#0044FF",
                "description": "Monthly paperwork"
              }
            ]
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(DocumentResponse.self, from: Data(json.utf8))

        #expect(response.document.id == "doc_123")
        #expect(response.document.fileName == "invoice-april.pdf")
        #expect(response.document.mimeType == "application/pdf")
        #expect(response.document.size == 4096)
        #expect(response.document.tags.count == 1)
        #expect(response.document.updatedAt != nil)
    }

    @Test func apiErrorExplainsAuthenticationFailure() {
        let error = PapraAPIError.httpStatus(
            401,
            "Authentication failed for /api/api-keys/current. Check that the API token is valid."
        )

        #expect(error.errorDescription == "Authentication failed for /api/api-keys/current. Check that the API token is valid.")
    }

    @Test func apiErrorPreservesDecodeContext() {
        let error = PapraAPIError.decoding(
            "Papra returned unexpected data for /api/organizations while decoding OrganizationsResponse. Missing key 'organizations'."
        )

        #expect(error.errorDescription?.contains("/api/organizations") == true)
        #expect(error.errorDescription?.contains("OrganizationsResponse") == true)
        #expect(error.errorDescription?.contains("Missing key 'organizations'") == true)
    }
}
