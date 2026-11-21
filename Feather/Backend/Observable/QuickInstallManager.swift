//
//  QuickInstallManager.swift
//  Muthabbit
//
//  One-tap flow: download → sign with the default options → install.
//  Runs in the background. Optional screens are controlled from Settings:
//  - "Muthabbit.showInstallOptions": show the signing options before a new install.
//  - "Muthabbit.showProcessLog": show the installation progress screen.
//

import Foundation
import SwiftUI
import Combine
import CoreData
import SafariServices
import IDeviceSwift

enum QuickInstallState: Equatable {
	case downloading
	case signing
	case installing
	case failed(String)
}

@MainActor
final class QuickInstallManager: ObservableObject {
	static let shared = QuickInstallManager()
	
	static let showInstallOptionsKey = "Muthabbit.showInstallOptions"
	static let showProcessLogKey = "Muthabbit.showProcessLog"
	static let deleteOldKey = "Muthabbit.deleteOldAfterUpdate"
	static let deleteFilesKey = "Muthabbit.deleteFilesAfterInstall"
	static let importFinishedNotification = Notification.Name("Muthabbit.importFinished")
	
	/// Keyed by the app bundle identifier (or the download id when unknown).
	@Published private(set) var states: [String: QuickInstallState] = [:]
	
	/// download id → (state key, is update)
	private var _pending: [String: (key: String, isUpdate: Bool)] = [:]
	
	// Background install session (kept alive while installing).
	private var _installer: ServerInstaller?
	private var _viewModel: InstallerStatusViewModel?
	private var _statusCancellable: AnyCancellable?
	private var _progressTask: Task<Void, Never>?
	private weak var _safari: UIViewController?
	private var _installingKey: String?
	private var _bundleIDs: [String: String] = [:]
	private var _watchdog: Task<Void, Never>?
	private var _fallbackTried: Set<String> = []
	private var _queue: [(app: AppInfoPresentable, key: String)] = []
	
	private var _observers: [NSObjectProtocol] = []
	
	private init() {
		_observers.append(
			NotificationCenter.default.addObserver(
				forName: Self.importFinishedNotification,
				object: nil,
				queue: .main
			) { [weak self] note in
				let id = note.userInfo?["id"] as? String ?? ""
				let error = note.userInfo?["error"] as? String
				Task { @MainActor in
					self?._importFinished(downloadID: id, error: error)
				}
			}
		)
		// Posted by the signing screen after a manual sign (options sheet).
		_observers.append(
			NotificationCenter.default.addObserver(
				forName: Notification.Name("Feather.installApp"),
				object: nil,
				queue: .main
			) { [weak self] _ in
				Task { @MainActor in
					guard let self, let signed = self._newestSigned() else { return }
					self._install(signed, key: signed.identifier ?? "manual")
				}
			}
		)
	}
	
	/// Must be called once at launch so the observers are registered.
	func activate() {}
	
	func state(for key: String?) -> QuickInstallState? {
		guard let key else { return nil }
		return states[key]
	}
	
	// MARK: Public entry points
	
	/// Get / Install from a source.
	func installFromSource(
		url: URL,
		downloadID: String,
		key: String,
		provenance: SourceAppProvenance?,
		isUpdate: Bool = false
	) {
		if let current = states[key], !current.isFailed { return }
		_pending[downloadID] = (key, isUpdate)
		states[key] = .downloading
		_ = DownloadManager.shared.startDownload(
			from: url,
			id: downloadID,
			sourceProvenance: provenance
		)
	}
	
	/// Update button in "تطبيقاتي".
	func installUpdate(_ update: AppUpdate) {
		installFromSource(
			url: update.downloadURL,
			downloadID: "FeatherManualDownload_Update_\(update.localUUID)",
			key: update.bundleIdentifier,
			provenance: update.sourceProvenance,
			isUpdate: true
		)
	}
	
	/// Install button for an app already in the library.
	func installExisting(_ app: AppInfoPresentable) {
		let key = app.identifier ?? app.uuid ?? UUID().uuidString
		if Storage.shared.getAppDirectory(for: app) == nil {
			UIAlertController.showAlertWithOk(
				title: .localized("Error"),
				message: "حُذفت ملفات هذا التطبيق بعد تثبيته. يمكن تثبيته مجددًا من «المتجر»."
			)
			return
		}
		if app.isSigned {
			_install(app, key: key)
		} else {
			_sign(app, key: key, isUpdate: false)
		}
	}
	
