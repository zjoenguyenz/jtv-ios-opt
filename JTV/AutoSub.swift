import Foundation
import Translation

// MARK: - AutoSub core types (spec AUTOSUB-EN-VI-SPEC §3.2, §3.2.1, §3.2.2; item S-1)
//
// This file owns:
//   • AutoSubSourceLanguage — the four supported source languages.
//   • The §3.2.2 source-priority selection (pure function).
//   • The §3.2.1 step-1 declared-language normalisation (pure function).
//   • AutoSubAvailability (S-1) — the per-pair LanguageAvailability probe.
//
// RECON verdict (binding, autosub-work/RECON.md §C3): no reliable
// original-language field reaches the player, so §3.2.2 rule 1
// (original language) is DORMANT in v1. `chooseSource` keeps the
// original-language slot in its signature — callers pass nil today —
// and the effective order is EN → JA → ZH. Nothing here ever infers
// an origin from Movie.lang display badges ("Engsub"/"Vietsub" are
// subtitle badges, not language codes).

// MARK: Source language

enum AutoSubSourceLanguage: String, Sendable, Codable {
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja = "ja"

    /// All four candidates, in declaration order (probe order for S-1).
    static let all: [AutoSubSourceLanguage] = [.en, .zhHans, .zhHant, .ja]

    /// "en-vi", "zh-Hans-vi", "zh-Hant-vi", "ja-vi" — the pair label
    /// used in DiagLog lines (§3.8) and the cache engine string (§3.7).
    var pairLabel: String { rawValue + "-vi" }

    /// The Translation-framework language for this source.
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }

    /// The translation target for every pair: Vietnamese.
    static var targetLanguage: Locale.Language {
        Locale.Language(identifier: "vi")
    }

    // MARK: §3.2.2 priority selection

    /// Picks the single source language to translate from, per
    /// §3.2.2: original language (when known, eligible and usable)
    /// → English → Japanese → Chinese (either script; Simplified
    /// preferred when both scripts are present, deterministically).
    /// A candidate whose pair is not usable is skipped at every
    /// step. Pure function: no I/O, no logging.
    ///
    /// - Parameters:
    ///   - candidates: languages identified as available (§3.2.1).
    ///   - originalLanguage: the title's original language when the
    ///     app genuinely knows it. DORMANT in v1 (RECON §C3) —
    ///     callers pass nil; the slot exists so the rule can light
    ///     up if original-language data is ever threaded through.
    ///   - isPairUsable: pair probe result (installed/supported).
    static func chooseSource(
        candidates: [AutoSubSourceLanguage],
        originalLanguage: AutoSubSourceLanguage? = nil,
        isPairUsable: (AutoSubSourceLanguage) -> Bool
    ) -> AutoSubSourceLanguage? {
        let present = Set(candidates)
        func usable(_ language: AutoSubSourceLanguage) -> Bool {
            present.contains(language) && isPairUsable(language)
        }
        // 1. Original language (dormant in v1 — see header note).
        if let originalLanguage, usable(originalLanguage) {
            return originalLanguage
        }
        // 2. English.
        if usable(.en) { return .en }
        // 3. Japanese.
        if usable(.ja) { return .ja }
        // 4. Chinese — Simplified wins the both-scripts tiebreak.
        if usable(.zhHans) { return .zhHans }
        if usable(.zhHant) { return .zhHant }
        return nil
    }

    // MARK: §3.2.1 step 1 — declared-language normalisation

    /// Normalises a track's declared language (`SubtitleTrack.lang`)
    /// and its human label into an `AutoSubDeclaredResult`, in the
    /// D-1 matching style (§3.2.1 step 1). Case-insensitive and
    /// tolerant of surrounding whitespace and "_" separators.
    ///
    /// Chinese needs its script settled: script-specific codes
    /// (zh-Hans/zh-CN/zh-SG, zh-Hant/zh-TW/zh-HK/zh-MO) and labels
    /// carrying a script signal ("Simplified"/"Traditional", 简/繁)
    /// resolve to a variant; a bare zh/chi/zho/"chinese" returns
    /// `.chineseScriptOpen` and step 2 (detection) resolves ONLY
    /// the script. Anything unrecognised returns `.undeclared` —
    /// never a guess.
    static func normaliseDeclared(lang: String, label: String) -> AutoSubDeclaredResult {
        let code = lang
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let name = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if code.isEmpty && name.isEmpty { return .undeclared }

        // Vietnamese — the track is a native VI track, never a source.
        if ["vi", "vie", "vnm"].contains(code) || code.hasPrefix("vi-")
            || name.contains("vietnam") || name.contains("việt") {
            return .vietnamese
        }

        // Chinese with the script settled by the code itself.
        if ["zh-hans", "zh-cn", "zh-sg"].contains(code) { return .source(.zhHans) }
        if ["zh-hant", "zh-tw", "zh-hk", "zh-mo"].contains(code) { return .source(.zhHant) }
        // Chinese with the script settled only by the label.
        // FIX (R1-logic m4): the label's script signal is honoured
        // ONLY when the track is actually Chinese — the code says
        // so (zh/chi/zho/zh-*), the label itself says "chinese", or
        // there is no code to contradict it. Previously this check
        // ran for ANY code, so an English track whose label happened
        // to contain "Simplified"/"Traditional" was misidentified
        // as a Chinese source.
        let chineseContext = ["zh", "chi", "zho"].contains(code)
            || code.hasPrefix("zh-")
            || name.contains("chinese")
            || code.isEmpty
        if chineseContext {
            if name.contains("simplified") || name.contains("简") { return .source(.zhHans) }
            if name.contains("traditional") || name.contains("繁") { return .source(.zhHant) }
        }
        // Bare Chinese — script stays open for detection (§3.2.1).
        if ["zh", "chi", "zho"].contains(code) || code.hasPrefix("zh-")
            || name.contains("chinese") {
            return .chineseScriptOpen
        }

        // English.
        if ["en", "eng"].contains(code) || code.hasPrefix("en-")
            || name.contains("english") {
            return .source(.en)
        }

        // Japanese ("jp" is a country code some sources misuse as a
        // language tag; the spec's normalisation list includes it).
        if ["ja", "jpn", "jp"].contains(code) || code.hasPrefix("ja-")
            || name.contains("japanese") {
            return .source(.ja)
        }

        return .undeclared
    }
}

