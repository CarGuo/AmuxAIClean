import Foundation

/// v2026.10.08: allocation ownership belongs to a scan transaction, not a directory refresh.
/// A retained catalog records directory totals and only multi-link file identities. Incremental
/// replacement preserves the path charged for each linked device/inode, and transfers
/// the charge to a surviving alias if it disappears. No filesystem work happens during merge.
public struct FileAllocationSnapshot: Sendable {
    struct Identity: Sendable, Hashable {
        let device: UInt64
        let inode: UInt64
    }

    struct Entry: Sendable {
        var owner: String
        var aliases: Set<String> = []
        var allocatedBytes: Int64
        var logicalBytes: Int64
        var paths: [String] { [owner] + aliases.sorted() }
    }

    var entries: [Identity: Entry] = [:]
    var knownLinkedIdentities: Set<Identity> = []
    var directories: [String: DirectoryTotals] = [:]
    var coveredRoots: Set<String> = []
    public init() {}

    struct DirectoryTotals: Sendable {
        var allocatedBytes: Int64
        var logicalBytes: Int64
        var fileCount: Int
    }

    public struct RemovedContribution: Sendable {
        public let path: String
        public let allocatedBytes: Int64
        public let logicalBytes: Int64
        public let fileCount: Int

        public init(path: String, allocatedBytes: Int64, logicalBytes: Int64, fileCount: Int) {
            self.path = path
            self.allocatedBytes = allocatedBytes
            self.logicalBytes = logicalBytes
            self.fileCount = fileCount
        }
    }

    public var retainedLinkedIdentityCount: Int { entries.count }
    public var retainedDirectoryCount: Int { directories.count }

