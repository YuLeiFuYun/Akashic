//
//  ImageFormat.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

extension ElysiumImageSerializer {
    public enum ImageFormat {
        case unknown
        
        case jpeg
        
        case gif
        
        case png(isDynamic: Bool)
        
        case webp(isDynamic: Bool)
        
        case heic(isDynamic: Bool)
        
        case avif(isDynamic: Bool)
        
        case jxl
        
        static let ftypSignature: [UInt8] = [0x66, 0x74, 0x79, 0x70]
        
        enum HeaderData {
            static let PNG: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            static let JPEG: [UInt8] = [0xFF, 0xD8, 0xFF]
            static let GIF: [UInt8] = [0x47, 0x49, 0x46]
            static let WEBP: [UInt8] = [0x52, 0x49, 0x46, 0x46]
            static let JXL: [UInt8] = [0xFF, 0x0A]
        }
        
        enum FormatSignature {
            static let WEBP: [UInt8] = [0x57, 0x45, 0x42, 0x50]
            static let HEIC: [[UInt8]] = [
                [0x68, 0x65, 0x69, 0x63],  // 'heic'
                [0x68, 0x65, 0x69, 0x78],  // 'heix'
                [0x6D, 0x69, 0x66, 0x31],  // 'mif1'
                [0x6D, 0x73, 0x66, 0x31]   // 'msf1'
            ]
            static let AVIF: [[UInt8]] = [
                [0x61, 0x76, 0x69, 0x66],  // 'avif'
                [0x61, 0x76, 0x69, 0x73]   // 'avis'
            ]
        }
    }
}

extension AkashicWrapper where Base == Data {
    public var imageFormat: ElysiumImageSerializer.ImageFormat {
        guard base.count > 12 else { return .unknown }
        
        if base.starts(with: ElysiumImageSerializer.ImageFormat.HeaderData.PNG) {
            var index = 8 // PNG文件头占用前8字节
            while index < base.count - 12 {
                let length = base.subdata(in: index..<(index + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                index += 4
                
                let type = base.subdata(in: index..<(index + 4))
                if let typeString = String(data: type, encoding: .ascii), typeString == "acTL" {
                    return .png(isDynamic: true)
                }

                index += Int(length) + 8 // 跳过当前块的长度，4字节类型，4字节CRC
            }
            return .png(isDynamic: false)
        } else if base.starts(with: ElysiumImageSerializer.ImageFormat.HeaderData.JPEG) {
            return .jpeg
        } else if base.starts(with: ElysiumImageSerializer.ImageFormat.HeaderData.GIF) {
            return .gif
        } else if base.starts(with: ElysiumImageSerializer.ImageFormat.HeaderData.WEBP) {
            if base[8..<12] == Data(ElysiumImageSerializer.ImageFormat.FormatSignature.WEBP) {
                // 动画 WebP 的检查需要寻找 'ANMF' 块
                var index = 12  // 从 'WEBP' 标记之后开始检查
                while index < base.count - 8 {
                    let chunkHeader = base.subdata(in: index..<index+4)
                    if let chunkType = String(data: chunkHeader, encoding: .ascii), chunkType == "ANMF" {
                        return .webp(isDynamic: true)
                    }
                    index += 4
                    if index < base.count - 4 {
                        let chunkSizeData = base.subdata(in: index..<index+4)
                        let chunkSize = chunkSizeData.withUnsafeBytes({ $0.load(as: UInt32.self) })
                        index += Int(chunkSize) + 4 // 跳过当前块的大小加上块大小字段的大小
                    }
                }
                return .webp(isDynamic: false)
            }
        } else if base[4..<8] == Data(ElysiumImageSerializer.ImageFormat.ftypSignature) {
            var offset = 0
            let dataLength = base.count

            var hasMoov = false
            var hasMeta = false
            var brandString = ""

            while offset + 8 < dataLength {
                let size: UInt32 = base.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                guard size > 8, offset + Int(size) <= dataLength else { break }
                
                let type = base.subdata(in: (offset + 4)..<offset + 8)
                let typeString = String(decoding: type, as: UTF8.self)
                
                switch typeString {
                case "ftyp":
                    brandString = String(decoding: base.subdata(in: (offset + 8)..<offset + 12), as: UTF8.self)
                case "moov":
                    hasMoov = true
                case "meta":
                    hasMeta = true
                default:
                    break
                }
                
                offset += Int(size)
            }

            if hasMoov && hasMeta {
                return brandString == "avis" ? .avif(isDynamic: true) : .heic(isDynamic: true)
            } else if hasMeta {
                return brandString == "avif" ? .avif(isDynamic: false) : .heic(isDynamic: false)
            }
        } else if base.starts(with: ElysiumImageSerializer.ImageFormat.HeaderData.JXL) {
            return .jxl
        }
        
        return .unknown
    }
}
