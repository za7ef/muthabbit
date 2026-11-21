//
//  String+localized.swift
//  NimbleKit
//
//  Created by samara on 20.03.2025.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import Foundation.NSString
import SwiftUI

/// Bundle used for every `.localized` lookup.
/// Uses the language chosen in Settings ("Muthabbit.language"), otherwise the system language.
nonisolated(unsafe) private let _nbLocalizationBundle: Bundle = {
	let supported = ["ar", "en", "fr", "es", "ru", "zh-Hans", "ur", "tr"]
	let chosen = UserDefaults.standard.string(forKey: "Muthabbit.language") ?? ""
	let code = chosen.isEmpty
		? (Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en")
		: chosen
	if
		let path = Bundle.main.path(forResource: code, ofType: "lproj"),
		let bundle = Bundle(path: path)
	{
		return bundle
	}
	return Bundle.main
}()

extension String {
	// from: https://github.com/NSAntoine/Antoine/blob/main/Antoine/Backend/Extensions/Foundation.swift#L43-L55
	// was given permission to use any code from antoine as I like - thank you Serena!~
	
	static public func localized(_ name: String) -> String {
		NSLocalizedString(name, tableName: nil, bundle: _nbLocalizationBundle, value: name, comment: "")
	}
	
	static public func localized(_ name: String, arguments: CVarArg...) -> String {
		String(
			format: NSLocalizedString(name, tableName: nil, bundle: _nbLocalizationBundle, value: name, comment: ""),
			arguments: arguments
		)
	}
	/// Localizes the current string using the main bundle.
	///
	/// - Returns: The localized string.
	public func localized() -> String {
		String.localized(self)
	}
}

extension LocalizedStringKey {
	static public func localized(_ key: String) -> LocalizedStringKey {
		LocalizedStringKey(String.localized(key))
	}
}
