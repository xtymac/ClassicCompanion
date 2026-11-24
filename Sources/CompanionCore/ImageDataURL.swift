import Foundation

/// 解析 `data:image/...` 地址。WebKit 不允许把 data: 地址作为顶层页面打开（WebKitErrorDomain 102），
/// 右键“在新窗口中打开图像”遇到内嵌图片时弹窗一片空白（2026-11-24），所以由应用自己取出图片数据来显示。
public enum ImageDataURL {
    public struct Payload: Equatable, Sendable {
        public let mimeType: String
        public let data: Data
    }

    /// 只接受 image/* 类型；其他 data: 地址返回 nil。
    public static func decode(_ url: URL?) -> Payload? {
        guard let text = url?.absoluteString, text.lowercased().hasPrefix("data:"),
              let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        let parts = header.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mime = parts.first?.lowercased(), mime.hasPrefix("image/"), mime.count > 6 else { return nil }
        let body = String(text[text.index(after: comma)...])
        guard let unescaped = body.removingPercentEncoding else { return nil }
        let data: Data?
        if parts.dropFirst().contains(where: { $0.lowercased() == "base64" }) {
            data = Data(base64Encoded: unescaped, options: .ignoreUnknownCharacters)
        } else {
            data = unescaped.data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        return Payload(mimeType: mime, data: data)
    }
}
