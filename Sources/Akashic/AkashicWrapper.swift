//
//  AkashicWrapper.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import UIKit

// 定义一个泛型结构体 AkashicWrapper，它将作为一个通用包装器，能够包装任何类型。
public struct AkashicWrapper<Base> {
    let base: Base // 保存被包装的原始值
    init(_ base: Base) {
        self.base = base // 初始化时将原始值保存到属性中
    }
}

// 定义一个空的协议 AkashicCompatible，用于标记类类型（引用类型）的对象可以使用 AkashicWrapper 进行扩展。
public protocol AkashicCompatible: AnyObject { }

// 定义一个空的协议 AkashicCompatibleValue，用于标记值类型的对象可以使用 AkashicWrapper 进行扩展。
public protocol AkashicCompatibleValue { }

// 为 AkashicCompatible 协议扩展一个计算属性 ak，这使得任何遵循 AkashicCompatible 的类型（即类）都能通过 .ak 访问其包装器 AkashicWrapper 实例。
extension AkashicCompatible {
    public var ak: AkashicWrapper<Self> {
        AkashicWrapper(self)
    }
    
    // 提供一个静态属性 ak，允许通过类型本身访问 AkashicWrapper，而不是类型的实例。
    public static var ak: AkashicWrapper<Self>.Type {
        AkashicWrapper<Self>.self
    }
}

// 为 AkashicCompatibleValue 协议扩展一个计算属性 ak，这使得任何遵循 AkashicCompatibleValue 的类型（即值类型）也能通过 .ak 访问其包装器 AkashicWrapper 实例。
extension AkashicCompatibleValue {
    public var ak: AkashicWrapper<Self> {
        AkashicWrapper(self)
    }
}

extension UIImage: AkashicCompatible { }

extension UIImageView: AkashicCompatible { }

extension Data: AkashicCompatibleValue { }
