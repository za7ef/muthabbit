//
//  VersionMatch.swift
//  Muthabbit
//
//  Lenient version comparison for matching a source's version text with the version inside
//  an IPA: "v2.3.4" == "2.3.4", "1.0" == "1.0.0", "1.0b15-release" ~ "1.0",
//  "andarium-1.1" == "1.1" (a source that copies the GitHub tag name as the version).
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import Foundation

enum VersionMatch {
	/// Drops a text prefix before the version number: "v2.3.4" → "2.3.4", "andarium-1.1" → "1.1",
	/// "release_2.0" → "2.0". The prefix is either a single "v"/"V" or letters ending with "-",
	/// "_" or a space; anything else (e.g. "ios15") is left unchanged.
	static func stripPrefix(_ value: Substring) -> Substring {
		guard let first = value.first, !(first.isASCII && first.isNumber) else { return value }
		if (first == "v" || first == "V"), let next = value.dropFirst().first, next.isASCII, next.isNumber {
			return value.dropFirst()
		}
		let prefix = value.prefix(while: { $0.isLetter })
		let rest = value.dropFirst(prefix.count)
		guard !prefix.isEmpty, let sep = rest.first, sep == "-" || sep == "_" || sep == " " else { return value }
		let tail = rest.dropFirst()
		guard let digit = tail.first, digit.isASCII, digit.isNumber else { return value }
		return tail
	}
	
	/// Leading numeric components: trims, drops any text before the first digit and a " (build)"
	/// part, stops at the first non-numeric suffix (-release, -beta, b15, rc1 …).
	static func components(_ value: String) -> [Int] {
		var s = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
		if let r = s.range(of: " (") { s = s[..<r.lowerBound] }
		s = stripPrefix(s)
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
	
	/// True when the text has nothing beyond plain numbers (after any text prefix such as "v"
	/// or "andarium-").
	static func isPlain(_ value: String) -> Bool {
		let s = stripPrefix(Substring(value.trimmingCharacters(in: .whitespacesAndNewlines)))
		return !s.isEmpty && s.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
	}
	
	/// Same release, ignoring text prefixes ("v", "andarium-"), trailing ".0" and text suffixes.
	static func sameRelease(_ a: String, _ b: String) -> Bool {
		let ca = components(a), cb = components(b)
		return !ca.isEmpty && ca == cb
	}
	
	/// The numeric build part of "1.1 (16)" → 16; nil when there is none or it is not a number
	/// (e.g. "1.1 (Beta)").
	static func build(_ value: String) -> Int? {
		guard let open = value.range(of: " (") else { return nil }
		var rest = value[open.upperBound...]
		if rest.hasSuffix(")") { rest = rest.dropLast() }
		return Int(rest.trimmingCharacters(in: .whitespacesAndNewlines))
	}
}
