import Foundation

/// 排版变化（切模式、拖边）前记下的阅读位置，到放回的时候还属不属于这个页面现在显示的内容。只做决定，不碰网页，不写日志。
///
/// 规则（按先后）：
/// 1. 记下以后这个页面的主框架提交过（重新加载、整页导航）：丢弃。网页里已是另一份文档。
/// 2. 路径一次没变（只变了 query 或 fragment，或者什么都没变）：保留。还是同一份文档里的同一个页面。
/// 3. 路径变过，按记下时和现在的地址的样子（`shape(_:)`）：
///    - 同一个对话（id 一样，写法可以不同，例如 `/c/<id>` 和 `/g/<空间>/c/<id>`）：保留；
///    - 新对话页一步到同一空间里的对话（`/` → `/c/<id>`、`/g/<空间>` → `/g/<空间>/c/<id>`）：要网页确认（`confirmOnPage`）；
///    - 其余都丢弃：换了对话、从对话到新对话页、新对话页之间、到别的空间、不止一步、任何一边不是聊天页面、地址不知道。
///
/// “新对话页 → 对话”为什么不能只看地址：第一条消息发出后对话拿到地址，和在新对话页点了侧栏里的另一个对话，都是同一份文档里
/// 路径从 `/` 变成 `/c/<id>`，样子一模一样（用户 11-20：不能把所有这种变化都当成同一个对话）。所以只在网页能确认记下时看着的
/// 那段对话还在原处时放回，确认不了就丢弃。确认的办法在网页里（`__ccReadingHold.restore(编号, true)`），不在这里。
///
/// 路径变化次数（pathChanges）和提交次数（commits）由调用方从记下那一刻数起（应用里是适配器的导航代号和标签页的提交计数）。
/// 规则只看记下时和现在两头；中间每换一次页面调用方都该再问一次，哪一次说丢弃就当场丢弃
/// （例如 `/c/a` → `/c/b` → `/c/a`：到 `/c/b` 时就丢了，不会因为最后又回到 `/c/a` 而保留）。
public enum ReadingContinuity {
    /// 一个地址在聊天站里是哪种页面。只认 https 的 chatgpt.com（不含子域名）。
    public enum PageShape: Equatable, Sendable {
        /// 新对话页：`/`（space 是 nil），或 GPT 的起始页 `/g/<space>`。
        case newChat(space: String?)
        /// 对话：`/c/<id>`（space 是 nil），或 `/g/<space>/c/<id>`。
        case conversation(id: String, space: String?)
        /// 别的：没有地址、不是 https、不是 chatgpt.com，或聊天站的其他路径（`/gpts`、分享页、项目页 `/g/<空间>/project` 等）。
        case other
    }

    /// 丢弃的原因（写日志用）。
    public enum Reason: Equatable, Sendable {
        /// 记下以后主框架提交过。
        case reloaded
        /// 记下时或现在不知道地址。
        case unknownAddress
        /// 换了一个对话（id 不同）。
        case otherConversation
        /// 从对话到了新对话页。
        case leftConversation
        /// 从新对话页到了另一个新对话页，或者换走又回到新对话页。
        case otherNewChat
        /// 新对话页到对话，但中间不止一次路径变化。
        case notOneStep
        /// 新对话页到了别的空间里的对话。
        case otherSpace
        /// 记下时或现在不是聊天页面（新对话页或对话）。
        case notChatPage
    }

    public enum Verdict: Equatable, Sendable {
        /// 还是同一个页面：放回。
        case keep
        /// 新对话页一步拿到了对话地址，地址分不清是不是同一个对话：交给网页确认，确认不了就丢弃。
        case confirmOnPage
        /// 不再属于现在显示的内容：丢弃（网页里记下的也要清掉）。
        case discard(Reason)
    }

    public static func shape(_ url: URL?) -> PageShape {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "chatgpt.com" else { return .other }
        let parts = url.path.split(separator: "/").map(String.init)
        switch parts.count {
        case 0:
            return .newChat(space: nil)
        case 2 where parts[0] == "g":
            return .newChat(space: parts[1])
        case 2 where parts[0] == "c":
            return .conversation(id: parts[1], space: nil)
        case 4 where parts[0] == "g" && parts[2] == "c":
            return .conversation(id: parts[3], space: parts[1])
        default:
            return .other
        }
    }

    /// saved：记下时的地址；current：现在的地址；pathChanges：记下以后路径（主机加路径）变了几次；
    /// commits：记下以后主框架提交了几次。
    public static func verdict(saved: URL?, current: URL?, pathChanges: Int, commits: Int) -> Verdict {
        if commits > 0 { return .discard(.reloaded) }
        if pathChanges == 0 { return .keep }
        guard let saved, let current else { return .discard(.unknownAddress) }
        switch (shape(saved), shape(current)) {
        case (.conversation(let before, _), .conversation(let now, _)):
            return before == now ? .keep : .discard(.otherConversation)
        case (.conversation, .newChat):
            return .discard(.leftConversation)
        case (.newChat(let before), .conversation(_, let now)):
            guard before == now else { return .discard(.otherSpace) }
            guard pathChanges == 1 else { return .discard(.notOneStep) }
            return .confirmOnPage
        case (.newChat, .newChat):
            return .discard(.otherNewChat)
        default:
            return .discard(.notChatPage)
        }
    }
}
