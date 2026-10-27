# AGENTS.md

Context for any coding agent working in this repo. Read this before changing
code. The detailed implementation plan for the feature this fork exists for is
in `docs/MUSE_INTEGRATION.md`.

---

## 1. What this repo is

A personal macOS menu bar app that shows how much of each AI subscription's
quota is used and when each limit resets. It is a fork of
[f-is-h/Usage4Claude](https://github.com/f-is-h/Usage4Claude) (MIT license),
built and run locally by Ethan. It is not distributed and does not publish
releases.

| | |
|---|---|
| Owner | `DigitalWestern` |
| Fork | `https://github.com/DigitalWestern/agent-usage` |
| Upstream | `https://github.com/f-is-h/Usage4Claude` (actively developed) |
| Stack | Swift 5.9+, SwiftUI + AppKit, macOS 13+ |
| App build | `Usage4Claude.xcodeproj` (authoritative build) |
| Unit tests | SwiftPM (`swift test`) against pure functions only |

### The goal

The app tracks two providers today: Claude and Codex. Ethan also uses **Muse
Code** (`muse`, installed at `~/.local/bin/muse`), whose usage is only visible
by opening the CLI and reading its status line. This fork exists to add Muse as
a third provider so every subscription shows in one menu bar, then retire the
upstream app.

Everything else follows from that:

- Keep the fork close enough to upstream that `git merge upstream/main` still
  works. Prefer additive changes in new files over edits to shared code.
- Do not redesign the app. The value here is the Muse column, not a rewrite.
- Never commit credentials, tokens, or the contents of `~/.config/muse/`.

---

## 2. Current state (verified 2026-10-26)

- `main` is upstream `3.5.0` plus documentation. **No Muse code exists yet.**
- Baseline is green. Confirm it before you start, so you know a later failure
  is yours:
  - `swift test` → 370 tests, 0 failures
  - `xcodebuild -project Usage4Claude.xcodeproj -scheme Usage4Claude-Debug -configuration Debug -derivedDataPath /tmp/u4c-dd CODE_SIGNING_ALLOWED=NO build` → `BUILD SUCCEEDED`
- The app is **hardcoded for exactly two providers**. `isMultiProviderActive`
  is a `Bool`, the detail window is 290pt for one provider and 580pt for two,
  and `switch` statements over `ProviderType` deliberately have no `default:`.
  Adding a third provider is a refactor across UI, settings, notifications and
  diagnostics, not a copy of the Codex files.

---

## 3. Decisions already made — do not re-litigate without asking Ethan

1. **Muse data comes from the CLI**: `muse usage --json`. Do not reverse
   engineer the HTTP endpoint or read `~/.config/muse/auth.json`. The CLI owns
   authentication, token refresh and the schema; reimplementing them is how
   this app breaks every time Muse ships a change.
2. **The local build runs without App Sandbox.**
   `Config/Usage4Claude.entitlements` currently sets
   `com.apple.security.app-sandbox = true`, which blocks both spawning a
   subprocess and reading `~/.config/muse`. Turning the sandbox off is the
   cheapest correct fix for a personal build. Read
   `docs/MUSE_INTEGRATION.md` §3 before changing it.
3. **Keep the product name and bundle ID** (`Usage4Claude`,
   `xyz.fi5h.Usage4Claude`). Renaming touches the Xcode project, Sparkle keys,
   the Keychain service names and all 7 localization files. That is a separate
   optional task; do not fold it into provider work.
4. **Do not touch `website/`.** It is upstream's marketing site, and
   `website/legal.html` is a Stripe-reviewed legal page. This fork does not
   publish it.
5. **Do not touch `.github/workflows/release.yml` triggers** beyond what is
   already done here. Releases belong to upstream.

---

## 4. Quickstart

```bash
# 1. Unit tests (fast, ~3s, no Xcode UI needed)
swift test

# 2. Build the app for local use
xcodebuild -project Usage4Claude.xcodeproj \
  -scheme Usage4Claude-Debug -configuration Debug \
  -derivedDataPath /tmp/u4c-dd CODE_SIGNING_ALLOWED=NO build
open /tmp/u4c-dd/Build/Products/Debug/Usage4Claude.app

# 3. Localization parity (7 languages, enforced upstream in CI)
python3 scripts/check_l10n.py
```

- `./scripts/build.sh` is upstream's release packager. It archives, exports and
  builds a DMG, and expects a signing identity. **Use the `xcodebuild` command
  above for development**, not `build.sh`.
- Xcode scheme: `Usage4Claude-Debug`. Set a development team in Xcode if
  signing prompts appear; the `CODE_SIGNING_ALLOWED=NO` build needs none.
- The `.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup` (object version
  77), so **new `.swift` files under `Usage4Claude/` are picked up
  automatically**. You do not edit `project.pbxproj` to add files.
- `Package.swift` is the exception: its `sources:` list is an explicit
  allowlist. A new pure-function file is invisible to `swift test` until you
  add it there.

---

## 5. Architecture map

```
Usage4Claude/
  App/
    ClaudeUsageMonitorApp.swift   app entry, AppDelegate wiring
    MenuBarManager.swift          NSStatusItem, menus, account switching (690 lines)
    MenuBarIconRenderer.swift     all menu bar icon drawing/composition (719 lines)
    MenuBarUI.swift               context menu construction
  Models/
    ProviderType.swift            .claude / .codex <- the enum to extend
    UserSettings.swift            settings facade + LimitType enum (1417 lines)
    AccountStore.swift            accounts, current account, credentials
    Account.swift                 per-provider account record
    ClaudeAPIResponseModels.swift Claude response models (pure, testable)
    CodexUsageData.swift          Codex models + parsing (pure, testable)
    CodexSessionTokenRotation.swift
    UserSettings + Appearance/LaunchAtLogin/Monitoring splits
  Services/
    ClaudeAPIService.swift        cookie + OAuth paths
    CodexAPIService.swift         two-step auth
    OAuthTokenCache.swift         actor, single-flight token refresh
    KeychainManager.swift         Keychain (UserDefaults with DEBUG_ prefix in DEBUG)
    NotificationManager.swift
  Helpers/
    DataRefreshManager.swift      timers, refresh orchestration, backoff (1046 lines)
    SmartRefreshPolicy.swift      active -> idle 1/3/5/10 min
    UsageFetchBackoffPolicy.swift per-provider retry backoff
    LocalizationHelper.swift      L.* accessors (617 lines)
    UsagePaceGraphMath.swift      pure math behind the pace graph
    UsageData+Formatting.swift    display strings for Claude
    CodexUsageData+Formatting.swift
  Views/
    UsageDetailView.swift         popover; columns, widths, error states (1040 lines)
    Components/CodexColumnView.swift  one provider's column (262 lines) <- template
    Components/PaceGraphView.swift
    Settings/...                  settings tabs (General/Display/Auth/Data/About)
  Resources/*.lproj/              Localizable.strings x7
```

### How a refresh flows today

1. `DataRefreshManager` owns timers and calls the per-provider services.
2. Each service authenticates, fetches, and calls back **on the main thread**.
3. Results land in `@Published` state: `usageData` (Claude),
   `codexUsageData`, plus separate `*ErrorMessage` and `*RequiresAuthAction`
   flags so one provider failing never hides the other.
4. `MenuBarManager` observes and rebuilds the status item icon through
   `MenuBarIconRenderer`.
5. `UsageDetailView` renders a column per active provider.

`ProviderType` is the spine. Adding a case there produces compiler errors at
every site that must be updated. **That is the feature, not a nuisance.** Do
not silence those errors with a `default:` branch.

---

## 6. Adding a provider — the checklist

The authoritative, file-by-file plan with rationale is
`docs/MUSE_INTEGRATION.md`. Summary of the blast radius:

| Area | Files |
|---|---|
| Identity | `Models/ProviderType.swift` |
| Data model | new `Models/MuseUsageData.swift` (pure, add to `Package.swift`) |
| Fetch | new `Services/MuseAPIService.swift`, `Services/MuseCLILocator.swift` |
| Refresh | `Helpers/DataRefreshManager.swift` |
| Menu bar | `App/MenuBarManager.swift`, `App/MenuBarIconRenderer.swift`, `App/MenuBarUI.swift` |
| Detail window | `Views/UsageDetailView.swift`, new `Views/Components/MuseColumnView.swift` |
| Limits + display | `Models/UserSettings.swift` (`LimitType`, `isMultiProviderActive`, custom display) |
| Settings UI | `Views/Settings/Tabs/{General,Display,Auth}SettingsView.swift` |
| Notifications | `Helpers/NotificationDecisionEngine.swift` |
| Diagnostics | `Helpers/DiagnosticRunner.swift`, `Models/DiagnosticReport.swift` |
| Strings | `Helpers/LocalizationHelper.swift` + all 7 `Resources/*.lproj/Localizable.strings` |
| Tests | new `Tests/Usage4ClaudeCoreTests/MuseUsageResponseTests.swift` |

---

## 7. Conventions

- **Commits**: English, imperative, no emoji, no `Co-Authored-By`. See
  `docs/COMMIT_MESSAGE_GUIDELINES.md`.
- **Localization**: every user-visible string goes through `L.*`. Add the key
  to all 7 languages. `scripts/check_l10n.py` enforces key parity, not
  translation quality — English text in the other six files passes the check,
  so mark entries you could not translate clearly and fix them later.
- **Main thread**: service-layer completions must call back on the main thread.
- **Pure code**: anything without UI or `L.*` dependencies belongs in a file
  that is listed in `Package.swift` and covered by `swift test`.
- **New root `*.md` files** are gitignored by `/*.md`. Add an
  `!/filename.md` allowlist entry in `.gitignore` or the file will not be
  committed.
- **Source comments**: the codebase mixes Chinese and English comments. Match
  the file you are editing; do not mass-translate.
- **Upstream docs**: `docs/archive/` holds outdated docs. New docs go in
  `docs/`, not the repo root.

---

## 8. Pitfalls that have already bitten this repo

- **App Sandbox blocks child processes.** Under
  `com.apple.security.app-sandbox`, `Process` cannot exec an external binary
  and the app cannot read `~/.config/muse`. This is the gate on the whole
  feature.
- **GUI apps do not inherit the shell `PATH`.** Launching from Finder or
  Xcode means `~/.local/bin` is not on `PATH`. Resolve the binary against an
  explicit list of candidate paths and surface "Muse CLI not found" as a
  normal, actionable state — never crash and never assume `muse` is callable
  by name.
- **`muse usage --json` is a network call**, roughly 1.5s on a good day. Run
  it off the main thread with a hard timeout (10s) and make sure a hung CLI
  cannot wedge a refresh cycle.
- **The Muse JSON has no window duration.** It reports `usedPercent` and
  `resetsAtMs` only. The pace graph needs a window length, so treat the
  window as 5 hours and weekly as 7 days until measured otherwise, and say so
  in the code.
- **OAuth refresh tokens rotate.** Any token-fetching path must reuse
  `OAuthTokenCache`'s single-flight mechanism (upstream issues #87, #88).
  Muse avoids this entirely by shelling out, which is one more reason to keep
  that design.
- **DEBUG builds store credentials in `UserDefaults`** with a `DEBUG_` key
  prefix, separate from Release Keychain storage. Testing in Debug does not
  validate the Release credential path.
- **SwiftUI Canvas is clockwise-inverted** relative to `NSBezierPath` (the
  y-axis points down). See `docs/SWIFTUI_CANVAS_PATH_DRAWING_GUIDE.md` before
  drawing icons.
- **`Config/Info.plist` is a static file.** Xcode's auto-generation mode drops
  the Sparkle keys, so edit the plist directly.

---

## 9. Staying in sync with upstream

```bash
git fetch upstream
git merge upstream/main      # resolve by keeping our new files, taking upstream edits
swift test                   # upstream moves fast; confirm green after every merge
```

Fork-specific files (`AGENTS.md`, `docs/MUSE_INTEGRATION.md`, the Muse
provider files) should never conflict with upstream. Codex-related bug fixes
from upstream are worth taking; do not drift.

The fork's release workflow is **manual-only**: the upstream push trigger was
removed in `3be0e2b`, because this fork has no signing secrets and publishes
nothing. GitHub also keeps workflows on a new fork disabled until they are
enabled once in the Actions tab; `Test` is the only one worth enabling.

Do not edit `CHANGELOG.md` or `docs/RELEASE_NOTES.md` except when merging
upstream. Releases are upstream's job.

---

## 10. Definition of done for the Muse feature

- [ ] Muse column appears beside Claude and Codex, matching their visual
      language (ring and pace graph, used/remaining toggle, stale-data
      indicator).
- [ ] Menu bar shows Muse icons; custom display lets each Muse limit be
      toggled individually.
- [ ] Settings shows Muse status: CLI found / not found / not signed in, with
      the resolved binary path visible.
- [ ] Quota threshold notifications fire for Muse like the other providers.
- [ ] `swift test` passes and includes new tests for Muse JSON decoding,
      including the malformed / unauthenticated cases.
- [ ] `python3 scripts/check_l10n.py` passes with every new key present in all
      7 languages.
- [ ] App builds and runs from a clean checkout with the commands in §4, with
      no Muse installed, without crashing.
