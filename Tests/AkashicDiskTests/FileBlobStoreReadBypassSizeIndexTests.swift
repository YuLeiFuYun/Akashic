import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk bounded read bypass size index")
struct FileBlobStoreReadBypassSizeIndexTests {
  @Test("stale size-index entries retain token identity until rebuild")
  func staleEntryPreventsObjectIdentifierABA() {
    final class DeinitFlag {
      var value = false
    }
    final class Token {
      let flag: DeinitFlag
      init(flag: DeinitFlag) { self.flag = flag }
      deinit { flag.value = true }
    }

    let flag = DeinitFlag()
    var index = FileBlobStoreReadBypassSizeIndex()
    var token: Token? = Token(flag: flag)
    let tokenID = ObjectIdentifier(token!)

    index.append(token: token!, expectedBytes: 1)
    token = nil

    #expect(!flag.value)
    #expect(index.frontToken(in: 0) == tokenID)

    index.discardFront(in: 0)
    #expect(!flag.value)

    index.rebuild([])
    #expect(flag.value)
  }

  @Test("exact slot-min index returns earliest fitting physical slot")
  func exactSlotMinIndexFirstFit() {
    var index = FileBlobStoreReadBypassExactIndex()
    _ = index.update(slot: 0, expectedBytes: 32)
    _ = index.update(slot: 1, expectedBytes: 64)
    _ = index.update(slot: 2, expectedBytes: 3)
    _ = index.update(slot: 3, expectedBytes: 2)
    _ = index.update(slot: 4, expectedBytes: 1)

    #expect(index.firstSlot(startingAt: 1, slotCount: 5, maximumBytes: 3).slot == 2)
    #expect(index.firstSlot(startingAt: 3, slotCount: 5, maximumBytes: 3).slot == 3)
    #expect(index.firstSlot(startingAt: 1, slotCount: 5, maximumBytes: 1).slot == 4)
    #expect(index.firstSlot(startingAt: 5, slotCount: 5, maximumBytes: 64).slot == nil)

    _ = index.update(slot: 2, expectedBytes: nil)
    #expect(index.firstSlot(startingAt: 1, slotCount: 5, maximumBytes: 3).slot == 3)
  }

  @Test("exact slot-min index rebuild preserves tombstones and queue positions")
  func exactSlotMinIndexRebuild() {
    var index = FileBlobStoreReadBypassExactIndex()
    let writes = index.rebuild([32, nil, 7, 3, nil, 1])
    #expect(writes > 0)
    #expect(index.leafCapacity == 8)
    #expect(index.scalarSlots == 16)
    #expect(index.firstSlot(startingAt: 0, slotCount: 6, maximumBytes: 3).slot == 3)
    #expect(index.firstSlot(startingAt: 4, slotCount: 6, maximumBytes: 3).slot == 5)
    #expect(index.firstSlot(startingAt: 0, slotCount: 6, maximumBytes: 0 + 1).slot == 5)
  }
}
