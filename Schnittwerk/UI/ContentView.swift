// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Main window of a project. Editor, import and cutting follow in
/// their own feature branches; for now it shows the empty mat.
struct ContentView: View {
    @ObservedObject var document: CutDocument
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "scissors")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Schnittwerk")
                .font(.largeTitle)
            Text("Cutting area: \(document.data.mat.title)")
                .foregroundStyle(.secondary)
            Picker("Mat", selection: Binding(
                get: { document.data.mat },
                set: { newValue in
                    document.update(String(localized: "Change mat"), undoManager: undoManager) { $0.mat = newValue }
                }
            )) {
                ForEach(MatType.allCases) { mat in
                    Text(mat.title).tag(mat)
                }
            }
            .frame(maxWidth: 280)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
