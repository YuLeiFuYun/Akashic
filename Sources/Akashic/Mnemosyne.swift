//
//  Mnemosyne.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import UIKit

public protocol CostCalculable {
    var cost: Int { get }
}

extension UIImage: CostCalculable {
    public var cost: Int {
        guard let cgImage else { return 0 }
        
        let bytesPerFrame = cgImage.bytesPerRow * cgImage.height
        let frameCount = images == nil ? 1 : images!.count
        return bytesPerFrame * frameCount
    }
}

fileprivate final class CacheNode<Key: Hashable, Value: CostCalculable> {
    let key: Key
    var value: Value
    var clock: Int
    var isActive = false
    var expirationDate: CFTimeInterval = 0
    var isExpired: Bool { CACurrentMediaTime() > expirationDate }
    
    unowned(unsafe) var prev: CacheNode<Key, Value>?
    unowned(unsafe) var next: CacheNode<Key, Value>?
    
    init(key: Key, value: Value, clock: Int) {
        self.key = key
        self.value = value
        self.clock = clock
    }
}

public final class Mnemosyne<Key: Hashable, Value: CostCalculable>: @unchecked Sendable {
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
        // 程序进入后台时是否要保留缓存，默认 false，即不保留。
        var keepWhenEnteringBackground: Bool = false
        
        public init(
            costLimit: Int = Int(ProcessInfo.processInfo.physicalMemory) / 4,
            entryCostLimit: Double = 0.1,
            countLimit: Int = .max,
            ttl: TimeInterval = 60,
            cleanupInterval: TimeInterval = 60
        ) {
            self.costLimit = costLimit
            self.entryCostLimit = entryCostLimit
            self.countLimit = countLimit
            self.ttl = ttl
            self.cleanupInterval = cleanupInterval
        }
    }
    
    private let config: Config
    private var cacheMap = [Key: CacheNode<Key, Value>]()
    private var bufferQueueKeys = FIFOQueue<Key>()
    private var lruListKeys: Set<Key> = []
    private unowned(unsafe) var head: CacheNode<Key, Value>?
    private unowned(unsafe) var tail: CacheNode<Key, Value>?
    private var totalCost = 0
    private var totalCount = 0
    private var clock = 0
    private let lock: os_unfair_lock_t
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer!
    
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
        
        let notifications: [(Notification.Name, Selector)] = [
            (UIApplication.willTerminateNotification, #selector(clearCacheIfNeeded)),
            (UIApplication.didEnterBackgroundNotification, #selector(clearCacheIfNeeded))
        ]
        notifications.forEach {
            NotificationCenter.default.addObserver(self, selector: $0.1, name: $0.0, object: nil)
        }
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        
        timer.invalidate()
        memoryPressureSource?.cancel()
    }
    
    public func isCached(forKey key: Key) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        return cacheMap[key] != nil
    }
    
    public func setValue(_ value: Value, forKey key: Key) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        guard Double(value.cost) < config.entryCostLimit * Double(config.costLimit) else { return }
        if let existingNode = cacheMap[key] {
            if lruListKeys.contains(existingNode.key) {
                deleteNode(existingNode)
                totalCost -= existingNode.value.cost
                existingNode.value = value
                existingNode.expirationDate = CACurrentMediaTime() + config.ttl
                totalCost += value.cost
                trimIfNeeded()
                appendNode(existingNode)
            } else {
                existingNode.isActive = true
                totalCost -= existingNode.value.cost
                existingNode.value = value
                totalCost += value.cost
                trimIfNeeded()
            }
        } else {
            let node = CacheNode(key: key, value: value, clock: clock)
            cacheMap[key] = node
            totalCost += value.cost
            totalCount += 1
            trimIfNeeded()
            bufferQueueKeys.enqueue(key)
        }
    }
    
    public func value(forKey key: Key) -> Value? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        guard let node = cacheMap[key] else { return nil }
        if lruListKeys.contains(node.key) {
            deleteNode(node)
            node.expirationDate = CACurrentMediaTime() + config.ttl
            appendNode(node)
        }
        
        node.isActive = true
        return node.value
    }
    
    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard let node = cacheMap[key] else { return nil }
        return _remove(node)
    }
    
    public func removeExpiredValues() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        while let key = bufferQueueKeys.peek {
            guard let node = cacheMap[key] else {
                bufferQueueKeys.dequeue()
                continue
            }
            
            if node.clock < clock {
                bufferQueueKeys.dequeue()
                handleDequeuedNode(forKey: key)
            } else {
                break
            }
        }
        
        while let node = head, node.isExpired {
            _remove(node)
        }
    }
    
    public func removeAllValues() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        totalCost = 0
        totalCount = 0
        head = nil
        tail = nil
        lruListKeys.removeAll()
        bufferQueueKeys.removeAll()
        cacheMap.removeAll()
    }
    
    @objc private func clearCacheIfNeeded() {
        guard !config.keepWhenEnteringBackground else { return }
        removeAllValues()
    }
    
    private func trimIfNeeded() {
        while totalCost > config.costLimit || totalCount > config.countLimit, let key = bufferQueueKeys.dequeue() {
            handleDequeuedNode(forKey: key)
        }
        
        while totalCost > config.costLimit || totalCount > config.countLimit, let node = head {
            _remove(node)
        }
    }
    
    @discardableResult
    private func _remove(_ node: CacheNode<Key, Value>) -> Value? {
        totalCost -= node.value.cost
        totalCount -= 1
        deleteNode(node)
        lruListKeys.remove(node.key)
        cacheMap[node.key] = nil
        
        return node.value
    }
    
    private func appendNode(_ node: CacheNode<Key, Value>) {
        if head == nil { head = node }
        node.prev = tail
        tail?.next = node
        tail = node
    }
    
    private func deleteNode(_ node: CacheNode<Key, Value>) {
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.next?.prev = node.prev
        node.prev?.next = node.next
        node.next = nil
    }
    
    private func handleDequeuedNode(forKey key: Key) {
        guard let node = cacheMap[key] else { return }
        
        if node.isActive {
            node.expirationDate = CACurrentMediaTime() + config.ttl
            appendNode(node)
            lruListKeys.insert(node.key)
        } else {
            totalCost -= node.value.cost
            totalCount -= 1
            cacheMap[node.key] = nil
        }
    }
}
