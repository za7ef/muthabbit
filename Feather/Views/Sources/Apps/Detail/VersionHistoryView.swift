//
//  VersionHistoryView.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import AltSourceKit

// MARK: - VersionHistoryView
struct VersionHistoryView: View {
	@Environment(\.dismiss) var dismiss
	
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	let versions: [ASRepository.App.Version]
	@ObservedObject private var quickInstall = QuickInstallManager.shared
    
	var body: some View {
		ScrollView {
			LazyVStack(spacing: 12) {
				ForEach(versions) { version in
					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text(version.isBeta ? L("تجريبي") : L("رسمي"))
								.font(.caption.bold())
								.padding(.horizontal, 8)
								.padding(.vertical, 3)
								.background((version.isBeta ? Color.orange : Color.green).opacity(0.18), in: Capsule())
								.foregroundStyle(version.isBeta ? Color.orange : Color.green)
							if let build = version.build {
								Text(L("البناء %@", "\(build)"))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							if let downloadURL = version.downloadURL {
								let key = app.id ?? app.currentUniqueId
								if let state = quickInstall.state(for: key), !state.isFailed {
									ProgressView()
								} else {
									Button {
										quickInstall.installFromSource(
											url: downloadURL,
											downloadID: "\(app.currentUniqueId).\(version.id)",
											key: key,
											provenance: SourceAppProvenance(
												sourceURL: sourceURL,
												repository: source,
												app: app,
												version: version
											)
										)
									} label: {
										Text(L("تثبيت"))
											.font(.subheadline.bold())
											.padding(.horizontal, 16)
											.padding(.vertical, 5)
											.background(Color(uiColor: .quaternarySystemFill), in: Capsule())
									}
									.buttonStyle(.borderless)
								}
							}
						}
						AppVersionInfo(
							version: version.version,
							date: version.date?.date,
							description: version.localizedDescription ?? .localized("No release notes available")
						)
					}
					.padding(.horizontal)
					.background(Color(.systemBackground))
					.contextMenu {
						if let downloadURL = version.downloadURL {
							Button {
								UIPasteboard.general.string = downloadURL.absoluteString
							} label: {
								Label(.localized("Copy Download URL"), systemImage: "doc.on.clipboard")
							}
						}
					}
                    
					Divider().padding(.horizontal)
				}
			}
			.padding(.top, 8)
		}
	}
}
