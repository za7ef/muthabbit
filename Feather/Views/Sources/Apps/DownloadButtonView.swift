//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var downloadManager = DownloadManager.shared
	@ObservedObject private var quickInstall = QuickInstallManager.shared
	
	private var _key: String { app.id ?? app.currentUniqueId }
	
	private var _isBusy: Bool {
		guard let state = quickInstall.state(for: _key) else { return false }
		return !state.isFailed
	}

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?

	@State private var _startedAt: Date?
	
	var body: some View {
		// The button never shrinks or truncates; status text gives way instead.
		if _isActive {
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
		let download = downloadManager.getDownload(by: app.currentUniqueId)
		if let download {
			TimelineView(.periodic(from: .now, by: 1)) { context in
				VStack(alignment: .trailing, spacing: 1) {
					if let remaining = _remaining(download, now: context.date) {
						Text(remaining).font(.caption2.weight(.semibold))
					}
					if download.totalBytes > 0 {
						Text(L("%@ / %@ م.ب", _mb(download.bytesDownloaded), _mb(download.totalBytes)))
							.font(.caption2)
					}
				}
				.foregroundStyle(.secondary)
				.monospacedDigit()
			}
			.onAppear { if _startedAt == nil { _startedAt = Date() } }
		} else if let state = quickInstall.state(for: _key), !state.isFailed {
			Text(state.progressText)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.onAppear { _startedAt = nil }
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
			if let currentDownload = downloadManager.getDownload(by: app.currentUniqueId) ?? quickInstall.downloadIDs[_key].flatMap({ downloadManager.getDownload(by: $0) }) {
				ZStack {
					Circle()
						.trim(from: 0, to: downloadProgress)
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.frame(width: 31, height: 31)
						.animation(.smooth, value: downloadProgress)

					Image(systemName: downloadProgress >= 0.75 ? "archivebox" : "square.fill")
						.foregroundStyle(.tint)
						.font(.footnote).bold()
				}
				.onTapGesture {
					if downloadProgress <= 0.75 {
						downloadManager.cancelDownload(currentDownload)
					}
				}
				.compatTransition()
			} else if _isBusy {
				ZStack {
					Circle()
						.stroke(Color.accentColor.opacity(0.25), lineWidth: 2.3)
					ProgressView()
						.controlSize(.small)
				}
				.frame(width: 31, height: 31)
				.compatTransition()
			} else if let id = app.id, quickInstall.installedIDs.contains(id), !_hasUpdate(id) {
				Button {
					UIApplication.openApp(with: id)
				} label: {
					Text(L("فتح"))
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 24)
						.padding(.vertical, 6)
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
					Text(.localized("Get"))
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 24)
						.padding(.vertical, 6)
						.background(Color(uiColor: .quaternarySystemFill))
						.clipShape(Capsule())
				}
				.buttonStyle(.borderless)
				.compatTransition()
			}
		}
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.onChange(of: downloadManager.downloads.count) { _ in
			setupObserver()
		}
		.animation(.easeInOut(duration: 0.3), value: downloadManager.getDownload(by: app.currentUniqueId) != nil)
	}

	private func setupObserver() {
		cancellable?.cancel()
		guard let download = downloadManager.getDownload(by: app.currentUniqueId) else {
			downloadProgress = 0
			return
		}
		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress = download.overallProgress
		}
	}
	
	private func _hasUpdate(_ bundleID: String) -> Bool {
		UpdateManager.shared.updates.values.contains { $0.bundleIdentifier == bundleID }
	}
	
	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
