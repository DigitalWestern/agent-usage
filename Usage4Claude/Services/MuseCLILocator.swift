//
//  MuseCLILocator.swift
//  Usage4Claude
//
//  Finds the `muse` executable without relying on PATH.
//
//  GUI apps launched from Finder or Xcode do not inherit the login shell's
//  PATH, so `~/.local/bin` is not on it and `Process` cannot resolve "muse" by
//  name. Every lookup here is an absolute path plus an executable check.
//
//  The lookup function is injectable so the ordering rules can be unit-tested
//  without touching the filesystem. Must stay free of `L.*`/UI dependency.
//

import Foundation

nonisolated struct MuseCLILocator {
    /// Default install locations, in priority order.
    ///
    /// Muse installs its launcher at `~/.local/bin/muse` (a shell script that
    /// keeps a versioned `muse-bin-*` beside it). The Homebrew paths are only
    /// plausible alternates; the launcher path is the one that matters.
    static var defaultCandidatePaths: [String] {
        [
            "\(NSHomeDirectory())/.local/bin/muse",
            "/opt/homebrew/bin/muse",
            "/usr/local/bin/muse"
        ]
    }

    let candidatePaths: [String]
    private let isExecutable: (String) -> Bool

    init(
        candidatePaths: [String] = MuseCLILocator.defaultCandidatePaths,
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
    }

    /// Resolve the executable. A non-empty `overridePath` (a setting the user
    /// can point anywhere) wins, but it is still checked before use.
    func locate(overridePath: String? = nil) -> URL? {
        searchedPaths(overridePath: overridePath)
            .first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }

    /// Every path this locator would try, in order, with duplicates removed.
    /// Used verbatim in the "CLI not found" message so the user can see where
    /// the app looked.
    func searchedPaths(overridePath: String? = nil) -> [String] {
        var paths: [String] = []
        if let override = normalize(overridePath) {
            paths.append(override)
        }
        for candidate in candidatePaths where !paths.contains(candidate) {
            paths.append(candidate)
        }
        return paths
    }

    /// Trim whitespace and expand a leading `~`, since a path typed into
    /// settings arrives as a raw string.
    private func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst())
        }
        return trimmed
    }
}
