import Foundation

struct BlobPhysicalRemovalSummary {
    var fileCount = 0
    var byteCount = 0

    mutating func record(byteCount: Int) {
        if fileCount < Int.max { fileCount += 1 }
        let addition = self.byteCount.addingReportingOverflow(max(0, byteCount))
        self.byteCount = addition.overflow ? Int.max : addition.partialValue
    }

    mutating func merge(_ other: BlobPhysicalRemovalSummary) {
        let countAddition = fileCount.addingReportingOverflow(other.fileCount)
        fileCount = countAddition.overflow ? Int.max : countAddition.partialValue
        let byteAddition = byteCount.addingReportingOverflow(other.byteCount)
        byteCount = byteAddition.overflow ? Int.max : byteAddition.partialValue
    }
}
