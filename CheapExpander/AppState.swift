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
import CryptoKit

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
            if !suppressSaveDuringLoad && !suppressSavesTemporarily {
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
    private var suppressSavesTemporarily = false

    // Debounce and change detection
    private var pendingReloadWorkItem: DispatchWorkItem?
    private var lastLoadedFileSignature: (size: UInt64, modDate: Date?, sha1: Data?) = (0, nil, nil)

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
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modDate = attrs[.modificationDate] as? Date
            let data = try Data(contentsOf: url)
            let sha1 = SnippetStore.sha1(of: data)

            // If signature is unchanged, skip reloading
            if lastLoadedFileSignature.size == size,
               lastLoadedFileSignature.modDate == modDate,
               lastLoadedFileSignature.sha1 == sha1 {
                return
            }

            let decoded = try JSONDecoder().decode([Snippet].self, from: data)
            self.snippets = decoded
            self.lastLoadedFileSignature = (size, modDate, sha1)
            NSLog("[Snippets] Loaded %d from %@", decoded.count, url.path)
        } catch {
            NSLog("[Snippets] Load failed or missing at %@: %@", url.path, String(describing: error))
            self.snippets = []
            self.lastLoadedFileSignature = (0, nil, nil)
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
            NSLog("[Snippets] Saving %d to %@", self.snippets.count, url.path)
            try ensureAppSupportDirectoryExists(for: url)
            let data = try JSONEncoder().encode(snippets)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modDate = attrs[.modificationDate] as? Date
            let sha1 = SnippetStore.sha1(of: data)
            self.fileMonitorQueue.async { [size, modDate, sha1] in
                self.lastLoadedFileSignature = (size, modDate, sha1)
            }
        } catch {
            NSLog("[Snippets] Save failed at %@: %@", url.path, String(describing: error))
        }
    }

    func add(startDelimiter: String, endAnchors: Set<Character>) {
        let defaultAnchor: Character = endAnchors.sorted().first ?? "/"
        let defaultTrigger = startDelimiter + String(defaultAnchor)
        snippets.append(Snippet(trigger: defaultTrigger, expansion: "", isEnabled: true))
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }
    
    func exportSnippets() {
        let panel = NSSavePanel()
        panel.title = "Export Snippets"
        panel.nameFieldStringValue = "snippets.json"
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try JSONEncoder().encode(snippets)
                try data.write(to: url, options: .atomic)
                NSLog("[Snippets] Exported %d to %@", snippets.count, url.path)
            } catch {
                NSLog("[Snippets] Export failed: %@", String(describing: error))
            }
        }
    }

    func importSnippets() {
        let panel = NSOpenPanel()
        panel.title = "Import Snippets"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode([Snippet].self, from: data)
                self.snippets = decoded
                NSLog("[Snippets] Imported %d from %@", decoded.count, url.path)
            } catch {
                NSLog("[Snippets] Import failed: %@", String(describing: error))
            }
        }
    }

    private func ensureAppSupportDirectoryExists(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // Staging controls: suppress auto-saves while the Settings UI is in edit mode
    func beginStagedEditing() {
        suppressSavesTemporarily = true
    }

    func commitStagedEditing() {
        suppressSavesTemporarily = false
        save()
    }

    func discardStagedEditing() {
        suppressSavesTemporarily = false
        load()
    }

    deinit {
        pendingReloadWorkItem?.cancel()
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

            // Ignore events from our own saves
            guard !self.isSavingFromThisProcess else { return }

            // Debounce multiple rapid events from the directory monitor
            self.pendingReloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.load()
                }
            }
            self.pendingReloadWorkItem = work
            self.fileMonitorQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
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

    private static func sha1(of data: Data) -> Data? {
        #if canImport(CryptoKit)
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest)
        #else
        return nil
        #endif
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
        var startDelimiter: String = ";"
        var endAnchors: [Character] = ["/", "."]

        enum CodingKeys: String, CodingKey {
            case desiredEnabled
            case soundEnabled
            case volume
            case playHundredth
            case soundAFilename
            case soundBFilename
            case sound100Filename
            case defaultExpansionSound
            case nextABIsA
            case startDelimiter
            case endAnchors
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            desiredEnabled = try c.decodeIfPresent(Bool.self, forKey: .desiredEnabled) ?? true
            soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
            volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 80
            playHundredth = try c.decodeIfPresent(Bool.self, forKey: .playHundredth) ?? true
            soundAFilename = try c.decodeIfPresent(String.self, forKey: .soundAFilename)
            soundBFilename = try c.decodeIfPresent(String.self, forKey: .soundBFilename)
            sound100Filename = try c.decodeIfPresent(String.self, forKey: .sound100Filename)
            defaultExpansionSound = try c.decodeIfPresent(SoundType.self, forKey: .defaultExpansionSound) ?? .b
            nextABIsA = try c.decodeIfPresent(Bool.self, forKey: .nextABIsA) ?? false
            startDelimiter = try c.decodeIfPresent(String.self, forKey: .startDelimiter) ?? ";"

            // Be permissive: prefer [String], fallback to single String, then default
            if let strings = try? c.decode([String].self, forKey: .endAnchors) {
                endAnchors = strings.compactMap { $0.first }
            } else if let single = try? c.decode(String.self, forKey: .endAnchors) {
                endAnchors = Array(single)
            } else {
                endAnchors = ["/", "."]
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(desiredEnabled, forKey: .desiredEnabled)
            try c.encode(soundEnabled, forKey: .soundEnabled)
            try c.encode(volume, forKey: .volume)
            try c.encode(playHundredth, forKey: .playHundredth)
            try c.encode(soundAFilename, forKey: .soundAFilename)
            try c.encode(soundBFilename, forKey: .soundBFilename)
            try c.encode(sound100Filename, forKey: .sound100Filename)
            try c.encode(defaultExpansionSound, forKey: .defaultExpansionSound)
            try c.encode(nextABIsA, forKey: .nextABIsA)
            try c.encode(startDelimiter, forKey: .startDelimiter)
            // Encode as [String] for maximum compatibility
            try c.encode(endAnchors.map { String($0) }, forKey: .endAnchors)
        }
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
    @Published var nextABIsA: Bool = true { didSet { saveSettings() } }

    // Staged Settings Editing (defer commits until Save)
    @Published var isEditingSettings: Bool = false
    @Published var stagedSettings: AppSettings? = nil

    // Legacy alternation state (persisted for backward compatibility; no longer used)
    // ... (rest unchanged)

    // Stats (persisted)
    @Published var totalSuccessfulExpansions: Int = 0 { didSet { saveStats() } }
    @Published var perTriggerUsageCounts: [String:Int] = [:] { didSet { saveStats() } }
    @Published var lastUsedTrigger: String = "" { didSet { saveStats() } }
    @Published var lastUsedAt: Date? = nil { didSet { saveStats() } }

    // Desired enabled persisted across launches (actual enable still gated by Accessibility)
    private var desiredEnabled: Bool = true

    // Audio players
    private var players: [SoundType: AVAudioPlayer] = [:]

    @Published var startDelimiter: String = ";" { didSet { rebuildTriggerIndex() } }
    @Published var endAnchors: Set<Character> = ["/", "."] { didSet { rebuildTriggerIndex() } }

    // Debug/Part 3 observables
    @Published var lastKeyString: String = ""
    @Published var lastKeyCode: UInt16 = 0
    @Published var lastModifiers: NSEvent.ModifierFlags = []
    @Published var justDeleted: Bool = false
    @Published var justMovedCaret: Bool = false
    @Published var debugLogKeys: Bool = false
    @Published var debugUIActive: Bool = false { didSet { if debugUIActive { publishKeyDebugStateIfNeeded(); publishBufferStateIfNeeded() } } }
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

    // Debug caches to avoid publishing unless needed
    private var lastKeyStringCache: String = ""
    private var lastKeyCodeCache: UInt16 = 0
    private var lastModifiersCache: NSEvent.ModifierFlags = []
    private var justDeletedCache: Bool = false
    private var justMovedCaretCache: Bool = false
    private var bufferStringCache: String = ""
    private var bufferLengthCache: Int = 0

    private struct IndexedTrigger {
        let trigger: String
        let expansion: String
    }
    private var triggerIndex: [Character: [IndexedTrigger]] = [:]

    private var matchRequiresSelection: Bool = false

    // Backing storage for loaded settings/stats before publishing
    private var loadedSettings: AppSettings = AppSettings()
    private var loadedStats: AppStats = AppStats()

    private var cancellables: Set<AnyCancellable> = []

    private var shouldPublishDebugState: Bool { debugUIActive || debugLogKeys || debugLogMatching }

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
        self.startDelimiter = loadedSettings.startDelimiter
        self.endAnchors = Set(loadedSettings.endAnchors)

        // Prepare a staged snapshot for immediate editing if the Settings UI binds eagerly
        self.stagedSettings = makeSettingsFromLive()

        // Seed example snippets on first run if none exist
        seedExampleSnippetsIfNeeded()

        // Build initial trigger index and keep it updated
        rebuildTriggerIndex()
        snippetStore.$snippets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildTriggerIndex()
            }
            .store(in: &cancellables)

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


    private func publishKeyDebugStateIfNeeded() {
        guard shouldPublishDebugState else { return }
        lastKeyString = lastKeyStringCache
        lastKeyCode = lastKeyCodeCache
        lastModifiers = lastModifiersCache
        justDeleted = justDeletedCache
        justMovedCaret = justMovedCaretCache
    }

    private func publishBufferStateIfNeeded() {
        guard shouldPublishDebugState else { return }
        bufferString = bufferStringCache
        bufferLength = bufferLengthCache
    }

    private func cacheKeyDebug(from decoded: KeyEventMonitor.DecodedKey) {
        lastKeyStringCache = decoded.characters ?? ""
        lastKeyCodeCache = UInt16(decoded.keyCode)
        lastModifiersCache = decoded.modifiers
        justDeletedCache = decoded.isBackspace || decoded.isDeleteForward
        justMovedCaretCache = decoded.isArrow
        publishKeyDebugStateIfNeeded()
    }

    private func cacheBufferDebug() {
        bufferStringCache = buffer.contents.replacingOccurrences(of: "\n", with: "\\n")
        bufferLengthCache = buffer.contents.count
        publishBufferStateIfNeeded()
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
            cacheBufferDebug()
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
            // Update debug observables (cached to avoid publishing unless needed)
            self.cacheKeyDebug(from: decoded)

            // Invalidate buffer and clear match state for command/control shortcuts (navigation/selection changes)
            if decoded.modifiers.contains(.command) || decoded.modifiers.contains(.control) {
                self.buffer.invalidate()
                // Publish buffer state after invalidation
                self.cacheBufferDebug()
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
            self.cacheBufferDebug()

            // Log the key event before evaluating matches so ordering is clear
            if self.debugLogKeys {
                let chars = self.lastKeyStringCache.isEmpty ? "nil" : self.lastKeyStringCache
                let mods = formatModifiers(self.lastModifiersCache)
                NSLog("[KeyEvent] code=\(self.lastKeyCodeCache) chars=\(chars) mods=\(mods) deleted=\(self.justDeletedCache) arrow=\(self.justMovedCaretCache)")
            }

            // Now evaluate matches
            self.evaluateMatches()

            if self.matchArmed {
                // Refresh AX selection only when we are about to replace
                self.updateSelectionState()
                let allowedByOverwrite = self.axSelectionAvailable && self.hasSelection
                if self.matchRequiresSelection && !allowedByOverwrite {
                    if self.debugLogMatching || self.debugLogKeys {
                        NSLog("[Replace] suppressed because selection unavailable")
                    }
                    self.matchArmed = false
                    self.matchRequiresSelection = false
                    self.lastMatchTrigger = ""
                    self.lastMatchExpansion = ""
                    return
                }
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
            self.cacheBufferDebug()
            self.matchArmed = false
            self.lastMatchTrigger = ""
            self.lastMatchExpansion = ""
            // 4) End replacement after a short window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.performingReplacement = false
            }
        }
    }

    private func rebuildTriggerIndex() {
        let anchors = endAnchors.isEmpty ? ["/"] : endAnchors
        var newIndex: [Character: [IndexedTrigger]] = [:]

        let enabled = snippetStore.snippets.filter { $0.isEnabled }
        for snip in enabled {
            guard let trig = normalizedTrigger(snip.trigger), let last = trig.last else { continue }
            guard anchors.contains(last) else { continue }
            newIndex[last, default: []].append(IndexedTrigger(trigger: trig, expansion: snip.expansion))
        }

        for key in newIndex.keys {
            newIndex[key]?.sort { $0.trigger.count > $1.trigger.count }
        }

        triggerIndex = newIndex
    }

    private func normalizedTrigger(_ raw: String) -> String? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if !candidate.hasPrefix(startDelimiter) {
            candidate = startDelimiter + candidate
        }

        let anchors: Set<Character> = endAnchors.isEmpty ? ["/"] : endAnchors

        if let last = candidate.last, !anchors.contains(last) {
            if let defaultAnchor = anchors.sorted().first {
                candidate.append(defaultAnchor)
            }
        }

        guard let last = candidate.last, anchors.contains(last) else { return nil }
        guard candidate.count > startDelimiter.count else { return nil }

        return candidate
    }

    private func evaluateMatches() {
        matchArmed = false
        matchRequiresSelection = false
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

        let anchors: Set<Character> = endAnchors.isEmpty ? ["/"] : endAnchors
        guard let lastChar = text.last, anchors.contains(lastChar) else { return }

        let candidates = triggerIndex[lastChar] ?? []
        guard !candidates.isEmpty else { return }

        for snip in candidates {
            let trig = snip.trigger

            if text.hasSuffix(trig) {
                // Boundary rule: character before trigger start must be boundary or start of buffer
                if let startIndex = text.index(text.endIndex, offsetBy: -trig.count, limitedBy: text.startIndex) {
                    let isAtStart = startIndex == text.startIndex
                    let beforeChar: Character? = isAtStart ? nil : text[text.index(before: startIndex)]
                    let boundarySatisfied = isAtStart || isBoundary(beforeChar)
                    lastMatchTrigger = trig
                    lastMatchExpansion = snip.expansion
                    lastMatchAt = Date()
                    matchArmed = true
                    matchRequiresSelection = !boundarySatisfied
                    if debugLogKeys || debugLogMatching {
                        let end = trig.last ?? "?"
                        let bufferEscaped = text.replacingOccurrences(of: "\n", with: "\\n")
                        NSLog("[Match] trigger=\"\(trig)\" anchor=\"\(end)\" buffer=\"\(bufferEscaped)\" expansion=\"\(snip.expansion)\" needsSelection=\(matchRequiresSelection)")
                    }
                    return
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
        s.startDelimiter = startDelimiter
        s.endAnchors = Array(endAnchors)
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

    // MARK: - Settings Staging & Commit Control
    private func makeSettingsFromLive() -> AppSettings {
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
        s.startDelimiter = startDelimiter
        s.endAnchors = Array(endAnchors)
        return s
    }

    private func applyLive(from s: AppSettings) {
        // Assign to live published properties; their didSet hooks will persist via saveSettings()
        desiredEnabled = s.desiredEnabled
        soundEnabled = s.soundEnabled
        soundVolume = s.volume
        playHundredth = s.playHundredth
        defaultExpansionSound = s.defaultExpansionSound
        soundAFilename = s.soundAFilename
        soundBFilename = s.soundBFilename
        sound100Filename = s.sound100Filename
        nextABIsA = s.nextABIsA
        startDelimiter = s.startDelimiter
        endAnchors = Set(s.endAnchors)
    }

    /// Begin an editing session for Settings. Call this when the Settings UI appears.
    func beginEditingSettings() {
        isEditingSettings = true
        stagedSettings = makeSettingsFromLive()
        // Begin staging snippets as well (defer snippet saves until Save)
        snippetStore.beginStagedEditing()
    }

    /// Apply staged settings to live values and persist. Call this from the Save button.
    func saveSettingsFromUI() {
        guard let staged = stagedSettings else { return }
        applyLive(from: staged)
        // Commit staged snippet changes
        snippetStore.commitStagedEditing()
        isEditingSettings = false
        stagedSettings = nil
    }

    /// Discard any staged changes. Call this from a Cancel button or when leaving Settings without saving.
    func discardStagedSettings() {
        // Discard snippet changes and reset staged app settings
        snippetStore.discardStagedEditing()
        isEditingSettings = false
        stagedSettings = nil
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

    // Unified play helper: use AVAudioPlayer if available, otherwise fall back to a system sound
    private func play(type: SoundType) {
        if let player = players[type] {
            player.currentTime = 0
            player.play()
            return
        }

        // Fallback to a system sound if no player is available (e.g., no custom file chosen)
        let fallbackName: String
        switch type {
        case .a:
            fallbackName = "Pop"
        case .b:
            fallbackName = "Glass"
        case .hundred:
            fallbackName = "Funk"
        }
        if let sound = NSSound(named: NSSound.Name(fallbackName)) {
            sound.volume = Float(soundVolume / 100.0)
            sound.play()
        } else {
            NSSound.beep()
        }
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
        play(type: type)
    }

    func revealSoundsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([soundsFolderURL])
    }

    func revealAppSupportFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([appSupportURL])
    }

    func resetSoundsToDefaults() {
        if stagedSettings != nil {
            // Adjust staged values only; do not touch live files/players yet
            stagedSettings?.soundAFilename = nil
            stagedSettings?.soundBFilename = nil
            stagedSettings?.sound100Filename = nil
            stagedSettings?.defaultExpansionSound = .b
        } else {
            // Live reset behavior
            soundAFilename = nil
            soundBFilename = nil
            sound100Filename = nil
            defaultExpansionSound = .b
            installDefaultSoundsIfNeeded()
            rebuildAllPlayers()
        }
    }

    private func installDefaultSoundsIfNeeded() {
        // If filenames are missing or files were removed, try to auto-assign from the Sounds folder
        do {
            try FileManager.default.createDirectory(at: soundsFolderURL, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: soundsFolderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            let audioExts: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf"]
            let files = urls.compactMap { url -> URL? in
                let ext = url.pathExtension.lowercased()
                guard audioExts.contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return url
            }

            func fileMissing(_ filename: String?) -> Bool {
                guard let filename, !filename.isEmpty else { return true }
                let url = soundsFolderURL.appendingPathComponent(filename)
                return !FileManager.default.fileExists(atPath: url.path)
            }

            func pickCandidate(prefixes: [String]) -> String? {
                let lowerPrefixes = prefixes.map { $0.lowercased() }
                let candidates = files.filter { url in
                    let name = url.lastPathComponent.lowercased()
                    return lowerPrefixes.contains { prefix in name.hasPrefix(prefix) }
                }
                let sorted = candidates.sorted { lhs, rhs in
                    let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lDate ?? .distantPast > rDate ?? .distantPast
                }
                return sorted.first?.lastPathComponent
            }

            if fileMissing(soundAFilename) {
                if let name = pickCandidate(prefixes: ["Sound_A_", "sound_a_", "a_"]) {
                    soundAFilename = name
                }
            }
            if fileMissing(soundBFilename) {
                if let name = pickCandidate(prefixes: ["Sound_B_", "sound_b_", "b_"]) {
                    soundBFilename = name
                }
            }
            if fileMissing(sound100Filename) {
                if let name = pickCandidate(prefixes: ["Sound_100_", "sound_100_", "100_"]) {
                    sound100Filename = name
                }
            }
        } catch {
            NSLog("[Sound] Failed scanning Sounds folder: \(error)")
        }
    }

    // MARK: - Seed Example Snippets
    private func seedExampleSnippetsIfNeeded() {
        // Only seed if there are no snippets yet
        guard snippetStore.snippets.isEmpty else { return }
        let anchors: Set<Character> = endAnchors.isEmpty ? ["/"] : endAnchors
        let anchor = anchors.sorted().first ?? "/"

        let emlTrigger = "\(startDelimiter)eml\(anchor)"
        let sigTrigger = "\(startDelimiter)sig\(anchor)"

        let samples: [Snippet] = [
            Snippet(trigger: emlTrigger, expansion: "user@example.com", isEnabled: true),
            Snippet(trigger: sigTrigger, expansion: "Best,\nYour Name", isEnabled: true)
        ]
        snippetStore.snippets = samples
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
            play(type: .hundred)
            return
        }

        // Play the selected default expansion sound (A or B).
        let chosen: SoundType = (defaultExpansionSound == .hundred) ? .b : defaultExpansionSound
        play(type: chosen)
    }

    // MARK: - Stats utilities
    func resetStats() {
        totalSuccessfulExpansions = 0
        perTriggerUsageCounts = [:]
        lastUsedTrigger = ""
        lastUsedAt = nil
    }
}

