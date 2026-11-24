# AUDIT-IOS.md: JTV iOS code audit (Phase 1, report only)

- **Tree audited:** `zjoenguyenz/jtv-ios-opt` @ `6d551e8` (= production `jtv-ios` @ `7b5c0895`, 1.22.23/49). All `file:line` references are to this tree.
- **Compared against:** `jtv-tvos-opt` @ `aec5cdc`, including its CORE-SYNC.md and the `sync-reference/` live-plugin snapshot (jtv-source @ `e89c0454`).
- **Date:** 2026-11-23
- **Method:** static reading. No Xcode, Swift toolchain or device was available, so **nothing was compiled, run or measured.** Every performance statement is **UNMEASURED** and names its measurement.
- **Confidence:** CONFIRMED = follows from the code as read; PLAUSIBLE = the code permits it, but device evidence is needed.
- **Flags:**
  - `PROTECTED`: rule-3 machinery; propose-with-risk only.
  - `CORE`: a shared-core file. iOS is the source of truth, so a change here implies a re-port to tvOS.
  - `BEHAVIOUR CHANGE`: changes observable results, timings or logs; needs approval.
  - `UI-GATE`: needs a screenshot-identical proof.

No code was changed.

---

## 0. Core identity check (brief §"shared core")

The brief's byte-identical claim is **refuted for 5 of 14 shared Swift files.** Method: SHA-256 of both trees, checked against the hash columns in tvOS CORE-SYNC.md.

| File | iOS vs tvOS | iOS file = CORE-SYNC iOS hash? | Verdict |
|---|---|---|---|
| HLSProxy, LocalHLSServer, Models, PluginEngine, Library, MetadataOverlay, AutoSubCache, AutoSubSubtitles, DebridSecrets | identical | yes | in sync |
| DebridResolver, PluginManager, Cache, DiagLog | differ | yes | every difference is a **recorded** tvOS adaptation |
| MovieService | differs | **no, and the tvOS file also ≠ its recorded hash** | every hunk I inspected maps to a recorded adaptation (L-T05 deadline, L-T11 join, L-T12 `probeOnly`, L-T13 breadcrumb, MediaFusion `BundledSecrets` fallback). **The table's hashes are stale on both sides,** so CORE-SYNC cannot currently prove the sync. |
| Plugins (`JTV/Plugins/`) | 6 of 12 scripts and `plugins.json` differ | yes | the two bundles were refreshed independently (§F) |

Consequences:
- The tvOS-only *improvements* (central log scrub, image rungs, bounded prefetch, 20 s page deadline) are **absent from the source of truth.** Because sync runs one way (iOS → TV), they will never flow back unless the owner chooses to back-port them (I-6, I-11).
- **D-0:** refresh both MovieService hash columns in CORE-SYNC.md.

---

## 1. Ranked findings (by user impact)

