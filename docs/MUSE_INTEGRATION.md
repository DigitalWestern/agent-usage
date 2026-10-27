# Muse Code integration plan

Working notes and the implementation plan for adding **Muse Code** as a third
usage provider. Written 2026-10-26 against `muse` 1.4.13 and this fork's
`main` at upstream 3.5.0.

Read `AGENTS.md` first for repo orientation, build commands and conventions.

---

## 1. Scope

**v1 (what this doc plans):**

- Muse appears as a third provider next to Claude and Codex: its own column in
  the detail window, its own menu bar icons, its own limit toggles, its own
  notification thresholds.
- Data comes from the locally installed `muse` CLI.
- Works when Muse is not installed: the app shows an actionable "CLI not
  found" state and everything else keeps working.

**Out of scope for v1:**

- Managing Muse login from inside the app. The CLI owns auth; the app reports
  whether a session exists.
- Multiple Muse accounts. The CLI holds one credential set; v1 maps it to one
  implicit account.
- Renaming the app, product or bundle ID.
- Publishing, signing, notarizing or distributing this fork.

---

## 2. The CLI contract (verified locally)

Muse Code is Meta's terminal coding agent. Its CLI is installed as a shell
launcher at `~/.local/bin/muse` that keeps a versioned binary beside it
(`~/.local/bin/muse-bin-<version>`).

### Command

```bash
muse usage --json
```

- Exit code `0`, one JSON object on stdout, nothing on stderr.
- Takes **~1.5s** through the launcher (it may check for updates, throttled to
  one hour) and **~0.47s** through the versioned binary directly.
- No TTY required. Safe to run from `Process`.

### Success payload

```json
{
  "schemaVersion": 1,
  "allowance": {
    "tier": "Muse Code Power Usage",
    "window": { "usedPercent": 19, "resetsAtMs": 1793075029000 },
    "weekly": { "usedPercent": 20, "resetsAtMs": 1793577600000 },
    "asOfMs": 1793072428666,
    "source": "mint"
  },
  "reason": null,
  "hint": null
}
```

| Field | Meaning |
|---|---|
| `schemaVersion` | Contract version. Reject anything that is not `1` |
| `allowance.tier` | Plan name, e.g. "Muse Code Power Usage" |
| `allowance.window.usedPercent` | Used share of the short rolling window, 0–100 |
| `allowance.window.resetsAtMs` | Window reset, Unix epoch **milliseconds** |
| `allowance.weekly.usedPercent` | Used share of the weekly window, 0–100 |
| `allowance.weekly.resetsAtMs` | Weekly reset, Unix epoch **milliseconds** |
| `allowance.asOfMs` | When the server measured this, epoch ms |
| `allowance.source` | Backend that produced it (`mint`) |
| `reason` / `hint` | Null on success. Assume they carry a human string when `allowance` is null |

The matching human output, for reference:

```
Tier: Muse Code Power Usage
Window: 19% used, resets in 43m
Weekly: 20% used, resets in 5d 20h
```

### Failure the app must handle

| Condition | Observed behaviour | App state |
|---|---|---|
| Not signed in | stderr `muse usage: not logged in: run \`muse login\` first`, exit `1`, empty stdout | "Muse: not signed in", with the command to run |
| Binary missing | `posix_spawn` fails / `ENOENT` | "Muse CLI not found", with the paths searched |
| Timeout (>10s) | process still running | transient error, keep last data, retry with backoff |
| Non-zero exit, other | stderr text | transient error, surface stderr (redacted, truncated) |
| `allowance: null` | not yet observed | treat as an error carrying `reason`/`hint` |
| Malformed JSON | not yet observed | treat as an error; never crash |

Known environment variables in the launcher: `MUSE_CHANNEL`,
`MUSE_UPDATE_INTERVAL_SECONDS`, `MUSE_AUTH_PATH`, `XDG_CONFIG_HOME`. Do not
depend on them in the app; they exist only for manual testing.

### Things to verify later

1. **Window length.** The JSON reports percentages and reset times but not the
   window duration, and the pace graph needs one. Claude and Codex both use
   5-hour and 7-day windows, and the Muse HUD reads like the same shape, so
   v1 assumes 5h / 7d. Confirm by recording `resetsAtMs` across a rollover: if
   it jumps forward by exactly the window length, the assumption holds. Log the
   observation in this file when you know.
