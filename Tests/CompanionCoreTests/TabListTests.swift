import Foundation
import Testing
@testable import CompanionCore

/// 聊天标签页列表：新增、上限、关闭后选谁、切换、最近关闭的记录和重新打开。
@Suite struct TabListTests {
    let home = URL(string: "https://chatgpt.com/")!

    func conversation(_ n: Int) -> URL {
        URL(string: "https://chatgpt.com/c/conv-\(n)")!
    }

    /// `count` 个标签页，选中最右的那个（和连按 ⌘T 一样）。
    func list(_ count: Int, capacity: Int = TabList.defaultCapacity) -> TabList {
        var list = TabList(capacity: capacity)
        for _ in 1..<count {
            _ = list.append()
        }
        return list
    }

    func added(_ result: TabList.AddResult) -> TabID? {
        if case .added(let id) = result { return id }
        return nil
    }

    /// `insert(rightOf:)` 放进来的标识（到上限、来源不在时是 nil）。
    func inserted(_ result: TabList.AddResult?) -> TabID? {
        if case .added(let id)? = result { return id }
        return nil
    }

    func reopened(_ result: TabList.ReopenResult) -> (id: TabID, url: URL)? {
        if case .reopened(let id, let url) = result { return (id, url) }
        return nil
    }

    // MARK: 开始和新增

    @Test func startsWithOneSelectedTab() {
        let l = TabList()
        #expect(l.tabs.count == 1)
        #expect(l.selected == l.tabs[0])
        #expect(l.capacity == 4)
        #expect(!l.isFull)
        #expect(l.recentlyClosed.isEmpty)
        #expect(l.recentlyClosed.limit == 10)
    }

    @Test func appendAddsAtTheRightAndSelects() throws {
        var l = TabList()
        let first = l.selected
        let second = try #require(added(l.append()))
        #expect(l.tabs == [first, second])
        #expect(l.selected == second)

        #expect(l.select(first) == true)
        let third = try #require(added(l.append()))
        #expect(l.tabs == [first, second, third], "放在最右，不是选中项的右边")
        #expect(l.selected == third)
    }

    @Test func appendInTheBackgroundKeepsTheSelection() throws {
        var l = TabList()
        let first = l.selected
        let background = try #require(added(l.append(select: false)))
        #expect(l.tabs == [first, background])
        #expect(l.selected == first)
    }

    @Test func identifiersAreNeverReused() throws {
        var l = list(3)
        let before = Set(l.tabs)
        #expect(before.count == 3)
        _ = l.close(l.tabs[1], url: home)
        let new = try #require(added(l.append()))
        #expect(!before.contains(new))
        #expect(Set(l.tabs).count == l.tabs.count)
    }

    @Test func fifthTabIsRefused() throws {
        var l = list(4)
        #expect(l.isFull)
        let before = l
        #expect(l.append() == .atCapacity)
        #expect(l.append(select: false) == .atCapacity)
        #expect(l == before, "到上限时列表不变")

        _ = l.close(l.tabs[0], url: home)
        #expect(!l.isFull)
        _ = try #require(added(l.append()))
        #expect(l.tabs.count == 4)
    }

    @Test func capacityIsAParameter() throws {
        var two = TabList(capacity: 2)
        _ = try #require(added(two.append()))
        #expect(two.append() == .atCapacity)

        var one = TabList(capacity: 1)
        #expect(one.isFull)
        #expect(one.append() == .atCapacity)
    }

    // MARK: 关闭后选谁

