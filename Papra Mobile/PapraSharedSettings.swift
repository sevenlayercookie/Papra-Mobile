//
//  PapraSharedSettings.swift
//  Papra Mobile
//
//  Created by Codex.
//

import Foundation

enum PapraSharedSettings {
    static let appGroupIdentifier = "group.sevenlayercookie.Papra-Mobile"
    static let baseURLKey = "papra.baseURL"
    static let apiTokenKey = "papra.apiToken"
    static let organizationIDKey = "papra.organizationID"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
