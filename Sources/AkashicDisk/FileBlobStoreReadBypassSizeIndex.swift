import Foundation

/// Rebuildable acceleration index for the package-only bounded-bypass scheduler candidate.
/// Primary pending slots and `pendingIndexByToken` remain the source of truth.
struct FileBlobStoreReadBypassSizeIndex {
    private struct TokenEntry {
        let token: AnyObject

        var id: ObjectIdentifier { ObjectIdentifier(token) }
    }

    private var tokens = Array(repeating: [TokenEntry](), count: Int.bitWidth)
    private var heads = Array(repeating: 0, count: Int.bitWidth)

    var classCount: Int { tokens.count }
    var tokenSlots: Int { tokens.reduce(0) { $0 + $1.count } }

    mutating func append(token: AnyObject, expectedBytes: Int) {
        tokens[classIndex(max(1, expectedBytes))].append(TokenEntry(token: token))
    }

    mutating func rebuild(_ entries: [(AnyObject, Int)]) {
        tokens = Array(repeating: [], count: Int.bitWidth)
        heads = Array(repeating: 0, count: Int.bitWidth)
        for (token, expectedBytes) in entries {
            append(token: token, expectedBytes: expectedBytes)
        }
    }

    func upperBound(for classIndex: Int) -> Int {
        if classIndex >= Int.bitWidth - 1 { return Int.max }
        return 1 << classIndex
    }

    func frontToken(in classIndex: Int) -> ObjectIdentifier? {
        let head = heads[classIndex]
        guard head < tokens[classIndex].count else { return nil }
        return tokens[classIndex][head].id
    }

    mutating func discardFront(in classIndex: Int) {
        if heads[classIndex] < tokens[classIndex].count { heads[classIndex] += 1 }
    }

    private func classIndex(_ bytes: Int) -> Int {
        guard bytes > 1 else { return 0 }
        return Int.bitWidth - (bytes - 1).leadingZeroBitCount
    }
}
