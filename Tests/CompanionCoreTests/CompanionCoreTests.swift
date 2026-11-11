import Foundation
import Testing
@testable import CompanionCore

@Suite struct NavigationPolicyTests {
    @Test func chatHosts() {
        #expect(NavigationPolicy.classify(URL(string: "https://chatgpt.com/")) == .chat)
        #expect(NavigationPolicy.classify(URL(string: "https://chatgpt.com/c/abc")) == .chat)
        #expect(NavigationPolicy.classify(URL(string: "https://cdn.chatgpt.com/x.js")) == .chat)
        #expect(NavigationPolicy.classify(URL(string: "about:blank")) == .chat)
    }

    @Test func authHosts() {
        #expect(NavigationPolicy.classify(URL(string: "https://auth.openai.com/log-in")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.com/o/oauth2")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://appleid.apple.com/auth")) == .auth)
    }

    @Test func googleRegionalAccountHosts() {
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.co.jp/accounts/SetSID")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.com.hk/accounts/SetSID")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.de/accounts/SetSID")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.youtube.com/accounts/SetSID")) == .auth)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.evil.example.com/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "https://accounts.google.c0m/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "https://www.google.co.jp/search")) == .external)
    }

    @Test func externalAndBlocked() {
        #expect(NavigationPolicy.classify(URL(string: "https://example.com/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "https://evilopenai.com/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "https://chatgpt.com.evil.io/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "http://chatgpt.com/")) == .external)
        #expect(NavigationPolicy.classify(URL(string: "file:///etc/passwd")) == .blocked)
        #expect(NavigationPolicy.classify(URL(string: "javascript:alert(1)")) == .blocked)
        #expect(NavigationPolicy.classify(nil) == .blocked)
    }

    @Test func restorable() {
        let u = NavigationPolicy.restorableConversationURL(URL(string: "https://chatgpt.com/c/123?model=x#y"))
        #expect(u?.absoluteString == "https://chatgpt.com/c/123")
        #expect(NavigationPolicy.restorableConversationURL(URL(string: "https://chatgpt.com/g/g-1/c/9")) != nil)
        #expect(NavigationPolicy.restorableConversationURL(URL(string: "https://chatgpt.com/")) == nil)
        #expect(NavigationPolicy.restorableConversationURL(URL(string: "https://auth.openai.com/c/1")) == nil)
    }
}

@Suite struct RedactorTests {
    @Test func redactsIdsAndQuery() {
        #expect(Redactor.describe(URL(string: "https://chatgpt.com/c/abc-123?x=1")) == "https://chatgpt.com/c/<id>?<redacted>")
        #expect(Redactor.describe(URL(string: "https://auth.openai.com/log-in/password")) == "https://auth.openai.com/log-in/…")
        #expect(Redactor.describe(URL(string: "https://chatgpt.com/")) == "https://chatgpt.com/")
    }
}

@Suite struct SegmenterTests {
    @Test func languages() {
        #expect(SpeechSegmenter.detectLanguage("今日はいい天気ですね") == "ja-JP")
        #expect(SpeechSegmenter.detectLanguage("今天天气很好") == "zh-CN")
        #expect(SpeechSegmenter.detectLanguage("The weather is nice today.") == "en-US")
        #expect(SpeechSegmenter.detectLanguage("1234 ---") == nil)
    }

    @Test func noticesKeptAndEmptyDropped() {
        let blocks = [
            AnswerBlock(kind: .text, text: "第一段。"),
            AnswerBlock(kind: .notice, text: "代码块已跳过"),
            AnswerBlock(kind: .text, text: "   "),
            AnswerBlock(kind: .text, text: "English paragraph."),
        ]
        let segs = SpeechSegmenter.segments(from: blocks)
        #expect(segs.count == 3)
        #expect(segs[1].isNotice)
        #expect(segs[2].language == "en-US")
    }

    @Test func longTextIsSplitWithinLimit() {
        let long = String(repeating: "这是一个用于测试的句子。", count: 80)
        let segs = SpeechSegmenter.segments(from: [AnswerBlock(kind: .text, text: long)])
        #expect(segs.count > 1)
        #expect(segs.allSatisfy { $0.text.count <= SpeechSegmenter.maxSegmentLength })
        #expect(segs.map(\.text).joined() == long)
    }

    @Test func hardSplitNoPunctuation() {
        let long = String(repeating: "字", count: 500)
        let segs = SpeechSegmenter.segments(from: [AnswerBlock(kind: .text, text: long)])
        #expect(segs.map(\.text).joined() == long)
        #expect(segs.allSatisfy { $0.text.count <= SpeechSegmenter.maxSegmentLength })
    }
}

@Suite struct PageZoomTests {
    @Test func zoomInMovesToTheNextLevel() {
        #expect(PageZoom.zoomedIn(from: 1) == 1.1)
    }

    @Test func zoomOutMovesToThePreviousLevel() {
        #expect(PageZoom.zoomedOut(from: 1) == 0.9)
    }

    @Test func zoomStopsAtTheEnds() {
        #expect(PageZoom.zoomedIn(from: PageZoom.levels.last!) == PageZoom.levels.last!)
        #expect(PageZoom.zoomedOut(from: PageZoom.levels.first!) == PageZoom.levels.first!)
    }

    @Test func storedValueSnapsToTheNearestLevel() {
        #expect(PageZoom.nearestLevel(to: 1.27) == 1.25)
        #expect(PageZoom.nearestLevel(to: 0) == PageZoom.levels.first!)
        #expect(PageZoom.nearestLevel(to: 9) == PageZoom.levels.last!)
    }

    @Test func levelsIncludeActualSize() {
        #expect(PageZoom.levels.contains(PageZoom.actualSize))
    }
}
