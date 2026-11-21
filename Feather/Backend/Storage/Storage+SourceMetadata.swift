//
//  Storage+SourceMetadata.swift
//  Feather
//
//  Created by Dominic on 26.05.2026.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import AltSourceKit
import CoreData
import Foundation

struct SourceAppProvenance: Equatable {
	let sourceRepositoryURL: URL
	let sourceRepositoryIdentifier: String?
	let sourceRepositoryName: String?
	let sourceAppIdentifier: String
	let sourceAppName: String?
	let sourceAppVersion: String?
	let sourceAppVersionDate: Date?
	let sourceAppDownloadURL: URL?
	
	var sourceVersionID: String {
		[
			sourceRepositoryIdentifier ?? sourceRepositoryURL.absoluteString,
			sourceAppIdentifier,
			sourceAppVersion ?? "",
			sourceAppDownloadURL?.absoluteString ?? ""
		].joined(separator: "|")
	}
}

extension SourceAppProvenance {
	/// Combines the marketing version with the build number (when the source provides one),
	/// so that two builds sharing the same marketing version are still told apart.
	static func versionString(
		_ version: ASRepository.App.Version?,
		fallback: String?
	) -> String? {
		guard let version else { return fallback }
		if
			let build = version.build?.trimmingCharacters(in: .whitespacesAndNewlines),
			!build.isEmpty,
			build != version.version
		{
			return "\(version.version) (\(build))"
		}
		return version.version
	}
	
	/// Returns the marketing version part of a string produced by `versionString`.
	static func baseVersion(_ value: String) -> String {
		if let range = value.range(of: " (") {
			return String(value[..<range.lowerBound])
		}
		return value
	}
}

enum SourceLinkedAppKind: String {
	case imported
	case signed
}

extension SourceAppProvenance {
	init?(
		sourceURL: URL?,
		repository: ASRepository,
		app: ASRepository.App,
		version: ASRepository.App.Version? = nil
	) {
		guard
			let sourceURL,
			let appIdentifier = app.id
		else {
			return nil
		}
		
		self.sourceRepositoryURL = sourceURL
		self.sourceRepositoryIdentifier = repository.id
		self.sourceRepositoryName = repository.name
		self.sourceAppIdentifier = appIdentifier
		self.sourceAppName = app.currentName
		let appVersion = SourceAppProvenance.versionString(
			version ?? app.currentAppVersion,
			fallback: app.currentVersion
		)
		let appVersionDate = version?.date?.date ?? app.currentDate?.date
		let appDownloadURL = version?.downloadURL ?? app.currentDownloadUrl
		self.sourceAppVersion = appVersion
		self.sourceAppVersionDate = appVersionDate
		self.sourceAppDownloadURL = appDownloadURL
	}
}

extension Storage {
	func sourceMetadata(for appUUID: String) -> AppSourceMetadata? {
		let request: NSFetchRequest<AppSourceMetadata> = AppSourceMetadata.fetchRequest()
		request.fetchLimit = 1
		request.predicate = NSPredicate(format: "appUUID == %@", appUUID)
		request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
		
		do {
			return try context.fetch(request).first
		} catch {
			return nil
		}
	}
	
	func sourceMetadata(for app: AppInfoPresentable) -> AppSourceMetadata? {
		guard let uuid = app.uuid else { return nil }
		return sourceMetadata(for: uuid)
	}
	
	func getSourceMetadata() -> [AppSourceMetadata] {
		let request: NSFetchRequest<AppSourceMetadata> = AppSourceMetadata.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: true)]
		do {
			return try context.fetch(request)
		} catch {
			return []
		}
	}
	
	func addSourceMetadata(
		for appUUID: String,
		kind: SourceLinkedAppKind,
		provenance: SourceAppProvenance
	) {
		let metadata = sourceMetadata(for: appUUID) ?? AppSourceMetadata(context: context)
		let now = Date()
		
		if metadata.createdAt == nil {
			metadata.createdAt = now
		}
		
		metadata.appUUID = appUUID
		metadata.appKind = kind.rawValue
		metadata.sourceRepositoryURL = provenance.sourceRepositoryURL
		metadata.sourceRepositoryIdentifier = provenance.sourceRepositoryIdentifier
		metadata.sourceRepositoryName = provenance.sourceRepositoryName
		metadata.sourceAppIdentifier = provenance.sourceAppIdentifier
		metadata.sourceAppName = provenance.sourceAppName
		metadata.sourceAppVersion = provenance.sourceAppVersion
		metadata.sourceAppVersionDate = provenance.sourceAppVersionDate
		metadata.sourceAppDownloadURL = provenance.sourceAppDownloadURL
		metadata.sourceVersionID = provenance.sourceVersionID
		metadata.updatedAt = now
		
		saveContext()
	}
	
	func copySourceMetadata(
		from sourceAppUUID: String?,
		to destinationAppUUID: String,
		kind: SourceLinkedAppKind
	) {
		guard
			let sourceAppUUID
		else {
			return
		}
		
		guard let source = sourceMetadata(for: sourceAppUUID) else {
			return
		}
		
		guard
			let repositoryURL = source.sourceRepositoryURL,
			let appIdentifier = source.sourceAppIdentifier,
			let versionID = source.sourceVersionID
		else {
			return
		}
		
		let metadata = sourceMetadata(for: destinationAppUUID) ?? AppSourceMetadata(context: context)
		let now = Date()
		if metadata.createdAt == nil {
			metadata.createdAt = now
		}
		metadata.appUUID = destinationAppUUID
		metadata.appKind = kind.rawValue
		metadata.sourceRepositoryURL = repositoryURL
		metadata.sourceRepositoryIdentifier = source.sourceRepositoryIdentifier
		metadata.sourceRepositoryName = source.sourceRepositoryName
		metadata.sourceAppIdentifier = appIdentifier
		metadata.sourceAppName = source.sourceAppName
		metadata.sourceAppVersion = source.sourceAppVersion
		metadata.sourceAppVersionDate = source.sourceAppVersionDate
		metadata.sourceAppDownloadURL = source.sourceAppDownloadURL
		metadata.sourceVersionID = versionID
		metadata.updatedAt = now
		
		saveContext()
	}
	
	func deleteSourceMetadata(for appUUID: String?) {
		guard let appUUID else {
			return
		}
		
		let request: NSFetchRequest<AppSourceMetadata> = AppSourceMetadata.fetchRequest()
		request.predicate = NSPredicate(format: "appUUID == %@", appUUID)
		
		do {
			let metadata = try context.fetch(request)
			metadata.forEach(context.delete)
			saveContext()
		} catch {
		}
	}
	
	func deleteSourceMetadata(kind: SourceLinkedAppKind) {
		let request: NSFetchRequest<AppSourceMetadata> = AppSourceMetadata.fetchRequest()
		request.predicate = NSPredicate(format: "appKind == %@", kind.rawValue)
		
		do {
			let deleteRequest = NSBatchDeleteRequest(fetchRequest: request as! NSFetchRequest<NSFetchRequestResult>)
			try context.execute(deleteRequest)
		} catch {
		}
	}
}
