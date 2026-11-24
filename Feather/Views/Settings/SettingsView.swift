//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//  Reorganized for Muthabbit (iOS Settings style).
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//

import SwiftUI
import NimbleViews
import NimbleExtensions
import UIKit

// MARK: - Icon helper
struct SettingsIcon: View {
	let systemName: String
	let color: Color
	
	var body: some View {
		Image(systemName: systemName)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 29, height: 29)
			.background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
	}
}

struct SettingsRow: View {
	let title: String
	let systemName: String
	let color: Color
	
	var body: some View {
		HStack(spacing: 12) {
			SettingsIcon(systemName: systemName, color: color)
			Text(title)
		}
	}
}

// MARK: - View
struct SettingsView: View {
	@AppStorage(AutoTranslate.enabledKey) private var _autoTranslate = true
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage(QuickInstallManager.showInstallOptionsKey) private var _showInstallOptions = false
	@AppStorage(QuickInstallManager.showProcessLogKey) private var _showProcessLog = false
	@AppStorage(QuickInstallManager.deleteOldKey) private var _deleteOld = true
	@AppStorage(QuickInstallManager.deleteFilesKey) private var _deleteFiles = false
	@State private var _usedBytes: Int64 = 0
	@State private var _cacheBytes: Int64 = 0
	@State private var _breakdown = StorageCleaner.Breakdown()
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				// Certificate
				Section {
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(destination: CertificatesView()) {
						SettingsRow(title: L("إدارة الشهادات"), systemName: "checkmark.seal.fill", color: .green)
					}
				} header: {
					Text(L("الشهادة"))
				} footer: {
					Text(L("تُستخدم الشهادة المحددة تلقائيًا لتوقيع كل تطبيق عند التثبيت أو التحديث. يلزم ملف p12 وملف mobileprovision."))
				}
				
				// GitHub
				Section {
					NavigationLink(destination: GitHubAccountView()) {
						HStack {
							SettingsRow(title: L("تسجيل الدخول عبر GitHub"), systemName: "person.crop.circle.fill", color: .black)
							Spacer()
							if let login = GitHubAccount.shared.login {
								Text("@\(login)").foregroundStyle(.secondary)
							}
						}
					}
				} header: {
					Text("GitHub")
				} footer: {
					Text(L("لعرض مستودعاتك وتثبيت تطبيقاتها من «مشاريعي»."))
				}
				
				// Install & signing defaults
				Section {
					NavigationLink(destination: ConfigurationView()) {
						SettingsRow(title: L("خيارات التثبيت الافتراضية"), systemName: "slider.horizontal.3", color: .blue)
					}
					NavigationLink(destination: InstallationView()) {
						SettingsRow(title: L("طريقة التثبيت"), systemName: "arrow.down.app.fill", color: .indigo)
					}
				} header: {
					Text(L("التثبيت"))
				} footer: {
					Text(L("تُطبَّق الخيارات الافتراضية (الاسم، معرّف الحزمة، الإصدار، الأدوات المحقونة، مشاركة الملفات، إزالة URL Schemes، إزالة تطبيق الساعة، الحد الأدنى لإصدار iOS، الصلاحيات المخصصة، وغيرها) تلقائيًا على كل تثبيت وتحديث. طريقة التثبيت الافتراضية «Semi Local» مناسبة لإصدارات iOS الحديثة."))
				}
				
				// Optional screens
				Section {
					Toggle(isOn: $_showInstallOptions) {
						SettingsRow(title: L("إظهار خيارات التثبيت عند تثبيت تطبيق جديد"), systemName: "list.bullet.rectangle.fill", color: .orange)
					}
					Toggle(isOn: $_showProcessLog) {
						SettingsRow(title: L("إظهار سجل العمليات"), systemName: "text.alignright", color: .gray)
					}
				} header: {
					Text(L("الشاشات الإضافية"))
				} footer: {
					Text(L("عند إيقاف الخيارين، يتم التنزيل والتوقيع والتثبيت بضغطة واحدة في الخلفية دون أي شاشات إضافية. ولا تظهر خيارات التثبيت عند التحديث."))
				}
				
				// Translation
				Section {
					Toggle(isOn: $_autoTranslate) {
						SettingsRow(title: L("ترجمة الأوصاف تلقائيًا"), systemName: "character.bubble.fill", color: .blue)
					}
				} header: {
					Text(L("الترجمة"))
				} footer: {
					Text(L("تُترجم أوصاف التطبيقات وعناوينها وملاحظات إصداراتها إلى لغة التطبيق عند كتابتها بلغة أخرى، عبر خدمة Google Translate. ويُرسل نص الوصف فقط، دون أي بيانات عن المستخدم."))
				}
				
