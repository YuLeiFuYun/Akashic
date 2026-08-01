import AkashicCore
import Foundation
import Testing

@Suite("AkashicCore identity contract")
struct BlobIdentityTests {
    @Test("AKASHIC-CT-001 canonical digest round trip")
    func canonicalDigestRoundTrip() throws {
        let data = Data("independent-akashic".utf8)
        let digest = BlobDigest.sha256(of: data)
        let reparsed = try BlobDigest(canonicalString: digest.canonicalString)

        #expect(reparsed == digest)
        #expect(reparsed.matches(data))
        #expect(reparsed.byteCount == data.count)

        let encoded = try JSONEncoder().encode(digest)
        #expect(try JSONDecoder().decode(BlobDigest.self, from: encoded) == digest)
    }

    @Test("AKASHIC-CT-002 malformed digest rejection")
    func malformedDigestRejection() {
        let invalid = [
            "sha256:00:1",
            "sha256:\(String(repeating: "0", count: 64)):01",
            "sha256:\(String(repeating: "A", count: 64)):1",
            "sha512:\(String(repeating: "0", count: 64)):1",
            "sha256:\(String(repeating: "0", count: 64)):-1",
        ]

        for value in invalid {
            #expect(throws: AkashicError.invalidIdentity) {
                _ = try BlobDigest(canonicalString: value)
            }
        }
    }

    @Test("AKASHIC-CT-003 partition derivation is opaque and domain separated")
    func partitionDerivation() throws {
        let material = Data("opaque-host-material".utf8)
        let first = try CachePartitionID.derive(domain: "test-a", material: material)
        let repeated = try CachePartitionID.derive(domain: "test-a", material: material)
        let otherDomain = try CachePartitionID.derive(domain: "test-b", material: material)

        #expect(first == repeated)
        #expect(first != otherDomain)
        #expect(throws: AkashicError.invalidIdentity) {
            _ = try CachePartitionID.derive(domain: "", material: material)
        }
    }

    @Test("Maintenance limits reject aggregate overflow")
    func maintenanceLimits() throws {
        let partition = try CachePartitionID.derive(
            domain: "maintenance-test",
            material: Data([1])
        )
        let first = BlobDigest.sha256(of: Data(repeating: 1, count: 4))
        let second = BlobDigest.sha256(of: Data(repeating: 2, count: 5))
        let references: Set<LiveBlobReference> = [
            LiveBlobReference(partition: partition, digest: first),
            LiveBlobReference(partition: partition, digest: second),
        ]

        try BlobMaintenanceLimits(
            maximumReferenceCount: 2,
            maximumReferencedBytes: 9
        ).validate(references)

        #expect(throws: AkashicError.limitExceeded) {
            try BlobMaintenanceLimits(
                maximumReferenceCount: 1,
                maximumReferencedBytes: 9
            ).validate(references)
        }
        #expect(throws: AkashicError.limitExceeded) {
            try BlobMaintenanceLimits(
                maximumReferenceCount: 2,
                maximumReferencedBytes: 8
            ).validate(references)
        }
    }
}
