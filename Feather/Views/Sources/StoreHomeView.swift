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

struct StoreAppEntry: Identifiable {
	let id: String
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
}

struct StoreHomeView: View {
	@StateObject private var viewModel = SourcesViewModel.shared
	@State private var _isSourcesPresenting = false
	@State private var _searchText = ""
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	private var _entries: [StoreAppEntry] {
		var result: [StoreAppEntry] = []
		var seen = Set<String>()
		for source in _sources {
			guard let repo = viewModel.sources[source] else { continue }
			for app in repo.apps {
				let key = (app.id ?? app.currentUniqueId) + (source.sourceURL?.absoluteString ?? "")
				guard !seen.contains(key) else { continue }
				seen.insert(key)
				result.append(StoreAppEntry(id: key, sourceURL: source.sourceURL, source: repo, app: app))
			}
		}
		return result.sorted { $0.app.currentName.localizedCompare($1.app.currentName) == .orderedAscending }
	}
	
	private var _filtered: [StoreAppEntry] {
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
				LazyVStack(alignment: .leading, spacing: 22) {
					if _searchText.isEmpty {
						if let hero = _entries.first {
							_heroCard(hero)
						}
						ForEach(Array(_entries.dropFirst().prefix(2))) { entry in
							_featuredAppCard(entry)
						}
					}
					
					if !_filtered.isEmpty {
						VStack(alignment: .leading, spacing: 0) {
							Text(_searchText.isEmpty ? "كل التطبيقات" : "نتائج البحث")
								.font(.title2.bold())
								.padding(.bottom, 8)
							ForEach(_filtered) { entry in
								_row(entry)
								if entry.id != _filtered.last?.id {
									Divider().padding(.leading, 76)
								}
							}
						}
						.padding(.horizontal, 20)
					}
				}
				.padding(.vertical, 8)
			}
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
			.shadow(color: .black.opacity(0.15), radius: 12, y: 6)
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 20)
	}
	
	@ViewBuilder
	private func _featuredAppCard(_ entry: StoreAppEntry) -> some View {
		NavigationLink {
			SourceAppsDetailView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
		} label: {
			ZStack(alignment: .bottom) {
				ZStack {
					_icon(entry.app.iconURL, size: 220)
						.blur(radius: 40)
						.opacity(0.7)
					Color.black.opacity(0.25)
					_icon(entry.app.iconURL, size: 96)
						.shadow(radius: 10)
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
					DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
				}
				.padding(16)
			}
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
		}
		.buttonStyle(.plain)
		.padding(.horizontal, 20)
	}
	
	@ViewBuilder
	private func _row(_ entry: StoreAppEntry) -> some View {
		NavigationLink {
			SourceAppsDetailView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
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
				DownloadButtonView(sourceURL: entry.sourceURL, source: entry.source, app: entry.app)
			}
			.padding(.vertical, 10)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
	
	@ViewBuilder
	private func _icon(_ url: URL?, size: CGFloat) -> some View {
		LazyImage(url: url) { state in
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
