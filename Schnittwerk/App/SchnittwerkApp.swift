// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Schnittwerk: cut on a Silhouette Cameo 4 from macOS.
// Copyright (C) 2026 Manuel Weiser
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

import AppKit
import SwiftUI

@main
struct SchnittwerkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start with an empty mat instead of the "Open" panel
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        MCPServerController.shared.apply()
        UpdateChecker.shared.start()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CutDocument() }) { file in
            ContentView(document: file.document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates …") { UpdateChecker.shared.check(userInitiated: true) }
            }
        }

        Settings {
            TabView {
                ProfilesSettingsView()
                    .tabItem { Label("Cut profiles", systemImage: "scissors") }
                MCPSettingsView()
                    .tabItem { Label("AI (MCP)", systemImage: "sparkles") }
                UpdateSettingsView()
                    .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            }
        }
    }
}

/// Opens a new, empty project when the app starts without a file.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}
