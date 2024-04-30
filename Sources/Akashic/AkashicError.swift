//
//  AkashicError.swift
//  Akashic
//
//  Created by 玉垒浮云 on 2024/4/30.
//

import Foundation

public enum AkashicError: Error {
    /// 无法将对象转换为数据进行存储。
    case cannotConvertToData(object: Any, error: any Error)
    
    /// 尝试在 url 处写入数据时失败
    case writeFailed(url: URL, error: any Error)
    
    /// 对象转换失败
    case objectConversionFailed(error: any Error)
    
    /// 数据读取失败
    case dataReadingFailed(url: URL, error: any Error)
    
    /// 无法创建缓存文件夹
    case directoryCreationFailed(url: URL, error: any Error)
    
    /// 设置文件过期时间失败
    case setExpirationDateFailed(url: URL, error: any Error)
    
    /// 删除文件或目录失败
    case removeEntryFailed(url: URL, error: any Error)
    
    /// 未知错误
    case unknow(error: any Error)
}
