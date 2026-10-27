# Local code signing

Why: macOS ties Keychain access to an app's code signature. Rebuilding this app
with a new signature makes macOS treat the new build as a different program, so
every rebuild asks for your password again when the app reads your Claude or
Codex credentials. A certificate that stays put gives every build the same
identity, and "Always Allow" then works permanently.

This is also why this fork signs with the same certificate name upstream uses,
`Usage4Claude-CodeSigning`. The Xcode project already points at it
(`CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE = Manual`, no team), so no build flags
are needed once the identity exists.

## One-time setup

```bash
./scripts/setup-local-signing.sh
```

The script:

1. Stops if `Usage4Claude-CodeSigning` already exists.
2. Generates a 4096-bit RSA key and a self-signed certificate with the code
   signing extended key usage, valid 10 years.
3. Imports both into `~/Library/Keychains/login.keychain-db`, granting
   `/usr/bin/codesign` access.
4. Marks the certificate trusted for code signing in the user trust domain, so
   `codesign` accepts the identity.

macOS may show one or two keychain dialogs during this. That is the setup, not
an ongoing cost.

Verify:

```bash
security find-identity -v -p codesigning
#  1) A1B2... "Usage4Claude-CodeSigning"
```

## Building

```bash
xcodebuild -project Usage4Claude.xcodeproj \
  -scheme Usage4Claude-Debug -configuration Debug \
  -derivedDataPath /tmp/u4c-dd build
```

No signing flags. `codesign -dv` on the result should print
`Authority=Usage4Claude-CodeSigning`.

`CODE_SIGNING_ALLOWED=NO` still builds, but produces an ad-hoc signature, which
is the thing that causes the repeated password prompts. Use it only to check
that code compiles on a machine without the identity.

## Notes

- The certificate is self-signed and local. It carries no Apple trust and
  cannot sign anything for distribution. Gatekeeper on another Mac will reject
  it, which is fine because this app is not distributed.
- If the identity is deleted or expires, run the script again. Keychain ACLs
  from the old certificate stop matching, so the first launch after that asks
  once more.
- Do not enable App Sandbox again. It is what blocks the Muse CLI. See
  `docs/MUSE_INTEGRATION.md` §3.
