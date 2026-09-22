/// WoodshedKit — pure-domain core for Woodshed.
///
/// Issue #1 ships only the skeleton namespace so CI has a real, testable
/// target. Issue #2 (domain) lands the append-only event ledger (Piece,
/// Session, SessionSplit, TempoLog), the deterministic derivation engine
/// (streaks, weekly minutes, per-piece recency/tempo progress), and the
/// versioned backup codec here. The GRDB store is issue #3 and lives in
/// the app target, not this package.
public enum WoodshedKit {
    /// Namespace marker for the domain layer.
    public static let domain = "WoodshedKit"

    /// Current build/CI milestone marker consumed by the app's debug surface.
    public static let milestone = "M0-skeleton"
}
