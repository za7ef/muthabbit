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
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	/// Drops a finished update right away (the next check confirms it).
	func clearUpdate(bundleID: String) {
		updates = updates.filter { $0.value.bundleIdentifier != bundleID }
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		defer {
			isChecking = false
			lastCheckedDate = Date()
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
	
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
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
			let storedSourceURL: URL
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
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else if
				let localSourceURL = localApp.source,
				let localIdentifier = localApp.identifier
			{
				sourceAppIdentifier = localIdentifier
				sourceAppVersion = localApp.version
				storedSourceURL = localSourceURL
			} else {
				continue
			}
			
			// For this app itself, the running binary is the truth (not the stored record).
			let effectiveVersion: String? = localApp.identifier == Bundle.main.bundleIdentifier
				? AppInfo.marketingVersion + " (" + AppInfo.buildNumber + ")"
				: sourceAppVersion
			
			for (sourceURL, repository) in repositories {

				
				guard _matchesStoredRepository(storedSourceURL: storedSourceURL, sourceURL: sourceURL) else {
					continue
				}
				
				guard let remoteApp = repository.apps.first(where: { $0.id == sourceAppIdentifier }) else {
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
	/// build number, the build decides: same build → no update, different build → update.
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
		guard let localBuild = VersionMatch.build(stored) ?? installedBuild() else { return true }
		return remoteBuild == localBuild
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
