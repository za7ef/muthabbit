//
//  StoreHomeView.swift
//  Muthabbit
//
//  App Store "Today"-style home for the store tab.
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
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
	@ObservedObject private var viewModel = SourcesViewModel.shared
	@State private var _isSourcesPresenting = false
	@State private var _searchText = ""
	@ObservedObject private var _github = GitHubAccount.shared
	@ObservedObject private var _translations = TranslationCache.shared
	
	/// Translated text from the cache when available (filled by `batchTranslate`), else the original.
	@AppStorage(AutoTranslate.enabledKey) private var _autoTranslate = true
	
	private func _tr(_ text: String) -> String {
		_ = _translations.revision
		guard _autoTranslate else { return text }
		return _translations.get(text, target: AutoTranslate.target) ?? text
	}
	
	/// Short texts to translate once per load: every subtitle plus the featured cards' descriptions.
	private var _textsToTranslate: [String] {
		var out = _entries.compactMap { $0.app.subtitle }
		let picks = _featuredPicks
		for e in [picks.sourcePick, picks.newThisWeek].compactMap({ $0 }) {
			if let d = _shortDescription(e.app) { out.append(d) }
		}
		return out
	}
	
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
	/// Category chips: built from the sources' `category` field; nil = all apps.
	@State private var _categories: [StoreCategory] = []
	@State private var _selectedCategory: String? = nil
	
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
		_categories = StoreCategory.build(from: _entries)
		if let selected = _selectedCategory, !_categories.contains(where: { $0.key == selected }) {
			_selectedCategory = nil
		}
		_filtered = _computeFiltered()
		_limit = 30
	}
	
	private func _computeFiltered() -> [StoreAppEntry] {
		var list = _entries
		if let selected = _selectedCategory {
			list = list.filter { StoreCategory.key(for: $0.app.category) == selected }
		}
		guard !_searchText.isEmpty else { return list }
		return list.filter {
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
					if !_categories.isEmpty {
						_categoryChips()
							.padding(.bottom, 14)
					}
					
					if _searchText.isEmpty, _selectedCategory == nil {
						if let hero = _entries.first {
							_heroCard(hero).padding(.bottom, 22)
						}
						// Themed cards, each with its own layout. Distinct ids (prefixed): the same apps also
						// appear in the list below; sharing ids inside one LazyVStack made SwiftUI swap views.
						let picks = _featuredPicks
						if let entry = picks.sourcePick {
							_sourcePickCard(entry).padding(.bottom, 22)
						}
						if let entry = picks.newThisWeek {
							_newThisWeekCard(entry).padding(.bottom, 22)
						}
						if !picks.recentlyUpdated.isEmpty {
							_recentUpdatesCard(picks.recentlyUpdated).padding(.bottom, 22)
						}
						if let spotlight = picks.spotlight {
							_categorySpotlightCard(spotlight).padding(.bottom, 22)
						}
					}
					
					if _searchText.isEmpty, _selectedCategory == nil, _github.isSignedIn {
						NavigationLink {
							MyProjectsView()
						} label: {
							HStack(spacing: 14) {
								SettingsIcon(systemName: "shippingbox.fill", color: .black)
								VStack(alignment: .leading) {
									Text(L("مشاريعي")).font(.headline)
									Text(L("تطبيقات مستودعاتك على GitHub")).font(.footnote).foregroundStyle(.secondary)
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
							Text(_searchText.isEmpty ? (_selectedCategoryTitle ?? L("كل التطبيقات")) : L("نتائج البحث"))
								.font(.title2.bold())
							Spacer()
							Text(L("%@ تطبيق من %@ مصدر", _filtered.count.formatted(), _sources.count.formatted()))
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
			.onChange(of: _selectedCategory) { _ in _refilter() }
			.navigationTitle(L("المتجر"))
			.batchTranslate(_autoTranslate ? _textsToTranslate : [])
			.navigationBarTitleDisplayMode(.large)
			.modifier(_SoftTopEdge())
			.searchable(text: $_searchText, prompt: L("ابحث في التطبيقات"))
			.overlay {
				if _sources.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(L("لا توجد مصادر"), systemImage: "bag")
						} description: {
							Text(L("تُضاف المصادر من زر المصادر في الأعلى."))
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
					.accessibilityLabel(L("المصادر"))
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
	
	// MARK: Category chips
	
	private var _selectedCategoryTitle: String? {
		guard let selected = _selectedCategory else { return nil }
		return _categories.first { $0.key == selected }?.title
	}
	
	@ViewBuilder
	private func _categoryChips() -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				_chip(title: L("كل التطبيقات"), isSelected: _selectedCategory == nil) {
					_selectedCategory = nil
				}
				ForEach(_categories) { category in
					_chip(title: category.title, isSelected: _selectedCategory == category.key) {
						_selectedCategory = category.key
					}
				}
			}
			.padding(.horizontal, 20)
		}
	}
	
	private func _chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.subheadline.weight(.semibold))
				.lineLimit(1)
				.foregroundStyle(isSelected ? Color.white : Color.primary)
				.padding(.horizontal, 16)
				.padding(.vertical, 9)
				.background(
					Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
				)
				.overlay(
					Capsule().stroke(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 0.5)
				)
		}
		.buttonStyle(.plain)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
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
					Text((entry.source.name ?? L("المصدر")).uppercased())
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.white.opacity(0.8))
					Text(L("اكتشف تطبيقات مصادرك"))
						.font(.title.bold())
						.foregroundStyle(.white)
					Text(entry.source.subtitle ?? L("ثبّت أي تطبيق بضغطة واحدة، وتصلك تحديثاته تلقائيًا."))
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
					HeroDriftBackground(urls: icons.compactMap(\.app.iconURL))
					if let header = entry.source.headerURL {
						LazyImage(url: header) { state in
							if let image = state.image {
								image.resizable().scaledToFill()
							}
						}
					}
					// Dimming only behind the title text at the bottom.
					LinearGradient(
						stops: [
							.init(color: .clear, location: 0),
							.init(color: .clear, location: 0.35),
							.init(color: .black.opacity(0.7), location: 0.75)
						],
						startPoint: .top,
						endPoint: .bottom
					)
				}
			)
			.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 20)
	}
	
	// MARK: Featured picks (no random apps)
	
	struct FeaturedPicks {
		var sourcePick: StoreAppEntry?
		var newThisWeek: StoreAppEntry?
		var recentlyUpdated: [StoreAppEntry] = []
		var spotlight: (category: StoreCategory, apps: [StoreAppEntry])?
	}
	
	/// Only real signals from the sources: `featuredApps` set by the source, and version dates.
	/// AltStore sources have no ratings or download counts, so nothing here is ranked by popularity.
	/// Each app appears in one card at most.
	private var _featuredPicks: FeaturedPicks {
		var picks = FeaturedPicks()
		var used = Set<String>()
		if let hero = _entries.first { used.insert(hero.id) }
		let now = Date()
		func date(_ e: StoreAppEntry) -> Date? { e.app.currentDate?.date }
		func isRecent(_ e: StoreAppEntry, days: Double) -> Bool {
			guard let d = date(e) else { return false }
			return d <= now.addingTimeInterval(86_400) && now.timeIntervalSince(d) < days * 86_400
		}
		let byDate = _entries.filter { date($0) != nil }.sorted { date($0)! > date($1)! }
		
		// 1. Source picks: apps listed in a source's `featuredApps`, newest first.
		let featured = _entries.filter { e in
			guard let id = e.app.id else { return false }
			return (e.source.featuredApps ?? []).contains(id)
		}
		.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
		if let pick = featured.first(where: { !used.contains($0.id) }) {
			picks.sourcePick = pick
			used.insert(pick.id)
		}
		
		// 2. New this week: an app whose only version was published in the last 7 days.
		if let pick = byDate.first(where: { e in
			!used.contains(e.id) && isRecent(e, days: 7) && (e.app.versions?.count ?? 1) <= 1
		}) {
			picks.newThisWeek = pick
			used.insert(pick.id)
		}
		
		// 3. Recently updated: up to 3 apps updated in the last 14 days.
		picks.recentlyUpdated = Array(byDate.filter { !used.contains($0.id) && isRecent($0, days: 14) }.prefix(3))
		picks.recentlyUpdated.forEach { used.insert($0.id) }
		
		// 4. Category spotlight: the largest category (not "other") with at least 3 apps.
		if let category = _categories.first(where: { $0.key != "other" && $0.count >= 3 }) {
			let apps = _entries.filter { StoreCategory.key(for: $0.app.category) == category.key }
				.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
			picks.spotlight = (category, Array(apps.prefix(4)))
		}
		return picks
	}
	
	/// First readable paragraph of the description (markdown symbols removed).
	private func _shortDescription(_ app: ASRepository.App) -> String? {
		let text = app.localizedDescription ?? app.description ?? ""
		for line in text.components(separatedBy: .newlines) {
			var clean = line.trimmingCharacters(in: .whitespaces)
			while let first = clean.first, "#*-•>".contains(first) {
				clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespaces)
			}
			clean = clean.replacingOccurrences(of: "**", with: "")
			if clean.count >= 12 { return _isDuplicate(clean, of: app.subtitle) ? nil : clean }
		}
		return nil
	}
	
	/// True when the description only repeats the subtitle (e.g. "GitHub project request: …").
	private func _isDuplicate(_ text: String, of subtitle: String?) -> Bool {
		guard let subtitle else { return false }
		func norm(_ s: String) -> String {
			s.lowercased().filter { $0.isLetter || $0.isNumber }
		}
		let a = norm(text), b = norm(subtitle)
		guard !a.isEmpty, !b.isEmpty else { return false }
		return a == b || a.hasPrefix(b) || b.hasPrefix(a)
	}
	
	/// "1.5 · 21 نوفمبر · 22.4 م.ب" (only the parts that are known).
	private func _meta(_ app: ASRepository.App) -> String {
		var parts: [String] = []
		if let v = app.currentVersion { parts.append("\u{2066}\(v)\u{2069}") }
		if let d = app.currentDate?.date {
			parts.append(d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.locale)))
		}
		if let bytes = app.size ?? app.currentAppVersion?.size.map(Int64.init) ?? app.backupSize, bytes > 0 {
			parts.append(L("%@ م.ب", (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(1)))))
		}
		return parts.joined(separator: " · ")
	}
	
	private func _cardLabel(_ text: String, systemImage: String, color: Color) -> some View {
		Label(text, systemImage: systemImage)
			.font(.footnote.weight(.bold))
			.foregroundStyle(color)
			.textCase(.uppercase)
	}
	
	private func _detailLink<Content: View>(_ entry: StoreAppEntry, @ViewBuilder label: () -> Content) -> some View {
		NavigationLink {
			SourceAppsDetailView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app, others: entry.others)
		} label: {
			label()
		}
		.buttonStyle(.plain)
	}
	
	/// Style 1 – «مختارات المصدر»: screenshot on top, details in a solid panel below
	/// (text never sits on the screenshot, so light screenshots stay readable).
	@ViewBuilder
	private func _sourcePickCard(_ entry: StoreAppEntry) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			_detailLink(entry) {
				Group {
					if let shot = entry.app.screenshotURLs?.first {
						LazyImage(request: ImageRequest(url: shot, processors: [
							ImageProcessors.Resize(size: CGSize(width: 700, height: 700), unit: .pixels)
						])) { state in
							if let image = state.image {
								image.resizable().scaledToFill()
							} else {
								Color(.tertiarySystemFill)
							}
						}
					} else {
						ZStack {
							_blurredBackdrop(entry.app.iconURL)
							_icon(entry.app.iconURL, size: 96)
						}
					}
				}
				.frame(height: 190)
				.frame(maxWidth: .infinity)
				.clipped()
				.contentShape(Rectangle())
			}
			
			VStack(alignment: .leading, spacing: 10) {
				_cardLabel(L("مختارات المصدر"), systemImage: "star.fill", color: .yellow)
				HStack(spacing: 12) {
					_detailLink(entry) {
						HStack(spacing: 12) {
							_icon(entry.app.iconURL, size: 52)
							VStack(alignment: .leading, spacing: 2) {
								Text(entry.app.currentName).font(.title3.bold()).lineLimit(1)
								Text(entry.app.subtitle.map(_tr) ?? entry.source.name ?? "")
									.font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
							}
							Spacer(minLength: 0)
						}
						.contentShape(Rectangle())
					}
					DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
				}
				if let desc = _shortDescription(entry.app) {
					Text(_tr(desc)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
				}
				Text(_meta(entry.app)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
			}
			.padding(16)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color(.secondarySystemBackground))
		}
		.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		.padding(.horizontal, 20)
	}
	
	/// Style 2 – «جديد هذا الأسبوع»: tinted card, big icon beside the text, details as tags.
	@ViewBuilder
	private func _newThisWeekCard(_ entry: StoreAppEntry) -> some View {
		let tint = entry.app.tintColor ?? entry.source.tintColor ?? .accentColor
		_detailLink(entry) {
			VStack(alignment: .leading, spacing: 12) {
				_cardLabel(L("جديد هذا الأسبوع"), systemImage: "sparkles", color: tint)
				HStack(alignment: .top, spacing: 14) {
					_icon(entry.app.iconURL, size: 84)
					VStack(alignment: .leading, spacing: 4) {
						Text(entry.app.currentName).font(.title2.bold()).lineLimit(2)
						if let sub = entry.app.subtitle {
							Text(_tr(sub)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
						}
					}
					Spacer(minLength: 0)
				}
				if let desc = _shortDescription(entry.app) {
					Text(_tr(desc)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
				}
				// Own row for the install button (overlaid below): text never runs under it.
				HStack(alignment: .center) {
					Text(_meta(entry.app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
					Spacer(minLength: 8)
					Color.clear.frame(width: 96, height: 50)
				}
			}
			.padding(18)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
			)
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		}
		.overlay(alignment: .bottomTrailing) {
			DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
				.padding(16)
		}
		.padding(.horizontal, 20)
	}
	
	/// Style 3 – «آخر التحديثات»: one card listing up to three freshly updated apps.
	@ViewBuilder
	private func _recentUpdatesCard(_ entries: [StoreAppEntry]) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			_cardLabel(L("آخر التحديثات"), systemImage: "arrow.triangle.2.circlepath", color: .orange)
				.padding(.bottom, 6)
			ForEach(entries, id: \.featuredID) { entry in
				HStack(spacing: 12) {
					_detailLink(entry) {
						HStack(spacing: 12) {
							_icon(entry.app.iconURL, size: 52)
							VStack(alignment: .leading, spacing: 2) {
								Text(entry.app.currentName).font(.body.weight(.semibold)).lineLimit(1)
								Text(_meta(entry.app)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
							}
							Spacer(minLength: 0)
						}
						.contentShape(Rectangle())
					}
					DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
				}
				.padding(.vertical, 6)
				if entry.id != entries.last?.id {
					Divider().padding(.leading, 64)
				}
			}
		}
		.padding(18)
		.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
		.padding(.horizontal, 20)
	}
	
	/// Style 4 – category spotlight: large title over overlapping icons; opens that category.
	@ViewBuilder
	private func _categorySpotlightCard(_ spotlight: (category: StoreCategory, apps: [StoreAppEntry])) -> some View {
		Button {
			withAnimation(.snappy) { _selectedCategory = spotlight.category.key }
		} label: {
			VStack(alignment: .leading, spacing: 14) {
				_cardLabel(L("تصنيف مميز"), systemImage: "square.grid.2x2.fill", color: .white.opacity(0.85))
				Text(spotlight.category.title).font(.largeTitle.bold()).foregroundStyle(.white)
				HStack(spacing: -14) {
					ForEach(spotlight.apps, id: \.featuredID) { entry in
						_icon(entry.app.iconURL, size: 58)
							.overlay(
								RoundedRectangle(cornerRadius: 58 * 0.225, style: .continuous)
									.stroke(.white.opacity(0.6), lineWidth: 2)
							)
					}
					Spacer(minLength: 0)
				}
				Text(L("%@ تطبيق في هذا التصنيف · عرض الكل", spotlight.category.count.formatted()))
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.white.opacity(0.85))
			}
			.padding(20)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				LinearGradient(colors: [.indigo, .purple, .pink.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
						Text(entry.app.subtitle.map(_tr) ?? entry.app.currentVersion ?? "")
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
					Text(entry.app.subtitle.map(_tr) ?? entry.source.name ?? "")
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


/// Slowly drifting, pre-blurred app icons behind the hero banner.
/// Cheap: blurred once by Nuke (cached bitmaps), ~20 fps, paused when off-screen,
/// when the app is not active, or when Reduce Motion is on.
struct HeroDriftBackground: View {
	let urls: [URL]
	@Environment(\.accessibilityReduceMotion) private var _reduceMotion
	@Environment(\.scenePhase) private var _scenePhase
	@State private var _isVisible = false
	@State private var _start = Date()
	
	private var _paused: Bool { _reduceMotion || !_isVisible || _scenePhase != .active }
	
	var body: some View {
		GeometryReader { geo in
			TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: _paused)) { context in
				let t = context.date.timeIntervalSince(_start)
				ZStack {
					ForEach(Array(urls.prefix(4).enumerated()), id: \.offset) { index, url in
						let phase = Double(index) * 1.7
						let x = cos(t / (9 + Double(index) * 2) + phase) * geo.size.width * 0.3
						let y = sin(t / (11 + Double(index) * 3) + phase) * geo.size.height * 0.22
						// Sharp icons (light blur only), so the apps stay recognizable.
						let side = geo.size.width * 0.34
						LazyImage(request: ImageRequest(url: url, processors: [
							ImageProcessors.Resize(size: CGSize(width: 256, height: 256), unit: .pixels),
							ImageProcessors.GaussianBlur(radius: 1)
						])) { state in
							if let image = state.image {
								image.resizable().scaledToFill()
							}
						}
						.frame(width: side, height: side)
						.clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
						.shadow(color: .black.opacity(0.25), radius: 8, y: 4)
						.opacity(0.9)
						.position(
							x: geo.size.width * (0.2 + 0.2 * Double(index)) + x,
							y: geo.size.height * (index.isMultiple(of: 2) ? 0.3 : 0.55) + y
						)
					}
				}
			}
		}
		.allowsHitTesting(false)
		.onAppear { _isVisible = true }
		.onDisappear { _isVisible = false }
	}
}


/// One category chip. Categories come from each app's `category` field in its source
/// (AltStore format, or custom values used by community sources). Equivalent spellings are
/// merged into one chip (e.g. "Tools" and "utilities", "EMU" and "Emulators") and translated;
/// unknown values are shown as written by the source.
struct StoreCategory: Identifiable, Equatable {
	let key: String
	let title: String
	let count: Int
	var id: String { key }
	
	/// canonical key → Arabic title (the localization key).
	private static let _titles: [String: String] = [
		"games": "ألعاب",
		"entertainment": "ترفيه",
		"utilities": "أدوات",
		"social": "تواصل",
		"developer": "أدوات المطورين",
		"photo-video": "صور وفيديو",
		"lifestyle": "نمط الحياة",
		"music": "موسيقى",
		"movies": "أفلام",
		"sideloading": "تثبيت جانبي",
		"exploits": "ثغرات",
		"emulators": "محاكيات",
		"ports": "ألعاب منقولة",
		"32bit": "تطبيقات 32 بت",
		"tweaks": "تطبيقات معدّلة",
		"other": "أخرى"
	]
	
	/// normalized spelling → canonical key.
	private static let _aliases: [String: String] = [
		"game": "games", "games": "games", "gaming": "games",
		"tool": "utilities", "tools": "utilities", "utility": "utilities", "utilities": "utilities",
		"social": "social", "socialnetworking": "social", "socialmedia": "social",
		"developer": "developer", "developertools": "developer", "development": "developer",
		"photo-video": "photo-video", "photovideo": "photo-video", "photo&video": "photo-video", "photoandvideo": "photo-video",
		"music": "music", "audio": "music",
		"movie": "movies", "movies": "movies",
		"sideload": "sideloading", "sideloading": "sideloading",
		"exploit": "exploits", "exploits": "exploits",
		"emu": "emulators", "emus": "emulators", "emulator": "emulators", "emulators": "emulators", "emulation": "emulators",
		"port": "ports", "ports": "ports",
		"32bit": "32bit", "32-bit": "32bit",
		"tweak": "tweaks", "tweaks": "tweaks", "tweaked": "tweaks", "tweakedapps": "tweaks",
		"other": "other", "others": "other", "misc": "other"
	]
	
	static func key(for raw: String?) -> String? {
		guard let raw else { return nil }
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmed.isEmpty else { return nil }
		let compact = trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
		return _aliases[compact] ?? _aliases[trimmed] ?? trimmed
	}
	
	/// Display name for a raw source category (translated when known, else as written).
	static func displayTitle(for raw: String?) -> String? {
		guard let raw, let key = key(for: raw) else { return nil }
		return _titles[key].map { L($0) } ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	static func build(from entries: [StoreAppEntry]) -> [StoreCategory] {
		var counts: [String: Int] = [:]
		var titles: [String: String] = [:]
		for entry in entries {
			guard let raw = entry.app.category, let key = key(for: raw) else { continue }
			counts[key, default: 0] += 1
			if titles[key] == nil {
				titles[key] = _titles[key].map { L($0) } ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		return counts.map { StoreCategory(key: $0.key, title: titles[$0.key] ?? $0.key, count: $0.value) }
			.sorted {
				// "Other" always last; the rest by number of apps, then by name.
				if ($0.key == "other") != ($1.key == "other") { return $1.key == "other" }
				if $0.count != $1.count { return $0.count > $1.count }
				return $0.title.localizedCompare($1.title) == .orderedAscending
			}
	}
}

// MARK: - Top edge

/// iOS 26-style top edge for the store: no opaque bar band; content fades and blurs
/// progressively under the title. iOS 26 uses the system soft scroll edge effect; older
/// versions get a material layer masked with a gradient.
private struct _SoftTopEdge: ViewModifier {
	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			content
				.toolbarBackgroundVisibility(.hidden, for: .navigationBar)
				.scrollEdgeEffectStyle(.soft, for: .top)
		} else {
			content
				.toolbarBackground(.hidden, for: .navigationBar)
				.overlay(alignment: .top) {
					GeometryReader { geo in
						Rectangle()
							.fill(.ultraThinMaterial)
							.mask(
								LinearGradient(
									stops: [
										.init(color: .black, location: 0),
										.init(color: .black.opacity(0.85), location: 0.55),
										.init(color: .clear, location: 1)
									],
									startPoint: .top, endPoint: .bottom
								)
							)
							.frame(height: geo.safeAreaInsets.top + 24)
							.ignoresSafeArea(edges: .top)
							.allowsHitTesting(false)
					}
				}
		}
	}
}
