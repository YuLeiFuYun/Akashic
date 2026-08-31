import AkashicCore
import Darwin
import Foundation

private struct SegmentGCSummary {
    let deleted: Int
    let referenced: Int
    let foreign: Int
}

struct SegmentedManifestSegmentGCReport: Codable {
    let schemaVersion: Int
    let referencedSegmentsSurvive: Bool
    let validUnreferencedRunDeleted: Bool
    let corruptUnreferencedRunDeleted: Bool
    let symlinkLookalikeRejected: Bool
    let symlinkTargetSurvives: Bool
    let hardlinkLookalikeRejected: Bool
    let hardlinkTargetSurvives: Bool
    let unsafeModeLookalikeRejected: Bool
    let immutableCleanupFailurePreservesAuthority: Bool
    let immutableRetrySucceeds: Bool
    let foreignNoncanonicalRemains: Bool
    let boundedEnumerationRejectsOverflow: Bool
    let logicalStateStableAcrossDebtFailures: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionGC: Bool
        let maliciousSameUserRaceProtection: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let formalPerformance: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func segmentGCShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let referencedSegmentsSurvive = try segmentGCReferencedCase(
            root: root.appendingPathComponent("referenced", isDirectory: true)
        )
        let validUnreferencedRunDeleted = try segmentGCOrphanCase(
            root: root.appendingPathComponent("valid-orphan", isDirectory: true),
            corrupt: false
        )
        let corruptUnreferencedRunDeleted = try segmentGCOrphanCase(
            root: root.appendingPathComponent("corrupt-orphan", isDirectory: true),
            corrupt: true
        )
        let symlink = try segmentGCSymlinkCase(
            root: root.appendingPathComponent("symlink", isDirectory: true)
        )
        let hardlink = try segmentGCHardlinkCase(
            root: root.appendingPathComponent("hardlink", isDirectory: true)
        )
        let unsafeModeLookalikeRejected = try segmentGCUnsafeModeCase(
            root: root.appendingPathComponent("unsafe-mode", isDirectory: true)
        )
        let immutable = try segmentGCImmutableCase(
            root: root.appendingPathComponent("immutable", isDirectory: true)
        )
        let foreignNoncanonicalRemains = try segmentGCForeignCase(
            root: root.appendingPathComponent("foreign", isDirectory: true)
        )
        let boundedEnumerationRejectsOverflow = try segmentGCBoundedCase(
            root: root.appendingPathComponent("bounded", isDirectory: true)
        )

        guard referencedSegmentsSurvive,
            validUnreferencedRunDeleted,
            corruptUnreferencedRunDeleted,
            symlink.rejected,
            symlink.targetSurvives,
            hardlink.rejected,
            hardlink.targetSurvives,
            unsafeModeLookalikeRejected,
            immutable.failurePreservedAuthority,
            immutable.retrySucceeds,
            foreignNoncanonicalRemains,
            boundedEnumerationRejectsOverflow
        else { throw SegmentedManifestShadowError.invariantViolation }

