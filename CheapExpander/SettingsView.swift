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

    private func normalizeTriggerInput(_ raw: String) -> String {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "" }

        if !candidate.hasPrefix(appState.startDelimiter) {
            candidate = appState.startDelimiter + candidate
        }

        return candidate
    }

    var body: some View {
        Form {
            // Editing controls for staged settings
            Section {
                HStack {
                    Button("Save") {
                        appState.saveSettingsFromUI()
                        appState.beginEditingSettings() // prepare a fresh staged snapshot after saving
                    }
                    Button("Cancel") {
                        appState.discardStagedSettings()
                        appState.beginEditingSettings() // reset staged snapshot to current live values
                    }
                    Spacer()
                    Text(appState.isEditingSettings ? "Editing (not saved)" : "")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .onAppear {
                // Always start a staged editing session when Settings appears
                appState.beginEditingSettings()
            }

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
                    Button("Add") { appState.snippetStore.add(startDelimiter: appState.startDelimiter, endAnchors: appState.endAnchors) }
                }

                if appState.snippetStore.snippets.isEmpty {
                    Text("No snippets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appState.snippetStore.snippets) { item in
                            if let idx = appState.snippetStore.snippets.firstIndex(where: { $0.id == item.id }) {
                                let enabledBinding = $appState.snippetStore.snippets[idx].isEnabled
                                let expansionBinding = $appState.snippetStore.snippets[idx].expansion

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Toggle("", isOn: enabledBinding)
                                            .toggleStyle(.switch)
                                            .labelsHidden()

                                        TextField("Trigger", text: $appState.snippetStore.snippets[idx].trigger)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 140)
                                            .onChange(of: appState.snippetStore.snippets[idx].trigger) { newValue in
                                                // Normalize asynchronously to avoid mutating during TextField update cycle
                                                DispatchQueue.main.async {
                                                    appState.snippetStore.snippets[idx].trigger = normalizeTriggerInput(newValue)
                                                }
                                            }

                                        Spacer()

                                        Button(role: .destructive) {
                                            if let deleteIdx = appState.snippetStore.snippets.firstIndex(where: { $0.id == item.id }) {
                                                appState.snippetStore.snippets.remove(at: deleteIdx)
                                            }
                                        } label: {
                                            Text("Delete")
                                        }
                                    }

                                    TextEditor(text: expansionBinding)
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
                    }
                    HStack {
                        Spacer()
                        Button("Reveal Snippets Folder") {
                            appState.revealAppSupportFolder()
                        }
                    }
                }

                Text("Saved to Application Support as snippets.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Triggers auto-format to start with \"\(appState.startDelimiter)\" and end with \(String(appState.endAnchors.sorted())) to match expansions.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Sound") {
                if let _ = appState.stagedSettings {
                    Toggle("Enable sound effects", isOn: Binding(
                        get: { appState.stagedSettings?.soundEnabled ?? appState.soundEnabled },
                        set: { appState.stagedSettings?.soundEnabled = $0 }
                    ))
                    HStack {
                        Text("Volume")
                        Slider(value: Binding(
                            get: { appState.stagedSettings?.volume ?? appState.soundVolume },
                            set: { appState.stagedSettings?.volume = $0 }
                        ), in: 0...100)
                        Text("\(Int(appState.stagedSettings?.volume ?? appState.soundVolume))%")
                            .frame(width: 40, alignment: .trailing)
                    }
                    Toggle("Play 100th-expansion sound", isOn: Binding(
                        get: { appState.stagedSettings?.playHundredth ?? appState.playHundredth },
                        set: { appState.stagedSettings?.playHundredth = $0 }
                    ))

                    Divider()

                    Picker("Expansion sound", selection: Binding(
                        get: { appState.stagedSettings?.defaultExpansionSound ?? appState.defaultExpansionSound },
                        set: { appState.stagedSettings?.defaultExpansionSound = $0 }
                    )) {
                        Text("Sound A").tag(AppState.SoundType.a)
                        Text("Sound B").tag(AppState.SoundType.b)
                    }

                    HStack {
                        Button("Play") { appState.playTest(appState.stagedSettings?.defaultExpansionSound ?? appState.defaultExpansionSound) }
                        Spacer()
                        Button("Reveal Sounds Folder") { appState.revealSoundsFolder() }
                        Button("Reset Sounds to Defaults") { appState.resetSoundsToDefaults() }
                    }
                } else {
                    // Fallback if no staged settings; display current values read-only
                    Toggle("Enable sound effects", isOn: .constant(appState.soundEnabled))
                    HStack {
                        Text("Volume")
                        Slider(value: .constant(appState.soundVolume), in: 0...100)
                        Text("\(Int(appState.soundVolume))%")
                            .frame(width: 40, alignment: .trailing)
                    }
                    Toggle("Play 100th-expansion sound", isOn: .constant(appState.playHundredth))

                    Divider()

                    Picker("Expansion sound", selection: .constant(appState.defaultExpansionSound)) {
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
            }

            Text("Changes to Sound settings are staged until you press Save above.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .onDisappear {
            // Ensure we don't leave snippet auto-save suppressed if the view goes away
            if appState.isEditingSettings {
                appState.discardStagedSettings()
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 420, minHeight: 700)
    }
}

