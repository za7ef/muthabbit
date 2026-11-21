//
//  AutoUpdateChecker.swift
//  Muthabbit
//
//  Runs the source update check automatically (launch / foreground),
//  and adds the default source on first launch.
//

import Foundation
import CoreData

@MainActor
enum AutoUpdateChecker {
	private static let _didAddDefaultSourceKey = "muthabbit.didAddDefaultSource"
	private static let _minimumInterval: TimeInterval = 10 * 60
	private static var _lastRun: Date?
	
	/// Adds the za7ef apps source once, on the first launch.
	static func addDefaultSourceIfNeeded() {
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: _didAddDefaultSourceKey) else { return }
		defaults.set(true, forKey: _didAddDefaultSourceKey)
		
		guard Storage.shared.getSources().isEmpty else { return }
		FR.handleSource(AppInfo.defaultSourceURL) {}
	}
	
	/// Checks all sources for newer versions of library apps.
	/// Skips when the last automatic check ran less than 10 minutes ago, unless `force` is set.
	static func checkNow(force: Bool = false) async {
		if
			!force,
			let last = _lastRun,
			Date().timeIntervalSince(last) < _minimumInterval
		{
			return
		}
		_lastRun = Date()
		
		let context = Storage.shared.context
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
		let signed = (try? context.fetch(signedRequest)) ?? []
		let imported = (try? context.fetch(importedRequest)) ?? []
		let localApps: [AppInfoPresentable] =
			signed.map { $0 as AppInfoPresentable } + imported.map { $0 as AppInfoPresentable }
		
		guard !localApps.isEmpty else { return }
		
		await UpdateManager.shared.checkForUpdates(
			sources: Storage.shared.getSources(),
			localApps: localApps
		)
	}
}
