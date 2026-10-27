//
//  MuseUsageData.swift
//  Usage4Claude
//
//  Pure-data types + parsing for `muse usage --json` (Muse Code CLI).
//  Lives here (not Helpers/) so it can be cherry-picked into a SwiftPM test
//  target — every symbol here must stay free of `L.*`/`Logger`/UI dependency.
//  Display formatting for Muse belongs in a `+Formatting` extension later.
//
//  Contract reference: docs/MUSE_INTEGRATION.md §2.
//
//  Sample payload (muse 1.4.13):
//    {
//      "schemaVersion": 1,
//      "allowance": {
//        "tier": "Muse Code Power Usage",
//        "window": {"usedPercent": 19, "resetsAtMs": 1793075029000},
//        "weekly": {"usedPercent": 20, "resetsAtMs": 1793577600000},
//        "asOfMs": 1793072428666,
//        "source": "mint"
//      },
//      "reason": null,
//      "hint": null
//    }
//

import Foundation

// MARK: - 内部数据模型

/// Muse Code 使用量数据（应用内部使用的标准化结构）。
///
/// Muse 只有两个窗口，与 Claude/Codex 的「5小时 + 7天」形状相同：
/// `window` 是短周期窗口，`weekly` 是每周窗口。
/// CLI 不返回窗口时长，因此窗口长度由调用方按 5 小时 / 7 天假设，
/// 见 docs/MUSE_INTEGRATION.md §2「Things to verify later」。
nonisolated struct MuseUsageData: Sendable, Equatable {
    /// 套餐名，例如 "Muse Code Power Usage"；CLI 未提供时为 nil
    let tier: String?
    /// 短周期窗口
    let window: Limit
    /// 每周窗口
    let weekly: Limit
    /// 服务端测量时间（asOfMs），用于判断数据新鲜度
    let asOf: Date

    nonisolated struct Limit: Sendable, Equatable {
        /// 已用百分比 (0...100)
        let usedPercent: Double
        /// 重置时间
        let resetsAt: Date
    }
}

// MARK: - CLI 响应模型

/// `muse usage --json` 的原始响应模型。
///
/// 字段名与 CLI 输出完全一致（camelCase），因此不需要 CodingKeys。
/// 所有可选字段都按「缺失也不崩」处理：CLI 升级、字段改名、
/// 后端返回不完整数据时，报错要能看懂，而不是解析崩溃。
nonisolated struct MuseUsageResponse: Codable, Sendable {
    /// 契约版本。当前只支持 1；其他值视为需要升级应用。
    let schemaVersion: Int
    /// 成功时非 nil；未登录/额度不可用时为 nil，原因在 reason/hint
    let allowance: Allowance?
    /// 失败原因（人类可读），成功时为 nil
    let reason: String?
    /// 补充提示，成功时为 nil
    let hint: String?

    nonisolated struct Allowance: Codable, Sendable {
        let tier: String?
        let window: Window
        let weekly: Window
        /// 服务端测量时间，epoch 毫秒。缺失时回落到解析时刻。
        let asOfMs: Double?
        /// 数据来源后端，例如 "mint"
        let source: String?
    }

    nonisolated struct Window: Codable, Sendable {
        /// 已用百分比，0...100
        let usedPercent: Double
        /// 重置时间，epoch 毫秒
        let resetsAtMs: Double
    }
}

// MARK: - 解析错误

/// 解析 `muse usage --json` 输出时的错误。
///
/// 这里不提供 `errorDescription`：用户可见文案由视图层按 `L.*` 映射，
/// 保证 7 种语言一致（见 AGENTS.md「Localization」）。
nonisolated enum MuseUsageParseError: Error, Equatable {
    /// schemaVersion 不是本应用支持的版本
    case unsupportedSchema(Int)
    /// 响应没有 allowance：未登录、额度不可用或后端异常
    case missingAllowance(reason: String?, hint: String?)
    /// 输出为空或不是合法 JSON
    case malformedOutput
}

extension MuseUsageResponse {
    /// 将 CLI 响应转换为内部模型。
    ///
    /// 规则：
    /// - `schemaVersion != 1` 直接失败，避免把未来格式当成当前格式显示。
    /// - `allowance == nil` 直接失败，并把 reason/hint 带出去供 UI 显示。
    /// - `usedPercent` 钳制到 0...100，非有限值按 0 处理：环形图和阈值逻辑
    ///   假设输入在范围内，越界数据不能让它画错或反复触发通知。
    /// - 毫秒时间戳除 1000 转 Date。已过去的重置时间照常返回，
    ///   由视图层标记为过期，不在模型层丢弃数据。
    func toMuseUsageData(now: Date = Date()) throws -> MuseUsageData {
        guard schemaVersion == 1 else {
            throw MuseUsageParseError.unsupportedSchema(schemaVersion)
        }
        guard let allowance else {
            throw MuseUsageParseError.missingAllowance(reason: reason, hint: hint)
        }

        func normalized(_ raw: Double) -> Double {
            guard raw.isFinite else { return 0 }
            return min(max(raw, 0), 100)
        }

        func date(fromMilliseconds value: Double) -> Date {
            guard value.isFinite else { return now }
            return Date(timeIntervalSince1970: value / 1000)
        }

        return MuseUsageData(
            tier: allowance.tier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            window: .init(
                usedPercent: normalized(allowance.window.usedPercent),
                resetsAt: date(fromMilliseconds: allowance.window.resetsAtMs)
            ),
            weekly: .init(
                usedPercent: normalized(allowance.weekly.usedPercent),
                resetsAt: date(fromMilliseconds: allowance.weekly.resetsAtMs)
            ),
            asOf: allowance.asOfMs.map(date(fromMilliseconds:)) ?? now
        )
    }

    /// 解码并转换。CLI 输出必须是一个 JSON 对象，不接受前后杂项文本。
    static func parse(_ data: Data, now: Date = Date()) throws -> MuseUsageData {
        guard !data.isEmpty else {
            throw MuseUsageParseError.malformedOutput
        }
        let response: MuseUsageResponse
        do {
            response = try JSONDecoder().decode(MuseUsageResponse.self, from: data)
        } catch {
            throw MuseUsageParseError.malformedOutput
        }
        return try response.toMuseUsageData(now: now)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
