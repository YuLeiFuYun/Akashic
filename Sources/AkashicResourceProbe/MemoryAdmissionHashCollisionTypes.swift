import Foundation

enum CollisionHashMode: String, Codable, CaseIterable, Sendable {
    case normal
    case constant
    case twoCluster
}

struct CollisionKey: Hashable, Sendable {
    let id: Int
    let mode: CollisionHashMode

    func hash(into hasher: inout Hasher) {
        switch mode {
        case .normal: hasher.combine(id)
        case .constant: hasher.combine(0)
        case .twoCluster: hasher.combine(id & 1)
        }
    }
}

struct CollisionRequest {
    let id: Int
    let cost: Int
}

enum CollisionEstimator: Equatable, Sendable {
    case hashOnly
    case exactGhost(capacity: Int)
    case oracleExactVictims

    var name: String {
        switch self {
        case .hashOnly: "hash-only"
        case .exactGhost(let capacity): "exact-ghost-\(capacity)"
        case .oracleExactVictims: "oracle-exact-victims"
        }
    }

    var ghostCapacity: Int {
        switch self {
        case .hashOnly: 0
        case .exactGhost(let capacity): capacity
        case .oracleExactVictims: 0
        }
    }
}

struct CollisionSketch {
    static let rowCount = 4
    private static let seeds: [UInt64] = [
        0x9e3779b97f4a7c15,
        0xbf58476d1ce4e5b9,
        0x94d049bb133111eb,
        0xd6e8feb86659fd93,
    ]

    let width: Int
    private var counters: [UInt16]
    private(set) var maximumCounter = 0

    init(width: Int = 128) {
        precondition(width > 0)
        self.width = width
        counters = Array(repeating: 0, count: Self.rowCount * width)
    }

    var counterPayloadBytes: Int {
        Self.rowCount * width * MemoryLayout<UInt16>.stride
    }

    mutating func increment(_ fingerprint: UInt64) {
        for row in 0..<Self.rowCount {
            let offset = row * width + index(fingerprint, row: row)
            if counters[offset] < .max { counters[offset] &+= 1 }
            maximumCounter = max(maximumCounter, Int(counters[offset]))
        }
    }

    func estimate(_ fingerprint: UInt64) -> Int {
        var value = Int.max
        for row in 0..<Self.rowCount {
            value = min(value, Int(counters[row * width + index(fingerprint, row: row)]))
        }
        return value == Int.max ? 0 : value
    }

    mutating func halve() {
        for index in counters.indices { counters[index] >>= 1 }
    }

    private func index(_ fingerprint: UInt64, row: Int) -> Int {
        Int(Self.mix(fingerprint ^ Self.seeds[row]) % UInt64(width))
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

struct CollisionGhostEntry {
    var count: Int
    var stamp: UInt64
}

struct CollisionGhost {
    let capacity: Int
    private var entries: [CollisionKey: CollisionGhostEntry] = [:]
    private var stamp: UInt64 = 0
    private(set) var maximumEntryCount = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var entryCount: Int { entries.count }
    var shallowPayloadBytesAtMaximum: Int {
        maximumEntryCount
            * (MemoryLayout<CollisionKey>.stride + MemoryLayout<CollisionGhostEntry>.stride)
    }

    mutating func observe(_ key: CollisionKey) {
        stamp &+= 1
        if var entry = entries[key] {
            entry.count = min(Int(UInt16.max), entry.count + 1)
            entry.stamp = stamp
            entries[key] = entry
            return
        }
        if entries.count >= capacity,
            let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key
        {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = CollisionGhostEntry(count: 1, stamp: stamp)
        maximumEntryCount = max(maximumEntryCount, entries.count)
    }

    func estimate(_ key: CollisionKey) -> Int? { entries[key]?.count }

    mutating func halve() {
        var aged: [CollisionKey: CollisionGhostEntry] = [:]
        aged.reserveCapacity(entries.count)
        for (key, var entry) in entries {
            entry.count /= 2
            if entry.count > 0 { aged[key] = entry }
        }
        entries = aged
    }
}

func collisionFingerprint(_ key: CollisionKey) -> UInt64 {
    var hasher = Hasher()
    key.hash(into: &hasher)
    return UInt64(bitPattern: Int64(hasher.finalize()))
}
