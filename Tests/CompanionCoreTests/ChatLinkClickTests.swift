import Foundation
import Testing
@testable import CompanionCore

/// ⌘ 点击、⇧⌘ 点击聊天链接在新标签页打开（3.12）：什么链接算、修饰键怎么看（ChatLinkClick.opening），
/// 什么时候不打开、按什么先后说原因（ChatLinkClick.refusal）。
@Suite struct ChatLinkClickTests {
    /// 算聊天页面的：https、主站本身（大小写不论），首页（带不带查询、片段）、对话 /c/…、GPT 和项目 /g/…。
    static let chatPages = [
        "https://chatgpt.com/",
        "https://chatgpt.com",
        "https://chatgpt.com/?model=gpt-4o",
        "https://chatgpt.com/#settings/General",
        "https://chatgpt.com/?temporary-chat=true",
        "https://chatgpt.com/c/abc-123",
        "https://chatgpt.com/c/abc-123?model=x",
        "https://chatgpt.com/g/g-abc",
        "https://chatgpt.com/g/g-abc/c/123",
        "https://chatgpt.com/g/g-p-123-project/project",
        "https://CHATGPT.com/c/1",
        "HTTPS://chatgpt.com/c/1",
    ]

    /// 不算的：主站的其他路径、认证页、别的网站、子域名、长得像的域名、http、about:、data:。
    static let otherLinks = [
        "https://chatgpt.com/pricing",
        "https://chatgpt.com/features/voice",
        "https://chatgpt.com/auth/login",
        "https://chatgpt.com/gpts",
        "https://chatgpt.com/share/abc",
        "https://chatgpt.com/codex",
        "https://chatgpt.com/cat",
        "https://chatgpt.com/library",
        "https://chatgpt.com/gg/abc",
        "https://auth.openai.com/log-in",
        "https://openai.com/",
        "https://accounts.google.com/o/oauth2",
        "https://cdn.chatgpt.com/c/1",
        "https://help.chatgpt.com/c/1",
        "https://chatgpt.com.evil.io/c/1",
        "http://chatgpt.com/",
        "http://chatgpt.com/c/1",
        "https://example.com/c/1",
        "about:blank",
        "data:text/html,hi",
        "blob:https://chatgpt.com/123",
    ]

    @Test(arguments: chatPages) func chatPagesOpenInATab(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(ChatLinkClick.opensInTab(url))
    }

    @Test(arguments: otherLinks) func otherLinksDoNotOpenInATab(_ address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!ChatLinkClick.opensInTab(url))
    }

    @Test func noAddressDoesNotOpenInATab() {
        #expect(!ChatLinkClick.opensInTab(nil))
    }

    /// 每一种地址 × 是不是点链接 × 有没有 ⌘ × 有没有 ⇧：只有点链接、按着 ⌘、聊天页面才打开；有 ⇧ 切换过去，没有就在后台。
    /// 地址判断和修饰键各自独立（不看 ⇧ 就能决定开不开）。
    @Test func openingOnlyForACommandClickOnAChatPage() throws {
        let urls: [URL?] = (Self.chatPages + Self.otherLinks).map { URL(string: $0) } + [nil]
        for url in urls {
            for linkActivated in [false, true] {
                for command in [false, true] {
                    for shift in [false, true] {
                        let got = ChatLinkClick.opening(url: url, linkActivated: linkActivated, command: command, shift: shift)
                        let expected: ChatLinkClick.Opening?
                        if linkActivated, command, ChatLinkClick.opensInTab(url) {
                            expected = shift ? .foreground : .background
                        } else {
                            expected = nil
                        }
                        #expect(got == expected,
                                "\(url?.absoluteString ?? "nil") 点链接=\(linkActivated) ⌘=\(command) ⇧=\(shift)")
                    }
                }
            }
        }
        let chat = URL(string: "https://chatgpt.com/c/1")
        #expect(ChatLinkClick.opening(url: chat, linkActivated: true, command: true, shift: false) == .background)
        #expect(ChatLinkClick.opening(url: chat, linkActivated: true, command: true, shift: true) == .foreground)
        #expect(ChatLinkClick.opening(url: chat, linkActivated: false, command: true, shift: false) == nil, "window.open 等不算")
        #expect(ChatLinkClick.opening(url: chat, linkActivated: true, command: false, shift: true) == nil, "只按 ⇧ 不算")
    }

    /// 32 种情形全看：都没有时打开（nil）；否则按先后说第一个原因：点击来自不显示的标签页、窗口没有显示、有应用级的模态框、
    /// 启动画面还在、已到上限。
    @Test func refusalNamesTheFirstReasonInOrder() {
        let order: [ChatLinkClick.Refusal] = [.sourceNotSelected, .windowNotShown, .appModal, .launchScreen, .atCapacity]
        for bits in 0..<32 {
            let present = (0..<5).map { bits & (1 << $0) != 0 }
            let situation = ChatLinkClick.Situation(sourceSelected: !present[0], windowShown: !present[1], appModal: present[2],
                                                    launchScreenUp: present[3], atCapacity: present[4])
            let expected = present.firstIndex(of: true).map { order[$0] }
            #expect(ChatLinkClick.refusal(situation) == expected, "\(situation)")
        }
        #expect(ChatLinkClick.refusal(ChatLinkClick.Situation()) == nil, "默认的情形是可以打开")
    }
}
