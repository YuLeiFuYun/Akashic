//
//  Elysium.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation
import UIKit.UIApplication

public protocol ElysiumEntryFormat {
    var expandedName: String? { get }
}

public extension ElysiumEntryFormat {
    var expandedName: String? { nil }
}

public protocol ElysiumEntry: Sendable {
    associatedtype Format: ElysiumEntryFormat
    
    var format: Format? { get }
    func toData() throws -> Data
    static func fromData(_ data: Data) throws -> Self
}

public extension ElysiumEntry {
    var format: Format? { nil }
}

extension String: ElysiumEntryFormat { }

extension Data: ElysiumEntry {
    public var format: String? { "data" }
    
    public func toData() throws -> Data {
        self
    }
    
    public static func fromData(_ data: Data) throws -> Data {
        data
    }
}

extension String: ElysiumKey {
    public var identifier: String { self }
}

public final class Elysium<Key: ElysiumKey, Entry: ElysiumEntry>: CustomStringConvertible, @unchecked Sendable {
    public struct Config {
        /// 磁盘存储上的文件大小限制，单位为字节。默认 500 MB。
        public var sizeLimit: UInt64
        
        /// 在执行缓存的清理过程中，将移除一些条目，直到剩余的条目总大小不超过 sizeLimit * trimRatio，总数量也不超过 countLimit * trimRatio。
        /// 默认的 trimRatio 是 0.7，意味着将保留大约 70% 的条目。
        public var trimRatio: Double
        
        /// 缓存的过期时间（以天为单位），默认一周后过期。
        public var expirationPeriodInDays: Days
        
        /// 缓存的基础路径。
        public var cachesBaseURL: URL
        
        /// 缓存文件夹名，用于在基础路径下创建特定的缓存目录。
        public var cachesDirectoryName: String
        
        /// 当检索到未清理的过期文件时是否使用，默认使用。
        public var useExpiredEntryIfAvailable: Bool
        
        /// 文件管理器，默认使用 FileManager.default。
        public var fileManager: FileManager
        
        var cachesDirectoryURL: URL {
            if #available(iOS 16, *) {
                cachesBaseURL.appending(path: cachesDirectoryName, directoryHint: .isDirectory)
            } else {
                cachesBaseURL.appendingPathComponent(cachesDirectoryName, isDirectory: true)
            }
        }
        
