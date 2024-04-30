//
//  DoublyLinkedList.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

protocol NodeProtocol: AnyObject, CustomStringConvertible {
    associatedtype Tag
    associatedtype Payload: CustomStringConvertible
    
    var tag: Tag { get }
    var payload: Payload { get set }
    var prev: Self? { get set }
    var next: Self? { get set }
}

protocol DoublyLinkedListProtocol: CustomStringConvertible {
    associatedtype Tag: Hashable
    associatedtype Payload: CustomStringConvertible
    associatedtype Node: NodeProtocol where Node.Tag == Tag, Node.Payload == Payload
    
    var head: Node? { get set }
    var tail: Node? { get set }
    
    mutating func append(_ newNode: Node)
    mutating func insert(_ newNode: Node, after nodeWithTag: Tag)
    mutating func delete(_ node: Node)
    func prepareForDealloc()
    subscript(tag: Tag) -> Node? { get }
}

extension DoublyLinkedListProtocol {
    mutating func append(_ newNode: Node) {
        if let tail {
            tail.next = newNode
            newNode.prev = tail
        } else {
            head = newNode
        }
        
        tail = newNode
    }
    
    mutating func insert(_ newNode: Node, after nodeWithTag: Tag) {
        guard head != nil else { return }
        
        var current = head
        while current != nil {
            if nodeWithTag == current?.tag {
                if current?.next != nil {
                    let newNext = current?.next
                    current?.next = newNode
                    newNext?.prev = newNode
                    newNode.prev = current
                    newNode.next = newNext
                    current = nil
                } else {
                    append(newNode)
                    current = nil
                }
            } else {
                current = current?.next
            }
        }
    }
    
    mutating func delete(_ node: Node) {
        if node.prev == nil {
            if let next = node.next {
                next.prev = nil
                head?.next = nil
                head = nil
                head = next
            } else {
                head = nil
                tail = nil
            }
        } else if node.next == nil {
            if let prev = node.prev {
                prev.next = nil
                tail?.prev = nil
                tail = nil
                tail = prev
            } else {
                head = nil
                tail = nil
            }
        } else {
            if let prev = node.prev, let next = node.next {
                prev.next = next
                next.prev = prev
            }
        }
        
        node.prev = nil
        node.next = nil
    }
    
    func prepareForDealloc() {
        var current: Node?
        if var tail {
            current = tail
            repeat {
                tail = current!
                current = current?.prev
                tail.prev = nil
                tail.next = nil
            } while current != nil
        }
    }
    
    subscript(tag: Tag) -> Node? {
        guard head != nil else { return nil }
        
        var current = head
        while current != nil {
            if tag == current?.tag {
                return current
            } else {
                current = current?.next
            }
        }
        
        return nil
    }
}

extension DoublyLinkedListProtocol {
    var description: String {
        var description = ""
        var next: Node?
        if let head {
            next = head
            repeat {
                description += "\(next!.description)\n"
                next = next?.next
            } while next != nil
        }
        
        return description
    }
}

final class DoublyLinkedList<Tag: Hashable, Payload: CustomStringConvertible, Node: NodeProtocol>: DoublyLinkedListProtocol where Node.Tag == Tag, Node.Payload == Payload {
    var head: Node?
    var tail: Node?
    
    deinit {
        prepareForDealloc()
        head = nil
        tail = nil
    }
}
