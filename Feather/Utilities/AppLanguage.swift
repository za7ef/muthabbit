//
//  AppLanguage.swift
//  Muthabbit
//
//  Interface language: follows the system by default, or a language chosen in Settings.
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
	case system = ""
	case ar, en, fr, es, ru
	case zhHans = "zh-Hans"
	case ur, tr
	
	var id: String { rawValue }
	
	static let storageKey = "Muthabbit.language"
	static let supported: [String] = ["ar", "en", "fr", "es", "ru", "zh-Hans", "ur", "tr"]
	
	/// Native name, shown the same in every interface language.
	var nativeName: String {
		switch self {
		case .system: return L("لغة النظام")
		case .ar: return "العربية"
		case .en: return "English"
		case .fr: return "Français"
		case .es: return "Español"
		case .ru: return "Русский"
		case .zhHans: return "简体中文"
		case .ur: return "اردو"
		case .tr: return "Türkçe"
		}
	}
	
	/// The language chosen in Settings (`.system` when following the device).
	static var selected: AppLanguage {
		AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
	}
	
	/// The language code actually in use (resolved once per launch).
	static let effectiveCode: String = {
		let chosen = selected.rawValue
		if !chosen.isEmpty { return chosen }
		let preferred = Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages)
		return preferred.first ?? "en"
	}()
	
	static var isRTL: Bool { effectiveCode == "ar" || effectiveCode == "ur" }
	
	static var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }
	
	static var locale: Locale { Locale(identifier: effectiveCode) }
	
	/// The .lproj bundle for the language in use.
	static let bundle: Bundle = {
		if
			let path = Bundle.main.path(forResource: effectiveCode, ofType: "lproj"),
			let b = Bundle(path: path)
		{
			return b
		}
		return Bundle.main
	}()
	
	/// Applies the stored choice to the system-level language list (call at launch / after a change).
	static func applyToSystem() {
		let chosen = selected.rawValue
		if chosen.isEmpty {
			UserDefaults.standard.removeObject(forKey: "AppleLanguages")
		} else {
			UserDefaults.standard.set([chosen], forKey: "AppleLanguages")
		}
	}
	
	static func select(_ language: AppLanguage) {
		UserDefaults.standard.set(language.rawValue, forKey: storageKey)
		applyToSystem()
	}
}

/// Localized string for an interface key (the Arabic text is the key).
func L(_ key: String) -> String {
	AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string with arguments (`%@` placeholders).
func L(_ key: String, _ args: CVarArg...) -> String {
	String(format: L(key), locale: AppLanguage.locale, arguments: args)
}