        public init(
            sizeLimit: UInt64 = 500 * 1024 * 1024,
            trimRatio: Double = 0.7,
            expirationPeriodInDays: Days = 7,
            cachesBaseURL: URL? = nil,
            cachesDirectoryName: String = "com.Elysium.Cache",
            useExpiredEntryIfAvailable: Bool = true,
            fileManager: FileManager = .default
        ) {
            self.sizeLimit = sizeLimit
            self.trimRatio = trimRatio
            self.expirationPeriodInDays = expirationPeriodInDays
            self.cachesBaseURL = cachesBaseURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.cachesDirectoryName = cachesDirectoryName
            self.useExpiredEntryIfAvailable = useExpiredEntryIfAvailable
            self.fileManager = fileManager
        }
    }
    
    public typealias Days = Double
    
    public var config: Config
    
    private var maybeCached: Set<String>?
    
    private let maybeCachedQueue = DispatchQueue(label: "com.Elysium.maybeCachedQueue")
    
    private let ioQueue = DispatchQueue(label: "com.Elysium.ioQueue", attributes: .concurrent)
    
    public var description: String {
        do {
            let (description, totalSize) = try directoryTreeString(at: config.cachesDirectoryURL)
            let sizeDesc = ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
            return config.cachesDirectoryName + "/ (total size: " + sizeDesc + ")\n" + description
        } catch {
            return "Permission denied or error reading directory"
        }
    }
    
    public init(config: Config = .init()) throws {
        self.config = config
        try createDirectoryIfNeeded(atPath: urlToPath(url: config.cachesDirectoryURL))
        prepareMaybeCached()
        registerForNotifications()
    }
    
    // MARK: - sync method
    
    public func isCached(froKey key: Key) -> Bool {
        let fileURL = try! cacheFileURL(forKey: key)
        let fileMaybeCached = maybeCachedQueue.sync {
            maybeCached?.contains(relativePath(for: fileURL)) ?? true
        }
        
        return fileMaybeCached && config.fileManager.fileExists(atPath: urlToPath(url: fileURL))
    }
    
    public func syncStore(_ entry: Entry, forKey key: Key) throws {
        try syncStore(entry, forKey: key, expirationPeriodInDays: config.expirationPeriodInDays)
    }
    
    public func syncStore(_ entry: Entry, forKey key: Key, expirationPeriodInDays: Days) throws {
        let data: Data
        do {
            data = try entry.toData()
        } catch {
            throw AkashicError.cannotConvertToData(object: entry, error: error)
        }
        
        let fileURL = try cacheFileURL(forKey: key, createIntermediateDirectoriesIfNeeded: true)
        do {
            try data.write(to: fileURL)
        } catch {
            throw AkashicError.writeFailed(url: fileURL, error: error)
        }
        
        let attributes: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(expirationPeriodInDays * 24 * 60 * 60)]
        do {
            try config.fileManager.setAttributes(attributes, ofItemAtPath: urlToPath(url: fileURL))
        } catch {
            throw AkashicError.setExpirationDateFailed(url: fileURL, error: error)
        }
        
        maybeCachedQueue.async {
            self.maybeCached?.insert(self.relativePath(for: fileURL))
        }
    }
    
    public func syncRetrieveEntry(forKey key: Key) throws -> Entry? {
        try syncRetrieveEntry(forKey: key, extendingExpiration: config.expirationPeriodInDays)
    }
    
    public func syncRetrieveEntry(forKey key: Key, extendingExpiration: Days) throws -> Entry? {
        let fileURL = try cacheFileURL(forKey: key)
        let filePath = urlToPath(url: fileURL)
        let fileMaybeCached = maybeCachedQueue.sync {
            maybeCached?.contains(relativePath(for: fileURL)) ?? true
        }
        
        guard fileMaybeCached, config.fileManager.fileExists(atPath: filePath) else { return nil }
        return try _retrieveEntry(forURL: fileURL, extendingExpiration: extendingExpiration)
    }
    
    public func syncRemoveEntry(forKey key: Key) throws {
        let fileURL = try! cacheFileURL(forKey: key)
        try removeEntry(forURL: fileURL)
    }
    
    public func syncRemoveExpiredEntries() throws {
        guard
            let enumerator = config.fileManager.enumerator(
                at: config.cachesDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return }
        
        for case let itemURL as URL in enumerator {
            let isDirectory = (try itemURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            if !isDirectory {
                let attributes = try config.fileManager.attributesOfItem(atPath: urlToPath(url: itemURL))
                if let expirationDate = attributes[.modificationDate] as? Date, expirationDate < Date() {
                    try removeEntry(forURL: itemURL)
                }
            }
        }
    }
    
    public func syncRemoveAll() throws {
        maybeCachedQueue.async {
            self.maybeCached?.removeAll()
        }
        
        try config.fileManager.removeItem(at: config.cachesDirectoryURL)
        try createDirectoryIfNeeded(atPath: urlToPath(url: config.cachesDirectoryURL))
    }
    
    // MARK: - async method
    
    public func store(_ entry: Entry, forKey key: Key, completionHandler: ((AkashicError?) -> Void)? = nil) {
        store(entry, forKey: key, expirationPeriodInDays: config.expirationPeriodInDays, completionHandler: completionHandler)
    }
    
    public func store(_ entry: Entry, forKey key: Key, expirationPeriodInDays: Days, completionHandler: ((AkashicError?) -> Void)? = nil) {
        ioQueue.async {
            do {
                try self.syncStore(entry, forKey: key, expirationPeriodInDays: expirationPeriodInDays)
                completionHandler?(nil)
            } catch let error as AkashicError {
                completionHandler?(error)
            } catch {
                completionHandler?(AkashicError.unknow(error: error))
            }
        }
    }
    
    public func retrieveEntry(forKey key: Key, completionHandler: @escaping (Result<Entry?, AkashicError>) -> Void) {
        retrieveEntry(forKey: key, extendingExpiration: config.expirationPeriodInDays, completionHandler: completionHandler)
    }
    
    public func retrieveEntry(forKey key: Key, extendingExpiration: Days, completionHandler: @escaping (Result<Entry?, AkashicError>) -> Void) {
        ioQueue.async {
            do {
                let entry = try self.syncRetrieveEntry(forKey: key, extendingExpiration: extendingExpiration)
                completionHandler(.success(entry))
            } catch let error as AkashicError {
                completionHandler(.failure(error))
            } catch {
                completionHandler(.failure(.unknow(error: error)))
            }
        }
    }
    
    public func retrieveDirectory(relativePath: String, skipsSubdirectory: Bool = true, completionHandler: @escaping (Result<[Entry], AkashicError>) -> Void) {
        ioQueue.async {
            let directoryURL = if #available(iOS 16, *) {
                self.config.cachesDirectoryURL.appending(path: relativePath, directoryHint: .isDirectory)
            } else {
                self.config.cachesDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
            }
            guard
                let enumerator = self.config.fileManager.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: skipsSubdirectory ? [.skipsSubdirectoryDescendants] : []
                )
            else { return }
            
            var entries: [Entry] = []
            let entriesQueue = DispatchQueue(label: "com.Elysium.entriesQueue")
            let semaphore = DispatchSemaphore(value: 6)
            let group = DispatchGroup()
            for case let itemURL as URL in enumerator {
                group.enter()
                semaphore.wait()
                
                self.ioQueue.async {
                    let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if !isDirectory {
                        do {
                            if let entry = try self._retrieveEntry(forURL: itemURL, extendingExpiration: self.config.expirationPeriodInDays) {
                                entriesQueue.sync { entries.append(entry) }
                            }
                        } catch let error as AkashicError {
                            completionHandler(.failure(error))
                        } catch {
                            completionHandler(.failure(.unknow(error: error)))
                        }
                    }
                    
                    group.leave()
                    semaphore.signal()
                }
            }
            
            group.notify(queue: .main) {
                completionHandler(.success(entries))
            }
        }
    }
    
    public func removeEntry(forKey key: Key, completionHandler: ((AkashicError?) -> Void)? = nil) {
        ioQueue.async {
            do {
                try self.syncRemoveEntry(forKey: key)
                completionHandler?(nil)
            } catch let error as AkashicError {
                completionHandler?(error)
            } catch {
                completionHandler?(AkashicError.unknow(error: error))
            }
        }
    }
    
    public func removeExpiredEntries(completionHandler: ((AkashicError?) -> Void)? = nil) throws {
        ioQueue.async {
            do {
                try self.syncRemoveExpiredEntries()
                completionHandler?(nil)
            } catch let error as AkashicError {
                completionHandler?(error)
            } catch {
                completionHandler?(AkashicError.unknow(error: error))
            }
        }
    }
    
    public func removeAll(completionHandler: ((AkashicError?) -> Void)? = nil) throws {
        ioQueue.async {
            do {
                try self.syncRemoveAll()
                completionHandler?(nil)
            } catch let error as AkashicError {
                completionHandler?(error)
            } catch {
                completionHandler?(AkashicError.unknow(error: error))
            }
        }
    }
    
    // MARK: - swift concurrency
    
    @available(iOS 13, *)
    public func store(_ entry: Entry, forKey key: Key) async throws {
        try await store(entry, forKey: key, expirationPeriodInDays: config.expirationPeriodInDays)
    }
    
    @available(iOS 13, *)
    public func store(_ entry: Entry, forKey key: Key, expirationPeriodInDays: Days) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try syncStore(entry, forKey: key, expirationPeriodInDays: expirationPeriodInDays)
                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    @available(iOS 13, *)
    public func retrieveEntry(forKey key: Key) async throws -> Entry? {
        try await retrieveEntry(forKey: key, extendingExpiration: config.expirationPeriodInDays)
    }
    
    @available(iOS 13, *)
    public func retrieveEntry(forKey key: Key, extendingExpiration: Days) async throws -> Entry? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Entry?, Error>) in
            do {
                let entry = try syncRetrieveEntry(forKey: key, extendingExpiration: extendingExpiration)
                continuation.resume(returning: entry)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    @available(iOS 13, *)
    public func retrieveDirectory(relativePath: String, skipsSubdirectory: Bool = true) async throws -> [Entry] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Entry], Error>) in
            retrieveDirectory(relativePath: relativePath, skipsSubdirectory: skipsSubdirectory) { result in
                switch result {
                case .success(let entries):
                    continuation.resume(returning: entries)
                case .failure(let failure):
                    continuation.resume(throwing: failure)
                }
            }
        }
    }
    
    @available(iOS 13, *)
    public func removeEntry(forKey key: Key) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), Error>) in
            do {
                try syncRemoveEntry(forKey: key)
                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    @available(iOS 13, *)
    public func removeExpiredEntries() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), Error>) in
            do {
                try syncRemoveExpiredEntries()
                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    @available(iOS 13, *)
    public func removeAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(), Error>) in
            do {
                try syncRemoveAll()
                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - utility method
    
    private func trim(toCost limit: Int) {
        let prefetchedProperties: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard
            let enumerator = config.fileManager.enumerator(
                at: config.cachesDirectoryURL,
                includingPropertiesForKeys: Array(prefetchedProperties)
            )
        else { return }
        
        var totalSize = 0
        var records: [(Date, Int, URL)] = []
        for case let itemURL as URL in enumerator {
            guard
                let resourceValues = try? itemURL.resourceValues(forKeys: prefetchedProperties),
                let isDirectory = resourceValues.isDirectory,
                !isDirectory,
                let fileSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize
            else { continue }
            
            if
                let attributes = try? self.config.fileManager.attributesOfItem(atPath: urlToPath(url: itemURL)),
                let expirationDate = attributes[.modificationDate] as? Date
            {
                totalSize += fileSize
                records.append((expirationDate, fileSize, itemURL))
            } else {
                try? removeEntry(forURL: itemURL)
            }
        }
        
        records.sort { $0.0 > $1.0 }
        while totalSize > limit {
            guard let record = records.popLast() else { break }
            try? removeEntry(forURL: record.2)
            totalSize -= record.1
        }
    }
    
    private func _retrieveEntry(forURL fileURL: URL, extendingExpiration: Days) throws -> Entry? {
        let filePath = urlToPath(url: fileURL)
        if
            let attributes = try? config.fileManager.attributesOfItem(atPath: filePath),
            let expirationDate = attributes[.modificationDate] as? Date
        {
            if !config.useExpiredEntryIfAvailable, expirationDate < Date() {
                try removeEntry(forURL: fileURL)
                return nil
            }
            
            let newDate = Date().addingTimeInterval(extendingExpiration * 24 * 60 * 60)
            if newDate > expirationDate {
                do {
                    try config.fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: filePath)
                } catch {
                    throw AkashicError.setExpirationDateFailed(url: fileURL, error: error)
                }
            }
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                let object = try Entry.fromData(data)
                return object
            } catch {
                throw AkashicError.objectConversionFailed(error: error)
            }
        } catch {
            throw AkashicError.dataReadingFailed(url: fileURL, error: error)
        }
    }
    
    @objc private func backgroundCleanExpiredEntries() {
        func endBackgroundTask(_ task: inout UIBackgroundTaskIdentifier) {
            UIApplication.shared.endBackgroundTask(task)
            task = UIBackgroundTaskIdentifier.invalid
        }
        
        var backgroundTask: UIBackgroundTaskIdentifier!
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Elysium:backgroundCleanExpiredEntries") {
            endBackgroundTask(&backgroundTask!)
        }
        
        cleanExpiredEntriesAndTrimToLimitCostIfNeeded()
        endBackgroundTask(&backgroundTask!)
    }
    
    @objc private func cleanExpiredEntriesAndTrimToLimitCostIfNeeded() {
        try? removeExpiredEntries()
        trim(toCost: Int(Double(config.sizeLimit) * config.trimRatio))
        removeEmptyDirectories(at: config.cachesDirectoryURL)
    }
    
    private func prepareMaybeCached() {
        maybeCachedQueue.async {
            do {
                guard
                    let enumerator = self.config.fileManager.enumerator(at: self.config.cachesDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey])
                else { return }
                
                self.maybeCached = []
                for case let itemURL as URL in enumerator {
                    let isDirectory = (try itemURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
                    if !isDirectory {
                        self.maybeCached?.insert(self.relativePath(for: itemURL))
                    }
                }
            } catch {
                self.maybeCached = nil
            }
        }
    }
    
    private func registerForNotifications() {
        let notifications: [(Notification.Name, Selector)] = [
            (UIApplication.willTerminateNotification, #selector(cleanExpiredEntriesAndTrimToLimitCostIfNeeded)),
            (UIApplication.didEnterBackgroundNotification, #selector(backgroundCleanExpiredEntries))
        ]
        notifications.forEach {
            NotificationCenter.default.addObserver(self, selector: $0.1, name: $0.0, object: nil)
        }
    }
    
    private func removeEntry(forURL url: URL) throws {
        do {
            try config.fileManager.removeItem(at: url)
        } catch {
            throw AkashicError.removeEntryFailed(url: url, error: error)
        }
        
        maybeCachedQueue.async {
            self.maybeCached?.remove(self.relativePath(for: url))
        }
    }
    
    /// 清除指定目录及其子目录中的所有空目录
    private func removeEmptyDirectories(at path: URL) {
        // 递归检查并删除空目录
        if let directoryContents = try? config.fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for fileURL in directoryContents {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), resourceValues.isDirectory == true {
                    // 递归检查子目录
                    removeEmptyDirectories(at: fileURL)
                }
            }
            
            // 再次检查当前目录是否为空，因为子目录可能已被删除
            if
                let newDirectoryContents = try? config.fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
                newDirectoryContents.isEmpty
            {
                // 尝试删除空目录
                try? config.fileManager.removeItem(at: path)
            }
        }
    }
    
    private func urlToPath(url: URL) -> String {
        if #available(iOS 16, *) { url.path(percentEncoded: false) } else { url.path }
    }
    
    private func createDirectoryIfNeeded(atPath path: String) throws {
        guard !config.fileManager.fileExists(atPath: path) else { return }
        do {
            try config.fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw AkashicError.directoryCreationFailed(url: config.cachesDirectoryURL, error: error)
        }
    }
    
    private func cacheFileURL(forKey key: Key, createIntermediateDirectoriesIfNeeded: Bool = false) throws -> URL {
        var fileURL = config.cachesDirectoryURL
        if let subdirectoryPath = key.subdirectoryPath {
            fileURL = if #available(iOS 16, *) {
                fileURL.appending(path: subdirectoryPath, directoryHint: .isDirectory)
            } else {
                fileURL.appendingPathComponent(subdirectoryPath, isDirectory: true)
            }
        }
        
        if createIntermediateDirectoriesIfNeeded {
            try createDirectoryIfNeeded(atPath: urlToPath(url: fileURL))
        }
        
        let filename = key.filename
        fileURL = if #available(iOS 16, *) {
            fileURL.appending(path: filename)
        } else {
            fileURL.appendingPathComponent(filename)
        }
        return fileURL
    }
    
    private func relativePath(for fileURL: URL) -> String {
        let relativePath = urlToPath(url: fileURL).replacingOccurrences(of: urlToPath(url: config.cachesDirectoryURL), with: "")
        return relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    private func directoryTreeString(at url: URL, indentLevel: Int = 0) throws -> (String, Int) {
        var prefetchedProperties: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        if #available(iOS 14, *) {
            prefetchedProperties.insert(.contentTypeKey)
        }
        let contents = try config.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(prefetchedProperties)
        )

        var filesOutput = "", directoriesOutput = "", totalSize = 0
        for (index, itemURL) in contents.enumerated() {
            let resourceValues = try itemURL.resourceValues(forKeys: prefetchedProperties)
            let isDirectory = resourceValues.isDirectory ?? false

            let prefix = String(repeating: "    ", count: indentLevel) + ((index == contents.count - 1) || isDirectory ? "└── " : "├── ")
            let itemOutput = prefix + itemURL.lastPathComponent
            
            if isDirectory {
                let result = try directoryTreeString(at: itemURL, indentLevel: indentLevel + 1)
                totalSize += result.1
                directoriesOutput += itemOutput + "/ (total size: " + ByteCountFormatter.string(fromByteCount: Int64(result.1), countStyle: .file) + ")\n" + result.0
            } else {
                var fileOutput = itemOutput + " ("
                if let fileSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
                    totalSize += fileSize
                    fileOutput += "size: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))"
                }

                if #available(iOS 14, *), let contentType = resourceValues.contentType {
                    fileOutput += ", type: \(contentType)"
                }

                let attributes = try config.fileManager.attributesOfItem(atPath: urlToPath(url: itemURL))
                if let expirationDate = attributes[.modificationDate] as? Date {
                    fileOutput += ", expiration date: \(expirationDate)"
                }
                fileOutput += ")\n"
                filesOutput += fileOutput
            }
        }
        
        if !directoriesOutput.isEmpty {
            if let index = filesOutput.lastIndex(of: "└") {
                filesOutput.replaceSubrange(index...index, with: "├")
            }
        }

        return (filesOutput + directoriesOutput, totalSize)
    }
}