        let report = SegmentedManifestSegmentGCReport(
            schemaVersion: 1,
            referencedSegmentsSurvive: true,
            validUnreferencedRunDeleted: true,
            corruptUnreferencedRunDeleted: true,
            symlinkLookalikeRejected: true,
            symlinkTargetSurvives: true,
            hardlinkLookalikeRejected: true,
            hardlinkTargetSurvives: true,
            unsafeModeLookalikeRejected: true,
            immutableCleanupFailurePreservesAuthority: true,
            immutableRetrySucceeds: true,
            foreignNoncanonicalRemains: true,
            boundedEnumerationRejectsOverflow: true,
            logicalStateStableAcrossDebtFailures: true,
            claims: .init(
                productionGC: false,
                maliciousSameUserRaceProtection: false,
                physicalDevice: false,
                powerLoss: false,
                formalPerformance: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func segmentGCReferencedCase(root: URL) throws -> Bool {
        let fixture = try segmentGCFixture(root: root)
        let before = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        let summary = try performSegmentGC(
            rootURL: fixture.rootURL,
            segmentDirectory: fixture.segments,
            maximumEntries: 128
        )
        let after = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        return summary.deleted == 0
            && summary.referenced == 2
            && before == after
            && FileManager.default.fileExists(atPath: fixture.baseURL.path)
            && FileManager.default.fileExists(atPath: fixture.runURL.path)
    }

    private static func segmentGCOrphanCase(root: URL, corrupt: Bool) throws -> Bool {
        let fixture = try segmentGCFixture(root: root)
        let orphan = fixture.segments.appendingPathComponent(
            corrupt ? "run-corrupt-orphan.seg" : "run-valid-orphan.seg"
        )
        if corrupt {
            try DurableFileWriter.writeReplacing(Data("not-a-segment".utf8), to: orphan)
        } else {
            let entries = try makeBaseEntries(count: 1)
            try DurableFileWriter.writeReplacing(try encodeRun([.upsert(entries[0])]), to: orphan)
        }
        let before = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        let summary = try performSegmentGC(
            rootURL: fixture.rootURL,
            segmentDirectory: fixture.segments,
            maximumEntries: 128
        )
        let after = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        return summary.deleted == 1
            && !FileManager.default.fileExists(atPath: orphan.path)
            && before == after
    }

    private static func segmentGCSymlinkCase(root: URL) throws -> (rejected: Bool, targetSurvives: Bool) {
        let fixture = try segmentGCFixture(root: root)
        let target = root.appendingPathComponent("foreign-target")
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: target)
        let linkURL = fixture.segments.appendingPathComponent("run-symlink.seg")
        guard symlink(target.path, linkURL.path) == 0 else { throw POSIXError(.EIO) }
        var rejected = false
        do {
            _ = try performSegmentGC(
                rootURL: fixture.rootURL,
                segmentDirectory: fixture.segments,
                maximumEntries: 128
            )
        } catch {
            rejected = true
        }
        return (rejected, FileManager.default.fileExists(atPath: target.path))
    }

    private static func segmentGCHardlinkCase(root: URL) throws -> (rejected: Bool, targetSurvives: Bool) {
        let fixture = try segmentGCFixture(root: root)
        let target = root.appendingPathComponent("hardlink-target")
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: target)
        let lookalike = fixture.segments.appendingPathComponent("run-hardlink.seg")
        guard link(target.path, lookalike.path) == 0 else { throw POSIXError(.EIO) }
        var rejected = false
        do {
            _ = try performSegmentGC(
                rootURL: fixture.rootURL,
                segmentDirectory: fixture.segments,
                maximumEntries: 128
            )
        } catch {
            rejected = true
        }
        return (rejected, FileManager.default.fileExists(atPath: target.path))
    }

