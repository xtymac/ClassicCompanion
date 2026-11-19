import Foundation
@testable import ClassicCompanion

/// 比较日志时间线（两套逐行比，或者和写好的一串比）时不算的行：有没有这一行、写的是什么，取决于测试运行时真实的鼠标、键盘、
/// 屏幕或别的应用，不取决于被测的代码。测试运行时用户照常用着电脑，这些行就会多出来或不一样。
/// 一次失败就是这样：建窗口时 center() 移动了窗口，那一刻用户按着鼠标，其中一个窗口多写了一行 [drag]。
///
/// 只去掉下面这些。窗口动作的日志（launch、appearance、nav、window 等）一行不去，照样逐行比。
/// 看过、没有去掉的类别：
/// - cycle：显示、隐藏、快捷键的计数，由被测代码调用 show()、hide() 时写，不看鼠标键盘。
/// - window：窗口的动作，要比。其中“隐藏后焦点未回到原应用”读前台应用，但只跟在隐藏一个显示着的窗口之后，
///   比时间线的测试都不显示窗口。
/// - ime：切换模式时写，内容是网页视图有没有输入上下文。
/// - net：只在调用 networkChanged 时写；测试里的运行时不看网络（watchesNetwork: false）。
/// - esc、render：运行时加载完成后自己异步写的，不看鼠标键盘；要不要比由各个测试自己定（LaunchWiringTests 不比）。
enum LiveInputLogLines {
    static func excludes(category: String, message: String) -> Bool {
        switch category {
        // 窗口移动时（建窗口时的 center() 也算）只有按着鼠标才写，写的是鼠标的位置。
        case "drag": true
        // 本应用收到的真实按键（本地按键监视），和 Esc 之后 150ms 的那一行。测试不发按键。
        case "keys": true
        // 系统通知显示器变化时写（接上、拔下、排列，K15：数量不变也会来），以及显示窗口之后记的位置：
        // 写的是真实屏幕的数量、名字，和窗口在不在屏幕里。
        case "screen": true
        // 唤醒后 0.35 秒读应用是否激活、窗口是否 key、焦点在哪、前台是哪个应用：取决于用户这时在用哪个应用。
        case "focus": true
        // 别的应用（VoiceOver、辅助工具、自动化）第一次来读网页时写。同一类里跟着设置写的那行照样比。
        case "ax": message.hasPrefix("首次收到无障碍请求")
        default: false
        }
    }

    static func excludes(_ entry: Diagnostics.Entry) -> Bool {
        excludes(category: entry.category, message: entry.message)
    }

    /// 去掉上面这些行，其余照原来的顺序。
    static func compared(_ entries: [Diagnostics.Entry]) -> [Diagnostics.Entry] {
        entries.filter { !excludes($0) }
    }
}
