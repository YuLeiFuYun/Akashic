import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

enum StructuralReservationProbeError: Error {
    case timeout(String)
    case invariant(String)
}

final class StructuralReservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String] = []
    private var gates: [String: DispatchSemaphore] = [:]
    private var corruptLabels: Set<String> = []

    func register(_ label: String, gate: DispatchSemaphore) {
        lock.lock()
        gates[label] = gate
        lock.unlock()
    }

    func markCorrupt(_ label: String) {
        lock.lock()
        corruptLabels.insert(label)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func read(url: URL, maximumBytes: Int, expectedBytes: Int?) throws -> BoundedFileReadResult {
        let label = url.lastPathComponent
        lock.lock()
        let gate = gates[label]
        let corrupt = corruptLabels.contains(label)
        starts.append(label)
        lock.unlock()
        guard let gate else { throw StructuralReservationProbeError.invariant("unregistered-\(label)") }
        gate.wait()
        let count = expectedBytes ?? maximumBytes
        return BoundedFileReadResult(
            data: Data(repeating: corrupt ? 0x00 : 0x6d, count: count),
            modificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

struct StructuralReservationHarness: Sendable {
    let scheduler: FileBlobStoreReadIO
    let state: StructuralReservationState

    init(
        maximumInFlightBytes: Int,
        maximumConcurrentReads: Int = 4,
        lookupMode: FileBlobStoreReadBypassLookupMode = .linear,
        admissionMode: FileBlobStoreReadBypassAdmissionMode = .structuralHeadReservation
    ) {
        let state = StructuralReservationState()
        self.state = state
        scheduler = FileBlobStoreReadIO(
            maximumConcurrentReads: maximumConcurrentReads,
            maximumInFlightBytes: maximumInFlightBytes,
            maximumPendingReads: 32,
            maximumBypassesPerBlockedHead: 3,
            bypassLookupMode: lookupMode,
            bypassAdmissionMode: admissionMode,
            operations: FileBlobStoreReadOperations(read: { url, maximumBytes, expectedBytes in
                try state.read(url: url, maximumBytes: maximumBytes, expectedBytes: expectedBytes)
            })
        )
    }

    func submit(bytes: Int, label: String, gate: DispatchSemaphore) -> Task<String, Never> {
        state.register(label, gate: gate)
        let data = Data(repeating: 0x6d, count: bytes)
        let digest = BlobDigest.sha256(of: data)
        let url = URL(fileURLWithPath: "/akashic-structural-reservation/\(label)")
        return Task {
            do {
                _ = try await scheduler.readVerified(
                    from: url,
                    maximumBytes: bytes,
                    expectedBytes: bytes,
                    digest: digest
                )
                return "ok"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error"
            }
        }
    }
}

struct StructuralReservationCase: Codable {
    let name: String
    let relevantStarts: [String]
    let passed: Bool
}

struct StructuralReservationReport: Codable {
    struct Claims: Codable {
        let productionDefaultChanged: Bool
        let formalLatency: Bool
        let serviceTimePrediction: Bool
        let filesystemIO: Bool
        let physicalDevice: Bool
        let byteAndWorkerAdmissionInvariantOnly: Bool
    }

    let schemaVersion: Int
    let cases: [StructuralReservationCase]
    let allCasesPass: Bool
    let observations: [String: Bool]
    let claims: Claims
}
