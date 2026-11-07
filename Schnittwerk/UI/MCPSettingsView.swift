// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Settings tab: switch the MCP server on or off and show how to
/// connect an AI assistant (e.g. Claude Code) to it.
struct MCPSettingsView: View {
    @ObservedObject private var server = MCPServerController.shared
    @AppStorage(MCPServerController.enabledKey) private var enabled = false
    @AppStorage(MCPServerController.portKey) private var port = Int(MCPServerController.defaultPort)

    @State private var confirmRenew = false

    private var command: String { server.claudeCommand }

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI assistants to design in Schnittwerk", isOn: $enabled)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(enabled)
                    .help("Turn the server off to change the port")
                statusLine
            } footer: {
                Text("The server is only reachable from this Mac. An assistant can read and change the project in the front window; every change can be undone with ⌘Z. Cutting is only started by you.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(verbatim: command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    Spacer()
                    Button("New key …") { confirmRenew = true }
                        .help("Creates a new secret key. Assistants that are already connected stop working until you run the new command.")
                }
            } header: {
                Text("Connect Claude Code")
            } footer: {
                Text("The command contains a secret key. Do not share it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: enabled) { server.apply() }
        .confirmationDialog("Create a new key?", isPresented: $confirmRenew) {
            Button("New key", role: .destructive) {
                server.renewToken()
                server.apply()
            }
        } message: {
            Text("Connected assistants stop working until you run the new command. Remove the old entry first: claude mcp remove schnittwerk -s user")
        }
        .onChange(of: port) {
            if !(1024...65535).contains(port) { port = Int(MCPServerController.defaultPort) }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch server.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            Label("Starting …", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .running(let p):
            Label("Running on port \(String(p))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label("Could not start: \(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
