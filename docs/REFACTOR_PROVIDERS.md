# Refactor: two providers → N providers

Everything before the Muse feature becomes visible. Read this together with
`AGENTS.md` (conventions) and `docs/MUSE_INTEGRATION.md` (the feature plan and
the CLI contract).

## Why a refactor at all

The app was built for exactly two providers, Claude and Codex. That assumption
is not one line: it is a `Bool`, a fixed window width, three explicit
`CodexUsageData?` parameters in signatures, and a set of `switch` statements
with no `default:` branch. Muse is the third provider, so every one of those
sites has to become "one per active provider".

The good news: the compiler enumerates the `switch` sites for you. The bad news:
`case .codex` also appears in `LimitType` switches, which is a different enum
with a different fix.

---

## Measured inventory (2026-10-27, `main` at `4516724`)

Line numbers are from that commit. They drift; the file list does not.

### 1. `ProviderType` switches — 9 sites, 8 files

Adding `case muse` makes each of these a hard compile error. Each needs a
`.muse` arm, not a `default:`.

| File | Line | What the switch does |
|---|---|---|
| `Models/ProviderAuthPath.swift` | 51 | credential → auth path |
| `Models/DiagnosticReport.swift` | 186 | diagnostic section title |
| `Helpers/DataRefreshManager.swift` | 805 | which provider a notification/context event refers to |
| `Helpers/DataRefreshManager.swift` | 873 | backoff state accessor |
| `App/MenuBarIconRenderer.swift` | 261 | provider brand icon |
| `Views/UsageDetailView.swift` | 208 | stale-data warning per provider |
| `Views/DiagnosticsView.swift` | 104 | SF Symbol per provider |
| `Views/Settings/Tabs/AuthSettingsView.swift` | 219 | settings account section icon |
| `Views/Settings/Welcome/SetupStepView.swift` | 436 | setup flow provider icon |

### 2. `LimitType` switches — 24 `case` lines, 8 files

Different enum (`Models/UserSettings.swift`, ~line 145). Muse needs two cases,
e.g. `.musePrimary` and `.museWeekly`. Every switch over `LimitType` grows by
two arms, plus the `provider` mapping, `isCircular`, `usesDashedStyle`,
`displayName` and the icon/color tables.

Find them with:

```bash
grep -rn "case \.fiveHour\|case \.codexPrimary" Usage4Claude --include="*.swift"
```

Files that carry a `LimitType` switch today: `UserSettings.swift`,
`MenuBarIconRenderer.swift`, `PaceGraphView.swift`, `UsageRowComponents.swift`,
`LimitSelectionSection.swift`, `NotificationDecisionEngine.swift`,
`IconShapePaths.swift`, `CodexColumnView.swift`.

### 3. Data threading — 69 references

```bash
grep -rn "codexUsageData" Usage4Claude --include="*.swift" | wc -l   # 69
```

Not all 69 need touching. The ones that define the shape:

- `MenuBarManager` publishes `usageData` and `codexUsageData` separately and
  forwards them to two subscriptions (`:64`, `:115`).
- `MenuBarIconRenderer.createIcon(usageData:codexUsageData:hasUpdate:button:)`
  takes both explicitly.
- `MenuBarUI.updateMenuBarIcon(usageData:codexUsageData:hasUpdate:shouldShowBadge:)`
  takes both explicitly.
- `UserSettings.getActiveDisplayTypes(usageData:codexUsageData:forMenuBar:)`
  takes both explicitly.

### 4. The `Bool` and the width

- `UserSettings.isMultiProviderActive` → `!accounts.isEmpty && !codexAccounts.isEmpty`,
  with a DEBUG branch. `Views/UsageDetailView.swift:94` reads it, plus the
  column layout at `:191`–`:196` and `:881`–`:890`.
- `contentWidth` is `290` or `580`; `multiProviderHeight`/`multiProviderDivider`
  assume two columns.

---

## Target design

Keep it boring. The goal is a third column, not a provider-abstraction framework.

