//
//  ReadmeImages.swift
//  Muthabbit
//
//  Preview images from a GitHub repo's README, for sources without screenshotURLs.
//

import Foundation

enum ReadmeImages {
	private static var _cache: [String: [URL]] = [:]
	private static let _lock = NSLock()
	
	static func images(for githubURL: URL) async -> [URL] {
		let parts = githubURL.pathComponents.filter { $0 != "/" }
		guard githubURL.host?.contains("github.com") == true, parts.count >= 2 else { return [] }
		let repo = parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
		_lock.lock(); let cached = _cache[repo]; _lock.unlock()
		if let cached { return cached }
		let diskKey = "Muthabbit.readmeImages." + repo
		if let saved = UserDefaults.standard.stringArray(forKey: diskKey) {
			let urls = saved.compactMap(URL.init(string:))
			_lock.lock(); _cache[repo] = urls; _lock.unlock()
			return urls
		}
		
		guard let api = URL(string: "https://api.github.com/repos/\(repo)/readme") else { return [] }
		var req = URLRequest(url: api, timeoutInterval: 15)
		req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
		guard
			let (data, resp) = try? await URLSession.shared.data(for: req),
			(resp as? HTTPURLResponse)?.statusCode == 200,
			let text = String(data: data, encoding: .utf8)
		else { return [] }
		
		let patterns = [#"!\[[^\]]*\]\(\s*<?([^)\s>]+)"#, #"<img[^>]+src\s*=\s*["']([^"']+)["']"#]
		var found: [String] = []
		for p in patterns {
			guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
			let ns = text as NSString
			for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
				found.append(ns.substring(with: m.range(at: 1)))
			}
		}
		let base = URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/")!
		var seen = Set<String>()
		let urls: [URL] = found.compactMap { raw -> URL? in
			let lower = raw.lowercased()
			let skip = ["shields.io", "badge", ".svg", "img.shields", "badgen", "buymeacoffee", "ko-fi", "paypal", "sponsor", "star-history", "contrib.rocks", "visitor", "logo", "icon", "avatar"]
			if skip.contains(where: lower.contains) { return nil }
			var url: URL?
			if raw.hasPrefix("http") {
				url = URL(string: raw)
			} else {
				url = URL(string: raw.hasPrefix("/") ? String(raw.dropFirst()) : raw, relativeTo: base)?.absoluteURL
			}
			// github.com/.../blob/... → raw
			if let u = url, u.host == "github.com", u.path.contains("/blob/") {
				url = URL(string: u.absoluteString.replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com").replacingOccurrences(of: "/blob/", with: "/"))
			}
			guard let u = url, !seen.contains(u.absoluteString) else { return nil }
			seen.insert(u.absoluteString)
			return u
		}
		let result = Array(urls.prefix(10))
		_lock.lock(); _cache[repo] = result; _lock.unlock()
		UserDefaults.standard.set(result.map(\.absoluteString), forKey: diskKey)
		return result
	}
}
