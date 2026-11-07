// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Settings tab: automatic update check on or off, check now.
struct UpdateSettingsView: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @AppStorage(UpdateChecker.autoKey) private var autoCheck = true

    var body: some View {
        Form {
            Section {
                Toggle("Check for new versions automatically", isOn: $autoCheck)
                LabeledContent("Installed version", value: AppVersion.current)
                LabeledContent("Last check") {
                    if let date = checker.lastCheck {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text("Never")
                    }
                }
                HStack {
                    Spacer()
                    if checker.checking { ProgressView().controlSize(.small) }
                    Button("Check now") { checker.check(userInitiated: true) }
                        .disabled(checker.checking)
                }
            } footer: {
                Text("Schnittwerk asks GitHub once a day whether a newer release exists. Nothing about you is sent. New versions are downloaded and installed by you.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
