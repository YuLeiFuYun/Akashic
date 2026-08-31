import Foundation

extension SegmentedManifestPrototypeV1 {
    package static func isCanonicalSegmentFileName(
        _ fileName: String,
        kind: SegmentedManifestDescriptorV1.Kind
    ) -> Bool {
        switch kind {
        case .baseJSON:
            return isCanonicalGenericSegmentFileName(
                fileName,
                prefix: "base-",
                suffix: ".json"
            )
        case .baseBinaryV1:
            return isCanonicalBinaryBaseFileName(fileName)
        case .baseBinaryV2:
            return isCanonicalBinaryBaseV2FileName(fileName)
        case .runV1:
            return isCanonicalGenericSegmentFileName(
                fileName,
                prefix: "run-",
                suffix: ".seg"
            )
        case .compoundRunV1:
            return isCanonicalGenericSegmentFileName(
                fileName,
                prefix: "compound-",
                suffix: ".cseg"
            )
        }
    }

    private static func isCanonicalGenericSegmentFileName(
        _ fileName: String,
        prefix: String,
        suffix: String
    ) -> Bool {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.utf8.count <= 128 else {
            return false
        }
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let stem = fileName[..<end]
        return !stem.isEmpty && stem.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    private static func isCanonicalBinaryBaseFileName(_ fileName: String) -> Bool {
        let prefix = "base-binary-"
        let suffix = ".akb"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.utf8.count <= 128 else {
            return false
        }
        let uuidText = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard uuidText == uuidText.lowercased(),
            let uuid = UUID(uuidString: uuidText)
        else { return false }
        return uuid.uuidString.lowercased() == uuidText
    }

    private static func isCanonicalBinaryBaseV2FileName(_ fileName: String) -> Bool {
        let prefix = "base-binary-v2-"
        let suffix = ".akb2"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix), fileName.utf8.count <= 128 else {
            return false
        }
        let uuidText = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard uuidText == uuidText.lowercased(),
            let uuid = UUID(uuidString: uuidText)
        else { return false }
        return uuid.uuidString.lowercased() == uuidText
    }

}
