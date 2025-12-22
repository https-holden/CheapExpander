//
//  InputBuffer.swift
//  CheapExpander
//
//  Part 4: Rolling buffer helper (no replacement yet)
//

import Foundation

struct InputBuffer {
    private(set) var contents: String = ""
    let maxLength: Int = 20
    private(set) var invalidated: Bool = false

    mutating func clear() {
        contents.removeAll(keepingCapacity: true)
        invalidated = false
    }

    mutating func invalidate() {
        contents.removeAll(keepingCapacity: true)
        invalidated = true
    }

    mutating func append(_ s: String) {
        if invalidated {
            // After a caret/selection move, start fresh on next typed character
            invalidated = false
        }
        if s.isEmpty { return }
        contents.append(s)
        if contents.count > maxLength {
            let overflow = contents.count - maxLength
            if overflow > 0 {
                contents.removeFirst(overflow)
            }
        }
    }

    mutating func backspace() {
        guard !contents.isEmpty else { return }
        contents.removeLast()
    }
}

