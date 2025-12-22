//
//  Trigger.swift
//  CheapExpander
//
//  Part 4: Trigger model and validation
//

import Foundation

struct Trigger {
    let raw: String
    let body: String
    let endAnchor: Character
    let expansion: String

    /// Initialize a trigger from its raw form and expansion, validating against the configured
    /// start delimiter and allowed end anchors.
    /// - Parameters:
    ///   - raw: Full trigger string, e.g. ";t/" or ";s."
    ///   - expansion: The expansion text to insert when matched.
    ///   - startDelimiter: The configured start delimiter (default ";").
    ///   - endAnchors: The allowed end anchors (default ["/", "."]).
    init?(raw: String, expansion: String, startDelimiter: String, endAnchors: Set<Character>) {
        guard raw.hasPrefix(startDelimiter), let last = raw.last, endAnchors.contains(last) else {
            return nil
        }
        let startIndex = raw.index(raw.startIndex, offsetBy: startDelimiter.count)
        let endIndex = raw.index(before: raw.endIndex)
        guard startIndex <= endIndex else { return nil }

        self.raw = raw
        self.body = String(raw[startIndex..<endIndex])
        self.endAnchor = last
        self.expansion = expansion
    }
}
