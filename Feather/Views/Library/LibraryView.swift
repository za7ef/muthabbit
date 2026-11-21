//
//  LibraryView.swift
//  Muthabbit
//
//  «تطبيقاتي»: App Store / SideStore-style list of confirmed installs.
//  Top: updates banner + apps with updates (yellow «تحديث» pill that fills with progress,
//  turns green «مثبّت», then the card moves down). Below: installed apps with «فتح».
//  Signed-only copies live in «الموقّعة».
//

import SwiftUI
import CoreData
import NimbleViews
import NukeUI
import UniformTypeIdentifiers
import AltSourceKit

struct LibraryView: View {
	@ObservedObject private var _updateManager = UpdateManager.shared
	@ObservedObject private var _quickInstall = QuickInstallManager.shared
	@State private var _searchText = ""
	@State private var _isImporting = false
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	/// Confirmed installs, one per bundle id (newest copy).
	private var _installed: [Signed] {
		var seen = Set<String>()
		return _signedApps.filter { app in
			guard
				let id = app.identifier,
				_quickInstall.installedIDs.contains(id),
				!seen.contains(id)
			else { return false }
			seen.insert(id)
			if _searchText.isEmpty { return true }
			return (app.name ?? "").localizedCaseInsensitiveContains(_searchText)
		}
	}
	
	private func _key(_ app: Signed) -> String {
		_updateManager.update(for: app)?.bundleIdentifier ?? app.identifier ?? app.uuid ?? ""
	}
	
	/// Stays in the top section while updating or just finished, so it can turn green before moving.
	private func _isInUpdatesSection(_ app: Signed) -> Bool {
		let key = _key(app)
		return _updateManager.update(for: app) != nil
			|| _quickInstall.justFinished.contains(key)
			|| (_quickInstall.state(for: key).map { !$0.isFailed } ?? false)
	}
	
	private var _withUpdates: [Signed] { _installed.filter { _isInUpdatesSection($0) } }
	private var _upToDate: [Signed] { _installed.filter { !_isInUpdatesSection($0) } }
	
