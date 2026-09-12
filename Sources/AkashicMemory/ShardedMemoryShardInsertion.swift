extension ShardedMemoryShard {
  func insertLocked(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    normalizedCost: Int
  ) {
    precondition(normalizedCost > 0 && normalizedCost <= costLimit)
    let reusable = node(for: key, rawHash: rawHash)
    if let reusable {
      detach(reusable)
    }

    var recycled: Node?
    while totalCost > costLimit - normalizedCost, let victim = nextVictim() {
      detach(victim)
      removeFromBucket(victim)
      if recycled == nil {
        recycled = victim
      }
    }
    finishInsertLocked(
      value,
      for: key,
      rawHash: rawHash,
      normalizedCost: normalizedCost,
      reusable: reusable,
      recycled: recycled
    )
  }

  func insertLocked(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    normalizedCost: Int,
    evictedVictims: inout [MemoryCacheEvictionVictim<Key>]?
  ) {
    precondition(normalizedCost > 0 && normalizedCost <= costLimit)
    let reusable = node(for: key, rawHash: rawHash)
    if let reusable {
      detach(reusable)
    }

    // Reporting callers pay identity collection; ordinary insert never carries this branch.
    var recycled: Node?
    while totalCost > costLimit - normalizedCost, let victim = nextVictim() {
      evictedVictims?.append(MemoryCacheEvictionVictim(key: victim.key, cost: victim.cost))
      detach(victim)
      removeFromBucket(victim)
      if recycled == nil {
        recycled = victim
      }
    }
    finishInsertLocked(
      value,
      for: key,
      rawHash: rawHash,
      normalizedCost: normalizedCost,
      reusable: reusable,
      recycled: recycled
    )
  }

  @inline(__always)
  private func finishInsertLocked(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    normalizedCost: Int,
    reusable: Node?,
    recycled: Node?
  ) {
    let node: Node
    if let reusable {
      reusable.value = value
      reusable.cost = normalizedCost
      reusable.visitedEpoch = 0
      reusable.previous = tail
      node = reusable
    } else if let recycled {
      recycled.key = key
      recycled.rawHash = rawHash
      recycled.value = value
      recycled.cost = normalizedCost
      recycled.visitedEpoch = 0
      recycled.previous = tail
      recycled.collisionNext = nil
      insertIntoBucket(recycled)
      node = recycled
    } else {
      node = Node(
        key: key,
        rawHash: rawHash,
        value: value,
        cost: normalizedCost,
        previous: tail
      )
      insertIntoBucket(node)
    }
    tail?.next = node
    if head == nil {
      head = node
    }
    tail = node
    totalCost += normalizedCost
  }
}