2. **`allowance: null`** shape and its `reason` values.
3. **Expired token** behaviour, as opposed to "never logged in".

---

## 3. The blocker: App Sandbox — RESOLVED

**Done in `cd3e48b`.** The sandbox is off; Step 1 of §5 no longer needs doing.
The analysis stays here because it is the reason the sandbox must not come
back.

`Config/Usage4Claude.entitlements` originally enabled the sandbox:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
```

Under App Sandbox the app cannot:

- `Process`-exec `~/.local/bin/muse` (external binary, outside the bundle),
- read `~/.config/muse/auth.json`,
- write anywhere outside its container.

There is no entitlement that grants an arbitrary child process. The options:

| Option | Cost | Verdict |
|---|---|---|
| **A. Disable the sandbox** for this local build | one entitlement line; app loses sandbox isolation | **Recommended.** Personal build, not distributed, no Mac App Store |
| B. Reimplement the Muse HTTP call against `~/.config/muse/auth.json` | new OAuth refresh logic, new failure modes, breaks on Muse changes; still needs sandbox off to read the token | Rejected |
| C. Ship the Muse binary inside the app bundle | binary needs its own update channel and credentials outside the container; still blocked | Rejected |
| D. XPC helper + app group | days of work for one menu bar app | Rejected |

### Change (applied)

Remove `com.apple.security.app-sandbox` (and the Sparkle XPC
`temporary-exception` array that exists only because of it) from
`Config/Usage4Claude.entitlements`, set `ENABLE_APP_SANDBOX = NO` in both
build configurations of `Usage4Claude.xcodeproj`, and drop
`ENABLE_USER_SELECTED_FILES` which only applies under the sandbox. Keep
`network.client`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>   <!-- loopback OAuth callback for Claude/Codex logins -->
```

Consequences to state in the commit message: the app is no longer sandboxed,
so it is not Mac App Store eligible and Sparkle's sandbox-specific XPC
services are no longer used. Neither matters for this fork.

Because this is a security-relevant change, tell Ethan before making it, and
keep it in its own commit so it can be reverted independently. That is what
`cd3e48b` is.

---

## 4. Data model

```swift
// Models/MuseUsageData.swift  (pure: no L.*, no AppKit, no Logger)
struct MuseUsageData: Sendable, Equatable {
    let tier: String?
    let window: Limit
    let weekly: Limit
    let asOf: Date

    struct Limit: Sendable, Equatable {
        let usedPercent: Double
        let resetsAt: Date
    }
}

nonisolated struct MuseUsageResponse: Codable, Sendable {
    let schemaVersion: Int
    let allowance: Allowance?
    let reason: String?
    let hint: String?

    struct Allowance: Codable, Sendable {
        let tier: String?
        let window: Window
        let weekly: Window
        let asOfMs: Double
        let source: String?
    }

    struct Window: Codable, Sendable {
        let usedPercent: Double
        let resetsAtMs: Double
    }
}
```

Decoding rules:

- Epoch values are **milliseconds** as `Double` — divide by 1000, do not
  decode as `Int` (some servers emit fractional ms).
- Clamp `usedPercent` to `0...100`; the ring and threshold logic assume it.
- `schemaVersion != 1` is a hard error with a clear message, so a future schema
  change surfaces as "update needed" rather than wrong numbers.
- `resetsAtMs` in the past means the window has rolled over but the CLI served
  a stale snapshot. Show the data, mark it stale, do not display a negative
  countdown.

Mapping to the UI's limit abstraction:

| Muse | `LimitType` case | Icon shape | Notes |
|---|---|---|---|
| short window | `.musePrimary` | circle (like `.codexPrimary`) | "5-Hour"-style row |
| weekly | `.museWeekly` | dashed circle (like `.codexSecondary`) | weekly row, threshold pair |

Pick a hue not already used by Claude (green/orange/red, purple, pink) or Codex
(teal, sky blue, gold). Violet/magenta is free and reads as distinct.

---

## 5. Implementation order

Each step should leave the app building and running. Do not batch these into
one commit.

