//
//  GitHubAccount.swift
//  Muthabbit
//
//  GitHub sign-in (OAuth Device Flow, no client secret), token in Keychain,
//  and "مشاريعي": the signed-in user's repositories whose releases contain IPA files,
//  exposed as an in-memory AltStore-style repository so the regular store,
//  one-tap install and update tracking can be reused.
//

import Foundation
import Security
import SwiftUI
import AltSourceKit

// MARK: - Keychain
enum KeychainStore {
	private static let _service = "com.za7ef.muthabbit.github"
	
	static func set(_ value: String?, for account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: _service,
			kSecAttrAccount as String: account
		]
		SecItemDelete(query as CFDictionary)
		guard let value, let data = value.data(using: .utf8) else { return }
		var add = query
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		SecItemAdd(add as CFDictionary, nil)
	}
	
	static func get(_ account: String) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: _service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var result: AnyObject?
		guard
			SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
			let data = result as? Data
		else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

// MARK: - Account
@MainActor
final class GitHubAccount: ObservableObject {
	static let shared = GitHubAccount()
	
	/// Public OAuth App client id (Device Flow enabled). No secret is needed for Device Flow.
	static let clientID = "Ov23liLxKkKt6bSxtRp9"
	/// Pseudo source URL used to tag apps installed from "مشاريعي".
	static let projectsSourceURL = URL(string: "https://github.com/muthabbit-projects")!
	
	struct DeviceCode {
		let userCode: String
		let verificationURL: URL
	}
	
	@Published private(set) var login: String?
	@Published private(set) var deviceCode: DeviceCode?
	@Published private(set) var isSigningIn = false
	@Published private(set) var errorMessage: String?
	
	@Published private(set) var projects: ASRepository?
	@Published private(set) var isLoadingProjects = false
	
	private var _signInTask: Task<Void, Never>?
	
	var token: String? { KeychainStore.get("token") }
	var isSignedIn: Bool { token != nil }
	
	private init() {
		login = UserDefaults.standard.string(forKey: "Muthabbit.githubLogin")
		if token == nil { login = nil }
	}
	
	// MARK: Device Flow
	
	func startSignIn() {
		_signInTask?.cancel()
		errorMessage = nil
		isSigningIn = true
		_signInTask = Task { [weak self] in
			await self?._runDeviceFlow()
		}
	}
	
	func cancelSignIn() {
		_signInTask?.cancel()
		_signInTask = nil
		deviceCode = nil
		isSigningIn = false
	}
	
	func signOut() {
		KeychainStore.set(nil, for: "token")
		UserDefaults.standard.removeObject(forKey: "Muthabbit.githubLogin")
		login = nil
		projects = nil
	}
	
	private func _runDeviceFlow() async {
		defer {
			isSigningIn = false
			deviceCode = nil
		}
		do {
			let start = try await _postForm(
				"https://github.com/login/device/code",
				["client_id": Self.clientID, "scope": "repo"]
			)
			guard
				let device = start["device_code"] as? String,
				let user = start["user_code"] as? String,
				let uriString = start["verification_uri"] as? String,
				let uri = URL(string: uriString)
			else {
				throw _error(start["error_description"] as? String ?? "تعذّر بدء تسجيل الدخول.")
			}
			var interval = max(5, start["interval"] as? Int ?? 5)
			let expiresIn = start["expires_in"] as? Int ?? 900
			
			deviceCode = DeviceCode(userCode: user, verificationURL: uri)
			UIPasteboard.general.string = user
			await UIApplication.shared.open(uri)
			
			let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
			while Date() < deadline {
				try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
				let poll = try await _postForm(
					"https://github.com/login/oauth/access_token",
					[
						"client_id": Self.clientID,
						"device_code": device,
						"grant_type": "urn:ietf:params:oauth:grant-type:device_code"
					]
				)
				if let token = poll["access_token"] as? String {
					KeychainStore.set(token, for: "token")
					try await _loadUser()
					await loadProjects()
					return
				}
				switch poll["error"] as? String {
				case "authorization_pending": continue
				case "slow_down": interval += 5
				case "expired_token": throw _error("انتهت صلاحية الرمز. يلزم البدء من جديد.")
				case "access_denied": throw _error("أُلغي تسجيل الدخول.")
				default: throw _error(poll["error_description"] as? String ?? "تعذّر تسجيل الدخول.")
				}
			}
			throw _error("انتهت صلاحية الرمز. يلزم البدء من جديد.")
		} catch is CancellationError {
		} catch {
			errorMessage = error.localizedDescription
		}
	}
	