| # | ID | Sev | Finding | Flags | Conf. |
|---|---|---|---|---|---|
| 1 | I-1 | High | The audio session is activated at app launch and never deactivated: opening JTV stops the user's music or podcast, and closing the player never lets it resume | BEHAVIOUR CHANGE | CONFIRMED |
| 2 | I-2 | High | Resolve tasks are unstructured and never cancelled. Closing the player, or switching source mid-resolve, leaves the old chain (including debrid polling) running | BEHAVIOUR CHANGE | CONFIRMED |
| 3 | I-3 | Med | Plugin sync loop: hentaihub and sayhentai are re-downloaded and their engines rebuilt on every launch | source-repo fix | CONFIRMED |
| 4 | I-4 | Med | A2 family: each history save (every 5 s of playback) re-renders the resolver and the player surface, plus Home (all rails), Library, Detail and the App body underneath | – | CONFIRMED |
| 5 | I-5 | Med | Home and Torrent rails use non-lazy `HStack`s, so every card is built and every poster load starts at first render. Prefetch is up to 60 per rail, with unbounded concurrency | UI-GATE | CONFIRMED (cost UNMEASURED) |
| 6 | I-6 | Med | Image pipeline: no downsampling, lazy decode at first draw (main thread), and image bytes stored twice (URLCache + own disk tier) | CORE | CONFIRMED / PLAUSIBLE (double store) |
| 7 | I-7 | Med | WebFetcher (Cloudflare lane) delegate callbacks are not tied to their navigation. A stale failure or stale DOM poll can answer the *next* request, giving nil or the wrong page's HTML | PROTECTED, CORE (iOS-only region) | PLAUSIBLE |
| 8 | I-8 | Med | Background playback without PiP: nothing detaches the player from its layer on background. Relies on auto-PiP; the KSPlayer surface may pause on background | BEHAVIOUR CHANGE | PLAUSIBLE |
| 9 | I-9 | Low-Med | Manga reader: zero-height placeholders fire many `onAppear`s at once, so the current/saved page can jump ahead. No forced save on exit | BEHAVIOUR CHANGE | PLAUSIBLE |
| 10 | I-10 | Low | Deprecated synchronous AVAsset APIs in the Actor preview | – | CONFIRMED |
| 11 | I-11 | Low (defence in depth) | The iOS DiagLog has no central scrub. Redaction relies on call-site discipline only (tvOS added a scrub); no leaking call site found | CORE | CONFIRMED |
| 12 | D-0…D-2 | Low | CORE-SYNC stale hashes; README stale; WebFetcher may attach to no window | – | CONFIRMED |
| – | §T | – | tvOS findings that apply unchanged | see §T | – |
| – | §S/§X | – | Secrets and build | – | – |

---

## 2. Findings

### I-1: Audio session activated at launch, never deactivated — CONFIRMED — BEHAVIOUR CHANGE
- **Evidence:**
  - `JTV/JTVApp.swift:66`: `AudioSession.configureForPlayback()` in `App.init`.
  - `JTV/AudioSession.swift:22,27`: `.playback` / `.moviePlayback`, then `setActive(true)`.
  - Both player surfaces call it again when they load (`PlayerView.swift:1095`, `KSPlayerView.swift:410`).
  - There is **no `setActive(false)` anywhere** in the tree.
- **Mechanism:** `.playback` without `.mixWithOthers` is a non-mixable category. Activating it interrupts other apps' non-mixable audio.
- **User-visible effect:**
  - Launching JTV (just to browse) stops Apple Music, Spotify or a podcast.
  - After the user closes the player, the other app is never told it may resume (`.notifyOthersOnDeactivation` is never sent).
- **Fix shape:**
  1. Drop the launch-time call. Playback still activates the session, because both surfaces already call `configureForPlayback()` when they load.
  2. On player close, deactivate with `.notifyOthersOnDeactivation`, but only when no surface is playing and PiP is not active.
- **Risk:** Medium. It is the background/PiP continuity path, so the deactivation point must come after the surface is dismantled, never while PiP is up. Interrupt handling (`PlayerView.swift:431-510`) is unaffected.
- **Verify:** on device, Music plays → launch JTV → Music keeps playing. Play then close a video → Music offers or resumes. PiP → close the cover → no premature deactivation.

### I-2: Resolve tasks never cancelled — CONFIRMED — BEHAVIOUR CHANGE
- **Evidence:**
  - `JTV/PlayerView.swift:2618-2622`: `startResolve()` spawns `Task { await resolve(generation:) }` and keeps no handle.
  - It is called from `.task { startResolve() }` (`:2457-2459`), so the `.task`'s automatic cancellation never reaches the spawned task.
  - It is also called from `switchSource` (`:2600-2616`) and the Retry button.
  - `resolve` (`:2624-2729`) only checks `generation == resolveGeneration` *after* the work is done.
- **Mechanism:**
  - Dismissing the cover, or superseding a resolve, never cancels the core chain.
  - The core's own cancellation checks (preflight walk, `PrefetchJoinBox`, phase-2 race) are therefore inert on iOS.
  - `jtvhash:` resolves have no deadline (patient mode), so the debrid polling can run for minutes after the user has left.
