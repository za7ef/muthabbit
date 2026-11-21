//
//  LibraryView.swift
//  Muthabbit
//
//  «تطبيقاتي»: App Store / SideStore-style list of confirmed installs.
//  Top: updates banner + apps with updates (yellow «تحديث» pill that fills with progress,
//  turns green «مثبّت», then the card moves down). Below: installed apps with «فتح».
//  Signed-only copies live in «الموقّعة».
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
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
	
	/// One history entry: the install record, plus its newest signed copy when one is still stored.
	struct Item: Identifiable {
		let record: InstallRecord
		let signed: Signed?
		var id: String { record.id }
	}
	
	/// Confirmed installs from the install history (not from stored signed copies, which can be
	/// deleted independently). This app itself is not listed.
	private var _installed: [Item] {
		var newest: [String: Signed] = [:]
		for app in _signedApps {
			if let id = app.identifier, newest[id] == nil { newest[id] = app }
		}
		return _quickInstall.records.values
			.filter { $0.id != QuickInstallManager.ownBundleID }
			.map { Item(record: $0, signed: newest[$0.id]) }
			.filter { _searchText.isEmpty || _name($0).localizedCaseInsensitiveContains(_searchText) }
			.sorted { _name($0).localizedCompare(_name($1)) == .orderedAscending }
	}
	
	private func _name(_ item: Item) -> String {
		item.record.name ?? item.signed?.name ?? _storeEntry(item.id)?.2.currentName ?? item.id
	}
	
	private func _update(_ item: Item) -> AppUpdate? {
		item.signed.flatMap { _updateManager.update(for: $0) }
	}
	
	private func _key(_ item: Item) -> String {
		_update(item)?.bundleIdentifier ?? item.id
	}
	
	/// Stays in the top section while updating or just finished, so it can turn green before moving.
	private func _isInUpdatesSection(_ item: Item) -> Bool {
		let key = _key(item)
		return _update(item) != nil
			|| _quickInstall.justFinished.contains(key)
			|| (_quickInstall.state(for: key).map { !$0.isFailed } ?? false)
	}
	
	private var _withUpdates: [Item] { _installed.filter { _isInUpdatesSection($0) } }
	private var _upToDate: [Item] { _installed.filter { !_isInUpdatesSection($0) } }
	
	private func _removeFromHistory(_ item: Item) {
		withAnimation(.snappy) {
			_quickInstall.unmarkInstalled(item.id)
			UpdateManager.shared.clearUpdate(bundleID: item.id)
		}
	}
	
	var body: some View {
		NBNavigationView(L("تطبيقاتي")) {
			// A plain List (styled like cards) so every entry supports swipe to delete.
			List {
				_banner
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 7, trailing: 20))
				
				if !_withUpdates.isEmpty {
					_header(L("التحديثات المتوفرة"))
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
						.listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
					ForEach(_withUpdates) { item in
						_row(item)
					}
				}
				
				if !_upToDate.isEmpty {
					_header(L("التطبيقات المثبّتة"))
						.listRowSeparator(.hidden)
						.listRowBackground(Color.clear)
						.listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
					ForEach(_upToDate) { item in
						_row(item)
					}
				}
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.animation(.snappy, value: _withUpdates.map(\.id))
			.searchable(text: $_searchText, placement: .platform())
			.overlay {
				if _installed.isEmpty, _searchText.isEmpty, #available(iOS 17, *) {
					ContentUnavailableView(
						L("لا توجد تطبيقات مثبّتة"),
						systemImage: "square.grid.2x2",
						description: Text(L("تظهر هنا التطبيقات المثبّتة من «المتجر» أو «مشاريعي»."))
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
					.accessibilityLabel(L("الموقّعة"))
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_isImporting = true
					} label: {
						Image(systemName: "plus")
					}
					.accessibilityLabel(L("تثبيت ملف IPA"))
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
				Text(count == 0 ? L("لا توجد تحديثات") : (count == 1 ? L("تحديث واحد متوفر · تحديث الكل") : L("%@ تحديثات متوفرة · تحديث الكل", count.formatted())))
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
	
	private func _row(_ item: Item) -> some View {
		_card(item)
			.listRowSeparator(.hidden)
			.listRowBackground(Color.clear)
			.listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
			.swipeActions(edge: .trailing, allowsFullSwipe: true) {
				Button(role: .destructive) {
					_removeFromHistory(item)
				} label: {
					Label(L("حذف من السجل"), systemImage: "trash")
				}
			}
	}
	
	@ViewBuilder
	private func _card(_ item: Item) -> some View {
		HStack(spacing: 14) {
			let info = HStack(spacing: 14) {
				StoreIconOverride(bundleID: item.id) {
					if let signed = item.signed {
						FRAppIconView(app: signed, size: 57)
					} else {
						Image("App_Unknown").appIconStyle(size: 57, isCircle: false)
					}
				}
				VStack(alignment: .leading, spacing: 3) {
					Text(_name(item))
						.font(.headline)
						.foregroundStyle(.primary)
						.lineLimit(1)
					Text(_subtitle(item))
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer(minLength: 8)
			}
			.contentShape(Rectangle())
			if let entry = _storeEntry(item.id) {
				NavigationLink {
					SourceAppsDetailView(sourceURL: entry.0, source: entry.1, app: entry.2)
				} label: { info }
				.buttonStyle(.plain)
			} else {
				info
			}
			_pill(item)
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.fill(Color(.secondarySystemBackground))
		)
		.contextMenu {
			Button(L("فتح"), systemImage: "arrow.up.forward.app") {
				UIApplication.openApp(with: item.id)
			}
			Button(L("حذف من السجل"), systemImage: "trash", role: .destructive) {
				_removeFromHistory(item)
			}
			if let signed = item.signed {
				Button(L("حذف الملفات"), systemImage: "doc.badge.ellipsis") {
					LibraryDeleteHelper.confirmDelete([signed])
				}
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
	
	private func _subtitle(_ item: Item) -> String {
		let version = item.record.version ?? item.signed?.version
		if let update = _update(item) {
			// Isolated LTR run so "old → new" reads correctly inside RTL text.
			return "\u{2066}\(update.localVersion ?? version ?? "—") → \(update.remoteVersion)\u{2069}"
		}
		return version ?? item.id
	}
	
	@ViewBuilder
	private func _pill(_ item: Item) -> some View {
		let key = _key(item)
		if _quickInstall.justFinished.contains(key) {
			ProgressPill(title: L("مثبّت"), color: .green, progress: 1, filled: true)
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
		} else if let update = _update(item) {
			Button {
				_quickInstall.installUpdate(update)
			} label: {
				ProgressPill(title: L("تحديث"), color: .yellow, progress: 1, filled: true)
			}
			.buttonStyle(.plain)
		} else {
			Button {
				UIApplication.openApp(with: item.id)
			} label: {
				ProgressPill(title: L("فتح"), color: .accentColor, progress: 0, filled: false)
			}
			.buttonStyle(.plain)
		}
	}
	
	private func _stateTitle(_ state: QuickInstallState) -> String {
		switch state {
		case .downloading: return L("تنزيل")
		case .signing: return L("توقيع")
		case .installing: return L("تثبيت")
		case .failed: return L("خطأ")
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
