import Foundation
import Testing
@testable import CompanionCore

/// 关闭的标签页留着（TabList.kept）：最多一个，⇧⌘T 先原样放回它，到时间由调用方结束留着（dropKept()），临时聊天不留。
@Suite struct KeptTabTests {
    let home = URL(string: "https://chatgpt.com/")!
    let temporary = URL(string: "https://chatgpt.com/?temporary-chat=true")!

    func conversation(_ n: Int) -> URL {
        URL(string: "https://chatgpt.com/c/conv-\(n)")!
    }

    func list(_ count: Int, capacity: Int = TabList.defaultCapacity) -> TabList {
        var list = TabList(capacity: capacity)
        for _ in 1..<count { _ = list.append() }
        return list
    }

    @Test func theKeepTimeIsSixtySeconds() {
        #expect(TabList.closedTabKeepSeconds == 60)
    }

    @Test func closingWithKeepRemembersTheTabItsPlaceAndWhetherItWasRecorded() {
        var l = list(3)
        let ids = l.tabs
        #expect(l.close(ids[1], url: conversation(1), keep: true) == .closed(selectionChanged: false))
        #expect(l.kept == TabList.KeptTab(id: ids[1], index: 1, recorded: true))
        #expect(l.tabs == [ids[0], ids[2]], "不在列表里")
        #expect(!l.isFull)
        #expect(l.recentlyClosed.latest?.url == conversation(1), "记录照常记")

        var draft = list(3)
        let draftIDs = draft.tabs
        _ = draft.close(draftIDs[2], url: home, keep: true)
        #expect(draft.kept == TabList.KeptTab(id: draftIDs[2], index: 2, recorded: false), "新对话页（草稿）也留着，不记")
        #expect(draft.recentlyClosed.isEmpty)
        #expect(draft.canReopen, "没有记录也能 ⇧⌘T")

        var none = list(3)
        _ = none.close(none.tabs[0], url: nil, keep: true)
        #expect(none.kept != nil, "没有地址的也留着")
    }

    @Test func closingWithoutKeepLeavesNothingKept() {
        var l = list(3)
        _ = l.close(l.tabs[1], url: conversation(1))
        #expect(l.kept == nil)
    }

    @Test func temporaryChatsAreNeverKept() {
        #expect(!TabList.mayKeep(url: temporary))
        #expect(!TabList.mayKeep(url: URL(string: "https://chatgpt.com/c/abc?temporary-chat=true")))
        #expect(TabList.mayKeep(url: conversation(1)))
        #expect(TabList.mayKeep(url: home))
        #expect(TabList.mayKeep(url: nil))

        var l = list(3)
        _ = l.close(l.tabs[1], url: temporary, keep: true)
        #expect(l.kept == nil)
        #expect(l.recentlyClosed.isEmpty)
        #expect(!l.canReopen)
    }

    @Test func anotherCloseEndsTheKeepingAndKeepsTheRecord() {
        var l = list(4)
        let ids = l.tabs
        _ = l.close(ids[1], url: conversation(1), keep: true)
        _ = l.close(ids[2], url: home, keep: true)
        #expect(l.kept?.id == ids[2], "最近关闭的那一个")
        #expect(l.recentlyClosed.entries.map(\.url) == [conversation(1)], "先留着的那个的记录留着")

        _ = l.close(ids[3], url: conversation(3))
        #expect(l.kept == nil, "不留的关闭也结束之前留着的")
        #expect(l.recentlyClosed.entries.map(\.url) == [conversation(1), conversation(3)])

        var only = list(1)
        _ = only.append()
        _ = only.close(only.tabs[0], url: conversation(0), keep: true)
        let before = only
        #expect(only.close(only.tabs[0], url: conversation(9), keep: true) == .onlyTab)
        #expect(only == before, "只剩一个时不关，留着的照样留着")
    }

    @Test func reopenBringsTheKeptTabBackWithItsOwnIDAtItsPlace() throws {
        for index in 0...3 {
            var l = list(4)
            let ids = l.tabs
            _ = l.close(ids[index], url: conversation(index), keep: true)
            let selectedBefore = l.selected
            var quiet = l
            #expect(l.reopen() == .broughtBack(ids[index]))
            #expect(l.tabs == ids, "原位置：\(index)")
            #expect(l.selected == ids[index])
            #expect(l.kept == nil)
            #expect(l.recentlyClosed.isEmpty, "它的记录一起消耗")
            #expect(!l.canReopen)

            #expect(quiet.reopen(select: false) == .broughtBack(ids[index]))
            #expect(quiet.selected == selectedBefore)
            #expect(quiet.tabs == ids)
        }

        var shrunk = list(4)
        let ids = shrunk.tabs
        _ = shrunk.close(ids[3], url: home, keep: true)
        _ = shrunk.dropKept()
        _ = shrunk.close(ids[1], url: conversation(1))
        _ = shrunk.close(ids[0], url: conversation(0), keep: true)
        #expect(shrunk.reopen() == .broughtBack(ids[0]))
        #expect(shrunk.tabs == [ids[0], ids[2]])
        #expect(shrunk.recentlyClosed.entries.map(\.url) == [conversation(1)], "只消耗它自己的那条")
        #expect(shrunk.reopen() != .nothingToReopen, "再按一次照记录重新打开")
    }

    @Test func aKeptTabWithoutARecordLeavesOlderRecordsAlone() {
        var l = list(3)
        let ids = l.tabs
        _ = l.close(ids[0], url: conversation(0))
        _ = l.close(ids[1], url: home, keep: true)
        #expect(l.reopen() == .broughtBack(ids[1]))
        #expect(l.recentlyClosed.entries.map(\.url) == [conversation(0)])
    }

    @Test func atCapacityTheKeptTabStaysKept() throws {
        var l = list(4)
        let ids = l.tabs
        _ = l.close(ids[1], url: conversation(1), keep: true)
        _ = l.append()
        #expect(l.isFull)
        let before = l
        #expect(l.reopen() == .atCapacity)
        #expect(l == before, "不放回，接着留着，记录也留着")
        #expect(l.kept?.id == ids[1])
    }

    @Test func droppingTheKeptTabFallsBackToTheRecord() throws {
        var l = list(3)
        let ids = l.tabs
        _ = l.close(ids[1], url: conversation(1), keep: true)
        #expect(l.dropKept() == ids[1])
        #expect(l.kept == nil)
        #expect(l.dropKept() == nil)
        #expect(l.canReopen, "记录还在")
        guard case .reopened(let id, let url) = l.reopen() else {
            Issue.record("照记录重新打开")
            return
        }
        #expect(id != ids[1], "新的标识")
        #expect(url == conversation(1))

        var draft = list(3)
        _ = draft.close(draft.tabs[1], url: home, keep: true)
        _ = draft.dropKept()
        #expect(!draft.canReopen, "没有记录的过了时间就没了")
        #expect(draft.reopen() == .nothingToReopen)
    }
}
