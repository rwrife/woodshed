import Foundation

/// Versioned JSON backup codec for the ledger (issue #2).
///
/// Format (`schema_version: Int`):
/// ```json
/// {
///   "schema_version": 1,
///   "generated_at": <unix seconds>,
///   "events": [ { "kind": ..., "entity_id": ..., "committed_at": ..., "payload": ... }, ... ]
/// }
/// ```
///
/// Guarantees:
/// - Lossless encode/decode round-trip: `decode(encode(ledger)) == ledger`,
///   event-for-event, in append order.
/// - Forward incompatibility: a backup with `schema_version` newer than
///   the newest version this codec understands is rejected with
///   `BackupCodecError.unsupportedSchemaVersion` — a typed error, not a
///   crash or partial decode.
/// - Older supported versions decode (currently only v1 exists, so no
///   migrations are wired yet; the versioned envelope is the seam).
public enum BackupCodec {
    /// Newest schema version this build can write.
    public static let currentSchemaVersion = 1
    /// Oldest schema version this build can still read.
    public static let oldestSupportedSchemaVersion = 1

    /// Wire-format envelope. `Date`s serialize as unix seconds
    /// (`timeIntervalSinceReferenceDate` rounded to whole seconds is NOT
    /// used — instead `JSONEncoder`'s `.secondsSinceReferenceDate`, which
    /// keeps sub-second precision within Double round-trip limits for the
    /// ledger's real timestamps).
    struct BackupFile: Codable {
        var schemaVersion: Int
        var generatedAt: Date
        var events: [LedgerEvent]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case generatedAt = "generated_at"
            case events
        }
    }

    public enum BackupCodecError: Error, Equatable, Sendable {
        /// The backup declares a schema version this build cannot read.
        case unsupportedSchemaVersion(found: Int, supported: ClosedRange<Int>)
        /// The backup is not valid `BackupFile` JSON.
        case malformed(underlying: String)
    }

    // MARK: - Encode

    /// Encode the full ledger (every committed event, append order) as
    /// pretty JSON with the current schema version.
    public static func encode(_ ledger: Ledger, generatedAt: Date = Date()) throws -> Data {
        let file = BackupFile(
            schemaVersion: currentSchemaVersion,
            generatedAt: generatedAt,
            events: ledger.events
        )
        let encoder = JSONEncoder()
        // Custom strategies preserve the exact `Date` Double payload
        // (timeIntervalSinceReferenceDate) so the round-trip is bit-for-bit
        // lossless across Darwin and Linux Foundation builds.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: - Decode

    /// Decode a backup into a fresh ledger. Events re-enter through the
    /// normal append path so a corrupt backup cannot smuggle a
    /// semantics-breaking event (e.g. out-of-order tempo) into a ledger.
    public static func decode(_ data: Data) throws -> Ledger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }

        let file: BackupFile
        do {
            file = try decoder.decode(BackupFile.self, from: data)
        } catch let error as DecodingError {
            // Distinguish "unknown/absent schema_version" style issues by
            // first sniffing the raw version field.
            if let version = rawSchemaVersion(from: data),
               !(oldestSupportedSchemaVersion...currentSchemaVersion).contains(version)
            {
                throw BackupCodecError.unsupportedSchemaVersion(
                    found: version,
                    supported: oldestSupportedSchemaVersion...currentSchemaVersion
                )
            }
            throw BackupCodecError.malformed(underlying: String(describing: error))
        }

        guard file.schemaVersion >= oldestSupportedSchemaVersion,
              file.schemaVersion <= currentSchemaVersion
        else {
            throw BackupCodecError.unsupportedSchemaVersion(
                found: file.schemaVersion,
                supported: oldestSupportedSchemaVersion...currentSchemaVersion
            )
        }

        var ledger = Ledger()
        for event in file.events {
            do {
                try ledger.append(event)
            } catch let ledgerError as LedgerError {
                // A backup violating ledger semantics is malformed data,
                // but preserve the ledger rejection reason.
                throw BackupCodecError.malformed(underlying: "ledger rejected event: \(ledgerError)")
            }
        }
        return ledger
    }

    /// Best-effort read of the `schema_version` integer from otherwise
    /// possibly-invalid JSON. Used to give a precise typed error for
    /// future-version files even when full decoding also fails.
    private static func rawSchemaVersion(from data: Data) -> Int? {
        struct VersionProbe: Decodable { let schema_version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return nil }
        return probe.schema_version
    }
}
