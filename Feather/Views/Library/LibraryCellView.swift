//
//  LibraryAppIconView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NukeUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var quickInstall = QuickInstallManager.shared
	@State private var _signedUpdateConfirmation: AppUpdate?
	@State private var _isSignedUpdateConfirmationPresented = false

	var certInfo: Date.ExpirationInfo? {
		Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
	}
	
	var certRevoked: Bool {
		Storage.shared.getCertificate(from: app)?.revoked == true
	}
	
	var app: AppInfoPresentable
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	
	// MARK: Selections
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	// MARK: Body
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 18) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			_appIcon(for: app)
			
			NBTitleWithSubtitleView(
				title: app.name ?? .localized("Unknown"),
				subtitle: _desc,
				linelimit: 0
			)
			
			if !isEditing {
				_buttonActions(for: app)
			}
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(_isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill))
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
		.confirmationDialog(
			.localized("Update Available"),
			isPresented: $_isSignedUpdateConfirmationPresented,
			titleVisibility: .visible
		) {
			Button(.localized("Install Current Version"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			if let update = _signedUpdateConfirmation {
				Button(.localized("Download Update"), systemImage: "arrow.down.circle") {
					_startUpdateDownload(update)
				}
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			if let update = _signedUpdateConfirmation {
				Text(verbatim: "\(update.appName) \(update.remoteVersion)")
			}
		}
	}
	
	private var _desc: String {
		if let version = app.version, let id = app.identifier {
			return "\(version) • \(id)"
		} else {
			return .localized("Unknown")
		}
	}
}


// MARK: - Extension: View
extension LibraryCellView {
	private func _appIcon(for app: AppInfoPresentable) -> some View {
		StoreIconOverride(bundleID: app.identifier) {
			FRAppIconView(app: app, size: 57)
		}
			.overlay(alignment: .topTrailing) {
				if updateManager.update(for: app) != nil {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 18, weight: .semibold))
						.symbolRenderingMode(.palette)
						.foregroundStyle(.white, Color.accentColor)
						.background(
							Circle()
								.fill(Color(.systemBackground))
								.frame(width: 20, height: 20)
						)
						.offset(x: 5, y: -5)
						.accessibilityLabel(.localized("Update Available"))
				}
			}
	}
	
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(L("حذف"), systemImage: "trash", role: .destructive) {
			LibraryDeleteHelper.confirmDelete([app])
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if let update = updateManager.update(for: app) {
			Button(.localized("Update"), systemImage: "arrow.down.circle") {
				quickInstall.installUpdate(update)
			}
		}
		
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					UIApplication.openApp(with: id)
				}
			}
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Re-sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		} else {
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		Group {
			if
				let state = quickInstall.state(for: updateManager.update(for: app)?.bundleIdentifier ?? app.identifier),
				!state.isFailed
			{
				ProgressView()
					.frame(minWidth: 44)
			} else if updateManager.update(for: app) != nil {
				// The update button lives in the "التحديثات المتوفرة" section above.
				EmptyView()
			} else {
				Button {
					if let id = app.identifier {
						UIApplication.openApp(with: id)
					}
				} label: {
					FRExpirationPillView(
						title: L("فتح"),
						revoked: false,
						expiration: nil
					)
				}
			}
		}
		.buttonStyle(.borderless)
	}
	
	private func _startUpdateDownload(_ update: AppUpdate) {
		_ = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: "Muthabbit_Update_\(update.localUUID)",
			sourceProvenance: update.sourceProvenance
		)
	}
}


/// Shows the source's iconURL when the app is listed in a source; falls back to the bundle icon.
struct StoreIconOverride<Fallback: View>: View {
	let bundleID: String?
	@ViewBuilder let fallback: () -> Fallback
	@ObservedObject private var _sources = SourcesViewModel.shared
	@ObservedObject private var _github = GitHubAccount.shared
	
	private var _iconURL: URL? {
		guard let bundleID else { return nil }
		for repo in _sources.sources.values {
			if let app = repo.apps.first(where: { $0.id == bundleID }), let url = app.iconURL { return url }
		}
		return _github.projects?.apps.first(where: { $0.id == bundleID })?.iconURL
	}
	
	var body: some View {
		if let url = _iconURL {
			LazyImage(url: url) { state in
				if let image = state.image {
					image.appIconStyle(size: 57, isCircle: false)
				} else {
					fallback()
				}
			}
		} else {
			fallback()
		}
	}
}
