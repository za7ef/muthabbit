//
//  AutoTranslate.swift
//  Muthabbit
//
//  On-device translation of source texts (descriptions, subtitles, release notes) into the
//  app language with Apple's Translation framework (iOS 18+). Nothing is sent to a server.
//  - Language detection: NaturalLanguage (NLLanguageRecognizer).
//  - Translates automatically only when both language packs are already on the device;
//    otherwise shows «ترجمة», because iOS asks before downloading a language pack.
//  - iOS 16–17: original text only.
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Cache

@MainActor
final class TranslationCache {
	static let shared = TranslationCache()
	
	private var _store: [String: String]
	private let _url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		.appendingPathComponent("Muthabbit-translations.json")
	
	private init() {
		_store = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: _url))) ?? [:]
	}
	
	private func _key(_ text: String, _ target: String) -> String { target + "|" + text }
	
	func get(_ text: String, target: String) -> String? { _store[_key(text, target)] }
	
	func set(_ value: String, for text: String, target: String) {
		if _store.count > 400 { _store.removeAll() }
		_store[_key(text, target)] = value
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
	
	/// App language as used by Translation ("ar", "en", "zh-Hans", …).
	static var target: String { AppLanguage.effectiveCode }
	
	private static func _base(_ code: String) -> String {
		String(code.split(separator: "-").first ?? Substring(code)).lowercased()
	}
	
	/// Detected source language when the text is clearly in another language; nil otherwise.
	static func foreignLanguage(of text: String) -> String? {
		let sample = String(text.prefix(600))
		guard sample.count >= 8 else { return nil }
		let recognizer = NLLanguageRecognizer()
		recognizer.processString(sample)
		guard
			let lang = recognizer.dominantLanguage,
			lang != .undetermined,
			(recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) >= 0.6
		else { return nil }
		return _base(lang.rawValue) == _base(target) ? nil : lang.rawValue
	}
}

// MARK: - View

/// Shows `content` with the translated text when possible, plus a small toggle line.
struct TranslatableText<Content: View>: View {
	let text: String
	var compact: Bool = false
	@ViewBuilder let content: (String) -> Content
	
	@State private var _translated: String?
	@State private var _showOriginal = false
	@State private var _canOffer = false
	@State private var _request = 0
	
	private var _source: String? {
		AutoTranslate.isEnabled ? AutoTranslate.foreignLanguage(of: text) : nil
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			content(_showOriginal ? text : (_translated ?? text))
			_footer
		}
		.modifier(_TranslateHook(text: text, source: _source, request: _request, translated: $_translated, canOffer: $_canOffer))
		.onAppear {
			if _translated == nil { _translated = TranslationCache.shared.get(text, target: AutoTranslate.target) }
		}
	}
	
	@ViewBuilder
	private var _footer: some View {
		if compact {
			EmptyView()
		} else if _translated != nil {
			Button {
				withAnimation(.snappy) { _showOriginal.toggle() }
			} label: {
				Text(_showOriginal ? L("عرض الترجمة") : L("مترجم تلقائيًا · عرض الأصل"))
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
		} else if _canOffer {
			Button {
				_request += 1
			} label: {
				Label(L("ترجمة"), systemImage: "translate")
					.font(.caption)
					.foregroundStyle(Color.accentColor)
			}
			.buttonStyle(.plain)
		}
	}
}

private struct _TranslateHook: ViewModifier {
	let text: String
	let source: String?
	let request: Int
	@Binding var translated: String?
	@Binding var canOffer: Bool
	
	@ViewBuilder
	func body(content: Content) -> some View {
		#if canImport(Translation)
		if let source {
			if #available(iOS 18.0, *) {
				content.modifier(_Translator(text: text, source: source, request: request, translated: $translated, canOffer: $canOffer))
			} else {
				content
			}
		} else {
			content
		}
		#else
		content
		#endif
	}
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct _Translator: ViewModifier {
	let text: String
	let source: String
	let request: Int
	@Binding var translated: String?
	@Binding var canOffer: Bool
	
	@State private var _config: TranslationSession.Configuration?
	
	private var _from: Locale.Language { Locale.Language(identifier: source) }
	private var _to: Locale.Language { Locale.Language(identifier: AutoTranslate.target) }
	
	func body(content: Content) -> some View {
		content
			.task(id: text) {
				guard translated == nil else { return }
				let status = await LanguageAvailability().status(from: _from, to: _to)
				switch status {
				case .installed:
					_config = TranslationSession.Configuration(source: _from, target: _to)
				case .supported:
					canOffer = true   // needs a language download; iOS asks first
				default:
					canOffer = false  // pair not supported
				}
			}
			.onChange(of: request) { _ in
				if _config == nil {
					_config = TranslationSession.Configuration(source: _from, target: _to)
				} else {
					_config?.invalidate()
				}
			}
			.translationTask(_config) { session in
				// Line by line so Markdown markers (#, -, *) stay outside the translated text.
				let lines = text.components(separatedBy: "\n")
				var prefixes: [String] = []
				var bodies: [String] = []
				for line in lines {
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					var prefix = ""
					var rest = Substring(trimmed)
					while let c = rest.first, "#-*•>".contains(c) || (c == " " && !prefix.isEmpty) {
						prefix.append(c)
						rest = rest.dropFirst()
					}
					if !prefix.isEmpty, !prefix.hasSuffix(" ") { prefix += " " }
					prefixes.append(prefix)
					bodies.append(String(rest).trimmingCharacters(in: .whitespaces))
				}
				let requests = bodies.enumerated()
					.filter { !$0.element.isEmpty }
					.map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
				guard !requests.isEmpty else { return }
				do {
					let responses = try await session.translations(from: requests)
					var out = bodies
					for r in responses {
						if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText }
					}
					let result = zip(prefixes, out).map { $0 + $1 }.joined(separator: "\n")
					await MainActor.run {
						translated = result
						canOffer = false
						TranslationCache.shared.set(result, for: text, target: AutoTranslate.target)
					}
				} catch {
					// Language pack declined, offline, or unsupported: keep the original text.
				}
			}
	}
}
#endif
