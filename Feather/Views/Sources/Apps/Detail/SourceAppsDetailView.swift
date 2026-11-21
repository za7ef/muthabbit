//
//  SourceAppsDetailView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import NukeUI

// MARK: - SourceAppsDetailView
struct SourceAppsDetailView: View {
	@ObservedObject var downloadManager = DownloadManager.shared
	@State private var _downloadProgress: Double = 0
	@State var cancellable: AnyCancellable? // Combine
	@State private var _isScreenshotPreviewPresented: Bool = false
	@State private var _selectedScreenshotIndex: Int = 0
	@State private var _isHeaderHidden: Bool = false
	@State private var _readmeImages: [URL] = []
	
	/// Source screenshots, or images from the GitHub README when the source has none.
	private var _previewURLs: [URL]? {
		if let urls = app.screenshotURLs, !urls.isEmpty { return urls }
		return _readmeImages.isEmpty ? nil : _readmeImages
	}
	
	var currentDownload: Download? {
		downloadManager.getDownload(by: app.currentUniqueId)
	}
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	/// Other sources offering the same bundle id.
	var others: [StoreAppEntry] = []
	
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 10) {
					if let iconURL = app.iconURL {
						LazyImage(url: iconURL) { state in
							if let image = state.image {
								image.appIconStyle(size: 111, isCircle: false)
							} else {
								standardIcon
							}
						}
					} else {
						standardIcon
					}

					VStack(alignment: .leading, spacing: 2) {
						Text(app.currentName)
							.font(.title2)
							.fontWeight(.semibold)
							.foregroundColor(.primary)
						Text(app.subtitle ?? app.developer ?? source.name ?? "")
							.font(.subheadline)
							.foregroundColor(.secondary)
						
						Spacer()
						
						HStack(spacing: 8) {
							DownloadButtonView(sourceURL: sourceURL, source: source, app: app)
							if app.currentAppVersion?.isBeta == true {
								Text("تجريبي")
									.font(.caption.bold())
									.foregroundStyle(.orange)
							}
						}
					}
					.lineLimit(2)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.onGeometryChange(for: Bool.self) { proxy in
					proxy.frame(in: .global).maxY < 100
				} action: { hidden in
					withAnimation(.easeInOut(duration: 0.2)) { _isHeaderHidden = hidden }
				}
				
				Divider()
				_infoStrip(app: app)
				Divider()
                
				if !others.isEmpty {
					NBSection("متوفر في مصادر أخرى") {
						VStack(spacing: 0) {
							ForEach(others) { other in
								NavigationLink {
									SourceAppsDetailView(sourceURL: other.sourceURL, source: other.source, app: other.app)
								} label: {
									HStack {
										Text(other.source.name ?? other.sourceURL?.host ?? "")
											.foregroundStyle(.primary)
										Spacer()
										Text(other.app.currentVersion ?? "")
											.foregroundStyle(.secondary)
											.monospacedDigit()
										Image(systemName: "chevron.forward")
											.font(.footnote)
											.foregroundStyle(.tertiary)
									}
									.padding(.vertical, 10)
								}
								.buttonStyle(.plain)
								Divider()
							}
						}
					}
					Divider()
				}
				
				if let screenshotURLs = _previewURLs, !screenshotURLs.isEmpty {
					NBSection("معاينة") {
						_screenshots(screenshotURLs: screenshotURLs)
					}
                    
					Divider()
				}
				
				if
					let currentVer = app.currentVersion,
					let whatsNewDesc = app.currentAppVersion?.localizedDescription
				{
					NBSection(.localized("What's New")) {
						AppVersionInfo(
							version: currentVer,
							date: app.currentDate?.date,
							description: whatsNewDesc
						)
						if let versions = app.versions {
							NavigationLink(
								destination: VersionHistoryView(
									sourceURL: sourceURL,
									source: source,
									app: app,
									versions: versions
								)
									.navigationTitle("جميع الإصدارات")
									.navigationBarTitleDisplayMode(.large)
							) {
								Text("جميع الإصدارات")
							}
						}
					}
					
					Divider()
				}
				
				if let appDesc = app.localizedDescription {
					NBSection(.localized("Description")) {
						VStack(alignment: .leading, spacing: 2) {
							ExpandableText(text: appDesc, lineLimit: 3)
						}
						.frame(maxWidth: .infinity, alignment: .leading)
					}
					
					Divider()
				}
                
				NBSection(.localized("Information")) {
					VStack(spacing: 12) {
						if let sourceName = source.name {
							_infoRow(title: .localized("Source"), value: sourceName)
						}
                        
						if let developer = app.developer {
							_infoRow(title: .localized("Developer"), value: developer)
						}
						
						if let size = app.size {
							_infoRow(title: .localized("Size"), value: size.formattedByteCount)
						}
						
						if let category = app.category {
							_infoRow(title: .localized("Category"), value: category.capitalized)
						}
						
						if let version = app.currentVersion {
							_infoRow(title: .localized("Version"), value: version)
						}
						
						if let date = app.currentDate?.date {
							_infoRow(title: .localized("Updated"), value: DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
						}
						
						if let bundleId = app.id {
							_infoRow(title: .localized("Identifier"), value: bundleId)
						}
					}
				}
				
				if let minOS = app.currentAppVersion?.minOSVersion {
					Text("يتطلب iOS \(minOS.description) أو أحدث.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				
				if let appPermissions = app.appPermissions {
					NBSection(.localized("Permissions")) {
						Group {
							if let entitlements = appPermissions.entitlements {
								NBTitleWithSubtitleView(
									title: .localized("Entitlements"),
									subtitle: entitlements.map(\.name).joined(separator: "\n")
								)
							} else {
								Text(.localized("No Entitlements listed."))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
							if let privacyItems = appPermissions.privacy {
								ForEach(privacyItems, id: \.self) { item in
									NBTitleWithSubtitleView(
										title: item.name,
										subtitle: item.usageDescription
									)
								}
							} else {
								Text(.localized("No Privacy Permissions listed."))
									.font(.subheadline)
									.foregroundStyle(.secondary)
							}
						}
						.padding()
						.background(
							RoundedRectangle(cornerRadius: 18, style: .continuous)
								.fill(Color(.quaternarySystemFill))
						)
					}
				}
			}
			.padding([.horizontal, .bottom])
			.padding(.top, 8)
		}
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				if _isHeaderHidden {
					LazyImage(url: app.iconURL) { state in
						if let image = state.image {
							image.appIconStyle(size: 30, isCircle: false)
						} else {
							Image("App_Unknown").appIconStyle(size: 30, isCircle: false)
						}
					}
					.transition(.opacity)
				}
			}
			ToolbarItem(placement: .topBarTrailing) {
				if _isHeaderHidden {
					DownloadButtonView(sourceURL: sourceURL, source: source, app: app)
						.transition(.opacity)
				}
			}
			NBToolbarButton(
				systemImage: "square.and.arrow.up",
				placement: .topBarTrailing
			) {
				let sharedString = """
				\(app.currentName) - \(app.currentVersion ?? "0")
				\(app.currentDescription ?? .localized("An awesome application"))
				---
				\(source.website?.absoluteString ?? source.name ?? "")
				"""
				UIActivityViewController.show(activityItems: [sharedString])
			}
		}
		.task {
			if (app.screenshotURLs ?? []).isEmpty, let gh = app.githubURL {
				_readmeImages = await ReadmeImages.images(for: gh)
			}
		}
		.fullScreenCover(isPresented: $_isScreenshotPreviewPresented) {
			if let screenshotURLs = _previewURLs {
				ScreenshotPreviewView(
					screenshotURLs: screenshotURLs,
					initialIndex: _selectedScreenshotIndex
				)
			}
		}
	}
	
	var standardIcon: some View {
		Image("App_Unknown").appIconStyle(size: 111, isCircle: false)
	}
	
	var standardHeader: some View {
		Image("App_Unknown")
			.resizable()
			.aspectRatio(contentMode: .fill)
			.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
			.clipped()
	}
}

