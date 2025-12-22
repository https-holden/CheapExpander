//
//  MenuBarView.swift
//  CheapExpander
//
//  Created by Holden McHugh on 12/22/25.
//


import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Permissions
            if !appState.accessibilityPermissionGranted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility permission required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)

                    Text("Enable in System Settings so CheapExpander can observe keystrokes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("Open System Settings") {
                            appState.openAccessibilityPrivacyPane()
                        }

                        Button("Check again") {
                            appState.refreshPermissionsPlaceholder()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }

                Divider()
            }

            Toggle("Enabled", isOn: $appState.isEnabled)
            Text(appState.keyMonitorStatus)
                .font(.system(size: 11))
                .foregroundStyle(appState.keyMonitorStatus == "Running" ? .green : (appState.keyMonitorStatus == "Failed to start" ? .red : .secondary))

            Divider()

            SettingsLink {
                Text("Settings…")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .onAppear {
            appState.refreshPermissionsPlaceholder()
        }
    }
}