### Step 1 — sandbox off (DONE, `cd3e48b`)

- `Config/Usage4Claude.entitlements`, `ENABLE_APP_SANDBOX`,
  `ENABLE_USER_SELECTED_FILES` changed; build verified signed and unsandboxed.
- Remaining human check: launch the app and confirm Claude and Codex still
  refresh and do not re-prompt for the Keychain more than once.

### Step 2 — CLI locator and service (no UI yet)

New `Services/MuseCLILocator.swift`:

```swift
enum MuseCLILocator {
    static var candidatePaths: [String] { [
        "\(NSHomeDirectory())/.local/bin/muse",
        "/opt/homebrew/bin/muse",
        "/usr/local/bin/muse"
    ] }
    static func locate() -> URL?
}
```

- Check `isExecutableFile` on each candidate. Do **not** rely on `PATH`; a
  Finder-launched app has a minimal environment.
- Honour an optional override path from settings (useful if Muse lands
  elsewhere).

New `Services/MuseAPIService.swift: UsageProvider`:

- `providerType = .muse`, implement `cancelAllRequests()`.
- `func fetchUsage(completion: @escaping (Result<MuseUsageData, Error>) -> Void)`
- `Process` + `Pipe`, `standardOutput`/`standardError` captured, environment
  inherited, 10-second hard timeout that calls `terminate()`.
- Never assume the CLI returns quickly and never block the main thread
  (`Process.waitUntilExit` on a background queue, or `terminationHandler`).
- A dedicated `enum MuseUsageError: LocalizedError` with `.cliNotFound`,
  `.notSignedIn`, `.timedOut`, `.schemaUnsupported(Int)`, `.malformedOutput`,
  `.commandFailed(String)` so the UI can branch. Classify `.notSignedIn` by
  matching `not logged in` in stderr — that string is the CLI's contract and
  is safer than parsing exit codes alone.

Add both new pure files to `Package.swift` `sources:` when they contain no UI
or `L.*` dependencies, and write decoder tests immediately.

### Step 3 — refresh plumbing

`Helpers/DataRefreshManager.swift`:

- `@Published var museUsageData: MuseUsageData?`
- `@Published var museErrorMessage: String?`
- `@Published var museErrorRequiresAuthAction = false`
- `@Published private(set) var museCLIMissing = false`
- `private var museBackoff = UsageFetchBackoffPolicy.State.initial`
- `shouldFetchMuseUsage` gate, mirroring `shouldFetchCodexUsage` including the
  DEBUG display-override branch.
- Refresh alongside the other two, reusing `recordFetchFailure` /
  `recordFetchSuccess` and `isBackoffElapsed`.
- Include Muse in `monitoringUtilizations` so smart refresh notices its
  changes.
- Announce resets through the existing reset-coalescing path.

### Step 4 — generalize "two providers" to N

This is the part that is not a copy-paste. Do it in small commits:

1. `UserSettings.isMultiProviderActive` currently returns `Bool` for
   Claude+Codex. Introduce `var activeProviders: [ProviderType]` as the single
   source of truth, and derive `isMultiProviderActive` from
   `activeProviders.count > 1` so existing call sites keep working.
2. `UsageDetailView`: `contentWidth` becomes `290 * activeProviders.count`
   (cap at 3 columns, or switch to a responsive HStack) and the Claude/Codex
   column pair is built by iterating `activeProviders`.
3. `MenuBarManager` / `MenuBarIconRenderer`: `createMultiProviderIcon`
   currently branches Claude-vs-Codex. Compose one icon group per active
   provider and join with `combineIcons(_:)`, which already takes an array.
4. Replace `switch provider { case .claude: … case .codex: … }` sites with
   exhaustive `case .muse:` branches — let the compiler find them. **Do not add
   `default:`**, that is how the next provider silently breaks.

Run the app after each sub-step with Muse disabled to confirm the existing
two-provider layout is pixel-identical.

### Step 5 — column UI

New `Views/Components/MuseColumnView.swift`, modelled on
`CodexColumnView.swift`:

- Header: "Muse" + tier as subtitle, stale-data indicator, cached-at time.
- Rows: window, weekly — used/remaining toggle, ring/pace graphs, reset
  countdowns. Reuse `UsageRowComponents` and `PaceGraphView` rather than
  drawing anything new.