    private static func segmentGCUnsafeModeCase(root: URL) throws -> Bool {
        let fixture = try segmentGCFixture(root: root)
        let lookalike = fixture.segments.appendingPathComponent("run-unsafe-mode.seg")
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: lookalike)
        guard chmod(lookalike.path, 0o644) == 0 else { throw POSIXError(.EIO) }
        do {
            _ = try performSegmentGC(
                rootURL: fixture.rootURL,
                segmentDirectory: fixture.segments,
                maximumEntries: 128
            )
            return false
        } catch {
            return FileManager.default.fileExists(atPath: lookalike.path)
        }
    }

    private static func segmentGCImmutableCase(
        root: URL
    ) throws -> (failurePreservedAuthority: Bool, retrySucceeds: Bool) {
        let fixture = try segmentGCFixture(root: root)
        let orphan = fixture.segments.appendingPathComponent("run-immutable-orphan.seg")
        let entry = try makeBaseEntries(count: 1)[0]
        try DurableFileWriter.writeReplacing(try encodeRun([.upsert(entry)]), to: orphan)
        let before = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        guard chflags(orphan.path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EIO) }
        var cleanupFailed = false
        do {
            _ = try performSegmentGC(
                rootURL: fixture.rootURL,
                segmentDirectory: fixture.segments,
                maximumEntries: 128
            )
        } catch {
            cleanupFailed = true
        }
        let during = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        guard chflags(orphan.path, 0) == 0 else { throw POSIXError(.EIO) }
        let retry = try performSegmentGC(
            rootURL: fixture.rootURL,
            segmentDirectory: fixture.segments,
            maximumEntries: 128
        )
        let after = try recoverRootState(rootURL: fixture.rootURL, segmentDirectory: fixture.segments)
        return (
            cleanupFailed && before == during,
            retry.deleted == 1 && !FileManager.default.fileExists(atPath: orphan.path) && after == before
        )
    }

    private static func segmentGCForeignCase(root: URL) throws -> Bool {
        let fixture = try segmentGCFixture(root: root)
        let foreign = fixture.segments.appendingPathComponent("README.foreign")
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: foreign)
        let summary = try performSegmentGC(
            rootURL: fixture.rootURL,
            segmentDirectory: fixture.segments,
            maximumEntries: 128
        )
        return summary.foreign == 1 && FileManager.default.fileExists(atPath: foreign.path)
    }

    private static func segmentGCBoundedCase(root: URL) throws -> Bool {
        let fixture = try segmentGCFixture(root: root)
        for index in 0..<127 {
            try DurableFileWriter.writeReplacing(
                Data([UInt8(truncatingIfNeeded: index)]),
                to: fixture.segments.appendingPathComponent("foreign-\(index)")
            )
        }
        do {
            _ = try performSegmentGC(
                rootURL: fixture.rootURL,
                segmentDirectory: fixture.segments,
                maximumEntries: 128
            )
            return false
        } catch {
            return true
        }
    }

    private static func performSegmentGC(
        rootURL: URL,
        segmentDirectory: URL,
        maximumEntries: Int
    ) throws -> SegmentGCSummary {
        let before = try recoverRootState(rootURL: rootURL, segmentDirectory: segmentDirectory)
        let rootData = try BoundedFileReader.read(from: rootURL, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: rootData)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        let referencedNames = Set(([root.base] + root.runs).map(\.fileName))
        let names = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: maximumEntries
        )
        var deleted = 0
        var referenced = 0
        var foreign = 0
        for name in names.sorted() {
            if referencedNames.contains(name) {
                referenced += 1
                continue
            }
            let isSegment = isCanonicalSegmentFileName(name, kind: .base)
                || isCanonicalSegmentFileName(name, kind: .run)
            guard isSegment else {
                foreign += 1
                continue
            }
            let url = segmentDirectory.appendingPathComponent(name)
            try StorageDirectorySecurity.validateRegularFile(url)
            do {
                try FileManager.default.removeItem(at: url)
                deleted += 1
            } catch {
                throw AkashicError.storageUnavailable
            }
        }
        guard try recoverRootState(rootURL: rootURL, segmentDirectory: segmentDirectory) == before else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        return SegmentGCSummary(deleted: deleted, referenced: referenced, foreign: foreign)
    }

    private static func segmentGCFixture(
        root: URL
    ) throws -> (segments: URL, rootURL: URL, baseURL: URL, runURL: URL) {
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let baseEntries = try makeBaseEntries(count: 64)
        let baseData = try encodeBase(baseEntries)
        let baseURL = segments.appendingPathComponent("base-live.seg")
        try DurableFileWriter.writeReplacing(baseData, to: baseURL)
        let base = try descriptor(.base, url: baseURL, expectedRecords: baseEntries.count)
        let mutations = try makeRunMutations(base: baseEntries, count: 16)
        let runData = try encodeRun(mutations)
        let runURL = segments.appendingPathComponent("run-live.seg")
        try DurableFileWriter.writeReplacing(runData, to: runURL)
        let run = try descriptor(.run, url: runURL, expectedRecords: mutations.count)
        let rootManifest = try makeRoot(generation: 1, base: base, runs: [run])
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(rootManifest), to: rootURL)
        _ = try recoverRootState(rootURL: rootURL, segmentDirectory: segments)
        return (segments, rootURL, baseURL, runURL)
    }
}
