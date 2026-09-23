/// WoodshedKit — pure-domain core for Woodshed.
///
/// Issue #2 lands the domain here: the append-only event ledger
/// (`Ledger`, `LedgerEvent`), the value types (`Instrument`, `Piece`,
/// `Session`, `SessionSplit`, `TempoLog`, `PracticeNote`), the
/// deterministic derivation engine (`Derivations`), and the versioned
/// JSON backup codec (`BackupCodec`).
///
/// Contract (issue #2, binding):
/// - Foundation only. No UI, no I/O, no network.
/// - Committed ledger events are immutable; corrections append new
///   events. There is deliberately no API to rewrite or remove history.
/// - Every derivation returns `.unknown` — never 0 — when its inputs
///   are absent.
/// - BPM and minute arithmetic is exact integer arithmetic; no floating
///   point is used for accumulated totals.
public enum WoodshedKit {
    /// Namespace marker for the domain layer.
    public static let domain = "WoodshedKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M1-domain"
}
