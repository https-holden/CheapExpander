//
//  SettingsView.swift
//  CheapExpander
//
//  Created by Holden McHugh on 12/22/25.
//

import SwiftUI
import Combine

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    private func formatModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.control) { parts.append("control") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.command) { parts.append("command") }
        if flags.contains(.capsLock) { parts.append("capsLock") }
        if flags.contains(.function) { parts.append("function") }
        return parts.isEmpty ? "[]" : "[" + parts.joined(separator: ",") + "]"
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Enabled") {
                    Text(appState.isEnabled ? "On" : "Off")
                }
                LabeledContent("Accessibility") {
                    Text(appState.accessibilityPermissionGranted ? "Granted" : "Not granted")
                }
                LabeledContent("Monitor Status") {
                    Text(appState.keyMonitorStatus)
                }
                LabeledContent("Debug Log Keys") {
                    Toggle("", isOn: $appState.debugLogKeys)
                        .labelsHidden()
                }
                LabeledContent("Last Key") {
                    Text(appState.lastKeyString.isEmpty ? "(none)" : appState.lastKeyString)
                }
                LabeledContent("KeyCode") {
                    Text("\(appState.lastKeyCode)")
                }
                LabeledContent("Modifiers") {
                    Text(formatModifiers(appState.lastModifiers))
                }
                LabeledContent("justDeleted") {
                    Text(appState.justDeleted ? "true" : "false")
                }
                LabeledContent("justMovedCaret") {
                    Text(appState.justMovedCaret ? "true" : "false")
                }
            }

            Section("Buffer / Matching") {
                LabeledContent("Buffer") {
                    Text(appState.bufferString.isEmpty ? "(empty)" : appState.bufferString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(6)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Length") {
                    Text("\(appState.bufferLength)")
                }
                LabeledContent("Match Armed") {
                    Text(appState.matchArmed ? "true" : "false")
                }
                LabeledContent("Last Trigger") {
                    Text(appState.lastMatchTrigger.isEmpty ? "(none)" : appState.lastMatchTrigger)
                }
                LabeledContent("Expansion") {
                    Text(appState.lastMatchExpansion.isEmpty ? "(none)" : appState.lastMatchExpansion)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .lineLimit(6)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Log Matching") {
                    Toggle("", isOn: $appState.debugLogMatching)
                        .labelsHidden()
                }
            }

            // MARK: - Part 8: Snippets UI + Persistence
            Section {
                HStack {
                    Text("Snippets")
                        .font(.headline)
                    Spacer()
                    Button("Add") { appState.snippetStore.add() }
                }

                if appState.snippetStore.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($appState.snippetStore.snippets) { $snippet in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("", isOn: $snippet.isEnabled)
                                        .toggleStyle(.switch)
                                        .labelsHidden()

                                    TextField("Trigger", text: $snippet.trigger)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 140)

                                    Spacer()

                                    Button(role: .destructive) {
                                        appState.snippetStore.delete(snippet)
                                    } label: {
                                        Text("Delete")
                                    }
                                }

                                TextEditor(text: $snippet.expansion)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .frame(minHeight: 64)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(.quaternary)
                                    )
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(0.25))
                            )
                        }
                    }
                    .padding(.top, 6)
                }

                Text("Saved to Application Support as snippets.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                Toggle("Enable sound effects", isOn: $appState.soundEnabled)
                HStack {
                    Text("Volume")
                    Slider(value: $appState.soundVolume, in: 0...100)
                    Text("\(Int(appState.soundVolume))%")
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Play 100th-expansion sound", isOn: $appState.playHundredth)

                Divider()

                Picker("Expansion sound", selection: $appState.defaultExpansionSound) {
                    Text("Sound A").tag(AppState.SoundType.a)
                    Text("Sound B").tag(AppState.SoundType.b)
                }

                HStack {
                    Button("Play") { appState.playTest(appState.defaultExpansionSound) }
                    Spacer()
                    Button("Reveal Sounds Folder") { appState.revealSoundsFolder() }
                    Button("Reset Sounds to Defaults") { appState.resetSoundsToDefaults() }
                }
            }

            Section("Stats") {
                LabeledContent("Total expansions") { Text("\(appState.totalSuccessfulExpansions)") }
                if !appState.lastUsedTrigger.isEmpty {
                    LabeledContent("Last used trigger") { Text(appState.lastUsedTrigger) }
                }
                if let last = appState.lastUsedAt {
                    LabeledContent("Last used at") { Text(last.formatted(date: .abbreviated, time: .standard)) }
                }
                let top = appState.perTriggerUsageCounts.sorted { $0.value > $1.value }.prefix(5)
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top triggers")
                            .font(.headline)
                        ForEach(Array(top), id: \.key) { pair in
                            HStack {
                                Text(pair.key)
                                Spacer()
                                Text("\(pair.value)")
                            }
                            .font(.caption)
                        }
                    }
                }
                Button(role: .destructive) { appState.resetStats() } label: { Text("Reset stats") }
            }

            Section("Next") {
                Text("If Accessibility is not granted, use the menu bar window to open System Settings → Privacy & Security → Accessibility.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 420, minHeight: 700)
    }
}
