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
}
