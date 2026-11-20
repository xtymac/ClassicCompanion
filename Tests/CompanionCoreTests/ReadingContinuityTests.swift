import Foundation
import Testing
@testable import CompanionCore

/// 排版变化前记下的阅读位置还属不属于页面现在显示的内容（ReadingContinuity）。
@Suite struct ReadingContinuityTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    let home = URL(string: "https://chatgpt.com/")!
    let a = URL(string: "https://chatgpt.com/c/aaa")!
    let b = URL(string: "https://chatgpt.com/c/bbb")!
    let gpt = URL(string: "https://chatgpt.com/g/g-123")!
    let gptA = URL(string: "https://chatgpt.com/g/g-123/c/aaa")!
    let gptC = URL(string: "https://chatgpt.com/g/g-123/c/ccc")!

    func verdict(_ saved: URL?, _ current: URL?, changes: Int = 1, commits: Int = 0) -> ReadingContinuity.Verdict {
        ReadingContinuity.verdict(saved: saved, current: current, pathChanges: changes, commits: commits)
    }

    // MARK: 页面的样子

    @Test func shapesOfChatPages() {
        typealias S = ReadingContinuity.PageShape
        #expect(ReadingContinuity.shape(home) == S.newChat(space: nil))
        #expect(ReadingContinuity.shape(url("https://chatgpt.com")) == S.newChat(space: nil), "没有路径也是首页")
        #expect(ReadingContinuity.shape(url("https://chatgpt.com/?temporary-chat=true")) == S.newChat(space: nil))
        #expect(ReadingContinuity.shape(gpt) == S.newChat(space: "g-123"))
        #expect(ReadingContinuity.shape(a) == S.conversation(id: "aaa", space: nil))
        #expect(ReadingContinuity.shape(url("https://chatgpt.com/c/aaa/")) == S.conversation(id: "aaa", space: nil))
        #expect(ReadingContinuity.shape(url("https://chatgpt.com/c/aaa?model=x#frag")) == S.conversation(id: "aaa", space: nil))
        #expect(ReadingContinuity.shape(gptA) == S.conversation(id: "aaa", space: "g-123"))
        #expect(ReadingContinuity.shape(url("https://CHATGPT.com/c/aaa")) == S.conversation(id: "aaa", space: nil), "主机不分大小写")
    }

    @Test func everythingElseIsOther() {
        for s in ["https://chatgpt.com/gpts", "https://chatgpt.com/share/xyz", "https://chatgpt.com/g/g-p-1/project",
                  "https://chatgpt.com/c", "https://chatgpt.com/c/aaa/extra", "https://chatgpt.com/g/g-1/c",
                  "https://chatgpt.com/g/g-1/x/aaa", "http://chatgpt.com/c/aaa", "https://auth.openai.com/c/aaa",
                  "https://sub.chatgpt.com/c/aaa", "https://example.com/", "about:blank"] {
            #expect(ReadingContinuity.shape(url(s)) == .other, "\(s)")
        }
        #expect(ReadingContinuity.shape(nil) == .other)
    }

    // MARK: 保留

    /// 路径一次没变（同一份文档，只变 query 或 fragment，或者什么都没变）：保留，不看地址。
    @Test func keepsWhenThePathNeverChanged() {
        #expect(verdict(a, url("https://chatgpt.com/c/aaa?model=x"), changes: 0) == .keep)
        #expect(verdict(home, url("https://chatgpt.com/?temporary-chat=true"), changes: 0) == .keep)
        #expect(verdict(url("https://chatgpt.com/gpts"), url("https://chatgpt.com/gpts"), changes: 0) == .keep)
        #expect(verdict(nil, nil, changes: 0) == .keep, "还没有页面时记下又放回：和原来一样交给网页（网页里没有记下的就什么都不做）")
    }

    /// 同一个对话（id 一样），地址换了写法：保留。
    @Test func keepsTheSameConversation() {
        #expect(verdict(a, gptA) == .keep)
        #expect(verdict(gptA, a) == .keep)
        #expect(verdict(a, a, changes: 2) == .keep, "换走又换回：中间那一步由调用方每次换页面时看（那一步就丢弃了）")
    }

    // MARK: 要网页确认

    /// 新对话页一步到同一空间里的对话：样子和“第一条消息发出、对话拿到地址”一样，
    /// 但从新对话页点侧栏里的另一个对话也是这样。只靠地址分不清，交给网页确认。
    @Test func aNewChatPageThatGotAConversationAddressInOneStepNeedsThePage() {
        #expect(verdict(home, a) == .confirmOnPage)
        #expect(verdict(url("https://chatgpt.com/?model=x"), url("https://chatgpt.com/c/aaa?model=x")) == .confirmOnPage)
        #expect(verdict(gpt, gptC) == .confirmOnPage)
    }

    // MARK: 丢弃

    @Test func discardsAfterAMainFrameCommitWhateverTheAddress() {
        #expect(verdict(a, a, changes: 0, commits: 1) == .discard(.reloaded), "⌘R、整页加载：网页里已是另一份文档")
        #expect(verdict(home, a, commits: 2) == .discard(.reloaded))
        #expect(verdict(a, gptA, commits: 1) == .discard(.reloaded))
    }

    @Test func discardsAnotherConversation() {
        #expect(verdict(a, b) == .discard(.otherConversation))
        #expect(verdict(gptA, gptC) == .discard(.otherConversation))
        #expect(verdict(a, gptC) == .discard(.otherConversation))
    }

    @Test func discardsLeavingAConversationForANewChatPage() {
        #expect(verdict(a, home) == .discard(.leftConversation))
        #expect(verdict(gptA, gpt) == .discard(.leftConversation))
    }

    @Test func discardsANewChatPageThatTookMoreThanOneStep() {
        #expect(verdict(home, a, changes: 2) == .discard(.notOneStep), "/ → /c/x → /c/a 之类：不是“拿到地址”那一步")
        #expect(verdict(gpt, gptC, changes: 3) == .discard(.notOneStep))
    }

    @Test func discardsANewChatPageThatGotAConversationInAnotherSpace() {
        #expect(verdict(home, gptA) == .discard(.otherSpace))
        #expect(verdict(gpt, a) == .discard(.otherSpace))
        #expect(verdict(gpt, url("https://chatgpt.com/g/g-999/c/aaa")) == .discard(.otherSpace))
    }

    @Test func discardsAnotherNewChatPage() {
        #expect(verdict(home, gpt) == .discard(.otherNewChat))
        #expect(verdict(gpt, home) == .discard(.otherNewChat))
        #expect(verdict(home, url("https://chatgpt.com/?model=x"), changes: 2) == .discard(.otherNewChat),
                "/ → /c/x → /：路径一样，但中间换过页面")
    }

    @Test func discardsAnythingInvolvingANonChatPage() {
        let gpts = url("https://chatgpt.com/gpts")
        #expect(verdict(a, gpts) == .discard(.notChatPage))
        #expect(verdict(gpts, a) == .discard(.notChatPage))
        #expect(verdict(home, url("https://chatgpt.com/g/g-p-1/project")) == .discard(.notChatPage))
        #expect(verdict(url("https://chatgpt.com/g/g-p-1/project"), url("https://chatgpt.com/g/g-p-1/c/aaa")) == .discard(.notChatPage),
                "项目页拿到对话地址：认不出是哪种页面，按丢弃")
        #expect(verdict(a, url("https://auth.openai.com/log-in")) == .discard(.notChatPage))
        #expect(verdict(gpts, gpts, changes: 2) == .discard(.notChatPage), "换走又换回非聊天页面")
    }

    @Test func discardsWhenAnAddressIsUnknown() {
        #expect(verdict(nil, a) == .discard(.unknownAddress))
        #expect(verdict(a, nil) == .discard(.unknownAddress))
        #expect(verdict(nil, nil, changes: 1) == .discard(.unknownAddress))
    }

    /// 先看提交，再看路径变没变：提交过就丢弃，路径没变也一样。
    @Test func aCommitWinsOverEverythingElse() {
        #expect(verdict(nil, nil, changes: 0, commits: 1) == .discard(.reloaded))
        #expect(verdict(home, a, changes: 1, commits: 1) == .discard(.reloaded))
    }
}
