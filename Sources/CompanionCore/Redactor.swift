import Foundation

/// 日志脱敏：只保留 host 与路径类别，不记录对话 ID、query、fragment。
public enum Redactor {
    public static func describe(_ url: URL?) -> String {
        guard let url else { return "<nil>" }
        guard let scheme = url.scheme else { return "<invalid>" }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return "\(scheme):<…>" }
        let host = url.host ?? "<no-host>"
        let parts = url.path.split(separator: "/")
        let kind: String
        if parts.isEmpty {
            kind = "/"
        } else if parts.first == "c" {
            kind = "/c/<id>"
        } else if parts.first == "g" {
            kind = parts.contains("c") ? "/g/<gpt>/c/<id>" : "/g/<gpt>"
        } else {
            // 只保留第一段路径，其余省略
            kind = "/\(parts[0])/…"
        }
        let q = (url.query?.isEmpty == false) ? "?<redacted>" : ""
        return "\(scheme)://\(host)\(kind)\(q)"
    }
}
