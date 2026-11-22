//
//  VersionMatch.swift
//  Muthabbit
//
//  Lenient version comparison for matching a source's version text with the version inside
//  an IPA: "v2.3.4" == "2.3.4", "1.0" == "1.0.0", "1.0b15-release" ~ "1.0".
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import Foundation

enum VersionMatch {
	/// Leading numeric components: trims, drops a leading "v"/"V" and a " (build)" part,
	/// stops at the first non-numeric suffix (-release, -beta, b15, rc1 …).
	static func components(_ value: String) -> [Int] {
		var s = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
		if let r = s.range(of: " (") { s = s[..<r.lowerBound] }
		if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
		var parts: [Int] = []
		for piece in s.split(separator: ".", omittingEmptySubsequences: false) {
			let digits = piece.prefix(while: { $0.isASCII && $0.isNumber })
			guard let n = Int(digits) else { break }
			parts.append(n)
			if digits.count != piece.count { break } // suffix reached
		}
		while parts.count > 1, parts.last == 0 { parts.removeLast() }
		return parts
	}
	
	/// True when the text has nothing beyond plain numbers (after an optional "v").
	static func isPlain(_ value: String) -> Bool {
		var s = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
		if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
		return !s.isEmpty && s.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
	}
	
	/// Same release, ignoring "v", trailing ".0" and text suffixes.
	static func sameRelease(_ a: String, _ b: String) -> Bool {
		let ca = components(a), cb = components(b)
		return !ca.isEmpty && ca == cb
	}
}