    public func covers(directory path: String) -> Bool {
        coveredRoots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    public func hasObservedDirectory(_ path: String) -> Bool {
        directories[path] != nil
    }

    /// Returns non-owner hardlink alias paths under `directoryPath` so shallow directory
    /// listings can zero out duplicate physical allocations without a full subtree scan.
    public func nonOwnerAliasPaths(inDirectory directoryPath: String) -> Set<String> {
        let prefix = directoryPath == "/" ? "/" : directoryPath + "/"
        var result = Set<String>()
        for entry in entries.values {
            for alias in entry.aliases where alias.hasPrefix(prefix) {
                result.insert(alias)
            }
        }
        return result
    }

    /// A sparse catalog cannot infer where an allocation that was previously single-link
    /// was charged. Discovering any linked identity that was not previously tracked as a
    /// linked identity invalidates that baseline; even if all current links are inside the
    /// refreshed scope, an unrefreshed directory may still retain the old single-link charge.
    public func introducesLinkedIdentity(comparedTo previous: FileAllocationSnapshot) -> Bool {
        entries.contains { identity, _ in
            previous.entries[identity] == nil
                && !previous.knownLinkedIdentities.contains(identity)
        }
    }

    public struct Delta: Sendable {
        public let path: String
        public let allocatedBytes: Int64
        public let logicalBytes: Int64
        public let resultingAllocatedBytes: Int64
        public let resultingLogicalBytes: Int64
    }

    public struct Replacement: Sendable {
        public let snapshot: FileAllocationSnapshot
        /// Corrections to the independently scanned incoming node stream.
        public let incomingDeltas: [Delta]
        /// Corrections to previously published paths outside the replaced scope.
        public let externalDeltas: [Delta]
    }

    /// The caller serializes this value through its source-revision CAS. Partial scans replace
    /// only observed paths; absence is authoritative only for a complete measurement.
    public func replacing(
        with incoming: FileAllocationSnapshot,
        replacesPath: (String) -> Bool,
        excludesPath: (String) -> Bool = { _ in false },
        removedContributions: [RemovedContribution] = []
    ) -> Replacement {
        var result = self
        result.coveredRoots.formUnion(incoming.coveredRoots)
        result.knownLinkedIdentities.formUnion(entries.keys)
        result.knownLinkedIdentities.formUnion(incoming.knownLinkedIdentities)
        result.knownLinkedIdentities.formUnion(incoming.entries.keys)
        result.directories = directories.filter { !replacesPath($0.key) && !excludesPath($0.key) }
        for contribution in removedContributions {
            // A directory's files live in its own direct totals, removed above. Only a
            // leaf contribution must also be removed from the surviving parent's direct sum.
            let prefix = contribution.path == "/" ? "/" : contribution.path + "/"
            guard directories[contribution.path] == nil,
                  !directories.keys.contains(where: { $0.hasPrefix(prefix) }) else { continue }
            let parent = (contribution.path as NSString).deletingLastPathComponent
            guard var totals = result.directories[parent] else { continue }
            totals.allocatedBytes = max(0, totals.allocatedBytes - contribution.allocatedBytes)
            totals.logicalBytes = max(0, totals.logicalBytes - contribution.logicalBytes)
            totals.fileCount = max(0, totals.fileCount - contribution.fileCount)
            result.directories[parent] = totals
        }
        var affected = Set<Identity>()
        for (identity, entry) in entries {
            let remaining = entry.paths.filter { !replacesPath($0) && !excludesPath($0) }
            guard remaining.count != entry.paths.count else { continue }
            affected.insert(identity)
            if let owner = remaining.first {
                result.entries[identity] = Entry(owner: owner, aliases: Set(remaining.dropFirst()),
                                                allocatedBytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes)
            } else {
                result.entries.removeValue(forKey: identity)
            }
        }
        for (identity, entry) in incoming.entries {
            let observed = entry.paths.filter { !excludesPath($0) }
            guard !observed.isEmpty else { continue }
            affected.insert(identity)
            let retained = result.entries[identity]?.paths ?? []
            let paths = Array(Set(retained + observed)).sorted()
            let preferredOwner = entries[identity]?.owner
            let owner = preferredOwner.flatMap { paths.contains($0) ? $0 : nil }
                ?? result.entries[identity]?.owner ?? observed[0]
            result.entries[identity] = Entry(owner: owner, aliases: Set(paths.filter { $0 != owner }),
                                            allocatedBytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes)
        }

        var incomingChanges: [String: (allocated: Int64, logical: Int64)] = [:]
        var externalChanges: [String: (allocated: Int64, logical: Int64)] = [:]
        func add(_ path: String, _ allocated: Int64, _ logical: Int64,
                 to changes: inout [String: (allocated: Int64, logical: Int64)]) {
            let old = changes[path] ?? (0, 0)
            changes[path] = (old.allocated + allocated, old.logical + logical)
        }
        for identity in affected {
            if let old = entries[identity], !replacesPath(old.owner), !excludesPath(old.owner) {
                add(old.owner, -old.allocatedBytes, -old.logicalBytes, to: &externalChanges)
            }
            if let scanned = incoming.entries[identity] {
                // Only its first observer was charged by the local scanner.
                add(scanned.owner, -scanned.allocatedBytes, -scanned.logicalBytes, to: &incomingChanges)
            }
            if let new = result.entries[identity] {
                if incoming.entries[identity]?.paths.contains(new.owner) == true {
                    add(new.owner, new.allocatedBytes, new.logicalBytes, to: &incomingChanges)
                } else {
                    add(new.owner, new.allocatedBytes, new.logicalBytes, to: &externalChanges)
                }
            }
        }
        var resultingOwnership: [String: Entry] = [:]
        for identity in affected {
            if let entry = result.entries[identity] { resultingOwnership[entry.owner] = entry }
        }
        func deltas(_ values: [String: (allocated: Int64, logical: Int64)]) -> [Delta] {
            values.compactMap { path, bytes in
                guard bytes.allocated != 0 || bytes.logical != 0 else { return nil }
                return Delta(path: path, allocatedBytes: bytes.allocated, logicalBytes: bytes.logical,
                             resultingAllocatedBytes: resultingOwnership[path]?.allocatedBytes ?? 0,
                             resultingLogicalBytes: resultingOwnership[path]?.logicalBytes ?? 0)
            }
        }
        let incomingDeltas = deltas(incomingChanges)
        let externalDeltas = deltas(externalChanges)
        func apply(_ deltas: [Delta], to values: inout [String: DirectoryTotals]) {
            for delta in deltas {
                let parent = (delta.path as NSString).deletingLastPathComponent
                guard var totals = values[parent] else { continue }
                totals.allocatedBytes = max(0, totals.allocatedBytes + delta.allocatedBytes)
                totals.logicalBytes = max(0, totals.logicalBytes + delta.logicalBytes)
                values[parent] = totals
            }
        }
        var incomingDirectories = incoming.directories.filter { !excludesPath($0.key) }
        apply(incomingDeltas, to: &incomingDirectories)
        apply(externalDeltas, to: &result.directories)
        for (path, totals) in incomingDirectories {
            if !replacesPath(path), let previous = result.directories[path] {
                // A partially enumerated directory provides a lower bound, never proof that
                // unobserved old files have disappeared. Match the presentation contract.
                result.directories[path] = DirectoryTotals(
                    allocatedBytes: max(previous.allocatedBytes, totals.allocatedBytes),
                    logicalBytes: max(previous.logicalBytes, totals.logicalBytes),
                    fileCount: max(previous.fileCount, totals.fileCount))
            } else { result.directories[path] = totals }
        }
        return Replacement(snapshot: result, incomingDeltas: incomingDeltas, externalDeltas: externalDeltas)
    }

    public struct Aggregate: Sendable {
        public let allocatedBytes: Int64
        public let logicalBytes: Int64
        public let fileCount: Int
    }

    /// v2026.10.09: indexed refreshes must derive every directory from the same merged ledger,
    /// even when the original scan retained only shallow projections. Walk each direct total's
    /// ancestors once instead of rescanning the whole catalog for every observed directory.
    public func directoryAggregates(inDirectory root: String) -> [String: Aggregate] {
        var totals: [String: DirectoryTotals] = [
            root: DirectoryTotals(allocatedBytes: 0, logicalBytes: 0, fileCount: 0)
        ]
        let prefix = root == "/" ? "/" : root + "/"
        for (path, direct) in directories where path == root || path.hasPrefix(prefix) {
            var cursor = path
            while true {
                let old = totals[cursor] ?? DirectoryTotals(allocatedBytes: 0, logicalBytes: 0, fileCount: 0)
                totals[cursor] = DirectoryTotals(
                    allocatedBytes: old.allocatedBytes + direct.allocatedBytes,
                    logicalBytes: old.logicalBytes + direct.logicalBytes,
                    fileCount: old.fileCount + direct.fileCount)
                if cursor == root { break }
                let parent = (cursor as NSString).deletingLastPathComponent
                guard parent != cursor else { break }
                cursor = parent
            }
        }
        return totals.mapValues {
            Aggregate(allocatedBytes: $0.allocatedBytes, logicalBytes: $0.logicalBytes, fileCount: $0.fileCount)
        }
    }

    /// Ordinary files are retained as one direct sum per directory, not one path per file.
    /// First-observer accounting remains exact for the observed transaction, with the same
    /// live-namespace limitation as the sparse DerivedData ledger documented in PITFALLS.
    public func aggregate(inDirectory root: String) -> Aggregate {
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var files = 0
        let prefix = root == "/" ? "/" : root + "/"
        for (path, totals) in directories where path == root || path.hasPrefix(prefix) {
            files += totals.fileCount
            allocated += totals.allocatedBytes
            logical += totals.logicalBytes
        }
        return Aggregate(allocatedBytes: allocated, logicalBytes: logical, fileCount: files)
    }

    public func contribution(forPath path: String) -> Aggregate? {
        for entry in entries.values {
            if entry.owner == path {
                return Aggregate(
                    allocatedBytes: entry.allocatedBytes,
                    logicalBytes: entry.logicalBytes,
                    fileCount: 1
                )
            }
            if entry.aliases.contains(path) {
                return Aggregate(
                    allocatedBytes: 0,
                    logicalBytes: 0,
                    fileCount: 1
                )
            }
        }
        let prefix = path == "/" ? "/" : path + "/"
        var matchedDirectory = false
        var allocated: Int64 = 0
        var logical: Int64 = 0
        var files = 0
        for (dirPath, totals) in directories where dirPath == path || dirPath.hasPrefix(prefix) {
            matchedDirectory = true
            allocated += totals.allocatedBytes
            logical += totals.logicalBytes
            files += totals.fileCount
        }
        guard matchedDirectory else { return nil }
        return Aggregate(allocatedBytes: allocated, logicalBytes: logical, fileCount: files)
    }
}
