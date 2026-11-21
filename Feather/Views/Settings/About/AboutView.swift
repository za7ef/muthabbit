//
//  AboutView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//  Simplified for Muthabbit.
//

import SwiftUI
import NimbleViews

// MARK: - Model
extension AboutView {
	struct CreditsModel: Hashable {
		let name: String
		let desc: String
		let url: String
	}
}

// MARK: - View
struct AboutView: View {
	private let _credits: [CreditsModel] = [
		.init(name: "Feather", desc: L("المشروع الأساسي — claration (samara) · GPL-3.0"), url: "https://github.com/claration/feather"),
		.init(name: "Asami", desc: L("مساهم في Feather"), url: "https://github.com/Nyasami"),
		.init(name: "AltSourceKit", desc: L("قراءة مصادر AltStore — llsc12"), url: "https://github.com/llsc12"),
		.init(name: "Zsign", desc: L("محرك التوقيع — zhlynn"), url: "https://github.com/zhlynn/zsign"),
		.init(name: "IDeviceKit", desc: L("أدوات التثبيت — khcrysalis"), url: "https://github.com/khcrysalis/IDeviceKit"),
		.init(name: "Nuke", desc: L("تحميل الصور — kean · MIT"), url: "https://github.com/kean/Nuke"),
		.init(name: "Vapor", desc: L("خادم التثبيت المحلي · MIT"), url: "https://github.com/vapor/vapor"),
		.init(name: "Zip / SWCompression", desc: L("فك الضغط · MIT"), url: "https://github.com/marmelroy/Zip")
	]
	
	// MARK: Body
	var body: some View {
		List {
			Section {
				VStack(spacing: 6) {
					FRAppIconView(size: 72)
					
					Text(AppInfo.displayName)
						.font(.largeTitle)
						.bold()
						.foregroundStyle(Color.accentColor)
					
					Text(L("الإصدار %@ — البناء %@", AppInfo.marketingVersion, AppInfo.buildNumber))
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity)
			}
			.listRowBackground(Color.clear)
			
			Section {
				Text(L("أداة مبسّطة لإضافة مصادر التطبيقات، وتصفّحها، وتثبيت التطبيقات بشهادة خاصة، مع التنبيه عند توفر تحديث لأي تطبيق مثبّت من مصدر."))
					.fixedSize(horizontal: false, vertical: true)
				_row(title: L("الإصدار"), value: AppInfo.marketingVersion)
				_row(title: L("رقم البناء"), value: AppInfo.buildNumber)
			} header: {
				Text(L("معلومات التطبيق"))
			}
			
			Section {
				Button {
					UIApplication.shared.open(AppInfo.developerURL)
				} label: {
					HStack {
						Label(L("المطوّر: github.com/za7ef"), systemImage: "chevron.left.forwardslash.chevron.right")
						Spacer()
						Image(systemName: "arrow.up.left")
							.foregroundColor(.secondary.opacity(0.65))
					}
				}
				Button {
					UIApplication.shared.open(AppInfo.repositoryURL)
				} label: {
					HStack {
						Label(L("الشيفرة المصدرية"), systemImage: "doc.text")
						Spacer()
						Image(systemName: "arrow.up.left")
							.foregroundColor(.secondary.opacity(0.65))
					}
				}
			} header: {
				Text(L("المطوّر"))
			}
			
			Section {
				ForEach(_credits, id: \.self) { credit in
					Button {
						if let url = URL(string: credit.url) {
							UIApplication.shared.open(url)
						}
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							Text(credit.name)
								.foregroundStyle(.primary)
							Text(credit.desc)
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
					}
				}
			} header: {
				Text(L("الشكر والتراخيص"))
			} footer: {
				Text(L("هذا التطبيق نسخة معدّلة ومبسّطة من Feather، ويُوزَّع بموجب رخصة GPL-3.0، وتبقى حقوق المكتبات المستخدمة لأصحابها وفق تراخيصها."))
			}
			
			Section {
				NavigationLink(destination: TermsOfUseView()) {
					Label(L("سياسة الاستخدام"), systemImage: "doc.plaintext")
				}
				NavigationLink(destination: PrivacyPolicyView()) {
					Label(L("سياسة الخصوصية"), systemImage: "hand.raised")
				}
			}
		}
		.navigationTitle(L("حول التطبيق"))
		.navigationBarTitleDisplayMode(.inline)
	}
	
	@ViewBuilder
	private func _row(title: String, value: String) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
		}
	}
}
