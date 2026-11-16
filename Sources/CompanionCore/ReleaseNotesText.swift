import Foundation

/// 更新确认窗口里的“更新内容”：从 appcast 条目的内嵌说明（<description>，签名过的 feed）取出一种语言的那一段，转成纯文本。
///
/// 内嵌说明每种语言一个 `<section lang="…">`（docs/release-notes/<版本>.html，prepare-appcast.sh 用 generate_appcast --embed-release-notes 嵌入）。
/// 只做简单的标签替换，不用 HTML 引擎、不保留链接：窗口里只显示文字。
public enum ReleaseNotesText {
    /// language 用应用界面语言的标签（en、ja、zh-Hans、zh-Hant）。没有这种语言就用英文；
    /// 说明里没有分语言的段落时用整段；转完是空的返回 nil。
    public static func plainText(from description: String?, format: String? = nil, language: String) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if let format, format.lowercased() == "plain-text" {
            return tidy(description)
        }
        let sections = self.sections(in: description)
        let body: String
        if sections.isEmpty {
            body = description
        } else if let match = sections.first(where: { $0.lang == language }) ?? sections.first(where: { $0.lang == "en" }) {
            body = match.body
        } else {
            body = sections[0].body
        }
        return tidy(render(body))
    }

    static func sections(in html: String) -> [(lang: String, body: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<section\b[^>]*\blang\s*=\s*["']([^"']+)["'][^>]*>(.*?)</section\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func render(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            (#"\s*\n\s*"#, " "),                       // 源码里的换行不算换行
            (#"<li\b[^>]*>"#, "\n• "),
            (#"</(li|p|h[1-6]|ul|ol|div)\s*>"#, "\n"),
            (#"<(p|h[1-6]|ul|ol|div)\b[^>]*>"#, "\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"<[^>]*>"#, ""),                          // 其余标签（b、a、code……）只留文字
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        guard let regex = try? NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#) else { return text }
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
                decoded = named[name.lowercased()]
            }
            result += decoded ?? ns.substring(with: match.range)
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// 每行去掉首尾空白，去掉空行。
    static func tidy(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
