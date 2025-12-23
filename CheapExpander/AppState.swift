//
//  AppState.swift
//  CheapExpander
//
//  Created by Holden McHugh on 12/22/25.
//


import SwiftUI
import Combine
import AppKit
import ApplicationServices
import Carbon
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Snippets (Part 8)

struct Snippet: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var trigger: String
    var expansion: String
    var isEnabled: Bool = true
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = [] {
        didSet {
            if !suppressSaveDuringLoad {
                save()
            }
        }
    }

    private let fileName = "snippets.json"
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private let fileMonitorQueue = DispatchQueue(label: "SnippetStoreFileMonitor")
    // Only read/written on fileMonitorQueue
    private var isSavingFromThisProcess = false
    private var suppressSaveDuringLoad = false

    init() {
        setupFileMonitor()
    }

    private var snippetsFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Keep consistent with AppState's existing appSupportURL folder naming.
        let dir = base.appendingPathComponent("CheapExpander", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    func load() {
        let url = snippetsFileURL
        suppressSaveDuringLoad = true
        defer { suppressSaveDuringLoad = false }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([Snippet].self, from: data)
            self.snippets = decoded
        } catch {
            // Non-fatal: treat missing/invalid file as empty.
            self.snippets = []
        }
    }

    func save() {
        let url = snippetsFileURL
        fileMonitorQueue.sync { isSavingFromThisProcess = true }
        defer {
            // Clear the flag after the save completes so file events originating from
            // our own writes don't immediately trigger a reload.
            fileMonitorQueue.async { self.isSavingFromThisProcess = false }
        }

        do {
            try ensureAppSupportDirectoryExists(for: url)
            let data = try JSONEncoder().encode(snippets)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            // Non-fatal for now.
        }
    }

    func add() {
        snippets.append(Snippet(trigger: "", expansion: "", isEnabled: true))
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    private func ensureAppSupportDirectoryExists(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        fileMonitor?.cancel()
    }

    private func setupFileMonitor() {
        let url = snippetsFileURL

        do {
            try ensureAppSupportDirectoryExists(for: url)
        } catch {
            // If we can't create the directory, skip installing the monitor.
            return
        }

        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        fileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .extend, .attrib, .link, .rename, .revoke], queue: fileMonitorQueue)

        source.setEventHandler { [weak self] in
            guard let self else { return }

            // Ignore events that originate from our own writes to avoid
            // reloading while bindings are mutating (which could crash the UI).
            guard !self.isSavingFromThisProcess else { return }

            Task { @MainActor [weak self] in
                self?.load()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        fileMonitor = source
        source.resume()
    }
}

final class AppState: ObservableObject {
    enum SoundType: String, Codable, CaseIterable { case a = "A", b = "B", hundred = "100" }

    struct AppSettings: Codable {
        var desiredEnabled: Bool = true
        var soundEnabled: Bool = true
        var volume: Double = 80 // 0-100
        var playHundredth: Bool = true
        var soundAFilename: String? = nil
        var soundBFilename: String? = nil
        var sound100Filename: String? = nil
        var defaultExpansionSound: SoundType = .b
        var nextABIsA: Bool = false
    }

    struct AppStats: Codable {
        var totalSuccessfulExpansions: Int = 0
        var perTriggerUsageCounts: [String:Int] = [:]
        var lastUsedTrigger: String? = nil
        var lastUsedAt: Date? = nil
    }

