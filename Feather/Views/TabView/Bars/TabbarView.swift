//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI

struct TabbarView: View {
	@State private var selectedTab: TabEnum = .sources
	@ObservedObject private var updateManager = UpdateManager.shared

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.badge(tab == .library ? updateManager.updates.count : 0)
					.tag(tab)
			}
		}
	}
}
