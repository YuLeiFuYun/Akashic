import Foundation
import Testing

@testable import AkashicMemory

@Suite("AkashicMemory removeAll predicate snapshot semantics")
struct MemoryCacheRemoveAllSnapshotTests {
    @Test("T102 removeAll predicate may re-enter the same cache")
    func predicateMayReenterSameCache() {
        let cache = MemoryCache<Int, Int>(costLimit: 16)
        for key in 0..<8 {
            cache.insert(key, for: key, cost: 1)
        }

        cache.removeAll { key in
            // This call acquires the same cache mutex. The previous implementation executed the
            // predicate while already holding that mutex and structurally deadlocked here.
            cache.value(for: key) != nil && key.isMultiple(of: 2)
        }

        for key in 0..<8 {
            if key.isMultiple(of: 2) {
                #expect(cache.value(for: key) == nil)
            } else {
                #expect(cache.value(for: key) == key)
            }
        }
    }

    @Test("T102 removeAll snapshot does not delete a replacement incarnation")
    func snapshotDoesNotDeleteReplacementIncarnation() async {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        cache.insert(1, for: 7, cost: 1)

        let enteredPredicate = DispatchSemaphore(value: 0)
        let allowPredicateToFinish = DispatchSemaphore(value: 0)
        let removal = Task.detached {
            cache.removeAll { key in
                guard key == 7 else { return false }
                enteredPredicate.signal()
                allowPredicateToFinish.wait()
                return true
            }
        }

        let enteredResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: enteredPredicate.wait(timeout: .now() + 2))
            }
        }
        #expect(enteredResult == .success)
        // Replacement creates a new resident node for the same key while the old node is only a
        // snapshot candidate. The completed predicate must not delete this new incarnation.
        cache.insert(2, for: 7, cost: 1)
        allowPredicateToFinish.signal()
        await removal.value

        #expect(cache.value(for: 7) == 2)
        #expect(cache.currentCost == 1)
    }
}
