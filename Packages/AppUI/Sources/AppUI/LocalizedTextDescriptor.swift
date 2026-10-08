import Foundation

/// A locale-neutral description of user-facing text that may outlive the View which created it.
///
/// v2026.07.17 live-localization regression fix: scan results, Smart Care checkpoints, stash
/// entries and deletion intents can remain alive while the user changes the in-app language.
/// Storing an already-localized `String` in those models freezes the old language. This value
/// stores catalog semantics instead and resolves them only at the presentation boundary.
///
/// File names, paths, product/version suffixes and other user data must use `.verbatim`; only
/// known String Catalog keys use `.catalog`. The descriptor never participates in path identity,
/// safety decisions or deletion authorization.
public struct LocalizedTextDescriptor: Sendable, Hashable {
    public enum Argument: Sendable, Hashable {
        case string(String)
        case signed(Int64)
        case unsigned(UInt64)
        case floating(Double)

        fileprivate var cVarArg: any CVarArg {
            switch self {
            case .string(let value): return value
            case .signed(let value): return value
            case .unsigned(let value): return value
            case .floating(let value): return value
            }
        }
    }

    public enum Segment: Sendable, Hashable {
        case verbatim(String)
        case catalog(key: String, arguments: [Argument])
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public static func verbatim(_ value: String) -> Self {
        Self(segments: [.verbatim(value)])
    }

    public static func catalog(
        _ key: String,
        arguments: [Argument] = []
    ) -> Self {
        Self(segments: [.catalog(key: key, arguments: arguments)])
    }

    public static func concatenating(_ descriptors: [Self]) -> Self {
        Self(segments: descriptors.flatMap(\.segments))
    }

    public func appendingVerbatim(_ value: String) -> Self {
        Self(segments: segments + [.verbatim(value)])
    }

    public func localized(locale: Locale) -> String {
        localized(locale: locale, bundle: .module)
    }

    /// v2026.10.08: compiled-catalog integration tests use the same projection as the App.
    func localized(locale: Locale, bundle: Bundle) -> String {
        var result = ""
        result.reserveCapacity(segments.reduce(0) { partial, segment in
            switch segment {
            case .verbatim(let value): return partial + value.count
            case .catalog(let key, _): return partial + key.count
            }
        })
        for segment in segments {
            switch segment {
            case .verbatim(let value):
                result += value
            case .catalog(let key, let arguments):
                if arguments.isEmpty {
                    result += AppLocalization.string(key, locale: locale, bundle: bundle)
                } else {
                    result += AppLocalization.format(
                        key,
                        locale: locale,
                        arguments: arguments.map(\.cVarArg),
                        bundle: bundle
                    )
                }
            }
        }
        return result
    }
}
