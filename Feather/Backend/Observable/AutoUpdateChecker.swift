//
//  AutoUpdateChecker.swift
//  Muthabbit
//
//  Runs the source update check automatically (launch / foreground),
//  and adds the default source on first launch.
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
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
		
		// Added once on first launch (even if other sources exist); never re-added after deletion.
		guard !Storage.shared.getSources().contains(where: { $0.sourceURL?.absoluteString == AppInfo.defaultSourceURL }) else { return }
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
		
		let localApps = installedApps()
		
		guard !localApps.isEmpty else { return }
		
		await UpdateManager.shared.checkForUpdates(
			sources: Storage.shared.getSources(),
			localApps: localApps
		)
	}
	
	/// Every app in «تطبيقاتي» (the install history), not only the ones that still have a
	/// stored signed copy: the newest signed copy when one exists, otherwise a stand-in built
	/// from the install record and the version iOS reports for the installed app.
	static func installedApps() -> [AppInfoPresentable] {
		let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		var newestSigned: [String: Signed] = [:]
		for app in (try? Storage.shared.context.fetch(signedRequest)) ?? [] {
			if let id = app.identifier, newestSigned[id] == nil { newestSigned[id] = app }
		}
		
		let own = QuickInstallManager.ownBundleID
		return QuickInstallManager.shared.records.values
			.filter { $0.id != own }
			.sorted { $0.id < $1.id }
			.map { record -> AppInfoPresentable in
				if let signed = newestSigned[record.id] { return signed }
				return InstalledRecordApp(record: record)
			}
	}
}

/// An installed app with no stored signed copy (its files were removed, or it was recorded
/// without one). Identified by its bundle id so the update check still covers it.
struct InstalledRecordApp: AppInfoPresentable {
	static let uuidPrefix = "installed-record-"
	
	let name: String?
	let version: String?
	let identifier: String?
	let date: Date?
	let icon: String? = nil
	let uuid: String?
	let source: URL? = nil
	let isSigned: Bool = true
	
	init(record: InstallRecord) {
		self.name = record.name
		self.identifier = record.id
		self.date = record.date
		self.uuid = Self.uuidPrefix + record.id
		// The version iOS reports for the installed app is the truth; the record is the fallback.
		let short = QuickInstallManager.installedVersion(record.id).version?
			.components(separatedBy: "|").last?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		self.version = (short?.isEmpty == false ? short : nil) ?? record.version
	}
}
