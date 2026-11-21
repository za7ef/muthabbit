//
//  AutoTranslate.swift
//  Muthabbit
//
//  Automatic translation of source texts (descriptions, subtitles, release notes) into the
//  app language with Google Translate's free web endpoint (no API key). Works on iOS 16+.
//  - Language detection: NaturalLanguage (NLLanguageRecognizer), so texts already in the
//    app language are never sent.
//  - Results are cached on the device; a failure or rate limit simply keeps the original text.
//  - Can be turned off in Settings ("Muthabbit.autoTranslate").
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI
import NaturalLanguage

// MARK: - Cache

@MainActor
final class TranslationCache: ObservableObject {
	static let shared = TranslationCache()
	
	private var _store: [String: String]
	/// Bumped on every change so observing views re-read translated strings.
	@Published private(set) var revision = 0
	private let _url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("Muthabbit-translations.json")
	
	private init() {
		_store = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: _url))) ?? [:]
	}
	
	private func _key(_ text: String, _ target: String) -> String { target + "|" + text }
	
	func get(_ text: String, target: String) -> String? { _store[_key(text, target)] }
	
	func setMany(_ pairs: [String: String], target: String) {
		guard !pairs.isEmpty else { return }
		if _store.count + pairs.count > 800 { _store.removeAll() }
		for (text, value) in pairs { _store[_key(text, target)] = value }
		revision += 1
		let data = try? JSONEncoder().encode(_store)
		let url = _url
		Task.detached(priority: .background) { try? data?.write(to: url, options: .atomic) }
	}
}

// MARK: - Detection

enum AutoTranslate {
	static let enabledKey = "Muthabbit.autoTranslate"
	
	static var isEnabled: Bool {
		UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
	}
	
	/// App language ("ar", "en", "zh-Hans", …).
	static var target: String { AppLanguage.effectiveCode }
	
	private static func _base(_ code: String) -> String {
		String(code.split(separator: "-").first ?? Substring(code)).lowercased()
	}
	
	/// True when the text is clearly in another language than the app.
	static func isForeign(_ text: String) -> Bool {
		let sample = String(text.prefix(600))
		guard sample.count >= 8, sample.contains(where: { $0.isLetter }) else { return false }
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(sample)
		guard
			let lang = recognizer.dominantLanguage,
			lang != .undetermined,
			(recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) >= 0.6
		else { return false }
		return _base(lang.rawValue) != _base(target)
	}
}

// MARK: - Google Translate (free endpoint)

enum GoogleTranslate {
	/// After a rate limit (HTTP 429) or block, pause all requests for a while.
	@MainActor private static var _pausedUntil = Date.distantPast
	
	private static let _session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 10
		config.timeoutIntervalForResource = 20
		config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0"]
		return URLSession(configuration: config)
	}()
	
	/// Google's code for the app language.
	private static var _targetCode: String {
		switch AutoTranslate.target {
		case "zh-Hans": return "zh-CN"
		case let code: return String(code.split(separator: "-").first ?? Substring(code))
		}
	}
	
	/// Translates one text; nil on any failure.
	static func translate(_ text: String) async -> String? {
		guard await MainActor.run(body: { Date() >= _pausedUntil }) else { return nil }
		// Long texts: at most ~4500 characters per request (POST body).
		let chunk = String(text.prefix(4500))
		guard let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(_targetCode)&dt=t") else { return nil }
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		request.httpBody = ("q=" + (chunk.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).data(using: .utf8)
		
		guard let (data, response) = try? await _session.data(for: request) else { return nil }
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		if status == 429 || status == 403 {
			await MainActor.run { _pausedUntil = Date().addingTimeInterval(600) }
			return nil
		}
		guard
			status == 200,
			let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
			let parts = json.first as? [Any]
		else { return nil }
		// [[["translated","original",…],…],…]
		let result = parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
		guard !result.isEmpty else { return nil }
		return text.count > chunk.count ? result + String(text.dropFirst(chunk.count)) : result
	}
	
	/// Translates several texts, at most 4 requests at a time. Returns only the successes.
	static func translateMany(_ texts: [String]) async -> [String: String] {
		var results: [String: String] = [:]
		var index = 0
		while index < texts.count {
			let slice = Array(texts[index..<min(index + 4, texts.count)])
			index += slice.count
			await withTaskGroup(of: (String, String?).self) { group in
				for text in slice {
					group.addTask { (text, await translate(text)) }
				}
				for await (text, translated) in group {
					if let translated { results[text] = translated }
				}
			}
			if await MainActor.run(body: { Date() < _pausedUntil }) { break }
		}
		return results
	}
}

// MARK: - Detail page text

/// Shows `content` with the translated text when possible, plus «مترجم تلقائيًا · عرض الأصل».
struct TranslatableText<Content: View>: View {
	let text: String
	var compact: Bool = false
	@ViewBuilder let content: (String) -> Content
	
	@State private var _translated: String?
	@State private var _showOriginal = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			content(_showOriginal ? text : (_translated ?? text))
			if !compact, _translated != nil {
				Button {
					withAnimation(.snappy) { _showOriginal.toggle() }
				} label: {
					Text(_showOriginal ? L("عرض الترجمة") : L("مترجم تلقائيًا · عرض الأصل"))
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
			}
		}
		.task(id: text) {
			guard AutoTranslate.isEnabled else { _translated = nil; return }
			let target = AutoTranslate.target
			if let cached = TranslationCache.shared.get(text, target: target) {
				_translated = cached
				return
			}
			guard AutoTranslate.isForeign(text) else { return }
			// Line by line keeps Markdown markers (#, -, *) outside the translated text.
			let lines = text.components(separatedBy: "\n")
			var prefixes: [String] = []
			var bodies: [String] = []
			for line in lines {
				var rest = Substring(line.trimmingCharacters(in: .whitespaces))
				var prefix = ""
				while let c = rest.first, "#-*•>".contains(c) {
					prefix.append(c)
					rest = rest.dropFirst()
				}
				if !prefix.isEmpty { prefix += " " }
				prefixes.append(prefix)
				bodies.append(rest.trimmingCharacters(in: .whitespaces))
			}
			let unique = Array(Set(bodies.filter { !$0.isEmpty }))
			let map = await GoogleTranslate.translateMany(unique)
			guard !map.isEmpty, !Task.isCancelled else { return }
			let result = zip(prefixes, bodies).map { $0 + (map[$1] ?? $1) }.joined(separator: "\n")
			TranslationCache.shared.setMany([text: result], target: target)
			_translated = result
		}
	}
}

// MARK: - Batch (store cards and rows)

extension View {
	/// Translates short texts (subtitles, card descriptions) once per change of the list,
	/// into `TranslationCache`. Views read results with `TranslationCache.shared.get`.
	func batchTranslate(_ texts: [String]) -> some View {
		modifier(_BatchTranslator(texts: texts))
	}
}

private struct _BatchTranslator: ViewModifier {
	let texts: [String]
	
	func body(content: Content) -> some View {
		content.task(id: texts.hashValue) {
			guard AutoTranslate.isEnabled else { return }
			let target = AutoTranslate.target
			let cache = TranslationCache.shared
			let pending = Set(texts).filter { cache.get($0, target: target) == nil && AutoTranslate.isForeign($0) }
			guard !pending.isEmpty else { return }
			let map = await GoogleTranslate.translateMany(Array(pending))
			guard !Task.isCancelled else { return }
			cache.setMany(map, target: target)
		}
	}
}
