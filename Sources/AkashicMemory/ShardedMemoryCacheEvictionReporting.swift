extension ShardedMemoryCache {
  func evictionReport(
    from victims: [MemoryCacheEvictionVictim<Key>]
  ) -> MemoryCacheEvictionReport<Key> {
    var releasedCost = 0
    for victim in victims {
      let addition = releasedCost.addingReportingOverflow(victim.cost)
      precondition(!addition.overflow)
      releasedCost = addition.partialValue
    }
    return MemoryCacheEvictionReport(
      evictedKeys: victims.map(\.key),
      summary: MemoryCacheRemovalSummary(
        itemCount: victims.count,
        costBytes: releasedCost
      )
    )
  }
}
