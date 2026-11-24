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

    /// 语言标签不分大小写，也认前缀（ja-JP、zh）；都不匹配时用英文。
    @Test func languageTagsMatchLoosely() {
        let html = #"<section lang="ZH-hans"><p>简体</p></section><section lang="ja-JP"><p>日本語</p></section><section lang="zh"><p>中文</p></section><section lang="EN"><p>English</p></section>"#
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hans") == "简体")
        #expect(ReleaseNotesText.plainText(from: html, language: "ja") == "日本語")
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hant") == "中文")
        #expect(ReleaseNotesText.plainText(from: html, language: "ko") == "English")
        #expect(ReleaseNotesText.plainText(from: #"<section lang="de"><p>Deutsch</p></section><section lang="fr"><p>Français</p></section>"#,
                                           language: "ja") == "Deutsch", "没有英文时用第一段")
    }

    /// 段落之外的文字（共同说明）保留，位置不变；其他语言的段落去掉。
    @Test func textOutsideSectionsIsKept() {
        let html = #"<p><b>Security notice</b> for everyone.</p><section lang="en"><p>English</p></section><section lang="ja"><p>日本語</p></section><p>Footer</p>"#
        #expect(ReleaseNotesText.plainText(from: html, language: "ja") == "Security notice for everyone.\n日本語\nFooter")
        #expect(ReleaseNotesText.plainText(from: html, language: "en") == "Security notice for everyone.\nEnglish\nFooter")
    }

    /// 注释、style、script 不显示成文字。
    @Test func commentsStylesAndScriptsAreDropped() {
        let html = "<style>\nul{margin:0}\n</style><!-- if a > b\n --><ul><li>One</li></ul><script>alert(1)</script><!--x-->"
        #expect(ReleaseNotesText.plainText(from: html, language: "en") == "• One")
    }

    /// 编辑器和 Markdown 转换常出的排版实体也解码；不认识的原样保留。
    @Test func typographicEntitiesAreDecoded() {
        let html = "<p>What&rsquo;s new &mdash; Settings &rarr; General&hellip; &ldquo;A&rdquo; &copy; &AMP; &unknownthing;</p>"
        #expect(ReleaseNotesText.plainText(from: html, language: "en") == "What’s new — Settings → General… “A” © & &unknownthing;")
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
            #expect(!text.contains("<") && !text.contains(">"), "\(language)：不留标签")
            #expect(text.range(of: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#, options: .regularExpression) == nil,
                    "\(language)：不留实体")
            texts.insert(text)
        }
        #expect(texts.count == 4, "四种语言各不相同")
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hans")?.contains("唤醒时窗口模式") == true)
        #expect(ReleaseNotesText.plainText(from: html, language: "zh-Hans")?.contains("Window Mode") == false)
    }

    /// 实际的 beta.4 说明：四种语言各取到自己那一段，各自提到应用名，没有剩下的标签或实体。
    @Test func betaFourReleaseNotesSplitByLanguage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/release-notes/0.1.0-beta.4.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let first: [String: String] = ["en": "What’s new", "zh-Hans": "新功能", "zh-Hant": "新功能", "ja": "新機能"]
        var texts: Set<String> = []
        for (language, heading) in first {
            let text = try #require(ReleaseNotesText.plainText(from: html, language: language), "\(language)")
            #expect(text.hasPrefix(heading), "\(language)：\(text.prefix(40))")
            #expect(text.contains("\n• "), "\(language)：要有列表项")
            #expect(text.contains("Classic Companion"), "\(language)：提到窗口顶部的应用名")
            #expect(!text.contains("<") && !text.contains(">"), "\(language)：不留标签")
            #expect(text.range(of: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#, options: .regularExpression) == nil,
                    "\(language)：不留实体")
            texts.insert(text)
        }
        #expect(texts.count == 4, "四种语言各不相同")
    }

    /// 实际的 beta.5 说明：四种语言各取到自己那一段，两个小标题、标签页和后退的快捷键、内存说明都在，没有剩下的标签或实体。
    @Test func betaFiveReleaseNotesSplitByLanguage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/release-notes/0.1.0-beta.5.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let headings: [String: (String, String)] = ["en": ("What’s new", "Improvements"), "zh-Hans": ("新功能", "改进"),
                                                    "zh-Hant": ("新功能", "改進"), "ja": ("新機能", "改善")]
        var texts: Set<String> = []
        for (language, (first, second)) in headings {
            let text = try #require(ReleaseNotesText.plainText(from: html, language: language), "\(language)")
            #expect(text.hasPrefix(first), "\(language)：\(text.prefix(40))")
            #expect(text.contains("\n\(second)\n"), "\(language)：第二个小标题")
            #expect(text.contains("\n• "), "\(language)：要有列表项")
            for needle in ["⌘T", "⌘[", "700 MB"] {
                #expect(text.contains(needle), "\(language)：提到 \(needle)")
            }
            #expect(!text.contains("<") && !text.contains(">"), "\(language)：不留标签")
            #expect(text.range(of: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#, options: .regularExpression) == nil,
                    "\(language)：不留实体")
            texts.insert(text)
        }
        #expect(texts.count == 4, "四种语言各不相同")
    }
}
