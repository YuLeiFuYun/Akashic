//
//  FIFOQueue.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

protocol Queue: CustomStringConvertible {
    associatedtype Element
    mutating func enqueue(_ element: Element)
    mutating func dequeue() -> Element?
    mutating func removeAll()
    var isEmpty: Bool { get }
    var peek: Element? { get }
    var count: Int { get }
}

struct FIFOQueue<Element>: Queue {
    private var left: [Element] = []
    private var right: [Element] = []
    
    var isEmpty: Bool {
        left.isEmpty && right.isEmpty
    }
    
    var peek: Element? {
        left.last ?? right.first
    }
    
    var count: Int {
        left.count + right.count
    }
    
    var description: String {
        (left.reversed() + right).description
    }
    
    /// 将元素添加到队列最后
    /// - 复杂度: O(1)
    mutating func enqueue(_ newElement: Element) {
        right.append(newElement)
    }
    
    /// 从队列前端移除一个元素
    /// 当队列为空时，返回 nil
    /// - 复杂度: 平摊 O(1)
    @discardableResult mutating func dequeue() -> Element? {
        if left.isEmpty {
            left = right.reversed()
            right.removeAll()
        }
        
        return left.popLast()
    }
    
    mutating func removeAll() {
        left.removeAll()
        right.removeAll()
    }
}
