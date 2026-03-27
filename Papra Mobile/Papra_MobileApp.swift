//
//  Papra_MobileApp.swift
//  Papra Mobile
//
//  Created by Harrison Rose on 3/24/26.
//

import AppIntents
import SwiftUI

@main
struct Papra_MobileApp: App {
    init() {
        PapraShortcutsProvider.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
