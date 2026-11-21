//
//  StoreHomeView.swift
//  Muthabbit
//
//  App Store "Today"-style home for the store tab.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews
import NukeUI
import Nuke

struct StoreAppEntry: Identifiable {
	let id: String
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	/// The same bundle id offered by other sources.
	var others: [StoreAppEntry] = []
	var featuredID: String { "featured." + id }
}

struct StoreHomeView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@State private var _isSourcesPresenting = false
	@State private var _searchText = ""
	@ObservedObject private var _github = GitHubAccount.shared
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	/// Built once per source change (not on every body pass / per row).
	@State private var _entries: [StoreAppEntry] = []
	@State private var _filtered: [StoreAppEntry] = []
	/// Infinite scroll: how many rows are rendered so far (pages of 30).
	@State private var _limit = 30
	
	private func _buildEntries() -> [StoreAppEntry] {
		// One entry per bundle id across all sources; the newest version is the main entry.
		var groups: [String: [StoreAppEntry]] = [:]
		var order: [String] = []
		for source in _sources {
			guard let repo = viewModel.sources[source] else { continue }
			for app in repo.apps {
				let bundle = app.id ?? app.currentUniqueId
				let entry = StoreAppEntry(id: bundle + (source.sourceURL?.absoluteString ?? ""), sourceURL: source.sourceURL, source: repo, app: app)
				if groups[bundle] == nil { order.append(bundle); groups[bundle] = [] }
				if !(groups[bundle]!.contains { $0.id == entry.id }) { groups[bundle]!.append(entry) }
			}
		}
		let result: [StoreAppEntry] = order.compactMap { bundle in
			guard var list = groups[bundle], !list.isEmpty else { return nil }
			list.sort { ($0.app.currentVersion ?? "0").compare($1.app.currentVersion ?? "0", options: .numeric) == .orderedDescending }
			var main = list.removeFirst()
			main.others = list
			return main
		}
		return result.sorted { $0.app.currentName.localizedCompare($1.app.currentName) == .orderedAscending }
	}
	
	private func _refilter() {
		_filtered = _computeFiltered()
		_limit = 30
	}
	
	private func _computeFiltered() -> [StoreAppEntry] {
		guard !_searchText.isEmpty else { return _entries }
		return _entries.filter {
			$0.app.currentName.localizedCaseInsensitiveContains(_searchText)
			|| ($0.app.subtitle?.localizedCaseInsensitiveContains(_searchText) ?? false)
			|| ($0.app.id?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}
	
	var body: some View {
		NavigationStack {
			ScrollView {
				// No spacing between list rows (and no negative paddings that overlap during lazy layout);
				// the cards get their own spacing.
				LazyVStack(alignment: .leading, spacing: 0) {
					if _searchText.isEmpty {
						if let hero = _entries.first {
							_heroCard(hero).padding(.bottom, 22)
						}
						// Distinct ids: the same apps also appear in the list below; sharing ids inside one
						// LazyVStack made SwiftUI swap card/row views and leave gaps while scrolling.
						ForEach(Array(_entries.dropFirst().prefix(2)), id: \.featuredID) { entry in
							_featuredAppCard(entry).padding(.bottom, 22)
						}
					}
					
					if _searchText.isEmpty, _github.isSignedIn {
						NavigationLink {
							MyProjectsView()
						} label: {
							HStack(spacing: 14) {
								SettingsIcon(systemName: "shippingbox.fill", color: .black)
								VStack(alignment: .leading) {
									Text("مشاريعي").font(.headline)
									Text("تطبيقات مستودعاتك على GitHub").font(.footnote).foregroundStyle(.secondary)
								}
								Spacer()
								Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
							}
							.padding(16)
							.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
						}
						.buttonStyle(.plain)
						.padding(.horizontal, 20)
						.padding(.bottom, 22)
					}
					
					if !_filtered.isEmpty {
						HStack(alignment: .firstTextBaseline) {
							Text(_searchText.isEmpty ? "كل التطبيقات" : "نتائج البحث")
								.font(.title2.bold())
							Spacer()
							Text("\(_filtered.count.formatted()) تطبيق من \(_sources.count.formatted()) \((3...10).contains(_sources.count) ? "مصادر" : "مصدر")")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
							.padding(.horizontal, 20)
							.padding(.top, 6)
							.padding(.bottom, 8)
						// Rows are direct children of the LazyVStack, so only visible rows are built.
						let page = Array(_filtered.prefix(_limit))
						let lastID = _filtered.last?.id
						let pageLastID = page.last?.id
						ForEach(page) { entry in
							VStack(spacing: 0) {
								_row(entry)
								if entry.id != lastID {
									Divider().padding(.leading, 76)
								}
							}
							.padding(.horizontal, 20)
							.onAppear {
								if entry.id == pageLastID, _limit < _filtered.count {
									_limit += 30
								}
							}
						}
						if _limit < _filtered.count {
							ProgressView()
								.frame(maxWidth: .infinity)
								.padding(.top, 30)
						}
					}
				}
				.padding(.vertical, 8)
			}
			.onAppear { _entries = _buildEntries(); _refilter() }
			.onChange(of: viewModel.sources.count) { _ in _entries = _buildEntries(); _refilter() }
			.onChange(of: viewModel.isFinished) { _ in _entries = _buildEntries(); _refilter() }
			.onChange(of: _sources.count) { _ in _entries = _buildEntries(); _refilter() }
			.onChange(of: _searchText) { _ in _refilter() }
			.navigationTitle("المتجر")
			.navigationBarTitleDisplayMode(.large)
			.searchable(text: $_searchText, prompt: "ابحث في التطبيقات")
			.overlay {
				if _sources.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label("لا توجد مصادر", systemImage: "bag")
						} description: {
							Text("تُضاف المصادر من زر المصادر في الأعلى.")
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_isSourcesPresenting = true
					} label: {
						Image(systemName: "square.stack.3d.up.fill")
					}
					.accessibilityLabel("المصادر")
				}
			}
			.refreshable {
				await viewModel.fetchSources(_sources, refresh: true)
				_entries = _buildEntries(); _refilter()
				await AutoUpdateChecker.checkNow(force: true)
			}
			.sheet(isPresented: $_isSourcesPresenting) {
				SourcesView()
			}
		}
		.task(id: Array(_sources)) {
			await viewModel.fetchSources(_sources)
		}
	}
	
	// MARK: Cards
	
	@ViewBuilder
	private func _heroCard(_ entry: StoreAppEntry) -> some View {
		let tint = entry.source.tintColor ?? entry.app.tintColor ?? .accentColor
		let icons = Array(_entries.prefix(5))
		NavigationLink {
			SourceAppsView(object: Array(_sources), viewModel: viewModel)
		} label: {
			VStack(alignment: .leading, spacing: 0) {
				VStack(alignment: .leading, spacing: 6) {
					Spacer(minLength: 150)
					Text((entry.source.name ?? "المصدر").uppercased())
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.white.opacity(0.8))
					Text("اكتشف تطبيقات مصادرك")
						.font(.title.bold())
						.foregroundStyle(.white)
					Text(entry.source.subtitle ?? "ثبّت أي تطبيق بضغطة واحدة، وتصلك تحديثاته تلقائيًا.")
						.font(.subheadline)
						.foregroundStyle(.white.opacity(0.85))
						.lineLimit(2)
				}
				.padding(20)
				
				HStack(spacing: 12) {
					ForEach(icons) { item in
						_icon(item.app.iconURL, size: 52)
					}
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 14)
				.frame(maxWidth: .infinity)
				.background(.ultraThinMaterial)
			}
			.background(
				ZStack {
					LinearGradient(
						colors: [tint, tint.opacity(0.55), .purple.opacity(0.7)],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
					if let header = entry.source.headerURL {
						LazyImage(url: header) { state in
							if let image = state.image {
								image.resizable().scaledToFill()
							}
						}
					}
					LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
				}
			)
			.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 20)
	}
	
	@ViewBuilder
	private func _featuredAppCard(_ entry: StoreAppEntry) -> some View {
		NavigationLink {
			SourceAppsDetailView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app, others: entry.others)
		} label: {
			ZStack(alignment: .bottom) {
				ZStack {
					// Cheap "blurred" backdrop: a tiny icon scaled up (no live blur pass while scrolling).
					_blurredBackdrop(entry.app.iconURL)
					Color.black.opacity(0.25)
					_icon(entry.app.iconURL, size: 96)
						.offset(y: -24)
				}
				.frame(height: 230)
				.clipped()
				
				HStack(alignment: .center) {
					VStack(alignment: .leading, spacing: 2) {
						Text(entry.app.currentName)
							.font(.headline)
							.foregroundStyle(.white)
						Text(entry.app.subtitle ?? entry.app.currentVersion ?? "")
							.font(.subheadline)
							.foregroundStyle(.white.opacity(0.8))
							.lineLimit(1)
					}
					Spacer()
					Color.clear.frame(width: 90, height: 1)
				}
				.padding(16)
			}
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		}
		.buttonStyle(.plain)
		// Install button sits outside the card link so a card tap or scroll never starts an install.
		.overlay(alignment: .bottomTrailing) {
			DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
				.padding(16)
		}
		.padding(.horizontal, 20)
	}
	
	@ViewBuilder
	private func _row(_ entry: StoreAppEntry) -> some View {
		HStack(spacing: 8) {
		NavigationLink {
			SourceAppsDetailView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app, others: entry.others)
		} label: {
			HStack(spacing: 14) {
				_icon(entry.app.iconURL, size: 62)
				VStack(alignment: .leading, spacing: 2) {
					Text(entry.app.currentName)
						.font(.body.weight(.medium))
						.foregroundStyle(.primary)
						.lineLimit(1)
					Text(entry.app.subtitle ?? entry.source.name ?? "")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
				Spacer()
			}
			.padding(.vertical, 10)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
		}
	}
	
	/// Backdrop blurred once by Nuke (cached bitmap) and laid out at the card's own size,
	/// so nothing is scaled beyond the card bounds and no live blur runs while scrolling.
	private func _blurredBackdrop(_ url: URL?) -> some View {
		LazyImage(request: url.map {
			ImageRequest(url: $0, processors: [
				ImageProcessors.Resize(size: CGSize(width: 120, height: 120), unit: .pixels),
				ImageProcessors.GaussianBlur(radius: 12)
			])
		}) { state in
			if let image = state.image {
				image.resizable().scaledToFill().opacity(0.7)
			} else {
				Color(.tertiarySystemFill)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.clipped()
	}
	
	@ViewBuilder
	private func _icon(_ url: URL?, size: CGFloat, thumb: Bool = false) -> some View {
		// Decoded and downsampled once to the displayed size, then served from Nuke's memory cache.
		let px = (thumb ? 8 : size) * UIScreen.main.scale
		LazyImage(request: url.map { ImageRequest(url: $0, processors: [.resize(size: CGSize(width: px, height: px), unit: .pixels)]) }) { state in
			if let image = state.image {
				image.resizable().scaledToFill()
			} else {
				Color(.tertiarySystemFill)
			}
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
				.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
		)
	}
}
