//
//  UpdateManager.swift
//  Feather
//
//  Created by Dominic on 24.05.2026.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	/// Bundle id of the installed app (the «تطبيقاتي» entry this update belongs to).
	let localBundleID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceProvenance: SourceAppProvenance
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	
	/// A check requested while another one is running runs again right after it, so a
	/// pull-to-refresh or post-install check is never dropped.
	private var _pendingRecheck: (sources: [AltSource], localApps: [AppInfoPresentable])?
	
	private init() {}
	
	/// Drops a finished update right away (the next check confirms it).
	func clearUpdate(bundleID: String) {
		updates = updates.filter { $0.value.bundleIdentifier != bundleID }
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		if let update = updates[uuid] { return update }
		guard let bundleID = app.identifier else { return nil }
		return update(forInstalled: bundleID)
	}
	
	/// The update for an installed app, by its bundle id (works with or without a stored signed copy).
	func update(forInstalled bundleID: String) -> AppUpdate? {
		updates.values.first { $0.localBundleID == bundleID }
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else {
			_pendingRecheck = (sources, localApps)
			return
		}
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
			if let next = _pendingRecheck {
				_pendingRecheck = nil
				Task { await self.checkForUpdates(sources: next.sources, localApps: next.localApps) }
			}
		}
		
		var repositories: [(URL, ASRepository)] = await _fetchRepositories(from: sources)
			.compactMap { pair in pair.0.sourceURL.map { ($0, pair.1) } }
		if GitHubAccount.shared.isSignedIn {
			await GitHubAccount.shared.loadProjects()
			if let projects = GitHubAccount.shared.projects {
				repositories.append((GitHubAccount.projectsSourceURL, projects))
			}
		}
		updates = _findUpdates(repositories: repositories, localApps: localApps)
	}
	
	private func _fetchRepositories(from sources: [AltSource]) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		
		for source in sources {
			guard let url = source.sourceURL else {
				continue
			}
			
			guard let repository = await _fetchRepository(from: url) else {
				continue
			}
			
			repositories.append((source, repository))
		}
		
		return repositories
	}
	
	/// Always reads the source from the network (never a cached copy), so a version published
	/// minutes ago is seen by the very next check.
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
				print("[UpdateManager] \(url.absoluteString): HTTP \(http.statusCode)")
				return nil
			}
			return try JSONDecoder().decode(ASRepository.self, from: data)
		} catch {
			print("[UpdateManager] \(url.absoluteString): \(error)")
			return nil
		}
	}
	
	private func _findUpdates(
		repositories: [(URL, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}
		
		for localApp in localApps {
			guard let localUUID = localApp.uuid else {
				continue
			}
			
			let sourceAppIdentifier: String
			let sourceAppVersion: String?
			let storedSourceURL: URL?
			if let directMetadata = metadataByUUID[localUUID] {
				guard
					let metadataSourceAppIdentifier = directMetadata.sourceAppIdentifier,
					let metadataSourceURL = directMetadata.sourceRepositoryURL
				else {
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = directMetadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				guard
					let metadataSourceAppIdentifier = fallback.metadata.sourceAppIdentifier,
					let metadataSourceURL = fallback.metadata.sourceRepositoryURL
				else {
					continue
				}
				
				sourceAppIdentifier = metadataSourceAppIdentifier
				sourceAppVersion = fallback.metadata.sourceAppVersion
				storedSourceURL = metadataSourceURL
				if !localUUID.hasPrefix(InstalledRecordApp.uuidPrefix) { Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				) }
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				storedSourceURL = localSourceURL
			} else if let localIdentifier = localApp.identifier {
				// Installed from a file or link (no source record): matched by bundle id in any source.
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				storedSourceURL = nil
			} else {
				continue
			}
			
			// For this app itself, the running binary is the truth (not the stored record).
			let effectiveVersion: String? = localApp.identifier == Bundle.main.bundleIdentifier
				? AppInfo.marketingVersion + " (" + AppInfo.buildNumber + ")"
				: sourceAppVersion
			
			// The linked source first; when it is missing or no longer lists the app (e.g. the source
			// was re-added under another URL), any source that lists the same bundle id.
			let linked = repositories.filter { pair in
				guard let stored = storedSourceURL else { return false }
				return _matchesStoredRepository(storedSourceURL: stored, sourceURL: pair.0)
			}
			let linkedHasApp = linked.contains { pair in pair.1.apps.contains { remote in remote.id == sourceAppIdentifier } }
			let candidates = linkedHasApp ? linked : repositories
			
			for (sourceURL, repository) in candidates {
				
				guard let remoteApp = repository.apps.first(where: { $0.id == sourceAppIdentifier })
					?? repository.apps.first(where: { Self._isSuffixedCopy(local: sourceAppIdentifier, remote: $0.id) })
				else {
					continue
				}
				
				guard
					let remoteVersion = SourceAppProvenance.versionString(
						remoteApp.currentAppVersion,
						fallback: remoteApp.currentVersion
					),
					!remoteVersion.isEmpty
				else {
					continue
				}
				
				let deviceBundleID = localApp.identifier ?? sourceAppIdentifier
				guard !_isSameVersion(
					remote: remoteVersion,
					stored: effectiveVersion,
					installedBuild: { QuickInstallManager.installedBuild(deviceBundleID) }
				) else {
					continue
				}
				// The installed app itself already runs what the source offers (e.g. a tweaked app
				// listed as "1.1.9 (21.47.6)" while iOS reports 21.47.6) → no notice.
				if localApp.identifier != Bundle.main.bundleIdentifier,
				   Self._deviceRunsRemote(remote: remoteVersion, bundleID: deviceBundleID) {
					continue
				}
				
				// Stable-first is already enforced by `currentAppVersion`: it is a pre-release only
				// when the app has no stable version at all. Such apps (e.g. Sawt Lite, all builds
				// published as GitHub pre-releases) still get «تحديث» to their newest build; an app
				// with any stable version never gets a notice for a pre-release.
				
				guard let downloadURL = remoteApp.currentDownloadUrl else {
					continue
				}
				
				guard let provenance = SourceAppProvenance(
					sourceURL: sourceURL,
					repository: repository,
					app: remoteApp
				) else {
					continue
				}
				
				foundUpdates[localUUID] = AppUpdate(
					id: localUUID,
					localUUID: localUUID,
					localBundleID: deviceBundleID,
					localVersion: effectiveVersion ?? localApp.version,
					remoteVersion: remoteVersion,
					appName: remoteApp.currentName,
					bundleIdentifier: sourceAppIdentifier,
					downloadURL: downloadURL,
					sourceURL: sourceURL,
					sourceProvenance: provenance
				)
				break
			}
		}
		
		return foundUpdates
	}
	
	/// Same version → no update notice. When the version numbers match and both sides have a
	/// numeric build number, the build decides: an update only when the source's build is higher
	/// (a same or older build is never offered).
	/// The installed build comes from the stored record ("1.1 (16)") or, when it has none,
	/// from iOS (`installedBuild`, read only when needed). Without a build on either side,
	/// the version match alone decides.
	private func _isSameVersion(
		remote: String,
		stored: String?,
		installedBuild: () -> String?
	) -> Bool {
		guard let stored, !stored.isEmpty else { return false }
		if remote == stored { return true }
		guard _isSameMarketingVersion(remote: remote, stored: stored) else { return false }
		guard let remoteBuild = VersionMatch.build(remote) else { return true }
		guard let localBuild = VersionMatch.build(stored) ?? installedBuild().flatMap({ Int($0) }) else { return true }
		return remoteBuild <= localBuild
	}
	
	/// "com.app.id.A1B2C3" (signed with the 6-character random protection suffix, see
	/// `Options.randomString`) is a copy of "com.app.id". Nothing looser, so another app whose id
	/// merely starts the same way is never matched.
	static func _isSuffixedCopy(local: String, remote: String?) -> Bool {
		guard let remote, !remote.isEmpty, local.hasPrefix(remote + ".") else { return false }
		let suffix = local.dropFirst(remote.count + 1)
		let allowed = Set("0123456789ABCDEF-")
		return suffix.count == 6 && suffix.allSatisfy { allowed.contains($0) }
	}
	
	/// True when the version iOS reports for the installed app (CFBundleShortVersionString or
	/// CFBundleVersion) is exactly the source's version or build. Unknown → false.
	private static func _deviceRunsRemote(remote: String, bundleID: String) -> Bool {
		guard let reported = QuickInstallManager.installedVersion(bundleID).version else { return false }
		let parts = reported.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		let installedBuild = parts.first ?? ""
		let installedShort = parts.count > 1 ? parts[1] : ""
		let remoteBase = SourceAppProvenance.baseVersion(remote)
		var remoteBuild: String?
		if let open = remote.range(of: " (") {
			var rest = remote[open.upperBound...]
			if rest.hasSuffix(")") { rest = rest.dropLast() }
			remoteBuild = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		guard !installedShort.isEmpty else { return false }
		if let remoteBuild, !remoteBuild.isEmpty {
			// Both the version and the build must match what is installed.
			if VersionMatch.sameRelease(remoteBase, installedShort) {
				// Same version: the build decides.
				return !installedBuild.isEmpty && remoteBuild == installedBuild
			}
			// Tweaked apps list the app's own version as the build ("1.1.9 (21.47.6)").
			return VersionMatch.isPlain(remoteBuild) && remoteBuild == installedShort
		}
		return VersionMatch.sameRelease(remoteBase, installedShort)
	}
	
	/// Marketing versions only (build numbers ignored).
	private func _isSameMarketingVersion(remote: String, stored: String) -> Bool {
		let remoteBase = SourceAppProvenance.baseVersion(remote)
		let storedBase = SourceAppProvenance.baseVersion(stored)
		if remoteBase == storedBase { return true }
		// Plain number (e.g. "2.3.4", "1.1") against source text such as "v2.3.4",
		// "andarium-1.1" or "1.0b15-release": same release → no false update notice.
		// Stays strict when both sides carry suffixes ("1.0b15" vs "1.0b16" is an update).
		if VersionMatch.isPlain(storedBase) || VersionMatch.isPlain(remoteBase) {
			return VersionMatch.sameRelease(remoteBase, storedBase)
		}
		return false
	}
	
	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}
	
	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}
		
		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}
