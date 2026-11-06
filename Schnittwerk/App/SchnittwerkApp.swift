// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Schnittwerk: cut on a Silhouette Cameo 4 from macOS.
// Copyright (C) 2026 Manuel Weiser
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

import SwiftUI

@main
struct SchnittwerkApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CutDocument() }) { file in
            ContentView(document: file.document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
    }
}