	func clearFailure(for key: String) {
		if case .failed = states[key] { states[key] = nil }
	}
	
	// MARK: Steps
	
	private func _importFinished(downloadID: String, error: String?) {
		guard let pending = _pending.removeValue(forKey: downloadID) else { return }
		
		if let error {
			_fail(pending.key, error)
			return
		}
		
		guard let imported = _newestImported() else {
			_fail(pending.key, "تعذّر العثور على الملف بعد التنزيل.")
			return
		}
		
		let showOptions = UserDefaults.standard.bool(forKey: Self.showInstallOptionsKey)
		if showOptions && !pending.isUpdate {
			states[pending.key] = nil
			_presentSigningOptions(for: imported)
			return
		}
		
		_sign(imported, key: pending.key, isUpdate: pending.isUpdate)
	}
	
	private func _sign(_ app: AppInfoPresentable, key: String, isUpdate: Bool) {
		guard let certificate = _selectedCertificate() else {
			states[key] = nil
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: "يلزم استيراد شهادة من الإعدادات قبل التثبيت."
			)
			return
		}
		
		states[key] = .signing
		var options = OptionsManager.shared.options
		options.post_installAppAfterSigned = false
		
		FR.signPackageFile(
			app,
			using: options,
			icon: nil,
			certificate: certificate
		) { [weak self] error in
			guard let self else { return }
			if let error {
				self._fail(key, error.localizedDescription)
				return
			}
			
			if options.post_deleteAppAfterSigned, !app.isSigned {
				Storage.shared.deleteApp(for: app)
			}
			
			guard let signed = self._newestSigned() else {
				self._fail(key, "تعذّر العثور على التطبيق بعد التوقيع.")
				return
			}
			self._install(signed, key: key)
		}
	}
	
	private func _install(_ app: AppInfoPresentable, key: String, methodOverride: Int? = nil) {
		if app.identifier == Bundle.main.bundleIdentifier {
			states[key] = nil
			UIAlertController.showAlertWithOk(
				title: .localized("Install"),
				message: "لا يمكن تحديث التطبيق من داخله. يمكن تثبيت التحديث الموقّع باستخدام أداة أخرى."
			)
			return
		}
		
		// Process log enabled → show the regular progress screen.
		if UserDefaults.standard.bool(forKey: Self.showProcessLogKey) {
			states[key] = nil
			_presentProgressScreen(for: app)
			return
		}
		
		// Only one background install at a time; the rest wait in a queue.
		if _installingKey != nil {
			states[key] = .installing
			_queue.append((app, key))
			return
		}
		states[key] = .installing
		_installingKey = key
		if let id = app.identifier { _bundleIDs[key] = id }
		
		let isIdevice = UserDefaults.standard.integer(forKey: "Feather.installationMethod") == 1
		let viewModel = InstallerStatusViewModel(isIdevice: isIdevice)
		_viewModel = viewModel
		
		if !isIdevice {
			do {
				_installer = try ServerInstaller(app: app, viewModel: viewModel)
			} catch {
				_fail(key, error.localizedDescription)
				return
			}
			
			let serverMethod = methodOverride ?? UserDefaults.standard.integer(forKey: "Feather.serverMethod")
			ServerInstaller.methodOverride = serverMethod
			let bundleID = app.identifier ?? ""
			
			_statusCancellable = viewModel.$status
				.receive(on: DispatchQueue.main)
				.sink { [weak self] status in
					guard let self else { return }
					switch status {
					case .ready:
						guard let installer = self._installer else { return }
						// No web page: open the itms-services link directly.
						let link = serverMethod == 0 ? installer.iTunesLink : installer.iTunesLinkExternal
						guard let url = URL(string: link) else {
							self._fallback(app, key: key, from: serverMethod)
							return
						}
						UIApplication.shared.open(url) { opened in
							if !opened {
								self._fallback(app, key: key, from: serverMethod)
							}
						}
						// If iOS never fetches the app, switch to the other method automatically.
						self._watchdog?.cancel()
						self._watchdog = Task { @MainActor [weak self] in
							try? await Task.sleep(nanoseconds: 45_000_000_000)
							guard let self, !Task.isCancelled, self._installingKey == key else { return }
							if case .ready = viewModel.status {
								self._fallback(app, key: key, from: serverMethod)
							}
						}
					case .sendingPayload, .sendingManifest:
						self._watchdog?.cancel()
					case .installing:
						if self._progressTask == nil, !bundleID.isEmpty {
							self._progressTask = self._pollInstall(bundleID: bundleID, viewModel: viewModel)
						}
					case .completed:
						self._finish(key)
					case .broken(let error):
						self._fail(key, error.localizedDescription)
					default:
						break
					}
				}
		}
		
		Task.detached {
			do {
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				let packageUrl = try await handler.archive()
				
				if isIdevice {
					let proxy = await InstallationProxy(viewModel: viewModel)
					try await proxy.install(at: packageUrl, suspend: false)
					await MainActor.run {
						QuickInstallManager.shared._finish(key)
					}
				} else {
					await MainActor.run {
						QuickInstallManager.shared._installer?.packageUrl = packageUrl
						viewModel.status = .ready
					}
				}
			} catch {
				await MainActor.run {
					QuickInstallManager.shared._fail(key, String(describing: error))
				}
			}
		}
		
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.start()
		#endif
	}
	
	/// Tries the other server method once (Semi Local ⇄ Local) before reporting failure.
	private func _fallback(_ app: AppInfoPresentable, key: String, from method: Int) {
		guard !_fallbackTried.contains(key) else {
			_fail(key, "تعذّر بدء التثبيت بالطريقتين. يمكن تغيير طريقة التثبيت من الإعدادات.")
			return
		}
		_fallbackTried.insert(key)
		_teardownInstall(startNext: false)
		_install(app, key: key, methodOverride: method == 0 ? 1 : 0)
	}
	
	// MARK: Completion
	
	private func _finish(_ key: String) {
		states[key] = nil
		_fallbackTried.remove(key)
		if _installingKey == key {
			_teardownInstall()
		}
		// Keep only what is needed: newest signed copy; remove old copies and temp work folders.
		if UserDefaults.standard.object(forKey: Self.deleteOldKey) as? Bool ?? true {
			StorageCleaner.pruneOldCopies(bundleID: _bundleIDs[key] ?? key)
		}
		if UserDefaults.standard.bool(forKey: Self.deleteFilesKey) {
			StorageCleaner.deleteInstalledFiles(bundleID: _bundleIDs[key] ?? key)
		}
		if _installingKey == nil {
			Task.detached(priority: .background) { StorageCleaner.cleanTemporaryFiles() }
		}
		Task { await AutoUpdateChecker.checkNow(force: true) }
	}
	
	private func _fail(_ key: String, _ message: String) {
		states[key] = .failed(message)
		_fallbackTried.remove(key)
		if _installingKey == key {
			_teardownInstall()
		}
		UIAlertController.showAlertWithOk(
			title: .localized("Error"),
			message: message
		)
	}
	
	private func _teardownInstall(startNext: Bool = true) {
		_watchdog?.cancel()
		_watchdog = nil
		ServerInstaller.methodOverride = nil
		_progressTask?.cancel()
		_progressTask = nil
		_statusCancellable?.cancel()
		_statusCancellable = nil
		_dismissSafari()
		_installer = nil
		_viewModel = nil
		_installingKey = nil
		#if !targetEnvironment(macCatalyst)
		BackgroundAudioManager.shared.stop()
		#endif
		
		if startNext, !_queue.isEmpty {
			let next = _queue.removeFirst()
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
				self._install(next.app, key: next.key)
			}
		}
	}
	
	private func _pollInstall(bundleID: String, viewModel: InstallerStatusViewModel) -> Task<Void, Never> {
		Task.detached(priority: .background) {
			var hasStarted = false
			while !Task.isCancelled {
				let raw = await UIApplication.installProgress(for: bundleID) ?? 0.0
				if raw > 0 { hasStarted = true }
				if hasStarted && raw == 0 {
					await MainActor.run {
						viewModel.status = .completed(.success(()))
					}
					break
				}
				try? await Task.sleep(nanoseconds: 200_000_000)
			}
		}
	}
	
	// MARK: Presentation
	
	private func _presentSafari(_ url: URL) {
		guard let top = UIApplication.topViewController() else { return }
		let safari = SFSafariViewController(url: url)
		safari.modalPresentationStyle = .pageSheet
		if let sheet = safari.sheetPresentationController {
			sheet.detents = [.medium()]
		}
		top.present(safari, animated: true)
		_safari = safari
	}
	
	private func _dismissSafari() {
		_safari?.dismiss(animated: true)
		_safari = nil
	}
	
	private func _presentSigningOptions(for app: AppInfoPresentable) {
		guard let top = UIApplication.topViewController() else { return }
		let view = SigningView(app: app)
			.environment(\.managedObjectContext, Storage.shared.context)
		let host = UIHostingController(rootView: view)
		host.modalPresentationStyle = .fullScreen
		top.present(host, animated: true)
	}
	
	private func _presentProgressScreen(for app: AppInfoPresentable) {
		guard let top = UIApplication.topViewController() else { return }
		let view = InstallPreviewView(app: app)
			.environment(\.managedObjectContext, Storage.shared.context)
		let host = UIHostingController(rootView: view)
		host.modalPresentationStyle = .pageSheet
		if let sheet = host.sheetPresentationController {
			sheet.detents = [.medium()]
			sheet.prefersGrabberVisible = true
		}
		top.present(host, animated: true)
	}
	
	// MARK: Storage helpers
	
	private func _selectedCertificate() -> CertificatePair? {
		let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
		let certificates = (try? Storage.shared.context.fetch(request)) ?? []
		let index = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		guard certificates.indices.contains(index) else { return certificates.first }
		return certificates[index]
	}
	
	private func _newestImported() -> Imported? {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		request.fetchLimit = 1
		return try? Storage.shared.context.fetch(request).first
	}
	
	private func _newestSigned() -> Signed? {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		request.fetchLimit = 1
		return try? Storage.shared.context.fetch(request).first
	}
}

