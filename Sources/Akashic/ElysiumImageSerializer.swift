//
//  ElysiumImageSerializer.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import UIKit

public protocol ElysiumSerializer {
    associatedtype Entry
    
    func serialize(_ entry: Entry) throws -> Data?
    func deserialize(_ data: Data) throws -> Entry?
}

public struct ElysiumImageSerializer: ElysiumSerializer {
    private let format: ImageFormat
    private let compressionQuality: CGFloat
    
    public init(format: ImageFormat = .png(isDynamic: false), compressionQuality: CGFloat = 1) {
        self.format = format
        self.compressionQuality = compressionQuality
    }
    
    public func serialize(_ entry: UIImage) throws -> Data? {
        fatalError()
    }
    
    public func deserialize(_ data: Data) throws -> UIImage? {
        fatalError()
    }
}
