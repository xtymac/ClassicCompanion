import Foundation

/// 更新确认窗口里的“更新内容”：从 appcast 条目的内嵌说明（<description>，签名过的 feed）取出一种语言的那一段，转成纯文本。
///
/// 内嵌说明每种语言一个 `<section lang="…">`（docs/release-notes/<版本>.html，prepare-appcast.sh 用 generate_appcast --embed-release-notes 嵌入，
/// 并检查新条目确实嵌入了说明）。只做简单的标签替换，不用 HTML 引擎、不保留链接：窗口里只显示文字。
public enum ReleaseNotesText {
    /// language 用应用界面语言的标签（en、ja、zh-Hans、zh-Hant）。选中的那一段加上所有段落之外的文字（比如前面的共同说明），
    /// 其他语言的段落去掉。语言标签不分大小写；没有完全相同的就按前缀找（ja-JP 算 ja，zh 算 zh-Hans）；还没有就用英文，再没有用第一段。
    /// 说明里没有分语言的段落时用整段；转完是空的返回 nil。
    public static func plainText(from description: String?, format: String? = nil, language: String) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if let format, format.lowercased() == "plain-text" {
            return tidy(description)
        }
        let html = stripNonText(description)
        let sections = self.sections(in: html)
        guard !sections.isEmpty else { return tidy(render(html)) }
        let chosen = pick(sections.map(\.lang), for: language) ?? 0
        let ns = html as NSString
        var kept = ""
        var last = 0
        for (index, section) in sections.enumerated() {
            kept += ns.substring(with: NSRange(location: last, length: section.range.location - last))
            if index == chosen { kept += section.body }
            last = section.range.location + section.range.length
        }
        kept += ns.substring(from: last)
        return tidy(render(kept))
    }

    /// 选哪一段：完全相同（不分大小写）→ 前缀相同 → 英文。
    static func pick(_ langs: [String], for language: String) -> Int? {
        let wanted = language.lowercased()
        let tags = langs.map { $0.lowercased() }
        if let exact = tags.firstIndex(of: wanted) { return exact }
        if let prefix = tags.firstIndex(where: { $0.hasPrefix(wanted + "-") || wanted.hasPrefix($0 + "-") }) { return prefix }
        return tags.firstIndex(of: "en") ?? tags.firstIndex(where: { $0.hasPrefix("en-") })
    }

    static func sections(in html: String) -> [(lang: String, body: String, range: NSRange)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<section\b[^>]*\blang\s*=\s*["']([^"']+)["'][^>]*>(.*?)</section\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)), $0.range)
        }
    }

    /// 注释、style、script 和 head 的内容不是给人看的文字，先整段去掉。
    static func stripNonText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?s)<!--.*?-->"#, #"(?s)<(style|script|head)\b[^>]*>.*?</\1\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    static func render(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            (#"\s*\n\s*"#, " "),                       // 源码里的换行不算换行
            (#"<li\b[^>]*>"#, "\n• "),
            (#"</(li|p|h[1-6]|ul|ol|div|section)\s*>"#, "\n"),
            (#"<(p|h[1-6]|ul|ol|div|section)\b[^>]*>"#, "\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"<[^>]*>"#, ""),                          // 其余标签（b、a、code……）只留文字
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return decodeEntities(text)
    }

    /// 常见的命名实体（XML 的五个加上编辑器和 Markdown 转换常出的排版符号）和全部数字实体。不认识的原样保留。
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒",
        "times": "×", "divide": "÷", "plusmn": "±", "minus": "−", "deg": "°", "prime": "′",
        "copy": "©", "reg": "®", "trade": "™", "sect": "§", "para": "¶",
        "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            var decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                // 实体名分大小写（rArr 和 rarr 不同）；只有大小写不同的写法（&AMP;）按小写再找一次。
                decoded = namedEntities[name] ?? namedEntities[name.lowercased()]
            }
            result += decoded ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// 每行去掉首尾空白（包括不换行空格），去掉空行。
    static func tidy(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
