import SwiftUI

/// 随应用打包的试用版说明，每种界面语言一份：Contents/Resources/TrialNotes.<语言>.md（build-app.sh 从 docs/ 生成）。
enum TrialNotes {
    enum Block: Equatable {
        case title(String), heading(String), body(String)
    }

    static func resourceName(_ language: AppLanguage) -> String { "TrialNotes.\(language.rawValue)" }

    static func text(_ language: AppLanguage, in bundle: Bundle = .main) -> String? {
        bundle.url(forResource: resourceName(language), withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// 说明只用标题、段落和编号，不需要完整的 Markdown 排版。
    static func blocks(from text: String) -> [Block] {
        text.split(whereSeparator: \.isNewline).map { line in
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            return .body(String(line))
        }
    }
}

struct TrialNotesView: View {
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let text = TrialNotes.text(languages.language) {
                    ForEach(Array(TrialNotes.blocks(from: text).enumerated()), id: \.offset) { _, block in
                        row(block)
                    }
                } else {
                    Text(L10n.string("trialNotes.missing")).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder private func row(_ block: TrialNotes.Block) -> some View {
        switch block {
        case .title(let s): Text(s).font(.title2.bold())
        case .heading(let s): Text(s).font(.headline).padding(.top, 8)
        case .body(let s):
            Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AboutView: View {
    let info: AppInfo
    let onShowTrialNotes: () -> Void
    let onShowDiagnostics: () -> Void
    @State private var copied = false
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Classic Companion").font(.title2.bold())
                Text(L10n.format("about.version", info.version, info.build))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(L10n.string("about.description"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("about.notOfficial"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if info.usesPlaceholderIcon {
                Text(L10n.string("about.placeholderIcon"))
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Button(L10n.string("about.trialNotes"), action: onShowTrialNotes)
            feedback
        }
        .padding(20)
        .environment(\.locale, languages.locale)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 有反馈地址时也保留“复制版本信息”和“打开诊断”：随包说明让用户提问题时附上这两样。
    @ViewBuilder private var feedback: some View {
        VStack(spacing: 6) {
            if let url = AppInfo.feedbackURL {
                Link(L10n.string("about.feedback"), destination: url)
            }
            HStack {
                Button(L10n.string(copied ? "about.copied" : "about.copyVersion")) {
                    let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.feedbackText(system: system, architecture: AppInfo.runningArchitecture), forType: .string)
                    copied = true
                }
                Button(L10n.string("settings.diagnostics.open"), action: onShowDiagnostics)
            }
            Text(L10n.string("about.feedbackNote"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