// MARK: - SourceAppsDetailView (Extension): Builders
extension SourceAppsDetailView {
	@available(iOS 18.0, *)
	@ViewBuilder
	private func _header() -> some View {
		ZStack {
			if let iconURL = source.currentIconURL {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image.resizable()
							.aspectRatio(contentMode: .fill)
							.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
							.clipped()
					} else {
						standardHeader
					}
				}
			} else {
				standardHeader
			}
			
			NBVariableBlurView()
				.rotationEffect(.degrees(-180))
				.overlay(
					LinearGradient(
						gradient: Gradient(colors: [
							Color.black.opacity(0.8),
							Color.black.opacity(0)
						]),
						startPoint: .top,
						endPoint: .bottom
					)
				)
		}
	}
	
	@ViewBuilder
	private func _infoPills(app: ASRepository.App) -> some View {
		let pillItems = _buildPills(from: app)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
		}
	}
	
	private func _infoStrip(app: ASRepository.App) -> some View {
		var items: [(String, String, String)] = []
		if let v = app.currentVersion { items.append(("الإصدار", v, "tag")) }
		if let size = app.size { items.append(("الحجم", size.formattedByteCount, "archivebox")) }
		if let c = app.category { items.append(("الفئة", c.capitalized, "square.grid.2x2")) }
		if let n = source.name { items.append(("المصدر", n, "bag")) }
		if let d = app.developer { items.append(("المطوّر", d, "person.crop.square")) }
		if let m = app.currentAppVersion?.minOSVersion { items.append(("الحد الأدنى", "iOS \(m.description)", "iphone")) }
		return ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 0) {
				ForEach(items.indices, id: \.self) { i in
					VStack(spacing: 6) {
						Text(items[i].0)
							.font(.caption2.weight(.semibold))
							.foregroundStyle(.secondary)
						Image(systemName: items[i].2)
							.font(.title3)
							.foregroundStyle(.secondary)
						Text(items[i].1)
							.font(.caption)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
					.frame(minWidth: 96)
					.padding(.horizontal, 6)
					if i < items.count - 1 {
						Divider().frame(height: 44)
					}
				}
			}
			.padding(.horizontal)
		}
		.padding(.horizontal, -16)
	}
	
	private func _buildPills(from app: ASRepository.App) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		
		if let version = app.currentVersion {
			pills.append(NBPillItem(title: version, icon: "tag", color: Color.accentColor))
		}
		
		if let size = app.size {
			pills.append(NBPillItem(title: size.formattedByteCount, icon: "archivebox", color: .secondary))
		}
		
		return pills
	}
	
	@ViewBuilder
	private func _infoRow(title: String, value: String) -> some View {
		LabeledContent(title, value: value)
		Divider()
	}
	
	@ViewBuilder
	private func _screenshots(screenshotURLs: [URL]) -> some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 12) {
				ForEach(screenshotURLs.indices, id: \.self) { index in
					let url = screenshotURLs[index]
					LazyImage(url: url) { state in
						if let image = state.image {
							image
								.resizable()
								.aspectRatio(contentMode: .fit)
								.frame(
									maxWidth: UIScreen.main.bounds.width - 32,
									maxHeight: 400
								)
								.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
								.overlay {
									RoundedRectangle(cornerRadius: 16, style: .continuous)
										.strokeBorder(.gray.opacity(0.3), lineWidth: 1)
								}
								.onTapGesture {
									_selectedScreenshotIndex = index
									_isScreenshotPreviewPresented = true
								}
						}
					}
				}
			}
			.padding(.horizontal)
			.compatScrollTargetLayout()
		}
		.compatScrollTargetBehavior()
		.padding(.horizontal, -16)
	}
}