				// Storage
				Section {
					LabeledContent {
						Text(ByteCountFormatter.string(fromByteCount: _usedBytes, countStyle: .file))
					} label: {
						SettingsRow(title: L("المساحة المستخدمة"), systemName: "internaldrive.fill", color: .gray)
					}
					DisclosureGroup(L("تفاصيل المساحة")) {
						_sizeRow(L("التطبيقات الموقّعة"), _breakdown.signed)
						_sizeRow(L("التطبيقات غير الموقّعة"), _breakdown.unsigned)
						_sizeRow(L("الأرشيف (ملفات IPA المصدّرة)"), _breakdown.archives)
						_sizeRow(L("الشهادات"), _breakdown.certificates)
						_sizeRow(L("الكاش"), _breakdown.cache)
						_sizeRow(L("أخرى"), _breakdown.other)
					}
					Button {
						Task { @MainActor in
							let freed = StorageCleaner.cleanUnusedFiles()
							await _refreshStorage()
							UIAlertController.showAlertWithOk(
								title: L("تنظيف الملفات غير المستخدمة"),
								message: freed.map {
									L("تم تحرير %@.", ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
								} ?? L("يوجد تثبيت أو تنزيل جارٍ. أعد المحاولة بعد انتهائه.")
							)
						}
					} label: {
						SettingsRow(title: L("تنظيف الملفات غير المستخدمة"), systemName: "sparkles", color: .teal)
					}
					Toggle(isOn: $_deleteOld) {
						SettingsRow(title: L("حذف النسخة السابقة بعد التحديث"), systemName: "arrow.triangle.2.circlepath", color: .orange)
					}
					Toggle(isOn: $_deleteFiles) {
						SettingsRow(title: L("حذف الملف بعد التثبيت أو التحديث"), systemName: "xmark.bin.fill", color: .pink)
					}
					Button(role: .destructive) {
						Task.detached(priority: .userInitiated) {
							StorageCleaner.clearCache()
							await _refreshStorage()
						}
					} label: {
						HStack {
							SettingsRow(title: L("مسح الكاش"), systemName: "trash.circle.fill", color: .red)
							Spacer()
							Text(ByteCountFormatter.string(fromByteCount: _cacheBytes, countStyle: .file))
								.foregroundStyle(.secondary)
						}
					}
				} header: {
					Text(L("التخزين"))
				} footer: {
					Text(L("يُحذف تلقائيًا بعد كل تثبيت أو تحديث ملف التنزيل والنسخ القديمة والملفات المؤقتة، وعند تفعيل «حذف النسخة السابقة بعد التحديث» يُحتفظ بآخر نسخة موقّعة فقط. وعند تفعيل «حذف الملف بعد التثبيت أو التحديث» تُحذف ملفات النسخة المثبّتة أيضًا، ويبقى التطبيق في «تطبيقاتي» لمتابعة تحديثاته. لا يحذف «مسح الكاش» التطبيقات ولا الشهادات."))
				}
				
				// Language
				Section {
					NavigationLink(destination: LanguageSettingsView()) {
						HStack {
							SettingsRow(title: L("اللغة"), systemName: "globe", color: .cyan)
							Spacer()
							Text(AppLanguage.selected.nativeName).foregroundStyle(.secondary)
						}
					}
				}
				
				// About
				Section {
					NavigationLink(destination: AboutView()) {
						HStack(spacing: 12) {
							FRAppIconView(size: 29)
							Text(L("حول التطبيق"))
						}
					}
					NavigationLink(destination: TermsOfUseView()) {
						SettingsRow(title: L("سياسة الاستخدام"), systemName: "doc.plaintext.fill", color: .teal)
					}
					NavigationLink(destination: PrivacyPolicyView()) {
						SettingsRow(title: L("سياسة الخصوصية"), systemName: "hand.raised.fill", color: .blue)
					}
				} header: {
					Text(L("حول"))
				} footer: {
					Text(L("الإصدار %@", AppInfo.fullVersion))
				}
				
				// Reset
				Section {
					NavigationLink(destination: ResetView()) {
						SettingsRow(title: .localized("Reset"), systemName: "trash.fill", color: .red)
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
			.task { await _refreshStorage() }
		}
	}
	
	private func _sizeRow(_ title: String, _ bytes: Int64) -> some View {
		LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
	}
	
	private func _refreshStorage() async {
		let used = await Task.detached(priority: .utility) { StorageCleaner.usedBytes() }.value
		let cache = await Task.detached(priority: .utility) { StorageCleaner.cacheBytes() }.value
		let parts = await Task.detached(priority: .utility) { StorageCleaner.breakdown() }.value
		await MainActor.run {
			_breakdown = parts
			_usedBytes = used
			_cacheBytes = cache
		}
	}
}


// MARK: - Language
struct LanguageSettingsView: View {
	@State private var _selected = AppLanguage.selected
	@State private var _showRestart = false
	
	var body: some View {
		List {
			ForEach(AppLanguage.allCases) { lang in
				Button {
					guard lang != _selected else { return }
					_selected = lang
					AppLanguage.select(lang)
					_showRestart = true
				} label: {
					HStack {
						Text(lang.nativeName).foregroundStyle(.primary)
						Spacer()
						if lang == _selected {
							Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
						}
					}
				}
			}
		}
		.navigationTitle(L("اللغة"))
		.alert(L("تغيير اللغة"), isPresented: $_showRestart) {
			Button(L("إغلاق التطبيق")) {
				UIApplication.shared.suspend()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
			}
			Button(L("لاحقًا"), role: .cancel) {}
		} message: {
			Text(L("تُطبَّق اللغة الجديدة بعد إعادة فتح التطبيق."))
		}
	}
}
