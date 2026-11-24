//
//  SearchMatch.swift
//  Muthabbit
//
//  Tolerant store search: ignores letter case, diacritics, spaces, "-", "." and "_";
//  treats look-alike characters as equal (I/l/1, O/0) and common Arabic letter variants
//  (أ إ آ → ا، ة → ه، ى → ي); allows a small typo for queries of 4 characters or more.
//  Results are ranked: exact name, then name prefix, then name contains, then other fields,
//  then near matches (typos).
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import Foundation

enum SearchMatch {
	/// Prepared query, built once per search text.
	struct Query {
		let raw: String
		let key: [Character]
		let maxTypos: Int
		
		init(_ text: String) {
			raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
			key = SearchMatch.normalize(raw)
			// Typo matching only for 4–32 characters: very long queries would make it slow.
			maxTypos = key.count > 32 ? 0 : (key.count >= 8 ? 2 : (key.count >= 4 ? 1 : 0))
		}
		
		var isEmpty: Bool { key.isEmpty }
	}
	
	private final class Box { let value: [Character]; init(_ v: [Character]) { value = v } }
	private static let _cache: NSCache<NSString, Box> = {
		let cache = NSCache<NSString, Box>()
		cache.countLimit = 20_000
		return cache
	}()
	
	/// `normalize` with a cache: names, bundle ids and developers repeat on every keystroke.
	static func normalizedCached(_ text: String) -> [Character] {
		if let hit = _cache.object(forKey: text as NSString) { return hit.value }
		let value = normalize(text)
		_cache.setObject(Box(value), forKey: text as NSString)
		return value
	}
	
	/// Lowercase, no diacritics, look-alikes merged, separators removed.
	static func normalize(_ text: String) -> [Character] {
		let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
		var out: [Character] = []
		out.reserveCapacity(folded.count)
		for ch in folded {
			switch ch {
			case "i", "l", "1", "|", "!": out.append("l")
			case "o", "0": out.append("o")
			case "أ", "إ", "آ", "ٱ": out.append("ا")
			case "ة": out.append("ه")
			case "ى": out.append("ي")
			default:
				if ch.isLetter || ch.isNumber { out.append(ch) }
			}
		}
		return out
	}
	
	/// Higher is better; nil means no match.
	/// - name: 100 exact, 80 prefix, 60 contains, 20 near match (typo).
	/// - other fields (bundle id, developer, subtitle): 40 contains.
	/// - long texts (descriptions): 10 contains (plain case-insensitive check, kept cheap).
	static func score(
		_ query: Query,
		name: String?,
		fields: [String?] = [],
		longTexts: [String?] = []
	) -> Int? {
		guard !query.isEmpty else { return 0 }
		let q = query.key
		let n = normalizedCached(name ?? "")
		if !n.isEmpty {
			if n == q { return 100 }
			if n.starts(with: q) { return 80 }
			if _contains(n, q) { return 60 }
		}
		for field in fields {
			guard let field, !field.isEmpty else { continue }
			if _contains(normalizedCached(field), q) { return 40 }
		}
		if query.maxTypos > 0, !n.isEmpty, _nearMatch(n, q, maxTypos: query.maxTypos) {
			return 20
		}
		for text in longTexts {
			guard let text, !text.isEmpty else { continue }
			if text.localizedCaseInsensitiveContains(query.raw) { return 10 }
		}
		return nil
	}
	
	/// Keeps matching items, best first; equal scores keep the original order.
	static func rank<T>(_ items: [T], query text: String, score: (Query, T) -> Int?) -> [T] {
		let query = Query(text)
		guard !query.isEmpty else { return items }
		var scored: [(Int, Int, T)] = []
		for (index, item) in items.enumerated() {
			if let s = score(query, item) { scored.append((s, index, item)) }
		}
		scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
		return scored.map { $0.2 }
	}
	
	private static func _contains(_ text: [Character], _ q: [Character]) -> Bool {
		guard q.count <= text.count else { return false }
		if q.isEmpty { return true }
		let last = text.count - q.count
		var i = 0
		while i <= last {
			if text[i] == q[0] {
				var j = 1
				while j < q.count, text[i + j] == q[j] { j += 1 }
				if j == q.count { return true }
			}
			i += 1
		}
		return false
	}
	
	/// True when `q` appears in `text` with at most `maxTypos` edits (insert, delete, replace).
	/// Approximate substring matching (Sellers), O(text × query), only run on names.
	private static func _nearMatch(_ text: [Character], _ q: [Character], maxTypos: Int) -> Bool {
		let m = q.count
		var prev = Array(0...m)
		var cur = [Int](repeating: 0, count: m + 1)
		if prev[m] <= maxTypos { return true }
		for ch in text {
			cur[0] = 0
			for j in 1...m {
				let cost = q[j - 1] == ch ? 0 : 1
				cur[j] = min(prev[j - 1] + cost, prev[j] + 1, cur[j - 1] + 1)
			}
			if cur[m] <= maxTypos { return true }
			swap(&prev, &cur)
		}
		return false
	}
}