```swift
// One value per provider, carried through the UI instead of two parameters.
enum ProviderSnapshot {
    case claude(UsageData)
    case codex(CodexUsageData)
    case muse(MuseUsageData)
}

// Single source of truth for "what is on screen".
var activeProviders: [ProviderType]   // order: claude, codex, muse
var isMultiProviderActive: Bool { activeProviders.count > 1 }  // keep the name
```

- `createIcon` and `updateMenuBarIcon` take `snapshots: [ProviderType: ProviderSnapshot]`
  and iterate `activeProviders`.
- Column layout becomes `290 * activeProviders.count`, capped at three, with the
  existing divider drawn between columns rather than the hardcoded pair.
- `getActiveDisplayTypes` takes the snapshot dictionary and returns limits for
  all active providers.
- Muse has **no `Account`**: the CLI holds one credential set. Do not add a
  `museAccounts` array. `Account.provider` decoding defaults to `.claude`, so
  nothing Muse-shaped should ever enter `AccountStore`.

---

## Execution order

Each step must leave the app building, running, and visually identical to
before, except the step that is supposed to change the UI.

**A. Add `ProviderType.muse`; fix the 9 sites.** Every new arm is inert: return
a placeholder or handle Muse in a way that never renders, because no Muse data
exists yet. No `default:`. Build until zero errors.

**B. Add the two `LimitType` cases; fix every switch.** Also inert. Watch for
`LimitType.allCases` / custom-display lists picking Muse up and showing empty
rows in settings before there is data — gate them behind "Muse is available".

**C. Replace the `Bool` with `activeProviders`.** Derive it exactly as today
(Claude accounts, Codex accounts) so 0/1/2-provider layouts stay
pixel-identical. Verify all three cases by launching with one provider
configured, then both.

**D. Refresh plumbing** (`docs/MUSE_INTEGRATION.md` §5 step 3). This is where
Muse first has data: `@Published museUsageData`, `museErrorMessage`,
`museErrorRequiresAuthAction`, `museCLIMissing`, `museBackoff`,
`shouldFetchMuseUsage`, plus `monitoringUtilizations`. `MuseAPIService` gains
`UsageProvider` conformance here.

**E. Column and menu bar** (§5 steps 4–5), then settings, notifications,
strings, diagnostics (§5 steps 6–8).

---

## Traps

- **The compiler's first pass is incomplete.** Adding `case muse` produced 8
  errors, while grep finds 9 sites: `Views/UsageDetailView.swift:208` was never
  reported, because Swift type-checks in batches and stops after the first
  failing batch. Rebuild repeatedly until there are zero errors. Do not trust
  the first error list as a checklist.

  Probe, if you want to reproduce it: temporarily add the case, run
  `xcodebuild -project Usage4Claude.xcodeproj -scheme Usage4Claude-Debug -configuration Debug -derivedDataPath /tmp/u4c-probe build 2>&1 | grep -E "^/Users.*error:"`,
  then revert. That is how the table above was produced.

- **Every `switch` over `ProviderType` and `LimitType` must stay exhaustive.**
  A `default:` compiles today and silently drops Muse in six months.

- **`ENABLE_APP_SANDBOX` must stay off.** `MuseAPIService` cannot spawn the CLI
  otherwise, and the failure is a `Process` launch error, not an obvious one.

- **No new files in `Package.swift` = no tests.** The SwiftPM target is an
  explicit allowlist. Any new pure file goes there in the same commit as its
  tests.

- **`swift test` does not compile the app target.** A green test suite says
  nothing about `MenuBarManager`/views. Always run `xcodebuild` too.

- **Clean build after adding files** (see `AGENTS.md` §4). Incremental builds
  can link stale objects and report success.

---

## Verification for every step

```bash
swift test
xcodebuild -project Usage4Claude.xcodeproj -scheme Usage4Claude-Debug \
  -configuration Debug -derivedDataPath /tmp/u4c-dd clean build
python3 scripts/check_l10n.py
```

Manual, after steps C and later:

1. Only Claude configured → one column, width 290, Claude icons only.
2. Claude + Codex → two columns, width 580, same as today's screenshots.
3. Add Muse → three columns, width 870, no clipping in the popover.
4. Turn Muse off → back to 2 columns, no ghost icons, no layout jump beyond the
   existing animation.
5. Launch with no Muse CLI installed → no crash, one clear status in settings.
