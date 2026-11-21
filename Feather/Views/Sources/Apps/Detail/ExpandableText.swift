//
//  ExpandableText.swift
//  Feather
//
//  Created by samsam on 7/26/25.
//
//  Modified by za7ef, 2026.
//  Copyright © 2026 za7ef. Licensed under GPL-3.0.
//


import SwiftUI

struct ExpandableText: View {
	let text: String
	let lineLimit: Int

	@State private var expanded: Bool = false
	
	/// Source texts are often Markdown (release notes). Headings become bold lines, list markers
	/// become bullets, and inline **bold**/*italic*/`code`/links are rendered. Plain text is unchanged.
	private var _rendered: AttributedString {
		var result = AttributedString()
		let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
		for (index, rawLine) in lines.enumerated() {
			var line = rawLine.trimmingCharacters(in: .whitespaces)
			var isHeading = false
			if line.hasPrefix("#") {
				line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
				isHeading = true
			} else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
				line = "• " + line.dropFirst(2)
			} else if line == "---" || line == "***" {
				line = ""
			}
			var part = (try? AttributedString(
				markdown: line,
				options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
			)) ?? AttributedString(line)
			if isHeading {
				part.font = .body.bold()
			}
			result += part
			if index < lines.count - 1 { result += AttributedString("\n") }
		}
		return result
	}
	@State private var truncated: Bool = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(_rendered)
				.lineLimit(expanded ? nil : lineLimit)
				.background(
					Text(_rendered)
						.lineLimit(lineLimit)
						.background(GeometryReader { proxy in
							Color.clear
								.onAppear {
									let totalHeight = proxy.size.height
									let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
									truncated = totalHeight > lineHeight * CGFloat(lineLimit)
								}
						})
						.hidden()
				)
				.onTapGesture {pGesture in
					withAnimation {
						expanded.toggle()
					}
				}

			if truncated {
				Button(action: {
					withAnimation {
						expanded.toggle()
					}
				}) {
					Text(expanded ? .localized("Less") : .localized("More"))
						.font(.caption)
						.foregroundColor(.accentColor)
				}
			}
		}
	}
}

