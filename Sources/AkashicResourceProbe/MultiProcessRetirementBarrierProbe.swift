import Foundation

struct RetirementBarrierReaderReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let label: String
    let physicalID: String
    let byteCount: Int
    let profile: String
    let baseKind: String
    let sharedBarrierHeld: Bool
    let payloadPathExists: Bool
}

struct RetirementBarrierFDOpened: Codable {
    let schemaVersion: Int
    let label: String
    let physicalID: String
    let descriptorValidated: Bool
    let sharedBarrierReleased: Bool
    let payloadPathExistsAtOpen: Bool
}

struct RetirementBarrierReaderResult: Codable {
    let schemaVersion: Int
    let label: String
    let physicalID: String
    let payloadPathExistsAfterWriter: Bool
    let bytesRead: Int
    let payloadExact: Bool
    let digestExact: Bool
}

struct RetirementBarrierWriterResult: Codable {
    let schemaVersion: Int
    let label: String
    let initialExclusiveWouldBlock: Bool
    let exclusiveEventuallyAcquired: Bool
    let physicalBefore: String
    let physicalAfter: String?
    let logicalMissAfterRemove: Bool
    let payloadPathExistsAfterRemove: Bool
    let profile: String
    let baseKind: String
}

struct RetirementBarrierCheckResult: Codable {
    let schemaVersion: Int
    let lockKind: String
    let immediatelyAvailable: Bool
}

struct RetirementTurnstileReaderReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let label: String
    let physicalID: String
    let byteCount: Int
    let gateReleased: Bool
    let retirementSharedHeld: Bool
    let profile: String
    let baseKind: String
}

struct RetirementTurnstileWriterResult: Codable {
    let schemaVersion: Int
    let label: String
    let gateInitiallyAvailable: Bool
    let retirementInitiallyWouldBlock: Bool
    let retirementEventuallyAcquired: Bool
    let physicalBefore: String
    let physicalAfter: String?
    let logicalMissAfterRemove: Bool
    let payloadPathExistsAfterRemove: Bool
    let profile: String
    let baseKind: String
}

struct RetirementTurnstileCheckResult: Codable {
    let schemaVersion: Int
    let range: String
    let lockKind: String
    let immediatelyAvailable: Bool
}

struct RetirementLocalRefcountState: Codable {
    let schemaVersion: Int
    let phase: String
    let readerCount: Int
}

struct RetirementLocalAdmissionState: Codable {
    let schemaVersion: Int
    let phase: String
    let acquired: Bool
    let readerCount: Int
}

struct RetirementLocalWriterState: Codable {
    let schemaVersion: Int
    let phase: String
    let acquired: Bool
    let readerCount: Int
    let readerAdmissionWhileWriterActive: Bool?
}

struct RetirementSeedResult: Codable {
    let schemaVersion: Int
    let label: String
    let physicalID: String
    let byteCount: Int
    let profile: String
    let baseKind: String
    let payloadPathExists: Bool
    let payloadExact: Bool
    let digestExact: Bool
}

struct RetirementTurnstileWriterPhaseState: Codable {
    let schemaVersion: Int
    let pid: Int32
    let phase: String
}