extension QuickInstallState {
	var isFailed: Bool {
		if case .failed = self { return true }
		return false
	}
}

// MARK: - Storage cleanup
enum StorageCleaner {
	private static var _fm: FileManager { .default }
	
	/// Removes temporary work folders (unzipped payloads, archived IPAs, downloads).
	static func cleanTemporaryFiles() {
		let tmp = _fm.temporaryDirectory
		guard let items = try? _fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
		for item in items {
			try? _fm.removeItem(at: item)
		}
	}
	
	/// After a successful install keeps only the newest signed copy of that app and
	/// deletes older signed copies and any unsigned imports of the same bundle id.
	@MainActor
	static func pruneOldCopies(bundleID: String) {
		guard !bundleID.isEmpty else { return }
		let ctx = Storage.shared.context
		
		let signedReq: NSFetchRequest<Signed> = Signed.fetchRequest()
		signedReq.predicate = NSPredicate(format: "identifier == %@", bundleID)
		signedReq.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		let signed = (try? ctx.fetch(signedReq)) ?? []
		for old in signed.dropFirst() {
			Storage.shared.deleteApp(for: old)
		}
		
		let importedReq: NSFetchRequest<Imported> = Imported.fetchRequest()
		importedReq.predicate = NSPredicate(format: "identifier == %@", bundleID)
		for item in (try? ctx.fetch(importedReq)) ?? [] {
			Storage.shared.deleteApp(for: item)
		}
	}
	