- **User-visible effect:**
  - Bandwidth and battery spent after closing.
  - After a manual source switch, the abandoned chain competes with the new one, giving a slower start on the source the user picked.
- **Fix shape:** keep the `Task` handle in `@State`. Cancel it in `startResolve()` before starting a new one, and in `.onDisappear`.
- **Risk:** Medium. A `CancellationError` reaching the `catch` sets `.failed` on the dismissed or superseded view (generation-guarded for supersede). Confirm with the debrid path that a cancelled RD/TorBox poll leaves no half-state.
- **Verify:** close during a debrid "downloading" phase. With log-only witnesses (or the network instrument), `debrid` lines should stop within one poll interval.

### I-3: Plugin sync loop on every launch — CONFIRMED (code + data)
- **Evidence (bundled iOS / live `plugins.json` / live script `getManifest()`):**
  - hentaihub: **1.0.2 / 1.0.7 / 1.0.5**
  - sayhentai: **3.1.0 / 3.2.0 / 3.1.0**
  - The sync download path records the *script's* version (`PluginManager.swift`, `syncSource`; identical logic to tvOS AUDIT §F.4.1).
- **Mechanism:**
  1. The live `plugins.json` version is higher than the installed version, so sync downloads the script.
  2. The script declares the lower version, which is what gets recorded.
  3. The engine is invalidated, the file is rewritten, and `syncGeneration` is bumped.
  4. The next sync repeats all of this.
  - iOS syncs once per launch (`HomeView.swift:61-74`, `didInitialSync`), plus pull-to-refresh and Settings.
- **User-visible effect:**
  - Two script downloads, two JSContext rebuilds and a `syncGeneration` bump per launch. Home and Torrent self-gate on their caches, so there is little visible reload.
  - **sayhentai users on iOS never get the 3.2.0 mirror gap-fill:** the iOS bundle ships 3.1.0, and live serves 3.1.0 code under a 3.2.0 label. Chapters stay missing in the middle of the affected titles.
- **Fix shape (source repo, owner):** publish the real 3.2.0 sayhentai script, and align hentaihub's two versions (and move `maxChainParses` into `getManifest()` if it is meant to apply). Then refresh the iOS bundle (§F).
- **Risk:** low.
- **Verify:** an exported log shows `[sync] plugin updated id=hentaihub v1.0.5` and `id=sayhentai v3.1.0` on every launch.

### I-4: History saves re-render the playback stack and everything under it — CONFIRMED
- **Evidence:**
  - Saves happen every 5 s: the AV periodic observer (`PlayerView.swift:108-113`) and the KS tick throttle (`KSPlayerView.swift:548-559`), into `history.upsert`. That call encodes all records and writes `UserDefaults` on main (`Library.swift`, identical to tvOS).
  - Observers of `history`:
    - `JTVApp` (`@StateObject`, `JTVApp.swift:54`): the App body re-evaluates.
    - `PlaybackResolverView` (`PlayerView.swift:2301`): reads it only in `switchSource` (`:2609`).
    - `PlayerView` (`:1937`) and `KSPlayerView` (`KSPlayerView.swift:61`): only *call* `upsert`, never read it in `body`.
    - `HomeView:6`, `LibraryView:57`, `DetailView:10`, `MangaReaderView:17`.
- **User-visible effect:** main-thread work every 5 s for the whole film, which costs battery. Home is the expensive one because of I-5. UNMEASURED.
- **Fix shape (shell only, zero behaviour):**
  - Give the three playback views a non-observing reference: a custom `EnvironmentKey` that carries the `WatchHistoryManager` reference, set once at the App root. `@Environment` of a class reference does not subscribe to it.
  - In Home, move `continueWatchingRow` (`HomeView.swift:231`) into its own subview that observes `history`, so only that row re-renders.
- **Risk:** low. Nothing in those bodies reads history state; check the source-switch resume (`:2609`) still reads the live object.
- **Verify:** Instruments → SwiftUI "View Body" counts during 5 min of playback, before and after. The exported log is unchanged.

