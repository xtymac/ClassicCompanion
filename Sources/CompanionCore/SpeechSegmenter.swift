import Foundation
import NaturalLanguage

/// 从网页适配器得到的回答块。`notice` 表示被跳过的内容提示（例如“代码块已跳过”）。
public struct AnswerBlock: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case text, notice }
    public var kind: Kind
    public var text: String
    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// 交给 TTS 的一个片段：单一语言、长度受限。
public struct SpeechSegment: Equatable, Sendable {
    public var text: String
    /// BCP-47，例如 zh-CN / ja-JP / en-US
    public var language: String
    public var isNotice: Bool
}

public enum SpeechSegmenter {
    /// 单个片段的最大字符数。较短片段让暂停/语速变化更及时，也降低单次合成失败的影响。
    public static let maxSegmentLength = 220

    public static func segments(from blocks: [AnswerBlock], fallbackLanguage: String = "zh-CN") -> [SpeechSegment] {
        var result: [SpeechSegment] = []
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if block.kind == .notice {
                result.append(SpeechSegment(text: trimmed, language: "zh-CN", isNotice: true))
                continue
            }
            for piece in split(trimmed, limit: maxSegmentLength) {
                let lang = detectLanguage(piece) ?? fallbackLanguage
                result.append(SpeechSegment(text: piece, language: lang, isNotice: false))
            }
        }
        return result
    }

    /// 语言判定：含假名 → 日语；含汉字 → 中文；否则交给 NLLanguageRecognizer。
    public static func detectLanguage(_ text: String) -> String? {
        var hasKana = false, hasHan = false, hasHangul = false, letters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: hasKana = true
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: hasHan = true
            case 0xAC00...0xD7AF: hasHangul = true
            default:
                if CharacterSet.letters.contains(scalar) { letters += 1 }
            }
        }
        if hasKana { return "ja-JP" }
        if hasHan { return "zh-CN" }
        if hasHangul { return "ko-KR" }
        guard letters > 0 else { return nil }
        // 拉丁字母短文本误判较多：限制候选语言，置信度不足时按英语处理
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .french, .german, .spanish, .italian, .portuguese]
        recognizer.languageHints = [.english: 0.9]
        recognizer.processString(text)
        guard let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first,
              lang != .english, p >= 0.8 else { return "en-US" }
        return lang.rawValue
    }

    /// 先按换行，再按句末标点切分；超长句再硬切。
    static func split(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.count <= limit { out.append(line); continue }
            var current = ""
            for sentence in sentences(line) {
                if current.count + sentence.count > limit, !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                if sentence.count > limit {
                    out.append(contentsOf: hardSplit(sentence, limit: limit))
                } else {
                    current += sentence
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", ".", "；", ";", "…"]
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if terminators.contains(ch) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func hardSplit(_ text: String, limit: Int) -> [String] {
        var result: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[idx..<end]))
            idx = end
        }
        return result
    }
}

/// 语速档位。AVSpeechSynthesizer 只有相对语速参数（0…1），无法保证精确倍速，
/// 因此 UI 只显示档位名称，不显示“1.5×”之类未经校准的倍率。
public enum SpeechRateLevel: Int, CaseIterable, Sendable, Codable {
    case slower = 0, normal, faster1, faster2, faster3, fastest

    public var label: String {
        switch self {
        case .slower: "较慢"
        case .normal: "标准"
        case .faster1: "稍快"
        case .faster2: "快"
        case .faster3: "较快"
        case .fastest: "最快"
        }
    }

    /// 映射到 AVSpeechUtterance.rate（系统默认值为 0.5）。
    public var utteranceRate: Float {
        switch self {
        case .slower: 0.42
        case .normal: 0.50
        case .faster1: 0.55
        case .faster2: 0.60
        case .faster3: 0.65
        case .fastest: 0.70
        }
    }
}