	/// Deletes the app files of every stored copy of this bundle id (keeps nothing on disk).
	/// The library entry and its source info stay, so the app still appears in "تطبيقاتي"
	/// and update checks keep working; installing it again re-downloads it.
	@MainActor
	static func deleteInstalledFiles(bundleID: String) {
		guard !bundleID.isEmpty else { return }
		let req: NSFetchRequest<Signed> = Signed.fetchRequest()
		req.predicate = NSPredicate(format: "identifier == %@", bundleID)
		for item in (try? Storage.shared.context.fetch(req)) ?? [] {
			if let dir = Storage.shared.getUuidDirectory(for: item) {
				try? _fm.removeItem(at: dir)
			}
		}
	}
	
	static func usedBytes() -> Int64 {
		var urls = [_fm.temporaryDirectory]
		urls += _fm.urls(for: .documentDirectory, in: .userDomainMask)
		urls += _fm.urls(for: .cachesDirectory, in: .userDomainMask)
		return urls.reduce(0) { $0 + _size(of: $1) }
	}
	
	static func cacheBytes() -> Int64 {
		var urls = [_fm.temporaryDirectory]
		urls += _fm.urls(for: .cachesDirectory, in: .userDomainMask)
		return urls.reduce(0) { $0 + _size(of: $1) }
	}
	
