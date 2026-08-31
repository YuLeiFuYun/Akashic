import AkashicCore
import AkashicDisk
import Foundation

private enum SchemaOpenControlError: Error {
    case invalidArguments
}

private struct SchemaOpenControlReport: Codable {
    let schemaVersion: Int
    let outcome: String
    let manifestGeneration: UInt64?
    let logicalEntryCount: Int?
}

enum SchemaOpenControlProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root"
        else { throw SchemaOpenControlError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let report: SchemaOpenControlReport
        do {
            let store = try await FileBlobStore.open(root: root)
            let snapshot = await store.resourceProbeManifestShadowSnapshot()
            report = SchemaOpenControlReport(
                schemaVersion: 1,
                outcome: "opened",
                manifestGeneration: snapshot.generation,
                logicalEntryCount: snapshot.entries.count
            )
        } catch let error as AkashicError {
            report = SchemaOpenControlReport(
                schemaVersion: 1,
                outcome: String(describing: error),
                manifestGeneration: nil,
                logicalEntryCount: nil
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
