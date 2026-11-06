// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Cut settings, material presets and sending to the Cameo 4.
struct CutPanelView: View {
    @ObservedObject var document: CutDocument
    @ObservedObject private var plotter = PlotterController.shared
    @Environment(\.undoManager) private var undoManager
    @State private var confirmOutside = false

    private var settings: CutSettings { document.data.settings }

    private func set(_ edit: @escaping (inout CutSettings) -> Void, markCustom: Bool = true) {
        document.update(String(localized: "Change cut settings"), undoManager: undoManager) { data in
            edit(&data.settings)
            if markCustom { data.settings.materialID = nil }
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<CutSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: { v in set { $0[keyPath: keyPath] = v } })
    }

    private var outsideCount: Int {
        let area = document.data.mat.size
        return document.data.shapes.filter { $0.cutEnabled && !$0.fits(in: area) }.count
    }

    private var cutCount: Int { document.data.shapes.filter(\.cutEnabled).count }

    var body: some View {
        Form {
            Section("Material") {
                Picker("Preset", selection: Binding(
                    get: { settings.materialID ?? "custom" },
                    set: { id in
                        guard let preset = MaterialPreset.all.first(where: { $0.id == id }) else { return }
                        set({ preset.apply(to: &$0) }, markCustom: false)
                    }
                )) {
                    ForEach(MaterialPreset.all) { Text($0.title).tag($0.id) }
                    if settings.materialID == nil {
                        Text("Custom").tag("custom")
                    }
                }
                Text("Starting values. Always do a test cut on new material.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tool") {
                Picker("Tool", selection: Binding(get: { settings.tool }, set: { t in set { $0.tool = t } })) {
                    ForEach(ToolKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Holder", selection: intBinding(\.holder)) {
                    Text("1 (left)").tag(1)
                    Text("2 (right)").tag(2)
                }
                if settings.tool == .autoBlade && settings.holder == 2 {
                    Label("The AutoBlade only works in holder 1.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if settings.tool == .autoBlade {
                    Stepper(value: intBinding(\.depth), in: CutSettings.depthRange) {
                        LabeledContent("Blade depth", value: "\(settings.depth)")
                    }
                }
                Stepper(value: intBinding(\.pressure), in: CutSettings.pressureRange) {
                    LabeledContent("Force", value: "\(settings.pressure)")
                }
                Stepper(value: intBinding(\.speed), in: CutSettings.speedRange) {
                    LabeledContent("Speed", value: "\(settings.speed)")
                }
                Stepper(value: intBinding(\.passes), in: CutSettings.passesRange) {
                    LabeledContent("Passes", value: "\(settings.passes)")
                }
            }

            Section("Plotter") {
                statusView
                if let p = plotter.progress {
                    ProgressView(value: p)
                }
                if outsideCount > 0 {
                    Label("Outside the cutting area: \(outsideCount). Lines there are cut off at the edge.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if plotter.isBusy {
                    Button("Cancel", role: .cancel) { plotter.cancel() }
                } else {
                    Button {
                        if outsideCount > 0 { confirmOutside = true } else { cut() }
                    } label: {
                        Label("Cut (\(cutCount))", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(cutCount == 0)
                    .keyboardShortcut(.return, modifiers: .command)

                    HStack {
                        Button("Test cut") {
                            plotter.send(GPGLBuilder.testCut(settings: settings, mat: document.data.mat))
                        }
                        .help("Cuts a 10 mm square with a triangle at the top left of the mat")
                        Button("Check connection") { plotter.checkConnection() }
                    }
                    Button("Export commands…", action: exportCommands)
                        .help("Saves the plotter commands as a text file, to check them without a plotter")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Some objects lie outside the cutting area.", isPresented: $confirmOutside) {
            Button("Cut anyway") { cut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lines outside the mat are moved to its edge.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch plotter.phase {
        case .idle:
            Text("Close Silhouette Studio, load the mat, then cut.")
                .foregroundStyle(.secondary)
        case .working(let text):
            Label(text, systemImage: "hourglass")
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func cut() {
        plotter.send(GPGLBuilder.build(for: document.data))
    }

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Schnittwerk-GPGL.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? GPGLBuilder.build(for: document.data).text.write(to: url, atomically: true, encoding: .utf8)
    }
}
