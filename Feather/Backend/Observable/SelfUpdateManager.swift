//
//  SelfUpdateManager.swift
//  Muthabbit
//
//  Checks the latest GitHub release of the app itself and offers the update.
//

import Foundation
import UIKit

enum AppInfo {
	static let displayName = "مُثبِّت"
	static let repository = "za7ef/muthabbit"
	static let repositoryURL = URL(string: "https://github.com/za7ef/muthabbit")!
	static let developerURL = URL(string: "https://github.com/za7ef")!
	static let defaultSourceURL = "https://raw.githubusercontent.com/za7ef/apps-source/main/source.json"
	
	static var marketingVersion: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
	}
	
	static var buildNumber: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
	}
	
	/// e.g. "1.0.0 (12)"
	static var fullVersion: String {
		"\(marketingVersion) (\(buildNumber))"
	}
}

struct SelfUpdateInfo: Equatable {
	let version: String
	let build: Int
	let notes: String
	let ipaURL: URL?
	let pageURL: URL
}

@MainActor
final class SelfUpdateManager {
	static let shared = SelfUpdateManager()
	
	private var _didCheckThisLaunch = false
	private let _skipKey = "muthabbit.selfUpdate.dismissedTag"
	
	private init() {}
	
	/// Checks once per launch. Silent on any network or parsing failure.
	func checkOnLaunch() {
		guard !_didCheckThisLaunch else { return }
		_didCheckThisLaunch = true
		
		Task {
			guard let info = await _fetchLatest() else { return }
			guard Self.isNewer(remoteVersion: info.version, remoteBuild: info.build) else { return }
			
			let tagKey = "\(info.version)-\(info.build)"
			if UserDefaults.standard.string(forKey: _skipKey) == tagKey { return }
			
			_present(info, tagKey: tagKey)
		}
	}
	
	static func isNewer(remoteVersion: String, remoteBuild: Int) -> Bool {
		let order = remoteVersion.compare(AppInfo.marketingVersion, options: .numeric)
		if order == .orderedDescending { return true }
		if order == .orderedAscending { return false }
		guard remoteBuild > 0 else { return false }
		let localBuild = Int(AppInfo.buildNumber) ?? 0
		return remoteBuild > localBuild
	}
	
	// MARK: Network
	
	private struct Release: Decodable {
		struct Asset: Decodable {
			let name: String
			let browser_download_url: URL
		}
		let tag_name: String
		let body: String?
		let html_url: URL
		let draft: Bool?
		let prerelease: Bool?
		let assets: [Asset]
	}
	
	private func _fetchLatest() async -> SelfUpdateInfo? {
		guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else {
			return nil
		}
		
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
			let release = try JSONDecoder().decode(Release.self, from: data)
			guard let parsed = Self.parseTag(release.tag_name) else { return nil }
			
			let ipa = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") })?.browser_download_url
			return SelfUpdateInfo(
				version: parsed.version,
				build: parsed.build,
				notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
				ipaURL: ipa,
				pageURL: release.html_url
			)
		} catch {
			return nil
		}
	}
	
	/// Tag formats: "v1.1" → ("1.1", 0), legacy "v1.0.0-b12" → ("1.0.0", 12)
	static func parseTag(_ tag: String) -> (version: String, build: Int)? {
		var value = tag
		if value.hasPrefix("v") { value.removeFirst() }
		let parts = value.components(separatedBy: "-b")
		if parts.count == 2, !parts[0].isEmpty, let build = Int(parts[1]) {
			return (parts[0], build)
		}
		// New format: "v1.1" (one marketing version per build; build number not in the tag).
		guard !value.isEmpty, value.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
		return (value, 0)
	}
	
	// MARK: UI
	
	private func _present(_ info: SelfUpdateInfo, tagKey: String) {
		var message = info.build > 0 ? L("الإصدار %@", "\(info.version) (\(info.build))") : L("الإصدار %@", "\(info.version)")
		if !info.notes.isEmpty {
			message += "\n\n" + L("ما الجديد:") + "\n" + String(info.notes.prefix(600))
		}
		
		let later = UIAlertAction(title: L("لاحقًا"), style: .cancel) { [weak self] _ in
			guard let self else { return }
			UserDefaults.standard.set(tagKey, forKey: self._skipKey)
		}
				let update = UIAlertAction(title: L("تحديث"), style: .default) { _ in
			guard let ipa = info.ipaURL else {
				UIApplication.shared.open(info.pageURL)
				return
			}
			// Download → sign with the selected certificate → install over itself (Server method).
			QuickInstallManager.shared.installFromSource(
				url: ipa,
				downloadID: "Muthabbit.selfUpdate.\(info.build)",
				key: Bundle.main.bundleIdentifier ?? "com.za7ef.muthabbit",
				provenance: nil,
				isUpdate: true
			)
		}
		
		UIAlertController.showAlert(
			title: L("تحديث جديد متوفر"),
			message: message,
			actions: [later, update]
		)
	}
}