	private func _loadUser() async throws {
		let user = try await api("user") as? [String: Any]
		login = user?["login"] as? String
		UserDefaults.standard.set(login, forKey: "Muthabbit.githubLogin")
	}
	
	// MARK: Projects
	
	func loadProjects() async {
		guard isSignedIn, !isLoadingProjects else { return }
		isLoadingProjects = true
		defer { isLoadingProjects = false }
		
		do {
			let repos = (try await api("user/repos?per_page=100&sort=updated&affiliation=owner,collaborator")) as? [[String: Any]] ?? []
			var apps: [[String: Any]] = []
			
			try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
				for repo in repos {
					guard let fullName = repo["full_name"] as? String else { continue }
					let name = repo["name"] as? String ?? fullName
					let description = repo["description"] as? String
					let avatar = (repo["owner"] as? [String: Any])?["avatar_url"] as? String
					group.addTask {
						await Self._appEntry(fullName: fullName, name: name, description: description, avatar: avatar)
					}
				}
				for try await entry in group {
					if let entry { apps.append(entry) }
				}
			}
			
			apps.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
			let json: [String: Any] = [
				"name": "مشاريعي",
				"identifier": "com.za7ef.muthabbit.projects",
				"subtitle": "مستودعات GitHub",
				"apps": apps
			]
			let data = try JSONSerialization.data(withJSONObject: json)
			projects = try JSONDecoder().decode(ASRepository.self, from: data)
		} catch {
			errorMessage = error.localizedDescription
		}
	}
	
	/// Builds one AltStore-style app entry from a repository's releases (nil when no IPA).
	nonisolated private static func _appEntry(
		fullName: String,
		name: String,
		description: String?,
		avatar: String?
	) async -> [String: Any]? {
		guard
			let releases = try? await GitHubAccount.apiStatic("repos/\(fullName)/releases?per_page=30") as? [[String: Any]]
		else { return nil }
		
		var versions: [[String: Any]] = []
		for release in releases where (release["draft"] as? Bool) != true {
			let assets = release["assets"] as? [[String: Any]] ?? []
			guard
				let ipa = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }),
				let assetURL = ipa["url"] as? String
			else { continue }
			
			let tag = release["tag_name"] as? String ?? "0"
			let parsed = _parseTag(tag)
			var version: [String: Any] = [
				"version": parsed.version,
				"downloadURL": assetURL,
				"size": ipa["size"] as? Int ?? 0,
				"localizedDescription": ((release["body"] as? String) ?? (release["name"] as? String) ?? tag),
				"prerelease": (release["prerelease"] as? Bool) ?? false
			]
			if let build = parsed.build { version["buildVersion"] = build }
			if let date = release["published_at"] as? String { version["date"] = date }
			versions.append(version)
		}
		guard let latest = versions.first(where: { ($0["prerelease"] as? Bool) != true }) ?? versions.first else {
			return nil
		}
		
		var app: [String: Any] = [
			"name": name,
			"bundleIdentifier": "github.\(fullName)",
			"developerName": fullName.components(separatedBy: "/").first ?? "",
			"subtitle": description ?? fullName,
			"localizedDescription": description ?? fullName,
			"version": latest["version"] ?? "1.0",
			"downloadURL": latest["downloadURL"] ?? "",
			"versions": versions
		]
		if let avatar { app["iconURL"] = avatar }
		return app
	}
	
	/// "v1.2.0-b14" → ("1.2.0", "14"); "v1.2.0" → ("1.2.0", nil)
	nonisolated private static func _parseTag(_ tag: String) -> (version: String, build: String?) {
		var t = tag
		if t.lowercased().hasPrefix("v") { t.removeFirst() }
		if let range = t.range(of: #"-b(\d+)$"#, options: .regularExpression) {
			let build = String(t[range].dropFirst(2))
			return (String(t[..<range.lowerBound]), build)
		}
		return (t, nil)
	}
	
	// MARK: Networking
	
	func api(_ path: String) async throws -> Any {
		try await Self.apiStatic(path)
	}
	
	nonisolated static func apiStatic(_ path: String) async throws -> Any {
		guard let token = KeychainStore.get("token") else { throw _staticError("يلزم تسجيل الدخول.") }
		var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
		request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode == 401 {
			throw _staticError("انتهت صلاحية تسجيل الدخول. يلزم تسجيل الدخول مجددًا.")
		}
		return try JSONSerialization.jsonObject(with: data)
	}
	
	/// Authenticated request for downloading a release asset (private repos supported).
	nonisolated static func downloadRequest(for url: URL) -> URLRequest {
		var request = URLRequest(url: url)
		if url.host == "api.github.com", let token = KeychainStore.get("token") {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
		}
		return request
	}
	
	private func _postForm(_ urlString: String, _ form: [String: String]) async throws -> [String: Any] {
		var request = URLRequest(url: URL(string: urlString)!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		var components = URLComponents()
		components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
		request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
		let (data, _) = try await URLSession.shared.data(for: request)
		return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
	}
	
	private func _error(_ message: String) -> NSError {
		Self._staticError(message)
	}
	
	nonisolated private static func _staticError(_ message: String) -> NSError {
		NSError(domain: "Muthabbit.GitHub", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
	}
}

// MARK: - Views
struct GitHubAccountView: View {
	@ObservedObject private var account = GitHubAccount.shared
	
	var body: some View {
		Form {
			if let login = account.login {
				Section {
					LabeledContent("الحساب", value: "@\(login)")
					Button("تسجيل الخروج", role: .destructive) {
						account.signOut()
					}
				} footer: {
					Text("يُحفظ رمز الدخول في سلسلة المفاتيح على هذا الجهاز فقط.")
				}
			} else {
				Section {
					if let code = account.deviceCode {
						VStack(alignment: .leading, spacing: 8) {
							Text("رمز التحقق")
								.font(.footnote)
								.foregroundStyle(.secondary)
							Text(code.userCode)
								.font(.system(.title, design: .monospaced).bold())
								.textSelection(.enabled)
							Text("نُسخ الرمز تلقائيًا. يُلصق في صفحة GitHub التي فُتحت ثم يُضغط «Authorize».")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
						Button("فتح صفحة GitHub") {
							UIApplication.shared.open(code.verificationURL)
						}
						Button("إلغاء", role: .cancel) {
							account.cancelSignIn()
						}
					} else {
						Button {
							account.startSignIn()
						} label: {
							HStack {
								Text("تسجيل الدخول عبر GitHub")
								if account.isSigningIn {
									Spacer()
									ProgressView()
								}
							}
						}
						.disabled(account.isSigningIn)
					}
				} footer: {
					Text("يتيح تسجيل الدخول عرض مستودعاتك، بما فيها الخاصة، التي تحتوي إصداراتها على ملفات IPA، وتثبيتها ومتابعة تحديثاتها من «مشاريعي». الصلاحية المطلوبة: repo.")
				}
			}
			
			if let error = account.errorMessage {
				Section {
					Text(error)
						.foregroundStyle(.red)
						.font(.footnote)
				}
			}
		}
		.navigationTitle("GitHub")
	}
}

struct MyProjectsView: View {
	@ObservedObject private var account = GitHubAccount.shared
	
	var body: some View {
		Group {
			if let repo = account.projects, !repo.apps.isEmpty {
				List {
					ForEach(repo.apps, id: \.currentUniqueId) { app in
						NavigationLink {
							SourceAppsDetailView(sourceURL: GitHubAccount.projectsSourceURL, source: repo, app: app)
						} label: {
							HStack(spacing: 12) {
								FRIconCellView(
									title: app.currentName,
									subtitle: (app.currentVersion ?? "") + ((app.currentAppVersion?.isBeta ?? false) ? " · تجريبي" : ""),
									iconUrl: app.iconURL
								)
								Spacer()
								DownloadButtonView(sourceURL: GitHubAccount.projectsSourceURL, source: repo, app: app)
							}
						}
					}
				}
			} else if account.isLoadingProjects {
				ProgressView()
			} else if #available(iOS 17, *) {
				ContentUnavailableView(
					"لا توجد مشاريع",
					systemImage: "shippingbox",
					description: Text(account.isSignedIn
						? "لم يُعثر على مستودعات تحتوي إصداراتها على ملفات IPA."
						: "يلزم تسجيل الدخول عبر GitHub من الإعدادات.")
				)
			}
		}
		.navigationTitle("مشاريعي")
		.refreshable { await account.loadProjects() }
		.task { if account.projects == nil { await account.loadProjects() } }
	}
}
