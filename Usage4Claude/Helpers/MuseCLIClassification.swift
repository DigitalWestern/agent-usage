//
//  MuseCLIClassification.swift
//  Usage4Claude
//
//  Pure classification of a finished `muse usage --json` run into the states
//  the UI has to distinguish. Kept separate from the `Process` plumbing in
//  Services/MuseAPIService.swift so it can be unit-tested without spawning
//  anything. Must stay free of `L.*`/UI dependency.
//
//  Verified behaviour (muse 1.4.13, see docs/MUSE_INTEGRATION.md §2):
//    success  → exit 0, one JSON object on stdout, empty stderr
//    no login → exit 1, stderr "muse usage: not logged in: run `muse login` first"
//

import Foundation

nonisolated enum MuseCLIOutcome: Equatable {
    /// 命令成功，携带 stdout 原始字节（尚未解码）
    case success(Data)
    /// CLI 明确表示没有登录会话，需要用户执行 `muse login`
    case notSignedIn(message: String)
    /// 退出码为 0 但没有任何输出：CLI 行为异常，不能当成成功
    case emptyOutput
    /// 其他非零退出，message 已裁剪为可展示的单行文本
    case failed(exitCode: Int32, message: String)
}

nonisolated enum MuseCLIClassification {
    /// 未登录时 stderr 中的稳定标记。CLI 文案可能变化，
    /// 因此匹配大小写不敏感，并保留原始 stderr 作为兜底展示。
    static let notSignedInMarker = "not logged in"

    /// stderr 展示长度上限。CLI 理论上只输出一行，
    /// 但没有保证，过长文本不应该塞进菜单栏弹窗。
    static let messageLimit = 400

    static func classify(exitCode: Int32, stdout: Data, stderr: String) -> MuseCLIOutcome {
        let message = displayMessage(stderr)

        guard exitCode == 0 else {
            if stderr.range(of: notSignedInMarker, options: .caseInsensitive) != nil {
                return .notSignedIn(message: message ?? "muse: not logged in")
            }
            return .failed(
                exitCode: exitCode,
                message: message ?? "muse exited with code \(exitCode)"
            )
        }

        // exit 0 但 stdout 只有空白：CLI 说成功了却没给数据，
        // 按失败处理，避免把 0% 当成真实用量显示。
        guard !isBlank(stdout) else {
            return .emptyOutput
        }

        return .success(stdout)
    }

    /// 把 stderr 压成单行、去掉首尾空白、限制长度。空输入返回 nil。
    static func displayMessage(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > messageLimit else { return collapsed }
        return String(collapsed.prefix(messageLimit)) + "…"
    }

    private static func isBlank(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return data.isEmpty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