	/// Clears temporary files and caches (icons, downloads). Apps and certificates are kept.
	static func clearCache() {
		cleanTemporaryFiles()
		for dir in _fm.urls(for: .cachesDirectory, in: .userDomainMask) {
			guard let items = try? _fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
			for item in items { try? _fm.removeItem(at: item) }
		}
		URLCache.shared.removeAllCachedResponses()
	}
	
	private static func _size(of url: URL) -> Int64 {
		guard let enumerator = _fm.enumerator(
			at: url,
			includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
		) else { return 0 }
		var total: Int64 = 0
		for case let file as URL in enumerator {
			let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
			if values?.isRegularFile == true {
				total += Int64(values?.totalFileAllocatedSize ?? 0)
			}
		}
		return total
	}
}

// MARK: - Library delete (asks what to remove)
@MainActor
enum LibraryDeleteHelper {
	/// Shows the delete options for one or more library entries.
	static func confirmDelete(_ apps: [AppInfoPresentable], completion: (() -> Void)? = nil) {
		guard !apps.isEmpty else { return }
		let filesOnly = UIAlertAction(title: "حذف الملفات فقط", style: .default) { _ in
			apps.forEach { _deleteFiles(of: $0) }
			completion?()
		}
		let all = UIAlertAction(title: "حذف الملفات والسجل", style: .destructive) { _ in
			apps.forEach { _deleteAllCopies(of: $0) }
			completion?()
		}
		let recordOnly = UIAlertAction(title: "إزالة من السجل", style: .default) { _ in
			_confirmRecordRemoval(apps, completion: completion)
		}
		let cancel = UIAlertAction(title: "إلغاء", style: .cancel)
		
		UIAlertController.showAlert(
			title: "حذف التطبيق",
			message: "«حذف الملفات فقط» يُبقي السجل لتستمر متابعة التحديثات. «حذف الملفات والسجل» يزيل التطبيق من «تطبيقاتي» ومن التحديثات.",
			style: .actionSheet,
			actions: [filesOnly, all, recordOnly, cancel]
		)
	}
	
	private static func _confirmRecordRemoval(_ apps: [AppInfoPresentable], completion: (() -> Void)?) {
		let deleteFiles = UIAlertAction(title: "حذف كل الملفات والنسخ المحمّلة لهذا التطبيق", style: .destructive) { _ in
			apps.forEach { _deleteAllCopies(of: $0) }
			completion?()
		}
		let keep = UIAlertAction(title: "إبقاء الملفات", style: .default) { _ in
			apps.forEach { _removeRecordOnly($0) }
			completion?()
		}
		let cancel = UIAlertAction(title: "إلغاء", style: .cancel)
		UIAlertController.showAlert(
			title: "إزالة من السجل",
			message: "ستتوقف متابعة تحديثات هذا التطبيق.",
			style: .actionSheet,
			actions: [deleteFiles, keep, cancel]
		)
	}
	
	private static func _deleteFiles(of app: AppInfoPresentable) {
		if let dir = Storage.shared.getUuidDirectory(for: app) {
			try? FileManager.default.removeItem(at: dir)
		}
	}
	
	/// Removes the record plus every stored copy (signed and imported) of the same bundle id.
	private static func _deleteAllCopies(of app: AppInfoPresentable) {
		let bundleID = app.identifier
		Storage.shared.deleteApp(for: app)
		guard let bundleID, !bundleID.isEmpty else { return }
		let ctx = Storage.shared.context
		let s: NSFetchRequest<Signed> = Signed.fetchRequest()
		s.predicate = NSPredicate(format: "identifier == %@", bundleID)
		let i: NSFetchRequest<Imported> = Imported.fetchRequest()
		i.predicate = NSPredicate(format: "identifier == %@", bundleID)
		((try? ctx.fetch(s)) ?? []).forEach { Storage.shared.deleteApp(for: $0) }
		((try? ctx.fetch(i)) ?? []).forEach { Storage.shared.deleteApp(for: $0) }
	}
	
	/// Removes the library record and its source info but leaves the files on disk.
	private static func _removeRecordOnly(_ app: AppInfoPresentable) {
		Storage.shared.deleteSourceMetadata(for: app.uuid)
		if let object = app as? NSManagedObject {
			Storage.shared.context.delete(object)
			try? Storage.shared.context.save()
		}
	}
}