- Empty/error states: CLI missing, not signed in, transient failure. Mirror
  how Codex renders `codexNeedsRelogin`.
- Add the pane to `UsageDetailView`.

### Step 6 — settings

- `GeneralSettingsView`: Muse toggle. Default on when the CLI is present,
  off otherwise.
- `DisplaySettingsView` / `LimitSelectionSection`: the two Muse limit types
  join custom display.
- `AuthSettingsView`: a Muse section that is **status, not login** — resolved
  binary path, whether a session exists, a "Check again" button, and the
  `muse login` instruction. No credentials pass through the app.
- `NotificationSection`: Muse thresholds reuse the weekly/extra pairs.

### Step 7 — notifications and diagnostics

- `NotificationDecisionEngine` takes a `ProviderType`; verify the Muse cases
  fall out of the existing generic code. Add the prefix strings only if the
  type switches are exhaustive.
- `DiagnosticRunner`: a Muse runner that reports binary path, version
  (`muse --version`), decoded percentages and reset times, and the classified
  error. Redact nothing sensitive because there is nothing sensitive — but do
  not dump the whole JSON if `reason`/`hint` ever carry an identifier.

### Step 8 — strings, tests, docs

- Add every new key to `Helpers/LocalizationHelper.swift` and all seven
  `Resources/*.lproj/Localizable.strings`.
- `Tests/Usage4ClaudeCoreTests/MuseUsageResponseTests.swift`: success payload,
  `allowance: null`, `schemaVersion: 2`, fractional/overflowing percentages,
  past reset times, malformed JSON, empty stdout.
- Update `README.md` feature table and this file's open questions.

---

## 6. Localization keys (proposed)

```
muse_status_title           Muse
muse_cli_found              Muse CLI found at %@
muse_cli_missing            Muse CLI not found. Install Muse Code, then check again.
muse_not_logged_in          Muse is not signed in. Run `muse login` in Terminal.
muse_recheck                Check again
muse_tier                   Plan
muse_window_limit          Muse Window Limit
muse_weekly_limit          Muse Weekly Limit
```

Follow the existing naming style (`codex_primary_limit`), keep the keys in all
7 files, and only touch English if you cannot translate the rest.

---

## 7. Manual verification

```bash
# Raw data
~/.local/bin/muse usage --json | python3 -m json.tool

# Timing (expect ~0.5s direct, ~1.5s through the launcher)
time ~/.local/bin/muse usage --json

# Not-signed-in behaviour, without touching the real credentials
HOME=$(mktemp -d) ~/.local/bin/muse-bin-* usage --json; echo "exit=$?"

# App (signed; run scripts/setup-local-signing.sh once per machine)
xcodebuild -project Usage4Claude.xcodeproj -scheme Usage4Claude-Debug \
  -configuration Debug -derivedDataPath /tmp/u4c-dd build
codesign -dv /tmp/u4c-dd/Build/Products/Debug/Usage4Claude.app 2>&1 | grep Authority
open /tmp/u4c-dd/Build/Products/Debug/Usage4Claude.app
swift test
python3 scripts/check_l10n.py
```

Acceptance checks:

1. Muse column shows both limits with correct percentages against the CLI.
2. Ring, pace graph, used/remaining toggle and reset countdowns all work.
3. Quit Muse login (`mv ~/.config/muse/auth.json{,.bak}`) and confirm the app
   shows "not signed in", keeps Claude and Codex working, and recovers after
   restoring the file.
4. Rename the binary away and confirm "CLI not found" instead of a crash.
5. Disable Muse in settings: the window returns to 1 or 2 columns and the menu
   bar drops its icons.
6. Threshold notifications fire once per crossing, not on every refresh.

---

## 8. Open questions for Ethan

1. **Pace graph default** for Muse weekly: weekdays-only or calendar days?
   Claude/Codex both expose this per limit; pick the same default as Codex.
2. **Column order** when all three are on: Claude, Codex, Muse (planned), or
   by plan cost?

Sandbox removal is settled (§3). Signing setup is settled
(`docs/LOCAL_SIGNING.md`).
