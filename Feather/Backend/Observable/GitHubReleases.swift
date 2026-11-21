//
//  GitHubReleases.swift
//  Muthabbit
//
//  Versions from a GitHub repo's releases (.ipa assets) and the repo description,
//  for source apps that link a GitHub repo. Cached for an hour.
//

import Foundation
import AltSourceKit

enum GitHubReleases {
	private static var _versions: [String: (Date, [ASRepository.App.Version])] = [:]
	private static var _descriptions: [String: String] = [:]
	private static let _lock = NSLock()
	
	static func repoPath(_ url: URL) -> String? {
		let parts = url.pathComponents.filter { $0 != "/" }
		guard url.host?.contains("github.com") == true, parts.count >= 2 else { return nil }
		return parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
	}
	
	private static func _get(_ path: String) async -> Any? {
		guard let url = URL(string: "https://api.github.com/" + path) else { return nil }
		var req = URLRequest(url: url, timeoutInterval: 20)
		req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		// Signed-in token raises the rate limit (60 → 5000 requests/hour).
		if let token = KeychainStore.get("token") {
			req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		guard
			let (data, resp) = try? await URLSession.shared.data(for: req),
			(resp as? HTTPURLResponse)?.statusCode == 200
		else { return nil }
		return try? JSONSerialization.jsonObject(with: data)
	}
	
	static func versions(for repoURL: URL) async -> [ASRepository.App.Version] {
		guard let repo = repoPath(repoURL) else { return [] }
		_lock.lock(); let cached = _versions[repo]; _lock.unlock()
		if let cached, Date().timeIntervalSince(cached.0) < 3600 { return cached.1 }
		
		var dicts: [[String: Any]] = []
		for page in 1...3 {
			guard let releases = await _get("repos/\(repo)/releases?per_page=100&page=\(page)") as? [[String: Any]] else { break }
			for release in releases where (release["draft"] as? Bool) != true {
				let tag = release["tag_name"] as? String ?? ""
				var version = tag
				if version.lowercased().hasPrefix("v") { version.removeFirst() }
				let assets = (release["assets"] as? [[String: Any]] ?? []).filter {
					let n = ($0["name"] as? String ?? "").lowercased()
					return n.hasSuffix(".ipa") || n.hasSuffix(".tipa")
				}
				for (i, asset) in assets.enumerated() {
					guard let dl = asset["browser_download_url"] as? String else { continue }
					var d: [String: Any] = [
						"version": assets.count > 1 ? "\(version) · \(asset["name"] as? String ?? "")" : version,
						"downloadURL": dl,
						"size": asset["size"] as? Int ?? 0,
						"localizedDescription": (release["body"] as? String) ?? (release["name"] as? String) ?? tag,
						"prerelease": (release["prerelease"] as? Bool) ?? false
					]
					if let date = release["published_at"] as? String { d["date"] = date }
					_ = i
					dicts.append(d)
				}
			}
			if releases.count < 100 { break }
		}
		var result: [ASRepository.App.Version] = []
		if
			let data = try? JSONSerialization.data(withJSONObject: dicts),
			let decoded = try? JSONDecoder().decode([ASRepository.App.Version].self, from: data)
		{
			result = decoded
		}
		_lock.lock(); _versions[repo] = (Date(), result); _lock.unlock()
		return result
	}
	
	/// Repo "about" text, or the first README paragraph when there is none.
	static func description(for repoURL: URL) async -> String? {
		guard let repo = repoPath(repoURL) else { return nil }
		_lock.lock(); let cached = _descriptions[repo]; _lock.unlock()
		if let cached { return cached }
		var text = (await _get("repos/\(repo)") as? [String: Any])?["description"] as? String
		if text?.isEmpty ?? true, let api = URL(string: "https://api.github.com/repos/\(repo)/readme") {
			var req = URLRequest(url: api, timeoutInterval: 15)
			req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
			if let token = KeychainStore.get("token") { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
			if let (data, _) = try? await URLSession.shared.data(for: req), let md = String(data: data, encoding: .utf8) {
				// First prose paragraph: skip headings, images, badges, HTML and links-only lines.
				text = md.components(separatedBy: "\n\n")
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.first { p in
						!p.isEmpty && !p.hasPrefix("#") && !p.hasPrefix("!") && !p.hasPrefix("<") && !p.hasPrefix("[") && !p.hasPrefix("|") && !p.hasPrefix("```") && p.count > 30
					}
					.map { String($0.prefix(600)) }
			}
		}
		if let text, !text.isEmpty {
			_lock.lock(); _descriptions[repo] = text; _lock.unlock()
		}
		return text
	}
}
