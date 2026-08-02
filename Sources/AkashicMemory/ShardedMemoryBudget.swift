/// 分片缓存的纯预算算术；不拥有锁或缓存状态。
enum ShardedMemoryBudget {
  static func partition(_ total: Int, count: Int) -> [Int] {
    precondition(total >= 0)
    precondition(count > 0)
    let base = total / count
    let remainder = total % count
    return (0 ..< count).map { base + ($0 < remainder ? 1 : 0) }
  }

  static func redistributedLimits(
    currentCosts: [Int],
    replacedCost: Int,
    targetIndex: Int,
    incomingCost: Int,
    totalLimit: Int
  ) -> [Int] {
    precondition(!currentCosts.isEmpty)
    precondition(currentCosts.indices.contains(targetIndex))
    precondition(totalLimit > 0)
    precondition(incomingCost > 0 && incomingCost <= totalLimit)
    precondition(replacedCost >= 0 && replacedCost <= currentCosts[targetIndex])

    var currentTotal = 0
    for cost in currentCosts {
      precondition(cost >= 0)
      let next = currentTotal.addingReportingOverflow(cost)
      precondition(!next.overflow, "shard costs must fit the global Int budget")
      currentTotal = next.partialValue
    }
    precondition(currentTotal <= totalLimit)

    let costWithoutReplaced = currentTotal - replacedCost
    let targetRetainedCost = currentCosts[targetIndex] - replacedCost
    if incomingCost <= totalLimit - costWithoutReplaced {
      let requiredTotal = costWithoutReplaced + incomingCost
      var required = currentCosts
      required[targetIndex] = targetRetainedCost + incomingCost
      let spare = partition(totalLimit - requiredTotal, count: currentCosts.count)
      return zip(required, spare).map(+)
    }

    let targetLimit =
      incomingCost <= totalLimit - targetRetainedCost
        ? targetRetainedCost + incomingCost
        : totalLimit
    let otherLimits = partition(
      totalLimit - targetLimit,
      count: max(1, currentCosts.count - 1)
    )
    var offset = 0
    return currentCosts.indices.map { index in
      guard index != targetIndex else { return targetLimit }
      defer { offset += 1 }
      return otherLimits[offset]
    }
  }
}
