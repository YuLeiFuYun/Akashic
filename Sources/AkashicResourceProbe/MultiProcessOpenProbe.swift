import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum MultiProcessOpenMode: String, Codable {
    case publicOpen = "public"
    case segmentedV3 = "segmented-v3"
}

private struct MultiProcessOpenArguments {
    let root: URL
    let mode: MultiProcessOpenMode
    let ready: URL?
    let release: URL?

    static func parse(_ arguments: [String], requiresSignals: Bool) throws -> MultiProcessOpenArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootPath = values["--root"],
              let modeRaw = values["--mode"],
              let mode = MultiProcessOpenMode(rawValue: modeRaw)
        else { throw ProbeError.invalidArguments }
        let ready = values["--ready"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        let release = values["--release"].map { URL(fileURLWithPath: $0, isDirectory: false) }
        if requiresSignals, (ready == nil || release == nil) {
            throw ProbeError.invalidArguments
        }
        return MultiProcessOpenArguments(
            root: URL(fileURLWithPath: rootPath, isDirectory: true),
            mode: mode,
            ready: ready,
            release: release
        )
    }
}

private struct MultiProcessOpenReadyReport: Codable {
    let schemaVersion: Int
    let pid: Int32
    let mode: MultiProcessOpenMode
    let root: String
    let opened: Bool
}

private struct MultiProcessOpenAttemptReport: Codable {
    let schemaVersion: Int
    let pid: Int32
    let mode: MultiProcessOpenMode
    let opened: Bool
    let outcome: String
}

enum MultiProcessOpenProbe {
    static func hold(arguments: [String]) async throws {
        let configuration = try MultiProcessOpenArguments.parse(arguments, requiresSignals: true)
        let store = try await open(configuration.mode, root: configuration.root)
        defer { _ = store }
        let report = MultiProcessOpenReadyReport(
            schemaVersion: 1,
            pid: Darwin.getpid(),
            mode: configuration.mode,
            root: configuration.root.path,
            opened: true
        )
        try writeJSON(report, to: configuration.ready!)
        while !FileManager.default.fileExists(atPath: configuration.release!.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func attempt(arguments: [String]) async throws {
        let configuration = try MultiProcessOpenArguments.parse(arguments, requiresSignals: false)
        let report: MultiProcessOpenAttemptReport
        do {
            let store = try await open(configuration.mode, root: configuration.root)
            defer { _ = store }
            report = MultiProcessOpenAttemptReport(
                schemaVersion: 1,
                pid: Darwin.getpid(),
                mode: configuration.mode,
                opened: true,
                outcome: "opened"
            )
        } catch AkashicError.transactionConflict {
            report = MultiProcessOpenAttemptReport(
                schemaVersion: 1,
                pid: Darwin.getpid(),
                mode: configuration.mode,
                opened: false,
                outcome: "transactionConflict"
            )
        } catch AkashicError.unsupportedSchema {
            report = MultiProcessOpenAttemptReport(
                schemaVersion: 1,
                pid: Darwin.getpid(),
                mode: configuration.mode,
                opened: false,
                outcome: "unsupportedSchema"
            )
        } catch AkashicError.invalidManifest {
            report = MultiProcessOpenAttemptReport(
                schemaVersion: 1,
                pid: Darwin.getpid(),
                mode: configuration.mode,
                opened: false,
                outcome: "invalidManifest"
            )
        } catch {
            report = MultiProcessOpenAttemptReport(
                schemaVersion: 1,
                pid: Darwin.getpid(),
                mode: configuration.mode,
                opened: false,
                outcome: "other-error:\(String(describing: error))"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func open(_ mode: MultiProcessOpenMode, root: URL) async throws -> FileBlobStore {
        switch mode {
        case .publicOpen:
            return try await FileBlobStore.open(root: root)
        case .segmentedV3:
            let metadata = try SegmentedManifestPrototypeV1.readRoot(
                from: root.appendingPathComponent("manifest.json", isDirectory: false)
            )
            guard metadata.profile == SegmentedManifestPrototypeV1.profileV3,
                metadata.base.kind == .baseBinaryV2
            else { throw ProbeError.resourceSampleFailed }
            return try await FileBlobStore.openSegmentedV3Candidate(root: root)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value) + Data([0x0A])
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try data.write(to: url, options: [.atomic])
    }
}
