//
//  SignedAppsView.swift
//  Muthabbit
//
//  «الموقّعة»: signed copies that are not (yet) installed. Install, share IPA, delete.
//
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI
import CoreData
import NimbleViews

struct SignedAppsView: View {
	@ObservedObject private var _quickInstall = QuickInstallManager.shared
	@State private var _sharing: AnyApp?
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signed: FetchedResults<Signed>
	
	private var _items: [Signed] {
		_signed.filter { app in
			guard let id = app.identifier else { return true }
			return !_quickInstall.installedIDs.contains(id)
		}
	}
	
	var body: some View {
		List {
			ForEach(_items, id: \.objectID) { app in
				HStack(spacing: 14) {
					FRAppIconView(app: app, size: 50)
					VStack(alignment: .leading, spacing: 2) {
						Text(app.name ?? .localized("Unknown"))
							.font(.headline)
						Text(app.version ?? "")
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
					Spacer()
					if
						let state = _quickInstall.state(for: app.identifier),
						!state.isFailed
					{
						ProgressView()
					} else {
						Button {
							_quickInstall.installExisting(app)
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
				.swipeActions {
					Button(L("حذف"), systemImage: "trash", role: .destructive) {
						Storage.shared.deleteApp(for: app)
					}
					Button(L("مشاركة"), systemImage: "square.and.arrow.up") {
						_sharing = AnyApp(base: app, archive: true)
					}
					.tint(.blue)
				}
				.contextMenu {
					Button(L("مشاركة ملف IPA"), systemImage: "square.and.arrow.up") {
						_sharing = AnyApp(base: app, archive: true)
					}
					Button(L("حذف"), systemImage: "trash", role: .destructive) {
						Storage.shared.deleteApp(for: app)
					}
				}
			}
		}
		.overlay {
			if _items.isEmpty, #available(iOS 17, *) {
				ContentUnavailableView(
					L("لا توجد تطبيقات موقّعة"),
					systemImage: "signature",
					description: Text(L("تظهر هنا التطبيقات التي وُقّعت ولم يكتمل تثبيتها."))
				)
			}
		}
		.navigationTitle(L("الموقّعة"))
		.sheet(item: $_sharing) { item in
			InstallPreviewView(app: item.base, isSharing: true)
				.presentationDetents([.height(200)])
				.presentationDragIndicator(.visible)
		}
	}
}