    @Test func closingTheSelectedFirstTabSelectsTheRightNeighbour() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.select(ids[0]) == true)
        #expect(l.close(ids[0], url: home) == .closed(selectionChanged: true))
        #expect(l.tabs == [ids[1], ids[2]])
        #expect(l.selected == ids[1])
    }

    @Test func closingTheSelectedMiddleTabSelectsTheRightNeighbour() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.select(ids[1]) == true)
        #expect(l.close(ids[1], url: home) == .closed(selectionChanged: true))
        #expect(l.tabs == [ids[0], ids[2]])
        #expect(l.selected == ids[2])
    }

    @Test func closingTheSelectedLastTabSelectsTheLeftNeighbour() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.selected == ids[2])
        #expect(l.close(ids[2], url: home) == .closed(selectionChanged: true))
        #expect(l.tabs == [ids[0], ids[1]])
        #expect(l.selected == ids[1])
    }

    @Test func closingAnUnselectedTabBeforeTheSelectedOneKeepsTheSelection() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.close(ids[0], url: home) == .closed(selectionChanged: false))
        #expect(l.tabs == [ids[1], ids[2]])
        #expect(l.selected == ids[2])
    }

    @Test func closingAnUnselectedTabAfterTheSelectedOneKeepsTheSelection() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.select(ids[0]) == true)
        #expect(l.close(ids[2], url: home) == .closed(selectionChanged: false))
        #expect(l.tabs == [ids[0], ids[1]])
        #expect(l.selected == ids[0])
    }

    @Test func theOnlyTabIsNotClosed() {
        var l = TabList()
        let before = l
        #expect(l.close(l.selected, url: conversation(1)) == .onlyTab)
        #expect(l == before, "列表不变，也不记入最近关闭")

        var two = list(2)
        _ = two.close(two.tabs[0], url: home)
        let remaining = two
        #expect(two.close(two.selected, url: conversation(2)) == .onlyTab)
        #expect(two == remaining)
    }

    @Test func closingATabThatIsNotInTheListDoesNothing() {
        var l = list(3)
        let gone = l.tabs[0]
        #expect(l.close(gone, url: conversation(1)) == .closed(selectionChanged: false))
        let after = l
        #expect(l.close(gone, url: conversation(1)) == .notFound)
        #expect(l == after, "不再记一次")
    }

    /// 关闭以后选谁可以先问（列表不改），答案和真的关闭以后的选中项一样：1–4 个标签页，选中每一个，关每一个。
    /// 只剩一个、不在列表里：nil（close 也不关）。
    @Test func theSelectionAfterClosingCanBeAskedFirstAndMatchesClose() {
        for count in 1...4 {
            for chosen in 0..<count {
                for closing in 0..<count {
                    var l = list(count)
                    let ids = l.tabs
                    _ = l.select(ids[chosen])
                    let before = l
                    let answer = l.selectionAfterClosing(ids[closing])
                    #expect(l == before, "只问不改")
                    let result = l.close(ids[closing], url: home)
                    if count == 1 {
                        #expect(answer == nil)
                        #expect(result == .onlyTab)
                    } else {
                        #expect(answer == l.selected, "\(count) 个，选中第 \(chosen) 个，关第 \(closing) 个")
                        #expect(result == .closed(selectionChanged: chosen == closing))
                    }
                }
            }
        }
        var l = list(3)
        let gone = l.tabs[0]
        _ = l.close(gone, url: home)
        #expect(l.selectionAfterClosing(gone) == nil)
        #expect(l.selectionAfterClosing(TabID(rawValue: 99)) == nil)
    }

    /// 选中的在中间：右边的邻居；在最右：左边的邻居；不是选中的：还是选中的那个。
    @Test func theSelectionAfterClosingIsTheRightNeighbourElseTheLeft() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.selectionAfterClosing(ids[2]) == ids[1])
        #expect(l.selectionAfterClosing(ids[0]) == ids[2])
        _ = l.select(ids[1])
        #expect(l.selectionAfterClosing(ids[1]) == ids[2])
        _ = l.select(ids[0])
        #expect(l.selectionAfterClosing(ids[0]) == ids[1])
    }

    // MARK: 切换

    @Test func nextAndPreviousWrapAround() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.selected == ids[2])
        #expect(l.selectNext() == true)
        #expect(l.selected == ids[0], "最右之后回到最左")
        #expect(l.selectNext() == true)
        #expect(l.selected == ids[1])
        #expect(l.selectPrevious() == true)
        #expect(l.selected == ids[0])
        #expect(l.selectPrevious() == true)
        #expect(l.selected == ids[2], "最左之前回到最右")
    }

    @Test func oneTabCannotSwitch() {
        var l = TabList()
        let only = l.selected
        #expect(l.selectNext() == false)
        #expect(l.selectPrevious() == false)
        #expect(l.selectLast() == false)
        #expect(l.select(position: 1) == false)
        #expect(l.select(only) == false)
        #expect(l.selected == only)
    }

    @Test func selectByPosition() {
        var l = list(4)
        let ids = l.tabs
        #expect(l.select(position: 1) == true)
        #expect(l.selected == ids[0])
        #expect(l.select(position: 3) == true)
        #expect(l.selected == ids[2])
        #expect(l.select(position: 4) == true)
        #expect(l.selected == ids[3])
        #expect(l.select(position: 4) == false, "已经选中时不变")
        #expect(l.select(position: 2) == true)
        #expect(l.selected == ids[1])
    }

    @Test func positionWithoutATabChangesNothing() {
        var l = list(2)
        #expect(l.select(position: 1) == true, "选中最左，超出时改选最后一个也能看出来")
        let before = l
        for position in [0, -1, 3, 4, 9] {
            #expect(l.select(position: position) == false, "position \(position)")
        }
        #expect(l == before)
    }

    @Test func selectLastPicksTheRightmostTab() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.select(position: 1) == true)
        #expect(l.selectLast() == true)
        #expect(l.selected == ids[2])
        #expect(l.selectLast() == false)

        var four = list(4)
        #expect(four.select(position: 2) == true)
        #expect(four.selectLast() == true)
        #expect(four.selected == four.tabs[3])
    }

    @Test func selectingAClosedTabChangesNothing() {
        var l = list(3)
        let gone = l.tabs[0]
        _ = l.close(gone, url: home)
        let before = l
        #expect(l.select(gone) == false)
        #expect(l == before)
    }

    // MARK: 选哪一个（不改列表）

    /// 每种个数、每个选中位置：下一个、上一个绕回，第 N 个、最后一个；问的时候列表不变，
    /// 选择（selectNext 等）选中的就是问出来的那一个。
    @Test(arguments: 1...4) func theQueriesNameTheTabTheSelectionsPick(count: Int) {
        for chosen in 0..<count {
            var l = list(count)
            let ids = l.tabs
            _ = l.select(ids[chosen])
            let before = l
            #expect(l.nextTab == ids[(chosen + 1) % count], "\(count) 个，选中第 \(chosen + 1) 个")
            #expect(l.previousTab == ids[(chosen + count - 1) % count], "\(count) 个，选中第 \(chosen + 1) 个")
            #expect(l.lastTab == ids[count - 1])
            for position in -1...10 {
                let expected: TabID? = (1...count).contains(position) ? ids[position - 1] : nil
                #expect(l.tab(atPosition: position) == expected, "\(count) 个，第 \(position) 个")
            }
            #expect(l == before, "问的时候不改")

            var next = l, previous = l, last = l
            _ = next.selectNext()
            _ = previous.selectPrevious()
            _ = last.selectLast()
            #expect(next.selected == l.nextTab)
            #expect(previous.selected == l.previousTab)
            #expect(last.selected == l.lastTab)
            for position in 1...count {
                var byPosition = l
                _ = byPosition.select(position: position)
                #expect(byPosition.selected == l.tab(atPosition: position))
            }
        }
    }

    @Test func withOneTabEveryQueryNamesTheSelectedTab() {
        let l = TabList()
        #expect(l.nextTab == l.selected)
        #expect(l.previousTab == l.selected)
        #expect(l.lastTab == l.selected)
        #expect(l.tab(atPosition: 1) == l.selected)
        #expect(l.tab(atPosition: 2) == nil)
    }

    // MARK: 最近关闭的记录

    @Test func onlyConversationAddressesAreRecorded() {
        var r = RecentlyClosedTabs()
        let notConversations: [URL?] = [
            nil,
            home,
            URL(string: "https://chatgpt.com/?temporary-chat=true"),
            URL(string: "https://chatgpt.com/gpts"),
            URL(string: "https://chatgpt.com/g/g-abc"),
            URL(string: "https://auth.openai.com/c/1"),
            URL(string: "https://example.com/c/1"),
            URL(string: "http://chatgpt.com/c/1"),
            URL(string: "about:blank"),
        ]
        for url in notConversations {
            #expect(r.record(url: url, index: 0) == false, "\(String(describing: url))")
        }
        #expect(r.isEmpty)

        #expect(r.record(url: URL(string: "https://chatgpt.com/c/abc?model=x#y"), index: 1) == true)
        #expect(r.record(url: URL(string: "https://chatgpt.com/g/g-1/c/9"), index: 2) == true)
        #expect(r.entries.map(\.url.absoluteString) == ["https://chatgpt.com/c/abc", "https://chatgpt.com/g/g-1/c/9"],
                "去掉查询参数和片段")
        #expect(r.entries.map(\.index) == [1, 2])
    }

    @Test func closingRecordsTheAddressAndPosition() {
        var l = list(3)
        let ids = l.tabs
        _ = l.close(ids[0], url: home)
        #expect(l.recentlyClosed.isEmpty, "新对话页不记")
        _ = l.close(ids[2], url: URL(string: "https://chatgpt.com/c/xyz?model=a"))
        #expect(l.recentlyClosed.entries == [RecentlyClosedTabs.Entry(url: URL(string: "https://chatgpt.com/c/xyz")!, index: 1)])
    }

    @Test func recordKeepsTheTenMostRecent() {
        var l = list(2)
        for n in 1...11 {
            _ = l.close(l.selected, url: conversation(n))
            _ = l.append()
        }
        #expect(l.recentlyClosed.entries.count == 10)
        #expect(l.recentlyClosed.entries.first?.url == conversation(2), "最旧的一条丢掉")
        #expect(l.recentlyClosed.latest?.url == conversation(11))
    }

    /// 不去重（用户 11-20 定的 D14）：同一个地址关闭几次就记几次，按关闭的先后；满 10 条丢最旧的，重复的也照样占位置。
    @Test func theSameAddressIsRecordedEachTimeItIsClosed() throws {
        var l = list(3)
        _ = l.close(l.tabs[0], url: conversation(1))
        _ = l.close(l.tabs[0], url: URL(string: "https://chatgpt.com/c/conv-1?model=x"))
        #expect(l.recentlyClosed.entries == [RecentlyClosedTabs.Entry(url: conversation(1), index: 0),
                                             RecentlyClosedTabs.Entry(url: conversation(1), index: 0)],
                "同一个地址（去掉查询参数后）记两次")

        var r = RecentlyClosedTabs()
        for n in 1...12 {
            #expect(r.record(url: conversation(n % 2), index: n) == true)
        }
        #expect(r.entries.count == 10)
        #expect(r.entries.map(\.index) == Array(3...12), "最旧的两条丢掉，其余按关闭的先后")
        #expect(r.entries.map(\.url) == (3...12).map { conversation($0 % 2) })
    }

    // MARK: 重新打开

    @Test func reopenStartsWithTheMostRecentlyClosed() {
        var l = list(4)
        let ids = l.tabs
        for n in 0..<3 {
            _ = l.close(ids[n], url: conversation(n))
        }
        #expect(l.tabs == [ids[3]])
        #expect(reopened(l.reopen())?.url == conversation(2))
        #expect(reopened(l.reopen())?.url == conversation(1))
        #expect(reopened(l.reopen())?.url == conversation(0))
        #expect(l.reopen() == .nothingToReopen)
        #expect(l.tabs.count == 4)
        #expect(l.tabs.last == ids[3], "按关闭的倒序放回，顺序和关闭前一样")
    }

    @Test func reopenPutsANewTabBackAtItsPositionAndSelectsIt() throws {
        var l = list(4)
        let ids = l.tabs
        #expect(l.select(ids[0]) == true)
        _ = l.close(ids[1], url: conversation(1))
        #expect(l.tabs == [ids[0], ids[2], ids[3]])

        let back = try #require(reopened(l.reopen()))
        #expect(back.url == conversation(1))
        #expect(!ids.contains(back.id), "重新打开的是新的标签页")
        #expect(l.tabs == [ids[0], back.id, ids[2], ids[3]])
        #expect(l.selected == back.id)
        #expect(l.recentlyClosed.isEmpty)
    }

    @Test func reopenGoesToTheEndWhenThePositionIsGone() throws {
        var l = list(4)
        let ids = l.tabs
        _ = l.close(ids[3], url: conversation(3))   // 位置 3
        _ = l.close(ids[2], url: home)              // 不记
        #expect(l.tabs == [ids[0], ids[1]])
        let back = try #require(reopened(l.reopen()))
        #expect(l.tabs == [ids[0], ids[1], back.id])
        #expect(l.selected == back.id)

        var three = list(3)
        let threeIDs = three.tabs
        _ = three.close(threeIDs[2], url: conversation(2))   // 位置 2，关后正好 2 个
        let end = try #require(reopened(three.reopen()))
        #expect(three.tabs == [threeIDs[0], threeIDs[1], end.id])
    }

    @Test func reopenAtCapacityKeepsTheRecord() throws {
        var l = list(4)
        _ = l.close(l.tabs[1], url: conversation(1))
        _ = try #require(added(l.append()))
        #expect(l.isFull)
        let before = l
        #expect(l.reopen() == .atCapacity)
        #expect(l == before, "不打开，也不消耗记录")
        #expect(l.recentlyClosed.latest?.url == conversation(1))

        _ = l.close(l.tabs[0], url: home)
        #expect(reopened(l.reopen())?.url == conversation(1))
    }

    @Test func nothingToReopen() {
        var l = TabList()
        #expect(l.reopen() == .nothingToReopen)

        var full = list(4)
        let before = full
        #expect(full.reopen() == .nothingToReopen, "没有记录时不算到上限")
        #expect(full == before)
    }

    /// 不选中地重新打开（ChatTabs 用的）：放的位置、发的标识、消耗的记录和 `reopen()` 一样，只是选中项不变；再选中它就和
    /// `reopen()` 的结果完全一样。上限 5：关闭时在位置 0–4，之后剩 1–4 个（另外关掉的是新对话页，不记），选中每一个
    /// （位置不存在的放最右）。
    @Test func reopenWithoutSelectingMatchesReopenExceptTheSelection() throws {
        for index in 0...4 {
            for count in 1...4 {
                for chosen in 0..<count {
                    var l = list(5, capacity: 5)
                    _ = l.close(l.tabs[index], url: conversation(index))
                    while l.tabs.count > count {
                        _ = l.close(l.tabs[0], url: home)
                    }
                    _ = l.select(l.tabs[chosen])
                    #expect(l.recentlyClosed.entries == [RecentlyClosedTabs.Entry(url: conversation(index), index: index)])
                    var a = l, b = l
                    let selectedBefore = a.selected
                    let quiet = try #require(reopened(a.reopen(select: false)))
                    let loud = try #require(reopened(b.reopen()))
                    let at = "关闭时在 \(index)，剩 \(count) 个，选中第 \(chosen) 个"
                    #expect(quiet.id == loud.id && quiet.url == loud.url, "\(at)")
                    #expect(a.tabs == b.tabs, "\(at)")
                    #expect(a.tabs.firstIndex(of: quiet.id) == min(index, count), "原位置，不存在就最右：\(at)")
                    #expect(a.selected == selectedBefore, "选中项不变：\(at)")
                    #expect(a.recentlyClosed.isEmpty && b.recentlyClosed.isEmpty, "一样消耗了记录：\(at)")
                    #expect(a.select(quiet.id) == true)
                    #expect(a == b, "再选中它就和 reopen() 一样：\(at)")
                }
            }
        }
    }

    /// 不选中地重新打开时的拒绝和 `reopen()` 一样：没有记录、已到上限（记录留着），列表都不变。
    @Test func reopenWithoutSelectingRefusesLikeReopen() throws {
        var empty = list(2)
        let before = empty
        #expect(empty.reopen(select: false) == .nothingToReopen)
        #expect(empty == before)

        var full = list(4)
        _ = full.close(full.tabs[1], url: conversation(1))
        _ = try #require(added(full.append()))
        let kept = full
        #expect(full.reopen(select: false) == .atCapacity)
        #expect(full == kept, "不打开，记录留着")
        #expect(full.recentlyClosed.latest?.url == conversation(1))
    }

    // MARK: ⌘ 点击链接打开的放在哪（D12）

    /// 放在来源的紧右边，不放最右；选中项不变。来源在最左、中间、最右，选中的是来源或别的都一样。
    @Test(arguments: 0..<3) func insertRightOfPutsTheNewTabRightNextToTheSource(sourceIndex: Int) throws {
        for chosen in 0..<3 {
            var l = list(3, capacity: 5)
            _ = l.select(l.tabs[chosen])
            let before = l.tabs, selected = l.selected
            let source = before[sourceIndex]
            let new = try #require(inserted(l.insert(rightOf: source)))
            var expected = before
            expected.insert(new, at: sourceIndex + 1)
            #expect(l.tabs == expected, "来源第 \(sourceIndex) 个，选中第 \(chosen) 个")
            #expect(l.selected == selected, "不选中")
            #expect(!before.contains(new))
        }
    }

    /// 只有一个标签页：放在它右边，不选中。
    @Test func insertRightOfTheOnlyTab() throws {
        var l = TabList()
        let first = l.selected
        let new = try #require(inserted(l.insert(rightOf: first)))
        #expect(l.tabs == [first, new])
        #expect(l.selected == first)
    }

    /// 从同一个来源连着打开：每个新的都紧挨着来源，先开的被往右挤（最新的离来源最近），来源右边原来的那些一直在最后。
    @Test func repeatedInsertsStackNextToTheSource() throws {
        var l = list(3, capacity: 6)
        let ids = l.tabs
        _ = l.select(ids[1])
        let a = try #require(inserted(l.insert(rightOf: ids[1])))
        let b = try #require(inserted(l.insert(rightOf: ids[1])))
        let c = try #require(inserted(l.insert(rightOf: ids[1])))
        #expect(l.tabs == [ids[0], ids[1], c, b, a, ids[2]])
        #expect(l.selected == ids[1])
        #expect(Set([a, b, c]).count == 3)
    }

    /// 和 `append(select: false)` 只差位置：同一个标识、同样的个数和选中项，记录不动（不记、不消耗）。
    @Test func insertRightOfMatchesBackgroundAppendExceptThePosition() throws {
        var a = list(3)
        _ = a.close(a.tabs[1], url: conversation(1))
        var b = a
        let records = a.recentlyClosed
        let put = try #require(inserted(a.insert(rightOf: a.tabs[0])))
        let appended = try #require(added(b.append(select: false)))
        #expect(put == appended)
        #expect(Set(a.tabs) == Set(b.tabs))
        #expect(a.selected == b.selected)
        #expect(a.recentlyClosed == records && b.recentlyClosed == records)
        #expect(a.tabs.firstIndex(of: put) == 1 && b.tabs.firstIndex(of: appended) == 2)
    }

    /// 已到上限：`.atCapacity`，列表、选中项、记录、下一个标识都不变。
    @Test func insertRightOfAtCapacityChangesNothing() throws {
        var l = list(4)
        _ = l.close(l.tabs[1], url: conversation(1))
        _ = try #require(added(l.append()))
        #expect(l.isFull)
        let before = l
        for source in before.tabs {
            #expect(l.insert(rightOf: source) == .atCapacity)
            #expect(l == before)
        }
        _ = l.close(l.tabs[0], url: home)
        let next = try #require(inserted(l.insert(rightOf: l.tabs[0])))
        #expect(!before.tabs.contains(next))
    }

    /// 来源不在列表里（已经关了）：nil，列表不变，也不发标识（下一个发的和没调用过一样）。到上限时也先看来源。
    @Test func insertRightOfAMissingSourceIsNil() throws {
        var l = list(3)
        let gone = l.tabs[1]
        _ = l.close(gone, url: home)
        let before = l
        #expect(l.insert(rightOf: gone) == nil)
        #expect(l == before)
        var other = before
        let next = try #require(added(l.append()))
        let expected = try #require(added(other.append()))
        #expect(next == expected, "没有消耗标识")

        var full = list(4)
        let closed = full.tabs[0]
        _ = full.close(closed, url: home)
        _ = try #require(added(full.append()))
        #expect(full.insert(rightOf: closed) == nil)
    }

    /// 标识不复用：插进来的和关掉过的、在列表里的都不同。
    @Test func insertRightOfNeverReusesIdentifiers() throws {
        var l = list(3)
        var seen = Set(l.tabs)
        _ = l.close(l.tabs[2], url: home)
        for _ in 0..<2 {
            let new = try #require(inserted(l.insert(rightOf: l.tabs[0])))
            #expect(!seen.contains(new))
            seen.insert(new)
        }
        #expect(Set(l.tabs).count == l.tabs.count)
    }
}
