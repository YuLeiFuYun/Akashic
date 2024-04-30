//
//  Mnemosyne.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

public protocol CacheCostCalculable: CustomStringConvertible {
    var cacheCost: Int { get }
}

final class LRUCacheNode<Tag: Hashable, Payload: CacheCostCalculable>: NodeProtocol {
    let tag: Tag
    var payload: Payload
    var clock: Int
    var isActive = false
    var isToBeDeleted = false
    var expirationDate: Date?
    var isExpired: Bool { Date() > expirationDate! }
    
    var prev: LRUCacheNode<Tag, Payload>?
    var next: LRUCacheNode<Tag, Payload>?
    
    var description: String {
        ""
    }

    init(tag: Tag, payload: Payload, clock: Int) {
        self.tag = tag
        self.payload = payload
        self.clock = clock
    }
}

public final class Mnemosyne<Key: Hashable, Value: CacheCostCalculable>: CustomStringConvertible, @unchecked Sendable {
    public struct Config {
        // 最大内存成本限制
        var costLimit: Int
        // 最大缓存对象成本
        var entryCostLimit: Double
        // 最大缓存对象数量
        var countLimit: Int
        // 缓存对象的过期时间
        var ttl: TimeInterval
        // 过期缓存清理间隔
        var cleanupInterval: TimeInterval
        
        public init(
            costLimit: Int = Int(ProcessInfo.processInfo.physicalMemory) / 4,
            entryCostLimit: Double = 0.1,
            countLimit: Int = .max,
            ttl: TimeInterval = 120,
            cleanupInterval: TimeInterval = 120
        ) {
            self.costLimit = costLimit
            self.entryCostLimit = entryCostLimit
            self.countLimit = countLimit
            self.ttl = ttl
            self.cleanupInterval = cleanupInterval
        }
    }
    
    private let config: Config
    private var cacheMap = [Key: LRUCacheNode<Key, Value>]()
    private var fifoQueue = FIFOQueue<LRUCacheNode<Key, Value>>()
    private var lruList = DoublyLinkedList<Key, Value, LRUCacheNode<Key, Value>>()
    private var lruListKeys: Set<Key> = []
    private var totalCost = 0
    private var totalCount = 0
    private var clock = 0
    private let lock: os_unfair_lock_t
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer!
    
    public var description: String { lruList.description }
    
    public init(config: Config = .init()) {
        self.config = config
        
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        
        self.timer = .scheduledTimer(withTimeInterval: config.cleanupInterval, repeats: true) { [weak self] _ in
            self?.removeExpiredValues()
            self?.clock += 1
        }
        
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in
            self?.removeAllValues()
        }
        memoryPressureSource?.resume()
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        
        timer.invalidate()
        memoryPressureSource?.cancel()
    }
    
    public func setValue(_ value: Value, forKey key: Key) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard Double(value.cacheCost) < config.entryCostLimit * Double(config.costLimit) else { return }
        
        if let existingNode = cacheMap[key] {
            if lruListKeys.contains(key) {
                lruList.delete(existingNode)
                totalCost -= existingNode.payload.cacheCost
                existingNode.payload = value
                existingNode.expirationDate = Date().addingTimeInterval(config.ttl)
                totalCost += value.cacheCost
                trimIfNeeded()
                lruList.append(existingNode)
            } else {
                existingNode.isActive = true
                totalCost -= existingNode.payload.cacheCost
                existingNode.payload = value
                totalCost += value.cacheCost
                trimIfNeeded()
            }
        } else {
            let node = LRUCacheNode(tag: key, payload: value, clock: clock)
            cacheMap[key] = node
            totalCost += value.cacheCost
            totalCount += 1
            trimIfNeeded()
            fifoQueue.enqueue(node)
        }
    }
    
    public func value(forKey key: Key) -> Value? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard let node = cacheMap[key] else { return nil }
        
        if node.isActive, lruListKeys.contains(key) {
            lruList.delete(node)
            node.expirationDate = Date().addingTimeInterval(config.ttl)
            lruList.append(node)
        }
        node.isActive = true
        return node.payload
    }
    
    public func isCached(forKey key: Key) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        return cacheMap[key] != nil
    }
    
    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        return _removeValue(forKey: key)
    }
    
    public func removeAllValues() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        totalCost = 0
        totalCount = 0
        cacheMap.removeAll()
        lruList = DoublyLinkedList<Key, Value, LRUCacheNode<Key, Value>>()
        lruListKeys.removeAll()
        fifoQueue.removeAll()
    }
    
    public func removeExpiredValues() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        while let node = fifoQueue.peek, node.clock < clock {
            fifoQueue.dequeue()
            handleDequeuedFIFONode(node: node)
        }
        
        while let node = lruList.head, node.isExpired {
            _removeValue(forKey: node.tag)
        }
    }
    
    @discardableResult
    private func _removeValue(forKey key: Key) -> Value? {
        guard let node = cacheMap[key] else { return nil }
        
        if lruListKeys.contains(key) {
            totalCost -= node.payload.cacheCost
            totalCount -= 1
            lruList.delete(node)
            lruListKeys.remove(key)
        } else {
            node.isToBeDeleted = true
        }
        
        cacheMap[key] = nil
        return node.payload
    }
    
    private func trimIfNeeded() {
        guard totalCost > config.costLimit || totalCount > config.countLimit else { return }
        
        while totalCost > config.costLimit || totalCount > config.countLimit, let node = fifoQueue.dequeue() {
            handleDequeuedFIFONode(node: node)
        }
        
        while totalCost > config.costLimit || totalCount > config.countLimit, let node = lruList.head {
            _removeValue(forKey: node.tag)
        }
    }
    
    private func handleDequeuedFIFONode(node: LRUCacheNode<Key, Value>) {
        if node.isActive, !node.isToBeDeleted {
            node.expirationDate = Date().addingTimeInterval(config.ttl)
            lruList.append(node)
            lruListKeys.insert(node.tag)
        } else {
            totalCost -= node.payload.cacheCost
            totalCount -= 1
            cacheMap[node.tag] = nil
        }
    }
}