	var body: some View {
		NBNavigationView("تطبيقاتي") {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					_banner
					
					if !_withUpdates.isEmpty {
						_header("التحديثات المتوفرة")
						ForEach(_withUpdates, id: \.objectID) { app in
							_card(app)
								.transition(.move(edge: .bottom).combined(with: .opacity))
						}
					}
					
					if !_upToDate.isEmpty {
						_header("التطبيقات المثبّتة")
						ForEach(_upToDate, id: \.objectID) { app in
							_card(app)
								.transition(.move(edge: .top).combined(with: .opacity))
						}
					}
				}
				.padding(.horizontal, 20)
				.padding(.bottom, 24)
				.animation(.snappy, value: _withUpdates.map(\.objectID))
			}
			.searchable(text: $_searchText, placement: .platform())
			.overlay {
				if _installed.isEmpty, _searchText.isEmpty, #available(iOS 17, *) {
					ContentUnavailableView(
						"لا توجد تطبيقات مثبّتة",
						systemImage: "square.grid.2x2",
						description: Text("تظهر هنا التطبيقات المثبّتة من «المتجر» أو «مشاريعي».")
					)
				}
			}
			.refreshable { await AutoUpdateChecker.checkNow(force: true) }
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					NavigationLink {
						SignedAppsView()
					} label: {
						Image(systemName: "signature")
					}
					.accessibilityLabel("الموقّعة")
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_isImporting = true
					} label: {
						Image(systemName: "plus")
					}
					.accessibilityLabel("تثبيت ملف IPA")
				}
			}
		}
		.task { await AutoUpdateChecker.checkNow() }
		.sheet(isPresented: $_isImporting) {
			FileImporterRepresentableView(
				allowedContentTypes: [.ipa, .tipa],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					urls.forEach { _quickInstall.installLocalFile($0) }
				}
			)
			.ignoresSafeArea()
		}
	}
	
	// MARK: Banner
	
	@ViewBuilder
	private var _banner: some View {
		let count = _updateManager.updates.count
		Button {
			for update in _updateManager.updates.values {
				_quickInstall.installUpdate(update)
			}
		} label: {
			HStack {
				Spacer()
				if _updateManager.isChecking {
					ProgressView().tint(.white)
				}
				Text(count == 0 ? "لا توجد تحديثات" : "\(count.formatted()) \(count == 1 ? "تحديث متوفر" : "تحديثات متوفرة") · تحديث الكل")
					.font(.headline)
					.foregroundStyle(count == 0 ? Color.secondary : Color.white)
				Spacer()
			}
			.padding(.vertical, 14)
			.background(
				Capsule().fill(count == 0 ? Color(.secondarySystemFill) : Color.accentColor)
			)
		}
		.buttonStyle(.plain)
		.disabled(count == 0)
		.padding(.top, 4)
	}
	
	private func _header(_ title: String) -> some View {
		Text(title)
			.font(.title3.bold())
			.padding(.top, 8)
	}
	
	// MARK: Card
	
	@ViewBuilder
	private func _card(_ app: Signed) -> some View {
		HStack(spacing: 14) {
			let info = HStack(spacing: 14) {
				StoreIconOverride(bundleID: app.identifier) {
					FRAppIconView(app: app, size: 57)
				}
				VStack(alignment: .leading, spacing: 3) {
					Text(app.name ?? .localized("Unknown"))
						.font(.headline)
						.foregroundStyle(.primary)
						.lineLimit(1)
					Text(_subtitle(app))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer(minLength: 8)
			}
			.contentShape(Rectangle())
			if let entry = _storeEntry(app.identifier) {
				NavigationLink {
					SourceAppsDetailView(sourceURL: entry.0, source: entry.1, app: entry.2)
				} label: { info }
				.buttonStyle(.plain)
			} else {
				info
			}
			_pill(app)
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.fill(Color(.secondarySystemBackground))
		)
		.contextMenu {
			if let id = app.identifier {
				Button("فتح", systemImage: "arrow.up.forward.app") {
					UIApplication.openApp(with: id)
				}
			}
			Button("حذف", systemImage: "trash", role: .destructive) {
				LibraryDeleteHelper.confirmDelete([app])
			}
		}
	}
	
	/// The app's listing in a source (or «مشاريعي»), for opening its store page.
	private func _storeEntry(_ bundleID: String?) -> (URL, ASRepository, ASRepository.App)? {
		guard let bundleID else { return nil }
		for (url, repo) in SourcesViewModel.shared.sources {
			if let app = repo.apps.first(where: { $0.id == bundleID }) { return (url.sourceURL ?? GitHubAccount.projectsSourceURL, repo, app) }
		}
		if let repo = GitHubAccount.shared.projects, let app = repo.apps.first(where: { $0.id == bundleID }) {
			return (GitHubAccount.projectsSourceURL, repo, app)
		}
		return nil
	}
	
	private func _subtitle(_ app: Signed) -> String {
		if let update = _updateManager.update(for: app) {
			// Isolated LTR run so "old → new" reads correctly inside RTL text.
			return "\u{2066}\(update.localVersion ?? app.version ?? "—") → \(update.remoteVersion)\u{2069}"
		}
		return app.version ?? (app.identifier ?? "")
	}
	
	@ViewBuilder
	private func _pill(_ app: Signed) -> some View {
		let key = _key(app)
		if _quickInstall.justFinished.contains(key) {
			ProgressPill(title: "مثبّت", color: .green, progress: 1, filled: true)
		} else if let state = _quickInstall.state(for: key), !state.isFailed {
			TimelineView(.periodic(from: .now, by: 0.3)) { _ in
				ProgressPill(
					title: _stateTitle(state),
					color: .yellow,
					progress: _progress(for: key, state: state),
					filled: false
				)
			}
			.onTapGesture { _quickInstall.cancel(key) }
		} else if let update = _updateManager.update(for: app) {
			Button {
				_quickInstall.installUpdate(update)
			} label: {
				ProgressPill(title: "تحديث", color: .yellow, progress: 1, filled: true)
			}
			.buttonStyle(.plain)
		} else {
			Button {
				if let id = app.identifier { UIApplication.openApp(with: id) }
			} label: {
				ProgressPill(title: "فتح", color: .accentColor, progress: 0, filled: false)
			}
			.buttonStyle(.plain)
		}
	}
	
	private func _stateTitle(_ state: QuickInstallState) -> String {
		switch state {
		case .downloading: return "تنزيل"
		case .signing: return "توقيع"
		case .installing: return "تثبيت"
		case .failed: return "خطأ"
		}
	}
	
	private func _progress(for key: String, state: QuickInstallState) -> Double {
		switch state {
		case .downloading:
			if let id = _quickInstall.downloadIDs[key], let dl = DownloadManager.shared.getDownload(by: id) {
				return 0.6 * dl.overallProgress
			}
			return 0.05
		case .signing: return 0.75
		case .installing: return 0.9
		case .failed: return 0
		}
	}
}

/// Capsule button whose background fills from the leading edge with progress.
struct ProgressPill: View {
	let title: String
	let color: Color
	let progress: Double
	let filled: Bool
	
	var body: some View {
		Text(title)
			.font(.subheadline.bold())
			.foregroundStyle(filled ? (color == .yellow ? Color.black : Color.white) : (progress > 0 ? Color.primary : color))
			.frame(minWidth: 78)
			.padding(.vertical, 7)
			.padding(.horizontal, 12)
			.background(
				GeometryReader { geo in
					ZStack(alignment: .leading) {
						Capsule().fill(color.opacity(0.2))
						Capsule()
							.fill(color)
							.frame(width: geo.size.width * (filled ? 1 : max(0, min(1, progress))))
							.opacity(filled || progress > 0 ? 1 : 0)
					}
				}
			)
			.clipShape(Capsule())
			.animation(.smooth, value: progress)
			.animation(.snappy, value: filled)
	}
}
