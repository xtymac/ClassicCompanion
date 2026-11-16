import Foundation
import Testing
@testable import CompanionCore

/// 更新确认窗口里的“更新内容”：只显示应用语言那一段，转成纯文本。
@Suite struct ReleaseNotesTextTests {
    let sample = """
    <section lang="en">
    <h3>What’s new</h3>
    <ul>
    <li>New setting: <b>Window Mode</b> &amp; more.</li>
    <li>Second
      line</li>
    </ul>
    <p>Known limitation: one.</p>
    </section>
    <section lang="zh-Hans">
    <h3>新功能</h3>
    <ul>
    <li>新设置：<b>唤醒时窗口模式</b>。</li>
    </ul>
    </section>
    """

    @Test func picksTheSectionForTheAppLanguage() {
        #expect(ReleaseNotesText.plainText(from: sample, language: "zh-Hans") == "新功能\n• 新设置：唤醒时窗口模式。")
    }

    @Test func englishSectionIsTheFallback() {
        let english = "What’s new\n• New setting: Window Mode & more.\n• Second line\nKnown limitation: one."
        #expect(ReleaseNotesText.plainText(from: sample, language: "en") == english)
        #expect(ReleaseNotesText.plainText(from: sample, language: "ja") == english, "没有日文段落时用英文")
    }

    @Test func descriptionWithoutSectionsIsUsedWhole() {
        #expect(ReleaseNotesText.plainText(from: "<ul><li>One &lt;two&gt;</li><li>&#x4E09;&#22235;</li></ul>", language: "ja") == "• One <two>\n• 三四")
        #expect(ReleaseNotesText.plainText(from: "  line one\n\n line two ", format: "plain-text", language: "en") == "line one\nline two")
    }

    @Test func emptyNotesGiveNil() {
        #expect(ReleaseNotesText.plainText(from: nil, language: "en") == nil)
        #expect(ReleaseNotesText.plainText(from: "", language: "en") == nil)
        #expect(ReleaseNotesText.plainText(from: "<section lang=\"en\"> <ul></ul> </section>", language: "en") == nil)
    }

    /// 实际的 beta.3 说明：四种语言各取到自己那一段，没有剩下的标签或实体。
    @Test func realReleaseNotesSplitByLanguage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/release-notes/0.1.0-beta.3.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let first: [String: String] = ["en": "What’s new", "zh-Hans": "新功能", "zh-Hant": "新功能", "ja": "新機能"]
        var texts: Set<String> = []
        for (language, heading) in first {
            let text = try #require(ReleaseNotesText.plainText(from: html, language: language), "\(language)")
            #expect(text.hasPrefix(heading), "\(language)：\(text.prefix(40))")
            #expect(text.contains("\n• "), "\(language)：要有列表项")
            #expect(!text.contains("<") && !text.contains(">") && !text.contains("&amp;"), "\(language)：不留标签和实体")
            texts.insert(text)
        }
        #expect(texts.count == 4, "四种语言各不相同")
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hans")?.contains("唤醒时窗口模式") == true)
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hans")?.contains("Window Mode") == false)
    }
}
