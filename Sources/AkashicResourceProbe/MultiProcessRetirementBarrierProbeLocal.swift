import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func multiProcessRetirementLocalRefcount(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let barrierPath = values["--barrier"],
            let readyPath = values["--ready"],
            let releaseOnePath = values["--release-one"],
            let afterOnePath = values["--after-one"],
            let releaseTwoPath = values["--release-two"],
            let afterTwoPath = values["--after-two"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let coordinator = try RetirementLocalReaderCoordinator(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        let firstCount = try coordinator.acquireReader()
        let secondCount = try coordinator.acquireReader()
        guard firstCount == 1, secondCount == 2 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "two-readers-held",
                readerCount: secondCount
            ),
            to: URL(fileURLWithPath: readyPath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REFCOUNT-READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: releaseOnePath) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let afterOneCount = try coordinator.releaseReader()
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "one-reader-remains",
                readerCount: afterOneCount
            ),
            to: URL(fileURLWithPath: afterOnePath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REFCOUNT-AFTER-ONE-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: releaseTwoPath) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let afterTwoCount = try coordinator.releaseReader()
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "all-readers-released",
                readerCount: afterTwoCount
            ),
            to: URL(fileURLWithPath: afterTwoPath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REFCOUNT-AFTER-TWO-SETTLED\n".utf8))
    }

    static func multiProcessRetirementLocalAdmission(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let barrierPath = values["--barrier"],
            let readyPath = values["--ready"],
            let tryOnePath = values["--try-one"],
            let resultOnePath = values["--result-one"],
            let tryTwoPath = values["--try-two"],
            let resultTwoPath = values["--result-two"],
            let releasePath = values["--release"],
            let releasedPath = values["--released"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let coordinator = try RetirementLocalReaderCoordinator(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        var count = try coordinator.acquireReader()
        guard count == 1 else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "one-reader-held",
                readerCount: count
            ),
            to: URL(fileURLWithPath: readyPath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-ADMISSION-READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: tryOnePath) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let first = try coordinator.tryAcquireReader()
        count = first.readerCount
        try schema5RetirementWriteJSON(
            RetirementLocalAdmissionState(
                schemaVersion: 1,
                phase: "first-try",
                acquired: first.acquired,
                readerCount: count
            ),
            to: URL(fileURLWithPath: resultOnePath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-ADMISSION-FIRST-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: tryTwoPath) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = try coordinator.tryAcquireReader()
        count = second.readerCount
        try schema5RetirementWriteJSON(
            RetirementLocalAdmissionState(
                schemaVersion: 1,
                phase: "second-try",
                acquired: second.acquired,
                readerCount: count
            ),
            to: URL(fileURLWithPath: resultTwoPath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-ADMISSION-SECOND-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: releasePath) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        while count > 0 { count = try coordinator.releaseReader() }
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "released",
                readerCount: count
            ),
            to: URL(fileURLWithPath: releasedPath, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-ADMISSION-RELEASED-SETTLED\n".utf8))
    }

    static func multiProcessRetirementLocalWriterState(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let required = [
            "--barrier", "--ready", "--begin", "--pending",
            "--try-reader", "--try-reader-result",
            "--finish-before-release", "--finish-before-result",
            "--release-reader", "--reader-released",
            "--finish-after-release", "--finish-after-result",
            "--release-writer", "--writer-released",
        ]
        guard required.allSatisfy({ values[$0] != nil }) else {
            throw SegmentedManifestShadowError.invalidArguments
        }

        let coordinator = try RetirementLocalReaderCoordinator(
            path: URL(fileURLWithPath: values["--barrier"]!, isDirectory: false)
        )
        var readerCount = try coordinator.acquireReader()
        guard readerCount == 1 else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "reader-held",
                readerCount: readerCount
            ),
            to: URL(fileURLWithPath: values["--ready"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--begin"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let begun = try coordinator.beginWriterIntent()
        guard begun else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "writer-pending-gate-held",
                acquired: false,
                readerCount: readerCount,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--pending"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-PENDING-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--try-reader"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let readerTry = try coordinator.tryAcquireReader()
        try schema5RetirementWriteJSON(
            RetirementLocalAdmissionState(
                schemaVersion: 1,
                phase: "reader-while-writer-pending",
                acquired: readerTry.acquired,
                readerCount: readerTry.readerCount
            ),
            to: URL(fileURLWithPath: values["--try-reader-result"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-READER-TRY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--finish-before-release"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let before = try coordinator.tryFinishWriterAcquire()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "finish-before-reader-release",
                acquired: before.acquired,
                readerCount: before.readerCount,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--finish-before-result"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-FINISH-BEFORE-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--release-reader"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        readerCount = try coordinator.releaseReader()
        try schema5RetirementWriteJSON(
            RetirementLocalRefcountState(
                schemaVersion: 1,
                phase: "reader-released",
                readerCount: readerCount
            ),
            to: URL(fileURLWithPath: values["--reader-released"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-READER-RELEASED-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--finish-after-release"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let after = try coordinator.tryFinishWriterAcquire()
        let readerDuringWriter = try coordinator.tryAcquireReader()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "writer-active",
                acquired: after.acquired,
                readerCount: after.readerCount,
                readerAdmissionWhileWriterActive: readerDuringWriter.acquired
            ),
            to: URL(fileURLWithPath: values["--finish-after-result"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-FINISH-AFTER-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--release-writer"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try coordinator.releaseWriter()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "writer-released",
                acquired: false,
                readerCount: 0,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--writer-released"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-WRITER-RELEASED-SETTLED\n".utf8))
    }
}