// MARK: Declared-language result (§3.2.1)

enum AutoSubDeclaredResult: Sendable, Equatable {
    /// Declared (or detected) as a supported source language.
    case source(AutoSubSourceLanguage)
    /// Chinese, but the script (Hans vs Hant) is not settled;
    /// detection may resolve ONLY the script.
    case chineseScriptOpen
    /// The track is Vietnamese — a native track, not a source.
    case vietnamese
    /// No usable declaration; detection decides, or the track is
    /// excluded (§3.2.1 step 3 — failure is exclusion, never a guess).
    case undeclared
}

// MARK: - S-1 pair-availability probe

enum AutoSubPairStatus: Sendable, Equatable {
    /// Pair supported and the language pack is downloaded.
    case installed
    /// Pair supported; the pack still needs downloading.
    case supported
    /// Pair not supported on this device — that source language is
    /// disabled (§3.2.2 skips it); also the value a probe error
    /// degrades to, so a broken probe never enables a broken pair.
    case unsupported
    /// The feature itself is absent (OS < iOS 18) — no probe ran
    /// and nothing is logged (spec T3: below iOS 18 AutoSub does
    /// not exist, so §3.8's probe lines are moot there).
    case unavailable
}

/// S-1: probes `LanguageAvailability` for all four source→vi pairs
/// on first use, caches the results for the app session, and logs
/// exactly one `autosub pair …` line per pair (§3.8).
///
/// Concurrency shape: this is a plain `final class` (the shape the
/// player code will hold via `shared`), but ALL mutable state lives
/// in the private `ProbeStore` actor below — the class itself stores
/// only the immutable actor reference, so it is safe to share across
/// isolations without `@unchecked`. `LanguageAvailability` (a
/// Translation-framework class, not Sendable) is created, used and
/// released inside the actor's probe method and never stored or
/// crossed over an isolation boundary.
final class AutoSubAvailability: Sendable {
    static let shared = AutoSubAvailability()

    private let store = ProbeStore()

    private init() {}

    /// The status of one source language's pair with Vietnamese.
    /// The first call (for any language) probes all four pairs;
    /// later calls serve the session cache. On OS < iOS 18 this
    /// returns `.unavailable` and logs nothing.
    func status(for language: AutoSubSourceLanguage) async -> AutoSubPairStatus {
        guard #available(iOS 18, *) else { return .unavailable }
        return await store.status(for: language)
    }

    /// Convenience for the §3.2.2 rule: a pair is usable when its
    /// pack is installed or downloadable (`.installed`/`.supported`).
    func isPairUsable(_ language: AutoSubSourceLanguage) async -> Bool {
        switch await status(for: language) {
        case .installed, .supported: return true
        case .unsupported, .unavailable: return false
        }
    }

    // MARK: Probe store
    //
    // The actor itself is deliberately NOT availability-gated: a
    // stored property of the outer class cannot hold an
    // iOS-18-only type. Instead the gate lives at the two places
    // that need it — `AutoSubAvailability.status(for:)` never calls
    // the store below iOS 18, and the one method that touches the
    // Translation framework is the @available helper at the bottom.

    private actor ProbeStore {
        /// Session cache; nil until the first probe completes.
        private var cached: [AutoSubSourceLanguage: AutoSubPairStatus]?

        func status(for language: AutoSubSourceLanguage) async -> AutoSubPairStatus {
            if let cached {
                return cached[language] ?? .unsupported
            }
            let results = await Self.probeAll()
            cached = results
            return results[language] ?? .unsupported
        }

        private static func probeAll() async -> [AutoSubSourceLanguage: AutoSubPairStatus] {
            guard #available(iOS 18, *) else { return [:] }
            return await probeAllAvailable()
        }

        /// Probes all four pairs once, logging one §3.8 line per
        /// pair. `LanguageAvailability.status(from:to:)` is
        /// non-throwing per Apple's documentation, so there is no
        /// error channel to catch: any status outside
        /// installed/supported (including a future unknown case)
        /// degrades to `.unsupported` for that pair — the spec's
        /// probe-error rule (treat as unsupported, log unsupported).
        @available(iOS 18, *)
        private static func probeAllAvailable() async -> [AutoSubSourceLanguage: AutoSubPairStatus] {
            var results: [AutoSubSourceLanguage: AutoSubPairStatus] = [:]
            for language in AutoSubSourceLanguage.all {
                // Created per pair and released here; never stored
                // (the class is not Sendable).
                let availability = LanguageAvailability()
                let status = await availability.status(
                    from: language.localeLanguage,
                    to: AutoSubSourceLanguage.targetLanguage
                )
                let mapped: AutoSubPairStatus
                switch status {
                case .installed: mapped = .installed
                case .supported: mapped = .supported
                case .unsupported: mapped = .unsupported
                @unknown default: mapped = .unsupported
                }
                results[language] = mapped
                let statusWord: String
                switch mapped {
                case .installed: statusWord = "installed"
                case .supported: statusWord = "supported"
                case .unsupported, .unavailable: statusWord = "unsupported"
                }
                DiagLog.log("autosub", "pair pair=\(language.pairLabel) status=\(statusWord)")
            }
            return results
        }
    }
}
