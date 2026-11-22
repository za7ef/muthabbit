//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	/// Toolbar style: small pill only, no size/status line under it.
	var compact: Bool = false
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var quickInstall = QuickInstallManager.shared
	
	private var _key: String { app.id ?? app.currentUniqueId }
	
	private var _isBusy: Bool {
		guard let state = quickInstall.state(for: _key) else { return false }
		return !state.isFailed
	}


	@State private var _startedAt: Date?
	
	var body: some View {
		// The button never shrinks or truncates; status text gives way instead.
		if compact {
			_button
				.fixedSize()
				.controlSize(.small)
				.font(.subheadline)
				.environment(\.dynamicTypeSize, .large)
		} else if _isActive {
			HStack(spacing: 8) {
				_statusText
					.lineLimit(1)
					.minimumScaleFactor(0.7)
				_button
					.fixedSize()
					.layoutPriority(1)
			}
		} else {
			VStack(spacing: 2) {
				_button
					.fixedSize()
					.layoutPriority(1)
				_statusText
					.lineLimit(1)
					.minimumScaleFactor(0.7)
			}
		}
	}
	
	private var _isActive: Bool {
		downloadManager.getDownload(by: app.currentUniqueId) != nil || _isBusy
	}
	
	/// App Store-style secondary text: remaining time + sizes while downloading, step text after,
	/// and the app size before install.
	@ViewBuilder
	private var _statusText: some View {
		if let download = _currentDownload {
			TimelineView(.periodic(from: .now, by: 1)) { context in
				VStack(alignment: .trailing, spacing: 1) {
					if let remaining = _remaining(download, now: context.date) {
						Text(remaining).font(.caption2.weight(.semibold))
					}
					if download.totalBytes > 0 {
						Text("\u{2066}\(Int((download.overallProgress * 100).rounded()))%\u{2069} · " + L("%@ / %@ م.ب", _mb(download.bytesDownloaded), _mb(download.totalBytes)))
							.font(.caption2)
					}
				}
				.foregroundStyle(.secondary)
				.monospacedDigit()
			}
			.onAppear { if _startedAt == nil { _startedAt = Date() } }
		} else if let state = quickInstall.state(for: _key), !state.isFailed {
			if case .installing = state, let progress = quickInstall.installProgress[_key] {
				Text("\(state.progressText) \u{2066}\(Int((progress * 100).rounded()))%\u{2069}")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.monospacedDigit()
			} else {
				Text(state.progressText)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.onAppear { _startedAt = nil }
			}
		} else if
			!(app.id.map { quickInstall.installedIDs.contains($0) } ?? false),
			let bytes = app.size ?? app.currentAppVersion?.size.map(Int64.init) ?? app.backupSize,
			bytes > 0
		{
			Text(L("%@ م.ب", _mb(bytes)))
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
	}
	
	private func _mb(_ bytes: Int64) -> String {
		String(format: "%.1f", Double(bytes) / 1_048_576)
	}
	
	private func _remaining(_ d: Download, now: Date) -> String? {
		guard let start = _startedAt, d.totalBytes > 0, d.bytesDownloaded > 0 else { return nil }
		let elapsed = now.timeIntervalSince(start)
		guard elapsed > 1 else { return nil }
		let rate = Double(d.bytesDownloaded) / elapsed
		let secs = Double(d.totalBytes - d.bytesDownloaded) / max(rate, 1)
		if secs < 60 { return L("أقل من دقيقة") }
		// The system formatter handles plurals (incl. Arabic dual) in every language.
		let f = DateComponentsFormatter()
		f.allowedUnits = secs >= 3600 ? [.hour, .minute] : [.minute]
		f.unitsStyle = .full
		f.maximumUnitCount = 2
		var cal = Calendar.current
		cal.locale = AppLanguage.locale
		f.calendar = cal
		return f.string(from: secs) ?? ""
	}
	
	private var _button: some View {
		ZStack {
			if let currentDownload = _currentDownload {
				// Read straight from the download on a timer: the old Combine subscription lived in
				// @State shared by two layouts and was cancelled by the layout that disappeared,
				// so the ring stayed at 0 and only the stop square showed.
				TimelineView(.periodic(from: .now, by: 0.2)) { _ in
					let progress = currentDownload.overallProgress
					ZStack {
						_ring(progress)
						Image(systemName: progress >= 0.75 ? "archivebox" : "square.fill")
							.foregroundStyle(.tint)
							.font(.system(size: 10, weight: .bold))
					}
					.frame(width: 31, height: 31)
					.contentShape(Circle())
					.onTapGesture {
						// Instant reset: clears the install state too, not only the download.
						if quickInstall.state(for: _key) != nil {
							quickInstall.cancel(_key)
						} else if currentDownload.overallProgress <= 0.75 {
							downloadManager.cancelDownload(currentDownload)
						}
					}
				}
				.compatTransition()
			} else if _isBusy {
				ZStack {
					if case .installing = quickInstall.state(for: _key), let progress = quickInstall.installProgress[_key] {
						_ring(progress)
						Image(systemName: "arrow.down.app")
							.foregroundStyle(.tint)
							.font(.system(size: 11, weight: .bold))
					} else {
						// Signing has no measurable progress (one call to the signing engine).
						Circle()
							.stroke(Color.accentColor.opacity(0.25), lineWidth: 2.3)
						ProgressView()
							.controlSize(.small)
					}
				}
				.frame(width: 31, height: 31)
				.contentShape(Circle())
				.onTapGesture { quickInstall.cancel(_key) }
				.compatTransition()
			} else if app.id == QuickInstallManager.ownBundleID, !_isNewerThanRunning {
				// This app itself (running now): never «تثبيت»; «محدّث» unless the source has a newer version.
				Text(L("محدّث"))
					.lineLimit(0)
					.font(compact ? .subheadline.bold() : .headline.bold())
					.foregroundStyle(.secondary)
					.padding(.horizontal, 20)
					.padding(.vertical, 6)
					.background(Color(uiColor: .quaternarySystemFill))
					.clipShape(Capsule())
					.compatTransition()
			} else if let id = app.id, quickInstall.installedIDs.contains(id), !_hasUpdate(id) {
				Button {
					UIApplication.openApp(with: id)
				} label: {
					Text(L("فتح"))
						.lineLimit(0)
						.font(compact ? .subheadline.bold() : .headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, compact ? 16 : 24)
						.padding(.vertical, compact ? 4 : 6)
						.background(Color(uiColor: .quaternarySystemFill))
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
				.compatTransition()
			} else {
				Button {
					if let url = app.currentDownloadUrl {
						quickInstall.installFromSource(
							url: url,
							downloadID: app.currentUniqueId,
							key: _key,
							provenance: _sourceProvenance(),
							backupURL: app.backupDownloadURL
						)
					}
				} label: {
					Text(app.id == QuickInstallManager.ownBundleID ? L("تحديث") : .localized("Get"))
						.lineLimit(0)
						.font(compact ? .subheadline.bold() : .headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, compact ? 16 : 24)
						.padding(.vertical, compact ? 4 : 6)
						.background(Color(uiColor: .quaternarySystemFill))
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
				.compatTransition()
			}
		}
		.animation(.easeInOut(duration: 0.3), value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
	}

	private var _currentDownload: Download? {
		downloadManager.getDownload(by: app.currentUniqueId)
			?? quickInstall.downloadIDs[_key].flatMap { downloadManager.getDownload(by: $0) }
	}
	
	/// App Store-style ring: faint full track plus the filled part.
	private func _ring(_ progress: Double) -> some View {
		ZStack {
			Circle()
				.stroke(Color.accentColor.opacity(0.25), lineWidth: 2.3)
			Circle()
				.trim(from: 0, to: max(0.02, min(progress, 1)))
				.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(-90))
				.animation(.smooth, value: progress)
		}
		.frame(width: 31, height: 31)
	}
	
	/// Source version of this app is newer than the running build.
	private var _isNewerThanRunning: Bool {
		guard let remote = app.currentVersion else { return false }
		return remote.compare(AppInfo.marketingVersion, options: .numeric) == .orderedDescending
	}
	
	private func _hasUpdate(_ bundleID: String) -> Bool {
		UpdateManager.shared.updates.values.contains { $0.bundleIdentifier == bundleID }
	}
	
	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
