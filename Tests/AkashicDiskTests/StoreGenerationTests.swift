import AkashicCore
@testable import AkashicDisk
import Foundation
import Testing

@Suite("AkashicDisk store generation")
struct StoreGenerationTests {
    private enum InjectedFailure: Error {
        case stop
    }

    @Test("AKASHIC-CT-014 generation pointer is stable for one fingerprint")
    func stableGenerationReuse() async throws {
        try await withGenerationTemporaryDirectory { root in
            let first = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "current-layout-a"
            )
            let second = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "current-layout-a"
            )
            let other = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "current-layout-b"
            )
            let recoveredFirst = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "current-layout-a"
            )

            #expect(first.identifier == second.identifier)
            #expect(first.identifier != other.identifier)
            #expect(first.identifier == recoveredFirst.identifier)
            #expect(try first.descriptor.identifier == first.identifier)
            #expect(generationDirectoryCount(root: root) == 2)
        }
    }

    @Test("AKASHIC-CT-014 every generation switch point recovers to a complete state")
    func switchPointRecovery() async throws {
        for point in StoreGenerationSwitchPoint.allCases {
            try await withGenerationTemporaryDirectory { root in
                do {
                    _ = try StoreGenerationDirectory.open(
                        root: root,
                        compatibilityFingerprint: "switch-\(label(point))"
                    ) { observed in
                        if observed == point { throw InjectedFailure.stop }
                    }
                    Issue.record("Expected injected failure at \(label(point))")
                } catch InjectedFailure.stop {
                    // Expected retained crash point.
                }

                let recovered = try await StoreGenerationDirectory.open(
                    root: root,
                    compatibilityFingerprint: "switch-\(label(point))"
                )
                let repeated = try await StoreGenerationDirectory.open(
                    root: root,
                    compatibilityFingerprint: "switch-\(label(point))"
                )

                #expect(recovered.identifier == repeated.identifier)
                #expect(FileManager.default.fileExists(
                    atPath: recovered.root.appendingPathComponent("generation.json").path
                ))
                #expect(noTemporaryPointers(root: root))
                #expect(generationDirectoryCount(root: root) == 1)
            }
        }
    }

    @Test("AKASHIC-CT-012 future generation pointer schema fails closed")
    func futurePointerSchemaFailsClosed() async throws {
        try await withGenerationTemporaryDirectory { root in
            let handle = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "future-pointer"
            )
            let pointer = root.appendingPathComponent("current-generation.json")
            let future = Data(#"{"schemaVersion":999}"#.utf8)
            try future.write(to: pointer)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: pointer.path
            )

            await expectGenerationAkashicError(.unsupportedSchema) {
                _ = try await StoreGenerationDirectory.open(
                    root: root,
                    compatibilityFingerprint: "future-pointer"
                )
            }
            #expect(try Data(contentsOf: pointer) == future)
            #expect(FileManager.default.fileExists(atPath: handle.root.path))
        }
    }

    @Test("AKASHIC-CT-012 future generation descriptor schema fails closed")
    func futureDescriptorSchemaFailsClosed() async throws {
        try await withGenerationTemporaryDirectory { root in
            let handle = try await StoreGenerationDirectory.open(
                root: root,
                compatibilityFingerprint: "future-descriptor"
            )
            let descriptor = handle.root.appendingPathComponent("generation.json")
            let future = Data(#"{"schemaVersion":999}"#.utf8)
            try future.write(to: descriptor)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: descriptor.path
            )

            await expectGenerationAkashicError(.unsupportedSchema) {
                _ = try await StoreGenerationDirectory.open(
                    root: root,
                    compatibilityFingerprint: "future-descriptor"
                )
            }
            #expect(try Data(contentsOf: descriptor) == future)
        }
    }
}

private func label(_ point: StoreGenerationSwitchPoint) -> String {
    switch point {
    case .afterGenerationDirectoryCreated:
        "directory-created"
    case .afterGenerationDescriptorPublished:
        "descriptor-published"
    case .afterPointerStaged:
        "pointer-staged"
    case .afterPointerPublished:
        "pointer-published"
    }
}

private func generationDirectoryCount(root: URL) -> Int {
    let generations = root.appendingPathComponent("generations", isDirectory: true)
    return ((try? FileManager.default.contentsOfDirectory(
        at: generations,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []).filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.count
}

private func noTemporaryPointers(root: URL) -> Bool {
    let children = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    )) ?? []
    return children.allSatisfy {
        !$0.lastPathComponent.hasPrefix(".current-generation.tmp-")
    }
}

private func withGenerationTemporaryDirectory<T>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akashic-generation-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    return try await operation(root)
}

private func expectGenerationAkashicError<T>(
    _ expected: AkashicError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected AkashicError.\(expected)")
    } catch let error as AkashicError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected AkashicError.\(expected), received \(error)")
    }
}