### I-5: Non-lazy horizontal rails plus unbounded prefetch — CONFIRMED (cost UNMEASURED) — UI-GATE
- **Evidence:**
  - `HomeView.swift:332-339` and `TorrentTabView.swift:136-142`: `ScrollView(.horizontal) { HStack { ForEach(items) { MovieCard } } }`.
  - `HomeView.swift:376` calls `ImageCacheManager.prefetch` for each rail.
  - `Cache.swift:857-862`: `prefetch` launches one unstructured `Task` per URL (up to 60 per call), with no concurrency bound.
- **Mechanism:** every card in every rail is instantiated and starts its image task at first render, on top of the prefetch fan-out. A launch can mean several hundred concurrent image loads and decodes, competing with the page fetches the user is waiting on. Wall-blocked hosts can also escalate into the 2-lane WebFetcher pool (the L-17 starvation history; the 20 s waiter cap limits the damage, not the cause).
- **Fix shape:**
  - `LazyHStack` with the same alignment and spacing. Cards are fixed-size (`MovieCard` 118 × 177 pt), so layout should be identical, but **prove it with screenshots (UI-GATE).**
  - Bound prefetch concurrency (tvOS already has a bounded queue in `ImageCacheManager`; port the *bound*, not its replace-semantics).
- **Risk:** Low-Med. Lazy rails delay off-screen poster loads (they still arrive via prefetch).
- **Verify:** cold launch, measuring image requests in flight (network instrument), time until the first rail's posters are visible, and peak memory, before and after.

### I-6: Image decode at source resolution, on main, stored twice — CONFIRMED / PLAUSIBLE — CORE
- **Evidence:**
  - `Cache.swift:719-745`: `UIImage(data:)` (lazily decoded, so the decode happens at first draw, on main).
  - `capped()` (`:672-686`) only shrinks images over 2048 px whose short side is over 1080 px. A 118-pt card at @3x needs about 354 × 531 px.
  - The bytes are fetched through `Net.session` (`:752`), whose 100 MB disk `URLCache` (`:14-22`) stores responses that the policy never reads, and then written again to `jtv-images` (`:739`).
- **User-visible effect:** scroll hitches when posters first draw, higher memory (the cost limit is 256 MB at `:633`), and flash writes.
- **Fix shape:**
  - Downsample with `CGImageSourceCreateThumbnailAtIndex` to the display size, off-main, and cache the result. The tvOS rung design is the model, back-ported deliberately.
  - Give images a session with `urlCache = nil`, or skip the own disk write.
- **Risk:** Medium (shared core; every image path). Back-porting tvOS logic into the source of truth is a CORE change the owner must approve.
- **Verify:** Time Profiler (main-thread `ImageIO` / decode) and VM Tracker peak while scrolling Home and Category, before and after. `Library/Caches` sizes after a session.

### I-7: WebFetcher navigation cross-talk — PLAUSIBLE — PROTECTED, CORE (iOS-only region)
- **Evidence:** `Cache.swift`:
  - `:501-514`: `load` sets `lane.continuation` and then calls `wv.stopLoading(); wv.load(req)`. The returned `WKNavigation` is discarded.
  - `:568-574`: `didFail` / `didFailProvisional` call `finish(lane, nil)` **and** `finishData(lane, nil)` without a generation.
  - `:530-566`: `didFinish` starts an up-to-~8 s DOM poll that finishes *whatever* continuation the lane holds when it ends. The HTML path has no generation guard; only the bytes path has one (`:374-397`).
- **Failure scenarios:**
  - **(a) Spurious nil:** a lane whose previous navigation is still loading (for example after a 40 s HTML or 15 s bytes timeout) gets a new request. The stop/replace cancels the old navigation with −999, and that `didFail` resolves the **new** request with nil.
  - **(b) Wrong page:** a Cloudflare challenge redirect produces two `didFinish` calls. The second poll loop outlives the first request; when the lane is reused it evaluates the DOM, possibly still the previous page before the new commit, and resolves the **next** request with that HTML.
