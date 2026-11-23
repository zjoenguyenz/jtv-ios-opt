# CLAUDE-OPT-BRIEF — JTV iOS optimisation engagement (Phase 1: audit only)

You are auditing the **iOS** app "JTV" (repo copy `jtv-ios-opt`, tree = production
`jtv-ios` @ `7b5c0895`, 51 files). This is the sibling of the tvOS engagement you
already completed (`jtv-tvos-opt`, AUDIT.md). Same owner, same rules.

## Access & workflow
- Your access is READ-ONLY. You output the audit as text in your chat; the owner
  forwards it; the leader applies/commits on this copy. Production repos are
  never written by you.
- Phase 1 = audit report only. No code changes in this phase.

## What this tree is
- iOS 17.0 minimum, SwiftUI app (target `JTV/`), KSPlayer pinned 2.3.4,
  AVPlayer lanes for HLS sources, plugin system identical in design to tvOS.
- IMPORTANT — shared core: the core files in this tree (MovieService,
  DebridResolver, Net, HLSProxy, LocalHLSServer, PluginManager, DiagLog, …) are
  byte-identical to the tvOS tree's core, which you already audited. Do NOT
  re-audit the core from zero. Verify the identity claim where cheap, reuse your
  tvOS findings for the core, and spend your effort on:
  1. the iOS shell (root/navigation, player session + KSPlayer integration,
     downloads, audio session, background/PiP behaviour, iOS lifecycle), and
  2. any core issue NOT already in the tvOS AUDIT.md, and
  3. drift between this tree's shared files and the tvOS tree's (iOS is the
     core's source of truth; sync runs one-way iOS → TV).

## Priorities (in order)
1. Correctness and playback reliability.
2. SwiftUI lifecycle / state churn (the tvOS A1/A2 pattern: work rebuilt or
   re-rendered on unrelated state changes) — look for the same family here.
3. Drift between duplicated code paths (shell replicas of core walks, etc.).
4. Performance — only with a concrete measurement plan (before/after); no
   unmeasured claims.
5. Build/CI hygiene: the iOS workflow has NO Xcode pin (floats on the runner
   default). The shipped IPA dissects as DTSDKName `iphoneos26.5`, MinOS 17.0 —
   SDK newer than target is normal on iOS (this is NOT the tvOS X2 disease);
   judge the missing pin on reproducibility grounds.

## Hard constraints
- Zero UI/design changes. Any behaviour change must be flagged as
  BEHAVIOUR CHANGE with evidence.
- Protected machinery (MovieService / DebridResolver / Net / HLSProxy /
  LocalHLSServer cores): propose-with-risk-analysis only.
- DiagLog witnesses are load-bearing diagnostics — never propose removing them.
- No secrets in code; report any credential you find as a finding, do not quote it.
- No fabricated APIs: if you are unsure an API exists in the iOS 17–26 SDKs,
  say so explicitly instead of guessing.
- tvOS focus rules do not apply here; iOS touch/PiP/audio-session rules do.

## Deliverable
`AUDIT-IOS.md` content (as chat text): ranked findings in the same format as the
tvOS audit (id, severity, file:line evidence, mechanism, user-visible effect,
proposed fix shape, risk), a section listing which tvOS findings also apply to
this tree unchanged, and a secrets/build section. Rank by user impact, not by
elegance.