    private var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CheapExpander", isDirectory: true)
    }
    private var soundsFolderURL: URL { appSupportURL.appendingPathComponent("Sounds", isDirectory: true) }
    private var settingsURL: URL { appSupportURL.appendingPathComponent("settings.json") }
    private var statsURL: URL { appSupportURL.appendingPathComponent("stats.json") }

    private let keyMonitor = KeyEventMonitor()
    @Published var snippetStore: SnippetStore = SnippetStore()

    // Settings (sound + desired enabled) persisted to Application Support
    @Published var soundEnabled: Bool = true { didSet { saveSettings() } }
    @Published var soundVolume: Double = 80 { didSet { applyVolumeToPlayers(); saveSettings() } } // 0-100
    @Published var playHundredth: Bool = true { didSet { saveSettings() } }
    @Published var defaultExpansionSound: SoundType = .b { didSet { saveSettings() } }
    @Published var soundAFilename: String? = nil { didSet { rebuildPlayer(for: .a); saveSettings() } }
    @Published var soundBFilename: String? = nil { didSet { rebuildPlayer(for: .b); saveSettings() } }
    @Published var sound100Filename: String? = nil { didSet { rebuildPlayer(for: .hundred); saveSettings() } }

    // Legacy alternation state (persisted for backward compatibility; no longer used)
    @Published var nextABIsA: Bool = true { didSet { saveSettings() } }

    // Stats (persisted)
    @Published var totalSuccessfulExpansions: Int = 0 { didSet { saveStats() } }
    @Published var perTriggerUsageCounts: [String:Int] = [:] { didSet { saveStats() } }
    @Published var lastUsedTrigger: String = "" { didSet { saveStats() } }
    @Published var lastUsedAt: Date? = nil { didSet { saveStats() } }

    // Desired enabled persisted across launches (actual enable still gated by Accessibility)
    private var desiredEnabled: Bool = true

    // Audio players
    private var players: [SoundType: AVAudioPlayer] = [:]

    @Published var startDelimiter: String = ";"
    @Published var endAnchors: Set<Character> = ["/", "."]

    // Debug/Part 3 observables
    @Published var lastKeyString: String = ""
    @Published var lastKeyCode: UInt16 = 0
    @Published var lastModifiers: NSEvent.ModifierFlags = []
    @Published var justDeleted: Bool = false
    @Published var justMovedCaret: Bool = false
    @Published var debugLogKeys: Bool = false
    @Published var keyMonitorStatus: String = "Stopped"

    // Part 4: Buffer & Matching
    @Published var debugLogMatching: Bool = false
    @Published var bufferString: String = ""
    @Published var bufferLength: Int = 0
    @Published var lastMatchTrigger: String = ""
    @Published var lastMatchExpansion: String = ""
    @Published var lastMatchAt: Date? = nil
    @Published var matchArmed: Bool = false

    // Part 6: Selection detection (AX)
    private var axSelectionAvailable: Bool = false
    private var hasSelection: Bool = false
    private var selectionLength: Int = 0
    private var lastHasSelection: Bool = false

    private var suppressMatchOnce: Bool = false
    private var performingReplacement: Bool = false

    private var buffer = InputBuffer()
    // private var triggers: [Trigger] = []

    // Backing storage for loaded settings/stats before publishing
    private var loadedSettings: AppSettings = AppSettings()
    private var loadedStats: AppStats = AppStats()

    private var cancellables: Set<AnyCancellable> = []

    // App enablement is gated by Accessibility permission.
    @Published var isEnabled: Bool = true {
        didSet {
            desiredEnabled = isEnabled; saveSettings()
            if isEnabled {
                refreshPermissions()
                if !accessibilityPermissionGranted {
                    // Revert immediately so the UI reflects reality.
                    isEnabled = false
                }
            }
            updateMonitorState()
        }
    }

    // Accessibility permission state (Privacy & Security -> Accessibility)
    @Published var accessibilityPermissionGranted: Bool = false

    init() {
        // Ensure Application Support directories exist
        createAppSupportIfNeeded()

        // Load settings & stats (and defaults on first run)
        loadSettings()
        loadStats()
        snippetStore.load()

        // Apply loaded settings to published properties
        self.soundEnabled = loadedSettings.soundEnabled
        self.soundVolume = loadedSettings.volume
        self.playHundredth = loadedSettings.playHundredth
        self.defaultExpansionSound = loadedSettings.defaultExpansionSound
        self.soundAFilename = loadedSettings.soundAFilename
        self.soundBFilename = loadedSettings.soundBFilename
        self.sound100Filename = loadedSettings.sound100Filename
        self.nextABIsA = loadedSettings.nextABIsA
        self.desiredEnabled = loadedSettings.desiredEnabled

        self.totalSuccessfulExpansions = loadedStats.totalSuccessfulExpansions
        self.perTriggerUsageCounts = loadedStats.perTriggerUsageCounts
        self.lastUsedTrigger = loadedStats.lastUsedTrigger ?? ""
        self.lastUsedAt = loadedStats.lastUsedAt

        // Install default sounds into Application Support if nothing is set
        installDefaultSoundsIfNeeded()

        // Build audio players now that we have filenames
        rebuildAllPlayers()
        applyVolumeToPlayers()

        // buildTriggers() -- removed for snippets
        refreshPermissions()
        setupKeyMonitor()

        // Honor desired enabled state across launches
        if accessibilityPermissionGranted && desiredEnabled {
            isEnabled = true
        } else if desiredEnabled {
            // Keep desired true, actual may be false until permission is granted
            isEnabled = true // will revert to false by refreshPermissions() if not granted
        }
    }


    private func updateSelectionState() {
        // Default state
        var available = false
        var selLen = 0
        var sel = false

        guard accessibilityPermissionGranted else {
            axSelectionAvailable = false
            hasSelection = false
            selectionLength = 0
            return
        }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let errFocused = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if errFocused == .success, let focused = focusedRef {
            let element = unsafeBitCast(focused, to: AXUIElement.self)

            // Try selected text range first (CFRange)
            var rangeRef: CFTypeRef?
            let errRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
            if errRange == .success, let cfVal = rangeRef, CFGetTypeID(cfVal) == AXValueGetTypeID() {
                let axVal: AXValue = unsafeBitCast(cfVal, to: AXValue.self)
                var range = CFRange()
                if AXValueGetType(axVal) == .cfRange, AXValueGetValue(axVal, .cfRange, &range) {
                    available = true
                    selLen = range.length
                    sel = range.length > 0
                }
            }

            // Fallback: selected text string
            if !available {
                var textRef: CFTypeRef?
                let errText = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef)
                if errText == .success, let s = textRef as? String {
                    available = true
                    selLen = s.count
                    sel = !s.isEmpty
                }
            }
        }

        // Publish/remember state
        axSelectionAvailable = available
        hasSelection = sel
        selectionLength = selLen

        // If selection state toggled (e.g., mouse selection), invalidate buffer to reflect new context
        if lastHasSelection != sel {
            lastHasSelection = sel
            buffer.invalidate()
            bufferString = buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
            bufferLength = buffer.contents.count
        }
    }

    func refreshPermissions() {
        accessibilityPermissionGranted = AXIsProcessTrusted()
        if accessibilityPermissionGranted && desiredEnabled && !isEnabled {
            isEnabled = true
        }
        updateMonitorState()

        // If user attempted to enable but permission is missing, prompt.
        if isEnabled && !accessibilityPermissionGranted {
            requestAccessibilityPermissionPrompt()
        }
    }

    func requestAccessibilityPermissionPrompt() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)

        // AX permission is granted asynchronously by the user in System Settings.
        accessibilityPermissionGranted = AXIsProcessTrusted()
    }

    func openAccessibilityPrivacyPane() {
        // Deep link to Accessibility privacy pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    // Temporary name to match the UI button we already wired.
    func refreshPermissionsPlaceholder() {
        refreshPermissions()
    }

    private func setupKeyMonitor() {
        let debugLogKeys = self.debugLogKeys

        func formatModifiers(_ flags: NSEvent.ModifierFlags) -> String {
            var parts: [String] = []
            if flags.contains(.shift) { parts.append("shift") }
            if flags.contains(.control) { parts.append("control") }
            if flags.contains(.option) { parts.append("option") }
            if flags.contains(.command) { parts.append("command") }
            if flags.contains(.capsLock) { parts.append("capsLock") }
            if flags.contains(.function) { parts.append("function") }
            return parts.isEmpty ? "[]" : "[" + parts.joined(separator: ",") + "]"
        }

        keyMonitor.onKeyDown = { [weak self] decoded in
            guard let self else { return }
            if self.performingReplacement { return }
            // Update debug observables
            self.lastKeyString = decoded.characters ?? ""
            self.lastKeyCode = UInt16(decoded.keyCode)
            self.lastModifiers = decoded.modifiers

            // Track context flags for later parts
            self.justDeleted = decoded.isBackspace || decoded.isDeleteForward
            self.justMovedCaret = decoded.isArrow

            // Update AX selection state (Part 6)
            self.updateSelectionState()

            // Invalidate buffer and clear match state for command/control shortcuts (navigation/selection changes)
            if decoded.modifiers.contains(.command) || decoded.modifiers.contains(.control) {
                self.buffer.invalidate()
                // Publish buffer state after invalidation
                self.bufferString = self.buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
                self.bufferLength = self.buffer.contents.count
                // Clear any armed match
                self.matchArmed = false
                self.lastMatchTrigger = ""
                self.lastMatchExpansion = ""
                if self.debugLogKeys {
                    let mods = formatModifiers(decoded.modifiers)
                    NSLog("[KeyEvent] (cmd/ctrl -> invalidate buffer) code=\(self.lastKeyCode) mods=\(mods)")
                }
                // Do not modify buffer further or evaluate matches
                return
            }

            // --- Part 4: Update buffer from keyDown ---
            if decoded.isBackspace || decoded.isDeleteForward {
                self.buffer.backspace()
                self.suppressMatchOnce = true
            } else if decoded.isArrow {
                self.buffer.invalidate()
            } else if let s = decoded.characters, !s.isEmpty {
                self.buffer.append(s)
            }

            // Publish buffer state
            self.bufferString = self.buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
            self.bufferLength = self.buffer.contents.count

            // Log the key event before evaluating matches so ordering is clear
            if self.debugLogKeys {
                let chars = self.lastKeyString.isEmpty ? "nil" : self.lastKeyString
                let mods = formatModifiers(self.lastModifiers)
                NSLog("[KeyEvent] code=\(self.lastKeyCode) chars=\(chars) mods=\(mods) deleted=\(self.justDeleted) arrow=\(self.justMovedCaret)")
            }

            // Now evaluate matches
            self.evaluateMatches()

            if self.matchArmed {
                let trigger = self.lastMatchTrigger
                let expansion = self.lastMatchExpansion
                self.performReplacement(triggerRaw: trigger, expansion: expansion)
            }
        }
        updateMonitorState()
    }

    private func updateMonitorState() {
        if isEnabled && accessibilityPermissionGranted {
            if !keyMonitor.isRunning {
                keyMonitor.start()
            }
            if keyMonitor.isRunning {
                keyMonitorStatus = "Running"
            } else {
                keyMonitorStatus = "Failed to start"
                // Revert enable switch if start failed
                if isEnabled { isEnabled = false }
            }
        } else {
            if keyMonitor.isRunning {
                keyMonitor.stop()
            }
            keyMonitorStatus = "Stopped"
        }
    }

    private func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func sendBackspaces(count: Int) {
        let keyCode = CGKeyCode(kVK_Delete)
        for _ in 0..<max(0, count) {
            sendKey(keyCode)
        }
    }

    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Command + V to paste
        sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        // Restore previous clipboard after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pb.clearContents()
            if let prev = previous {
                pb.setString(prev, forType: .string)
            }
        }
    }

    private func performReplacement(triggerRaw: String, expansion: String) {
        guard !triggerRaw.isEmpty else { return }
        performingReplacement = true
        let allowedByOverwrite = axSelectionAvailable && hasSelection
        if debugLogMatching || debugLogKeys {
            NSLog("[Replace] deleting \(triggerRaw.count) chars, inserting \(expansion.count) chars overwrite=\(allowedByOverwrite)")
        }
        // 1) Delete the typed trigger characters
        sendBackspaces(count: triggerRaw.count)
        // 2) Paste the expansion after a short delay to allow deletes to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            self.pasteText(expansion)
            self.recordSuccessfulExpansion(triggerRaw: triggerRaw)
            // 3) Reset buffer and match state, and suppress next match once
            self.suppressMatchOnce = true
            self.buffer.invalidate()
            self.bufferString = self.buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
            self.bufferLength = self.buffer.contents.count
            self.matchArmed = false
            self.lastMatchTrigger = ""
            self.lastMatchExpansion = ""
            // 4) End replacement after a short window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.performingReplacement = false
            }
        }
    }

    private func evaluateMatches() {
        matchArmed = false
        lastMatchTrigger = ""
        lastMatchExpansion = ""

        if suppressMatchOnce {
            // One-tick suppression after a deletion to avoid flicker/re-trigger while editing the tail
            suppressMatchOnce = false
            if debugLogKeys || debugLogMatching {
                let bufferEscaped = buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
                NSLog("[Match] (suppressed by justDeleted) buffer=\"\(bufferEscaped)\"")
            }
            return
        }

        let text = buffer.contents
        guard !text.isEmpty else { return }

        // Evaluate snippets whose trigger starts with the configured delimiter and ends with an allowed end anchor
        let enabled = snippetStore.snippets
            .filter { $0.isEnabled }
            .sorted { $0.trigger.count > $1.trigger.count }

        for snip in enabled {
            let trig = snip.trigger
            guard trig.hasPrefix(startDelimiter), let end = trig.last, endAnchors.contains(end) else { continue }
            if text.hasSuffix(trig) {
                // Boundary rule: character before trigger start must be boundary or start of buffer
                if let startIndex = text.index(text.endIndex, offsetBy: -trig.count, limitedBy: text.startIndex) {
                    let isAtStart = startIndex == text.startIndex
                    let beforeChar: Character? = isAtStart ? nil : text[text.index(before: startIndex)]
                    let allowedByOverwrite = axSelectionAvailable && hasSelection
                    if isAtStart || isBoundary(beforeChar) || allowedByOverwrite {
                        lastMatchTrigger = trig
                        lastMatchExpansion = snip.expansion
                        lastMatchAt = Date()
                        matchArmed = true
                        if debugLogKeys || debugLogMatching {
                            let bufferEscaped = text.replacingOccurrences(of: "\n", with: "\\n")
                            NSLog("[Match] trigger=\"\(trig)\" anchor=\"\(end)\" buffer=\"\(bufferEscaped)\" expansion=\"\(snip.expansion)\" overwrite=\(allowedByOverwrite)")
                        }
                        return
                    }
                }
            }
        }
    }

    private func isBoundary(_ c: Character?) -> Bool {
        guard let c = c else { return true }
        if c.isWhitespace { return true }
        // Conservative URL separators
        let separators: Set<Character> = ["/", "?", "&", "=", "#", ":"]
        if separators.contains(c) { return true }
        // If char is alphanumeric or underscore, it's NOT a boundary
        if c.isLetter || c.isNumber || c == "_" { return false }
        // Otherwise treat as boundary
        return true
    }

    // MARK: - Application Support & Persistence
    private func createAppSupportIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: soundsFolderURL, withIntermediateDirectories: true)
        } catch {
            NSLog("[Persistence] Failed creating app support dirs: \(error)")
        }
    }
    private func writeAtomically(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmpURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }

    private func loadSettings() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: settingsURL), let s = try? decoder.decode(AppSettings.self, from: data) {
            loadedSettings = s
        } else {
            loadedSettings = AppSettings() // defaults
        }
    }

    private func loadStats() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: statsURL), let st = try? decoder.decode(AppStats.self, from: data) {
            loadedStats = st
        } else {
            loadedStats = AppStats()
        }
    }

    private func saveSettings() {
        var s = AppSettings()
        s.desiredEnabled = desiredEnabled
        s.soundEnabled = soundEnabled
        s.volume = soundVolume
        s.playHundredth = playHundredth
        s.defaultExpansionSound = defaultExpansionSound
        s.soundAFilename = soundAFilename
        s.soundBFilename = soundBFilename
        s.sound100Filename = sound100Filename
        s.nextABIsA = nextABIsA
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(s)
            try writeAtomically(data: data, to: settingsURL)
        } catch {
            NSLog("[Persistence] Failed saving settings: \(error)")
        }
    }

    private func saveStats() {
        var st = AppStats()
        st.totalSuccessfulExpansions = totalSuccessfulExpansions
        st.perTriggerUsageCounts = perTriggerUsageCounts
        st.lastUsedTrigger = lastUsedTrigger.isEmpty ? nil : lastUsedTrigger
        st.lastUsedAt = lastUsedAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(st)
            try writeAtomically(data: data, to: statsURL)
        } catch {
            NSLog("[Persistence] Failed saving stats: \(error)")
        }
    }

    // MARK: - Sound File Management
    private func urlForSoundFilename(_ filename: String?) -> URL? {
        guard let filename, !filename.isEmpty else { return nil }
        return soundsFolderURL.appendingPathComponent(filename)
    }

    private func rebuildPlayer(for type: SoundType) {
        let filename: String?
        switch type {
        case .a: filename = soundAFilename
        case .b: filename = soundBFilename
        case .hundred: filename = sound100Filename
        }
        players[type]?.stop()
        players[type] = nil
        guard let url = urlForSoundFilename(filename) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(soundVolume / 100.0)
            players[type] = player
        } catch {
            NSLog("[Sound] Failed to load sound for \(type): \(error)")
        }
    }

    private func rebuildAllPlayers() {
        SoundType.allCases.forEach { rebuildPlayer(for: $0) }
    }

    private func applyVolumeToPlayers() {
        for (_, p) in players { p.volume = Float(soundVolume / 100.0) }
    }

    func chooseSound(for type: SoundType) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.audio]
        panel.title = "Choose Sound \(type.rawValue)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try FileManager.default.createDirectory(at: soundsFolderURL, withIntermediateDirectories: true)
                let destName = uniqueFilename(for: url.lastPathComponent)
                let destURL = soundsFolderURL.appendingPathComponent(destName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
                switch type {
                case .a: soundAFilename = destName
                case .b: soundBFilename = destName
                case .hundred: sound100Filename = destName
                }
            } catch {
                NSLog("[Sound] Copy failed: \(error)")
            }
        }
    }

    private func uniqueFilename(for base: String) -> String {
        let name = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        let stamp = Int(Date().timeIntervalSince1970)
        let newBase = "\(name)_\(stamp)"
        if ext.isEmpty { return newBase }
        return newBase + "." + ext
    }

    func playTest(_ type: SoundType) {
        guard let player = players[type] else { return }
        player.currentTime = 0
        player.play()
    }

    func revealSoundsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([soundsFolderURL])
    }

    func resetSoundsToDefaults() {
        // Remove current filenames and try installing defaults again
        soundAFilename = nil
        soundBFilename = nil
        sound100Filename = nil
        defaultExpansionSound = .b
        installDefaultSoundsIfNeeded()
        rebuildAllPlayers()
    }

    private func installDefaultSoundsIfNeeded() {
        // In sandboxed environments, avoid auto-copying from external folders like Downloads.
        // End product relies on user-chosen sounds via NSOpenPanel.
        // If filenames are already set (from a previous run), players will be rebuilt accordingly.
    }

    // MARK: - Expansion Accounting & Sounds
    private func recordSuccessfulExpansion(triggerRaw: String) {
        totalSuccessfulExpansions += 1
        perTriggerUsageCounts[triggerRaw, default: 0] += 1
        lastUsedTrigger = triggerRaw
        lastUsedAt = Date()
        playExpansionSound()
    }

    private func playExpansionSound() {
        guard soundEnabled else { return }

        // 100th behavior (global)
        if playHundredth && totalSuccessfulExpansions > 0 && totalSuccessfulExpansions % 100 == 0 {
            if let p = players[.hundred] {
                p.currentTime = 0
                p.play()
            }
            return
        }

        // Play the selected default expansion sound (A or B).
        let chosen: SoundType = (defaultExpansionSound == .hundred) ? .b : defaultExpansionSound
        if let p = players[chosen] {
            p.currentTime = 0
            p.play()
        }
    }

    // MARK: - Stats utilities
    func resetStats() {
        totalSuccessfulExpansions = 0
        perTriggerUsageCounts = [:]
        lastUsedTrigger = ""
        lastUsedAt = nil
    }
}

