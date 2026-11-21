//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//  Reorganized for Muthabbit (iOS Settings style).
//

import SwiftUI
import NimbleViews
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
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@AppStorage(QuickInstallManager.showInstallOptionsKey) private var _showInstallOptions = false
	@AppStorage(QuickInstallManager.showProcessLogKey) private var _showProcessLog = false
	@AppStorage(QuickInstallManager.deleteOldKey) private var _deleteOld = true
	@AppStorage(QuickInstallManager.deleteFilesKey) private var _deleteFiles = false
	@State private var _usedBytes: Int64 = 0
	@State private var _cacheBytes: Int64 = 0
	
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
						SettingsRow(title: "إدارة الشهادات", systemName: "checkmark.seal.fill", color: .green)
					}
				} header: {
					Text("الشهادة")
				} footer: {
					Text("تُستخدم الشهادة المحددة تلقائيًا لتوقيع كل تطبيق عند التثبيت أو التحديث. يلزم ملف p12 وملف mobileprovision.")
				}
				
				// GitHub
				Section {
					NavigationLink(destination: GitHubAccountView()) {
						HStack {
							SettingsRow(title: "تسجيل الدخول عبر GitHub", systemName: "person.crop.circle.fill", color: .black)
							Spacer()
							if let login = GitHubAccount.shared.login {
								Text("@\(login)").foregroundStyle(.secondary)
							}
						}
					}
				} header: {
					Text("GitHub")
				} footer: {
					Text("لعرض مستودعاتك وتثبيت تطبيقاتها من «مشاريعي».")
				}
				
				// Install & signing defaults
				Section {
					NavigationLink(destination: ConfigurationView()) {
						SettingsRow(title: "خيارات التثبيت الافتراضية", systemName: "slider.horizontal.3", color: .blue)
					}
					NavigationLink(destination: InstallationView()) {
						SettingsRow(title: "طريقة التثبيت", systemName: "arrow.down.app.fill", color: .indigo)
					}
				} header: {
					Text("التثبيت")
				} footer: {
					Text("تُطبَّق الخيارات الافتراضية (الاسم، معرّف الحزمة، الإصدار، الأدوات المحقونة، مشاركة الملفات، إزالة URL Schemes، إزالة تطبيق الساعة، الحد الأدنى لإصدار iOS، الصلاحيات المخصصة، وغيرها) تلقائيًا على كل تثبيت وتحديث. طريقة التثبيت الافتراضية «Semi Local» مناسبة لإصدارات iOS الحديثة.")
				}
				
				// Optional screens
				Section {
					Toggle(isOn: $_showInstallOptions) {
						SettingsRow(title: "إظهار خيارات التثبيت عند تثبيت تطبيق جديد", systemName: "list.bullet.rectangle.fill", color: .orange)
					}
					Toggle(isOn: $_showProcessLog) {
						SettingsRow(title: "إظهار سجل العمليات", systemName: "text.alignright", color: .gray)
					}
				} header: {
					Text("الشاشات الإضافية")
				} footer: {
					Text("عند إيقاف الخيارين، يتم التنزيل والتوقيع والتثبيت بضغطة واحدة في الخلفية دون أي شاشات إضافية. ولا تظهر خيارات التثبيت عند التحديث.")
				}
				
				// Storage
				Section {
					LabeledContent {
						Text(ByteCountFormatter.string(fromByteCount: _usedBytes, countStyle: .file))
					} label: {
						SettingsRow(title: "المساحة المستخدمة", systemName: "internaldrive.fill", color: .gray)
					}
					Toggle(isOn: $_deleteOld) {
						SettingsRow(title: "حذف النسخة السابقة بعد التحديث", systemName: "arrow.triangle.2.circlepath", color: .orange)
					}
					Toggle(isOn: $_deleteFiles) {
						SettingsRow(title: "حذف الملف بعد التثبيت أو التحديث", systemName: "xmark.bin.fill", color: .pink)
					}
					Button(role: .destructive) {
						Task.detached(priority: .userInitiated) {
							StorageCleaner.clearCache()
							await _refreshStorage()
						}
					} label: {
						HStack {
							SettingsRow(title: "مسح الكاش", systemName: "trash.circle.fill", color: .red)
							Spacer()
							Text(ByteCountFormatter.string(fromByteCount: _cacheBytes, countStyle: .file))
								.foregroundStyle(.secondary)
						}
					}
				} header: {
					Text("التخزين")
				} footer: {
					Text("يُحذف تلقائيًا بعد كل تثبيت أو تحديث ملف التنزيل والنسخ القديمة والملفات المؤقتة، وعند تفعيل «حذف النسخة السابقة بعد التحديث» يُحتفظ بآخر نسخة موقّعة فقط. وعند تفعيل «حذف الملف بعد التثبيت أو التحديث» تُحذف ملفات النسخة المثبّتة أيضًا، ويبقى التطبيق في «تطبيقاتي» لمتابعة تحديثاته. لا يحذف «مسح الكاش» التطبيقات ولا الشهادات.")
				}
				
				// About
				Section {
					NavigationLink(destination: AboutView()) {
						HStack(spacing: 12) {
							FRAppIconView(size: 29)
							Text("حول التطبيق")
						}
					}
					NavigationLink(destination: TermsOfUseView()) {
						SettingsRow(title: "سياسة الاستخدام", systemName: "doc.plaintext.fill", color: .teal)
					}
					NavigationLink(destination: PrivacyPolicyView()) {
						SettingsRow(title: "سياسة الخصوصية", systemName: "hand.raised.fill", color: .blue)
					}
				} header: {
					Text("حول")
				} footer: {
					Text("الإصدار \(AppInfo.fullVersion)")
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
	
	private func _refreshStorage() async {
		let used = await Task.detached(priority: .utility) { StorageCleaner.usedBytes() }.value
		let cache = await Task.detached(priority: .utility) { StorageCleaner.cacheBytes() }.value
		await MainActor.run {
			_usedBytes = used
			_cacheBytes = cache
		}
	}
}
