//
//  DocumentPlugin.swift
//  Runner
//
//  Created by perol on 2021/12/12.
//

import Foundation
import Flutter
import Photos
import SwiftUI

struct DocumentPlugin {
    static func bind(_ engineBridge: FlutterImplicitEngineBridge){
        let channel = FlutterMethodChannel(name: "com.perol.dev/save",
                                           binaryMessenger: engineBridge.applicationRegistrar.messenger())
        channel.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            if call.method == "save"  {
                let args = call.arguments as? [String:Any]
                let data  = args?["data"] as! FlutterStandardTypedData
                let name = args?["name"] as! String
                let createMillis = (args?["create_millis"] as? NSNumber)?.int64Value
                let sData = Data(data.data)
                save(sData, name: name, in: name.contains("sanity") ? "pxez_sanity" : "pxez", createMillis: createMillis)
                result(true)
                return
            } else if call.method == "saveFromPath" {
                let args = call.arguments as? [String:Any]
                let sourcePath = args?["source_path"] as! String
                let name = args?["name"] as! String
                let createMillis = (args?["create_millis"] as? NSNumber)?.int64Value
                saveFromPath(sourcePath, in: name.contains("sanity") ? "pxez_sanity" : "pxez", createMillis: createMillis) { success in
                    // PhotoKit 的回调在后台队列上，回复必须回到主线程。
                    DispatchQueue.main.async {
                        result(success)
                    }
                }
                return
            } else if call.method == "permissionStatus" {
                if #available(iOS 14, *) {
                    let readWriteStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    // .limited（"仅选中的照片"）同样允许添加新资源，不能当成没授权。
                    result(readWriteStatus == .authorized || readWriteStatus == .limited)
                } else {
                    result(true)
                }
                return
            } else if call.method == "requestPermission" {
                if #available(iOS 14, *) {
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                        result(status == .authorized)
                    }
                } else {
                    result(true)
                }
                return
            }
            result(false)
        })
    }
    
    static var picCacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pic", isDirectory: true)
    
    /// 完全访问和"仅选中的照片"都能往相册添加新资源，两者都不能拒。
    static func canAddToLibrary() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
    
    static func save(_ data: Data, name: String, in dir: String, createMillis: Int64? = nil) {
        if !canAddToLibrary() {
            PHPhotoLibrary.requestAuthorization({ (status) -> Void in
                if !canAddToLibrary() {
                    return
                }
                createAlbum(albumName: dir, completion: { assetCollection in
                    guard let assetCollection = assetCollection else { return }
                    self.save(data: data, name: name, assetCollection: assetCollection, createMillis: createMillis)
                })
            })
        } else {
            createAlbum(albumName: dir, completion: { assetCollection in
                guard let assetCollection = assetCollection else { return }
                self.save(data: data, name: name, assetCollection: assetCollection, createMillis: createMillis)
            })
        }
    }
    
    static func createAlbum(albumName: String, completion: @escaping (PHAssetCollection?) -> Void) {
        if let assetCollection = self.findAlbum(name: albumName) {
            completion(assetCollection)
            return
        }
        PHPhotoLibrary.shared().performChanges({
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
        }){ success, error in
            completion(success ? self.findAlbum(name: albumName) : nil)
        }
    }
    
    static func findAlbum(name: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", name)
        let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        return collection.firstObject
    }
    
    static func save(data:Data,name:String, assetCollection: PHAssetCollection, createMillis: Int64? = nil){
        if !FileManager.default.fileExists(atPath: picCacheDir.path) {
            do{
                try FileManager.default.createDirectory(at: picCacheDir, withIntermediateDirectories: true)
            } catch {
                print("create dir failed => \(picCacheDir.path)")
                return
            }
        }
        
        guard let fileName = name.split(separator: " ").last else { return }
        print("fileName = \(fileName)")
        
        let fileUrl = picCacheDir.appendingPathComponent("\(fileName)")
        
        do {
            try data.write(to: fileUrl)
            
        } catch {
            return
        }
        
        addAsset(fileUrl: fileUrl, assetCollection: assetCollection, createMillis: createMillis, deleteSourceWhenDone: true)
    }
    
    /// 直接把磁盘上的文件交给 PhotoKit，不再把整张图的字节经 Flutter 通道传过来。
    ///
    /// 批量保存时每张图只会在 PhotoKit 里打开一次，Dart 堆和原生堆都不用
    /// 各留一份，缓存命中、下载瞬间完成的情况下也不会堆内存。
    static func saveFromPath(_ path: String, in dir: String, createMillis: Int64? = nil, completion: @escaping (Bool) -> Void) {
        if !FileManager.default.fileExists(atPath: path) {
            print("saveFromPath: file not found => \(path)")
            completion(false)
            return
        }
        let fileUrl = URL(fileURLWithPath: path)
        let handleAlbum: (PHAssetCollection?) -> Void = { assetCollection in
            guard let assetCollection = assetCollection else {
                completion(false)
                return
            }
            self.addAsset(fileUrl: fileUrl, assetCollection: assetCollection, createMillis: createMillis, deleteSourceWhenDone: true) { success in
                completion(success)
            }
        }
        if !canAddToLibrary() {
            PHPhotoLibrary.requestAuthorization({ (status) -> Void in
                if !canAddToLibrary() {
                    completion(false)
                    return
                }
                createAlbum(albumName: dir, completion: handleAlbum)
            })
        } else {
            createAlbum(albumName: dir, completion: handleAlbum)
        }
    }
    
    static func addAsset(fileUrl: URL, assetCollection: PHAssetCollection, createMillis: Int64?, deleteSourceWhenDone: Bool = false, completion: ((Bool) -> Void)? = nil) {
        var created = false
        PHPhotoLibrary.shared().performChanges({
            guard let assetChangeRequest = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileUrl) else {
                return
            }
            created = true
            // 不设置 creationDate 时，PhotoKit 会从图片元数据里取 EXIF 拍摄时间，
            // 取不到就用保存时的当前时间，于是同一批下载的图日期参差不齐。
            // 这里统一写成作品在 pixiv 的发布时间（多页作品按页码 +1s 保证顺序）。
            if let createMillis = createMillis {
                assetChangeRequest.creationDate = Date(timeIntervalSince1970: TimeInterval(createMillis) / 1000.0)
            }
            let assetPlaceHolder = assetChangeRequest.placeholderForCreatedAsset
            let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection)
            let enumeration: NSArray = assetPlaceHolder == nil ? [] : [assetPlaceHolder!]
            albumChangeRequest?.addAssets(enumeration)
        }, completionHandler: { (success, error) -> Void in
            print("addAsset success \(success)")
            if deleteSourceWhenDone {
                try? FileManager.default.removeItem(at: fileUrl)
            }
            completion?(success && created)
        })
    }
}