- **User-visible effect:** intermittent empty or wrong pages on Cloudflare-fronted sources (sayhentai), and image-ladder misses.
- **Fix shape:** store the `WKNavigation` returned by `load` per lane, and ignore delegate callbacks for any other navigation (the delegate methods receive `navigation`). Add a generation token to the HTML path to match the bytes path.
- **Risk:** Medium; this is device-tuned machinery.
- **Verify first:** add a log-only witness when a delegate callback's navigation is not the lane's current one, then exercise sayhentai cold.

### I-8: Background playback relies on auto-PiP — PLAUSIBLE — BEHAVIOUR CHANGE
- **Evidence:**
  - The AV surface renders through `AVPlayerLayer`, with `canStartPictureInPictureAutomaticallyFromInline = true` (`PlayerView.swift:1104-1109`).
  - There is no `didEnterBackground` / `scenePhase` handling anywhere.
  - `UIBackgroundModes: audio` is declared (`project.yml:82-83`), and `AudioSession.swift` promises background audio.
- **Mechanism (Apple's documented behaviour, to be confirmed on device):** a player attached to a visible layer is paused when the app backgrounds unless PiP takes over. With "Start PiP Automatically" turned off in iOS Settings, background audio therefore stops.
- **KSPlayer surface:** it has no PiP (Metal, `KSPlayerView.swift:405-409`). Whether KSPlayer 2.3.4 pauses on background unless one of its options enables background play needs checking in its source; **I could not verify the option's name or default, and do not assert it.**
- **Fix shape:** on entering background with PiP inactive, detach `playerLayer.player`, and reattach on foreground. For KS, set the library's background-play option once verified.
- **Risk:** Medium (interacts with PiP restore).
- **Verify:** device test with automatic PiP turned off: play, lock, press Home; audio should continue.

### I-9: Manga reader page tracking — PLAUSIBLE — BEHAVIOUR CHANGE
- **Evidence:**
  - `MangaReaderView.swift:101-115`: each page in a `LazyVStack` calls `onAppear { currentIndex = index; saveProgress(); prefetch(next 3) }`. Before it loads, a page is a placeholder with no intrinsic height (`CachedAsyncImage`, `Cache.swift:902-916`), so many placeholders fit on screen at once.
  - `saveProgress` (`:296-311`) uses the throttled `upsert`, and there is no forced save on exit.
- **User-visible effect:**
  - On a cold chapter, `currentIndex` (and the "Trang x/y" label, `:190`) can jump to a far page.
  - The saved page may be wrong.
  - The last ~2 s of reading can be lost on close.
- **Fix shape:** derive the current page from the existing `.scrollPosition(id: $scrollTarget)` (`:120`; iOS 17+ API), and force a save in `onDisappear`.
- **Risk:** Low. It changes saved positions, which is the intended correction.
- **Verify:** on a cold chapter with 40 pages, the log-only `currentIndex` sequence and the saved record after closing on page 5.

### I-10: Deprecated synchronous AVAsset APIs — CONFIRMED
- **Evidence:** `ActorView.swift:808-818`: `asset.tracks(withMediaType:)`, `naturalSize` and `preferredTransform`, all deprecated in iOS 16 in favour of the async `load(...)` / `loadTracks(withMediaType:)` (available iOS 15+).
- **Effect:** none today, because they are read after `.readyToPlay`. It is a future-SDK risk.
- **Fix:** an async load inside the existing `Task`. NONE expected; low priority.

### I-11: No central log scrub in the source of truth — CONFIRMED — CORE
- **Evidence:** the iOS `DiagLog.swift` (148 lines) is memory-only, and redaction relies on every call site using `urlForLog` (`:23-35`). tvOS added a central scrub of credential values and URL queries in `append`.
- **What I checked:** all 200+ iOS call sites with raw interpolations. **No leaking call site found.** For example, `PluginManager.swift:521` logs `error.localizedDescription`, which for `URLError` carries no URL.
- **Effect:** none today. A single future careless line would put a token or a signed URL into a user-exported log.
- **Fix shape:** back-port the scrub. Owner decision, because it is a reverse-direction CORE change. The tvOS AUDIT A5 per-line cost notes then apply.

### D-0…D-2: Code health
- **D-0:** CORE-SYNC MovieService hashes are stale on both sides (§0).
- **D-1:** `README.md` says "Swift 5.9, no external libraries". The project is Swift 6.0 (`project.yml:13`) with KSPlayer 2.3.4 (`:22-24`).
- **D-2:** `WebFetcher.ensureWebView` (`Cache.swift:477-495`) attaches the hidden WKWebView only if a key window exists at that moment, and caches the lane anyway. If it is created while no window is key, that lane stays detached, which is the JS-throttled state the comment warns about. Low.

---

## T. tvOS AUDIT.md findings that apply to this tree

**Apply unchanged (same code):**
- **E1–E4:** HLSProxy and LocalHLSServer are byte-identical.
  - E4 has **more** exposure on iOS: the loopback server listens on all interfaces, which includes any public Wi-Fi the phone joins.
  - E3 hits the AV self-heal path at `PlayerView.swift:317, 366`, which awaits `register` with no watchdog.
- **E5 (URL caches):** worse on iOS; see I-6.
- **B1** (`pageCache`), **B3** (`prefetchedEmbeds`): identical MovieService region.
- **B2:** the AV dismantle only pauses (`PlayerView.swift:165-171`, no `replaceCurrentItem(nil)`, loader tasks not cancelled).
- **B4** (JSContext per plugin), **B5** (disk prune at launch, eviction by write time): identical code.
- **A8** (MetadataOverlay main-actor I/O), **A9** (`engine(for:)` without in-flight dedupe): identical files.
- **C2** (`StreamPreflight` budget Task): identical region.
- **§F.4 live-repo defects:** apply to iOS too; see I-3.

**Do not apply:**
- **A1:** `App.init` runs once, unlike a View init.
- **A2:** replaced by the iOS-specific I-4.
- **A3:** there is no page planner on iOS.
- **A4 / A6:** iOS has a different image pipeline (I-6).
- **A5:** the iOS DiagLog is memory-only with no scrub or disk writes. Only its O(n) `removeFirst` (`DiagLog.swift:74-76`) applies; trivial.
- **A7:** `didInitialSync` guards the sync (`HomeView.swift:61-74`).
- **C1:** iOS has no shell replica; it calls the core walk directly.
- **D1:** AutoSub is live on iOS.
- **X1 / X2:** see §X.

---

## F. Bundled vs live plugins (iOS bundle)

| Plugin | iOS bundled | Live json / script | Verdict |
|---|---|---|---|
| avdbapi, javhd, misskon, torrenthub, vlxx | = live | – | IN SYNC (byte-identical) |
| njav 1.0.8, sextop1 2.0.4, topxx 1.0.3 | = live | – | IN SYNC (newer than the tvOS bundle) |
| sayhentai 3.1.0 | = live script | 3.2.0 / 3.1.0 | IN SYNC by bytes, but caught in the I-3 loop. The tvOS bundle has the newer 3.2.0 |
| 123av 1.0.7 | | 1.0.8 / 1.0.8 | STALE: lacks the 1.0.8 mixed-case embed-id fix, so titles with ids like `8W30XN` fail to resolve until sync. iOS never injects the relay, so 1.0.8's relay mode is irrelevant here |
| missav 1.1.4 | | 1.1.7 | STALE: same consequences as tvOS §F.3 (no mirror rotation; packed-eval stream-id misses) |
| hentaihub 1.0.2 | | 1.0.7 / 1.0.5 | STALE + I-3 loop |
| javguru, javsnap | – | 1.0.0 | MISSING IN BUNDLE: absent until the first successful sync |

**When the bundle runs on iOS:** the first Home load of a fresh install (the silent-sync branch), and any sync failure. Scripts live in Application Support on iOS, so there is no Caches-purge path. The tvOS §F.5 refresh policy applies as written; run it for **both** bundles from the same pinned jtv-source commit.

---

## S. Secrets

- **No committed credential found.**
  - Scan: credential-assignment regexes plus quoted literals of 32 or more base64/alphanumeric characters, across `.swift`, `.js` and `.json`.
  - The only hits are base64 alphabets.
  - `DebridSecrets.swift` holds empty strings; no `relayBase` is present.
- **The iOS CI injects nothing:** no secrets step. So the IPA ships no credentials, and debrid tokens come only from Settings (`SettingsView.swift:311-323`).
- **Observation (owner decision):** those tokens and the MediaFusion manifest URL are stored in **`UserDefaults`** (`DebridResolver.swift:3-19`, `MovieService.swift:2108-2111`). That is a plaintext plist included in device backups. The Keychain is the platform store for credentials. Moving them would be a CORE change with a data migration (BEHAVIOUR CHANGE).

## X. Build and CI (`.github/workflows/build-jtv.yml`)

Judged on reproducibility, per the brief. SDK 26.5 against MinOS 17.0 is normal on iOS.

- **X-1:** `runs-on: macos-latest` with **no Xcode selection.** The SDK and Swift compiler change silently whenever GitHub moves the image default, so two dispatches of the same commit can build with different toolchains. Pin both the runner image and the Xcode version, and record them in the build log.
- **X-2:** `brew install xcodegen` is unpinned. A new XcodeGen release can change the generated project. Pin the version.
- **X-3:** no `Package.resolved` is committed. KSPlayer is `exactVersion: 2.3.4` (`project.yml:22-24`), but any transitive package it declares with a range would float. Check KSPlayer 2.3.4's manifest; either way, committing `Package.resolved` makes the build reproducible.
- **X-4:** dispatch-only, with no `pull_request` trigger. Same situation as tvOS X1, which the leader fixed on that copy.
- **X-5:** artifacts use the default retention. Nothing secret is in the IPA today (§S), so no exposure.

---

## Proposed Phase 2 order (subject to approval)

| PR | Closes | Behaviour change | Notes |
|---|---|---|---|
| 1 | I-4 (non-observing history in the 3 playback views + Home row split) | NONE | shell only; View-Body counts |
| 2 | I-5 (LazyHStack rails) | NONE (UI-GATE screenshots) | shell only |
| 3 | I-2 (cancel resolve tasks) | **YES**: approval | shell only |
| 4 | I-1 (audio session at playback only + deactivate) | **YES**: approval | shell only; device test matrix |
| – | I-3 | source repo + bundle refresh | owner |
| – | I-6, I-7, I-11, the tvOS E/B items | CORE / PROTECTED | proposals; "verify first" steps |
| – | I-8, I-9, I-10, X-1…X-4 | as flagged | |

---

## Leader verification (2026-11-23, after receipt)

- §0 core-identity: independently re-checked by direct byte comparison of the two trees — exactly the 5 named files differ (DebridResolver, PluginManager, Cache, DiagLog, MovieService); the other 9 shared files are byte-identical. Claude's refutation of the brief's claim is CORRECT; the brief's claim was the leader's error.
- I-1: verified — `AudioSession.configureForPlayback()` at `JTVApp.swift:66`; zero `setActive(false)` in the tree.
- I-2: verified — `startResolve()` at `PlayerView.swift:2618-2622` spawns an unstored `Task`.
- I-3 / §F: verified — iOS bundle (12 plugins): sayhentai 3.1.0, hentaihub 1.0.2, missav 1.1.4, 123av 1.0.7; javguru/javsnap absent.
- §S: verified — debrid tokens keyed in UserDefaults (`DebridTokens`), build-time `DebridSecrets` as fallback.
- Remaining findings (I-4…I-11, §T, §X) are verified per-PR as their turn comes, per the engagement's standing rule.
