//
//  ElysiumKey.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

public protocol ElysiumKey: Hashable {
    /// 若设置，则文件存储在此子目录下。如果指定的子目录不存在，则创建此目录。
    var subdirectoryPath: String? { get }
    
    /// 资源的唯一标识符，通常用作未提供自定义生成器时的默认文件名。
    /// 此标识符应保证唯一性，以确保资源能被正确识别并从存储中检索。
    var identifier: String { get }
    
    /// 可选的后缀，可添加到文件或文件夹名称中，以提供额外的上下文或版本信息。
    /// 此后缀可用于区分相似资源或同一资源的不同版本。
    var identifierSuffix: String? { get }
    
    /// 开启后，会使用 identifier 的最后路径分量加上 identifierSuffix（如果设置）作为文件名，
    /// 扩展名首先尝试 fileExtension，若未设置，尝试从 resourceIdentifier 中提取。
    /// 默认 false。
    var useLastPathComponentAsFileName: Bool { get }
    
    /// 表示文件名是否应进行哈希处理的布尔值，默认值为 true。
    var usesHashedFileName: Bool { get }
    
    var extensionName: String? { get }
    
    var filename: String { get }
}

extension ElysiumKey {
    public var subdirectoryPath: String? { nil }
    
    public var identifierSuffix: String? { nil }
    
    public var useLastPathComponentAsFileName: Bool { false }
    
    public var usesHashedFileName: Bool { true }
    
    public var extensionName: String? { nil }
    
    public var filename: String {
        if useLastPathComponentAsFileName {
            var (filename, extName) = getLastPathComponentWithExtension(from: identifier)
            filename += identifierSuffix ?? ""
            extName = extensionName ?? extName
            if !extName.isEmpty {
                filename += ".\(extName)"
            }
            return filename
        }
        
        var filename = identifier
        if let identifierSuffix = identifierSuffix {
            filename += identifierSuffix
        }
        
        if usesHashedFileName {
            filename = filename.hashedKey
        }
        
        if let extensionName {
            filename += ".\(extensionName)"
        }
        
        return filename
    }
    
    private func getLastPathComponentWithExtension(from path: String) -> (lastComponent: String, extensionComponent: String) {
        // Attempt to parse the string as a URL
        if let url = URL(string: path) {
            let lastPathComponent = url.deletingPathExtension().lastPathComponent
            let extensionComponent = url.pathExtension
            return (lastPathComponent, extensionComponent)
        }

        // Fallback to manual parsing if URL parsing fails
        // First, strip away any query parameters
        let pathWithoutQuery = path.components(separatedBy: "?").first ?? ""
        // Attempt to decode percent encoding
        let decodedPath = pathWithoutQuery.removingPercentEncoding ?? pathWithoutQuery
        var lastComponent = decodedPath.components(separatedBy: "/").last ?? ""
        var extensionComponent = ""
        
        // Regex to find extension that are up to 5 letters long and consist of alphabet characters only
        let regex = try! NSRegularExpression(pattern: "\\.([a-zA-Z]{1,5})$", options: [])
        if let match = regex.firstMatch(in: lastComponent, options: [], range: NSRange(location: 0, length: lastComponent.utf16.count)) {
            let range = Range(match.range(at: 1), in: lastComponent)!
            extensionComponent = String(lastComponent[range])
            lastComponent.removeSubrange(lastComponent.index(lastComponent.endIndex, offsetBy: -extensionComponent.count - 1)...)
        }
        
        return (lastComponent, extensionComponent)
    }
}

public struct DefaultElysiumKey: ElysiumKey {
    public var subdirectoryPath: String?
    
    public var identifier: String
    
    public var identifierSuffix: String?
    
    public var useLastPathComponentAsFileName: Bool = false
    
    public var usesHashedFileName: Bool = true
    
    public var extensionName: String?
}

public struct CustomFileNameElysiumKey: ElysiumKey {
    public var subdirectoryPath: String?
    public var identifier: String
    public var filename: String
}
