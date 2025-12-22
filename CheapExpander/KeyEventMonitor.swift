//
//  KeyEventMonitor.swift
//  CheapExpander
//
//  Part 3: Global Event Tap and Key Capture
//
//  Captures keyDown events, decodes characters with keyboard layout awareness,
//  and tracks backspace, delete, arrows, and shift+arrows.
//

import Foundation
import AppKit
import Carbon

final class KeyEventMonitor {
    private(set) var isRunning: Bool = false

    struct DecodedKey {
        let characters: String?
        let keyCode: CGKeyCode
        let modifiers: NSEvent.ModifierFlags
        let isBackspace: Bool
        let isDeleteForward: Bool
        let isArrow: Bool
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Callback for clients to receive decoded keys.
    var onKeyDown: ((DecodedKey) -> Void)?

    func start() {
        stop()

        if isRunning { return }

        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, userInfo in
                guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyEventMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
                if type == .keyDown {
                    monitor.handle(event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            NSLog("[KeyEventMonitor] Failed to create event tap (requires Accessibility permission)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        NSLog("[KeyEventMonitor] Started")
    }

    func stop() {
        if !isRunning { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
        NSLog("[KeyEventMonitor] Stopped")
    }

    private func handle(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

        let isBackspace = keyCode == kVK_Delete
        let isDeleteForward = keyCode == kVK_ForwardDelete
        let isArrow = keyCode == kVK_LeftArrow || keyCode == kVK_RightArrow || keyCode == kVK_UpArrow || keyCode == kVK_DownArrow

        let chars = decodeCharacters(from: event)
        let decoded = DecodedKey(
            characters: chars,
            keyCode: CGKeyCode(keyCode),
            modifiers: flags,
            isBackspace: isBackspace,
            isDeleteForward: isDeleteForward,
            isArrow: isArrow
        )
        onKeyDown?(decoded)
    }

    // Decode characters using current keyboard layout; falls back to event's unicodeString if available.
    private func decodeCharacters(from event: CGEvent) -> String? {
        // If NSEvent is available, try charactersIgnoringModifiers first
        if let nsEvent = NSEvent(cgEvent: event) {
            // For text entry, we want the produced character considering layout but often ignoring modifiers like shift for arrows
            if let s = nsEvent.characters, !s.isEmpty { return s }
            if let s = nsEvent.charactersIgnoringModifiers, !s.isEmpty { return s }
        }

        // Fallback: translate via current keyboard layout
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(ptr, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> String? in
            guard let base = rawPtr.baseAddress else { return nil }
            let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            var keysDown: UInt32 = 0
            var chars: [UniChar] = Array(repeating: 0, count: 4)
            var realLength: Int = 0

            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifierFlags = event.flags
            let modifiers = UInt32(modifierFlags.rawValue) >> 16

            let deadKeyState = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
            defer { deadKeyState.deallocate() }
            deadKeyState.pointee = 0

            let err = UCKeyTranslate(layoutPtr,
                                     keyCode,
                                     UInt16(kUCKeyActionDown),
                                     modifiers & 0xFF,
                                     UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                     &keysDown,
                                     chars.count,
                                     &realLength,
                                     &chars)
            if err == noErr, realLength > 0 {
                return String(utf16CodeUnits: chars, count: realLength)
            }
            return nil
        }
    }
}

