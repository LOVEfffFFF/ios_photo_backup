import UIKit
import Flutter
import Photos
import UniformTypeIdentifiers
import Network

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {

    private var photoChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 保持屏幕常亮，防止锁屏中断大批量操作
        application.isIdleTimerDisabled = true

        GeneratedPluginRegistrant.register(with: self)

        // 注册原生照片桥接插件
        if let controller = window?.rootViewController as? FlutterViewController {
            let messenger = controller.binaryMessenger
            photoChannel = FlutterMethodChannel(
                name: "com.photobackup/photo_library",
                binaryMessenger: messenger
            )
            photoChannel?.setMethodCallHandler(handlePhotoCall)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Method Channel Handler

    private func handlePhotoCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "fetchAllAssets":
            fetchAllAssets(result: result)
        case "exportPhotoAsset":
            exportPhotoAsset(call: call, result: result)
        case "exportVideoAsset":
            exportVideoAsset(call: call, result: result)
        case "exportLivePhotoVideo":
            exportLivePhotoVideo(call: call, result: result)
        case "savePhotoToLibrary":
            savePhotoToLibrary(call: call, result: result)
        case "saveVideoToLibrary":
            saveVideoToLibrary(call: call, result: result)
        case "saveLivePhotoToLibrary":
            saveLivePhotoToLibrary(call: call, result: result)
        case "requestLocalNetworkPermission":
            requestLocalNetworkPermission(result: result)
        case "checkAssetsExist":
            checkAssetsExist(call: call, result: result)
        case "getAssetDetail":
            getAssetDetail(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 获取单个资产的完整信息（用于「备份 vs 原图」对比）

    /// 返回 PHAsset 的全部可读元数据 + 资源清单（用于诊断一份照片到底由哪些文件组成）
    private func getAssetDetail(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let localIdentifier = args["localIdentifier"] as? String else {
            result(nil)
            return
        }

        PHPhotoLibrary.requestAuthorization { status in
            guard self.isPhotoLibraryAccessGranted(status) else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = fetchResult.firstObject else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            // 资源清单：一张照片可能由多份文件组成（ProRAW 的 DNG+JPEG、
            // 人像模式的深度图、HDR 的增益图、Live Photo 的配对视频…）
            var resourceList: [[String: Any]] = []
            for r in PHAssetResource.assetResources(for: asset) {
                resourceList.append([
                    "type": r.type.rawValue,
                    "uti": r.uniformTypeIdentifier,
                    "fileSize": r.fileSize,
                    "originalFilename": r.originalFilename,
                ])
            }

            let location = asset.location
            let detail: [String: Any] = [
                "localIdentifier": asset.localIdentifier,
                "creationDate": asset.creationDate?.timeIntervalSince1970 ?? 0,
                "modificationDate": asset.modificationDate?.timeIntervalSince1970 ?? 0,
                "pixelWidth": asset.pixelWidth,
                "pixelHeight": asset.pixelHeight,
                "mediaType": self.mediaTypeString(asset.mediaType),
                "duration": asset.duration,
                "isFavorite": asset.isFavorite,
                "isHidden": asset.isHidden,
                "originalFilename": asset.originalFilename,
                "subtypes": Self.subtypeNames(asset),
                "hasLocation": location != nil,
                "latitude": location?.coordinate.latitude ?? 0,
                "longitude": location?.coordinate.longitude ?? 0,
                "formatDescriptions": asset.formatDescriptions as [String],
                "resourceCount": resourceList.count,
                "resources": resourceList,
            ]
            DispatchQueue.main.async { result(detail) }
        }
    }

    /// mediaSubtypes 转成可读名称（判断是否 Live Photo / HDR / 人像 / RAW …）
    private static func subtypeNames(_ asset: PHAsset) -> [String] {
        let table: [(PHAssetMediaSubtype, String)] = [
            (.photoLive, "实况照片"),
            (.photoPanorama, "全景"),
            (.photoHDR, "HDR"),
            (.photoHDRGainMap, "HDR 增益图"),
            (.photoDepthEffect, "人像深度效果"),
            (.photoContentAware, "主体识别"),
            (.photoRAW, "RAW 原片"),
            (.videoStream, "视频流"),
            (.videoLive, "Live Photo 视频"),
            (.videoHighFps, "高帧率"),
            (.videoTimelapse, "延时摄影"),
            (.videoCinematic, "电影效果"),
        ]
        return table.compactMap { subtype, name in
            asset.mediaSubtypes.contains(subtype) ? name : nil
        }
    }

    // MARK: - 查询相册资产是否仍存在

    /// 批量查询给定的 localIdentifier 是否还在相册中。
    /// 恢复前用它跳过「照片本来就没删」的条目，避免把同一张照片重复导入。
    private func checkAssetsExist(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let ids = args["localIdentifiers"] as? [String] else {
            result([])
            return
        }

        PHPhotoLibrary.requestAuthorization { status in
            guard self.isPhotoLibraryAccessGranted(status) else {
                DispatchQueue.main.async { result([]) }
                return
            }

            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var existing: [String] = []
            fetchResult.enumerateObjects { asset, _, _ in
                existing.append(asset.localIdentifier)
            }
            DispatchQueue.main.async { result(existing) }
        }
    }

    // MARK: - 获取所有照片资源

    private func fetchAllAssets(result: @escaping FlutterResult) {
        PHPhotoLibrary.requestAuthorization { status in
            guard self.isPhotoLibraryAccessGranted(status) else {
                DispatchQueue.main.async { result([]) }
                return
            }

            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false)
            ]

            let allAssets = PHAsset.fetchAssets(with: fetchOptions)
            var assetsList: [[String: Any]] = []

            allAssets.enumerateObjects { asset, _, _ in
                let assetDict: [String: Any] = [
                    "localIdentifier": asset.localIdentifier,
                    "creationDate": asset.creationDate?.timeIntervalSince1970 ?? 0,
                    "mediaType": self.mediaTypeString(asset.mediaType),
                    "isLivePhoto": asset.mediaSubtypes.contains(.photoLive),
                    "pixelWidth": asset.pixelWidth,
                    "pixelHeight": asset.pixelHeight,
                    "duration": asset.duration,
                ]
                assetsList.append(assetDict)
            }

            DispatchQueue.main.async {
                result(assetsList)
            }
        }
    }

    // MARK: - 导出照片

    private func exportPhotoAsset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let localIdentifier = args["localIdentifier"] as? String,
              let targetPath = args["targetPath"] as? String else {
            result(false)
            return
        }

        let isNetworkAccessAllowed = args["isNetworkAccessAllowed"] as? Bool ?? true

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )

        guard let asset = fetchResult.firstObject else {
            result(false)
            return
        }

        // 直接写资源原始字节：requestImageDataAndOrientation 拿到的是解码后的数据，
        // 再写死 .jpg 会让 HEIC/RAW 变成「内容与扩展名不符」的坏文件
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto }) else {
            result(false)
            return
        }

        // 扩展名由资源真实类型推导
        let ext = Self.preferredExtension(forUTI: resource.uniformTypeIdentifier)
        let targetURL = URL(fileURLWithPath: targetPath)
            .deletingPathExtension()
            .appendingPathExtension(ext)

        let directory = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? FileManager.default.removeItem(at: targetURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed

        // 回调可能触发多次，且必须切回主线程才能安全调用 FlutterResult
        var responded = false
        PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: targetURL,
            options: options
        ) { error in
            DispatchQueue.main.async {
                guard !responded else { return }
                responded = true
                if let error = error {
                    print("PhotoBackup: Failed to write photo: \(error)")
                    result(false)
                } else {
                    result(targetURL.path)
                }
            }
        }
    }

    // MARK: - 导出视频

    private func exportVideoAsset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let localIdentifier = args["localIdentifier"] as? String,
              let targetPath = args["targetPath"] as? String else {
            result(false)
            return
        }

        let isNetworkAccessAllowed = args["isNetworkAccessAllowed"] as? Bool ?? true

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )

        guard let asset = fetchResult.firstObject else {
            result(false)
            return
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        options.deliveryMode = .highQualityFormat
        options.version = .original

        PHImageManager.default().requestExportSession(
            forVideo: asset,
            options: options,
            exportPreset: AVAssetExportPresetPassthrough
        ) { session, info in
            guard let session = session else {
                result(false)
                return
            }

            let targetURL = URL(fileURLWithPath: targetPath)
            let directory = targetURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            try? FileManager.default.removeItem(at: targetURL)

            session.outputURL = targetURL
            session.outputFileType = .mov

            session.exportAsynchronously {
                DispatchQueue.main.async {
                    switch session.status {
                    case .completed:
                        result(true)
                    case .failed, .cancelled:
                        print("PhotoBackup: Video export failed: \(session.error?.localizedDescription ?? "unknown")")
                        result(false)
                    default:
                        result(false)
                    }
                }
            }
        }
    }

    // MARK: - 导出 Live Photo 配对视频

    private func exportLivePhotoVideo(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let localIdentifier = args["localIdentifier"] as? String,
              let targetPath = args["targetPath"] as? String else {
            result(false)
            return
        }

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )

        guard let asset = fetchResult.firstObject else {
            result(false)
            return
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            result(false)
            return
        }

        let targetURL = URL(fileURLWithPath: targetPath)
        let directory = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try? FileManager.default.removeItem(at: targetURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(
            for: videoResource,
            toFile: targetURL,
            options: options
        ) { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Live Photo video export failed: \(error)")
                    result(false)
                } else {
                    result(true)
                }
            }
        }
    }

    // MARK: - 写入照片到相册

    /// 写入照片。成功时返回「新资产的 localIdentifier」—— 恢复去重要靠它
    /// 追踪「当初导入的那张现在还在不在相册」，失败返回 false。
    private func savePhotoToLibrary(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              let creationDateTimeInterval = args["creationDate"] as? Double else {
            result(false)
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            result(false)
            return
        }

        let creationDate = Date(timeIntervalSince1970: creationDateTimeInterval / 1000.0)
        var newLocalIdentifier: String?

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .photo, fileURL: fileURL, options: nil)
            request.creationDate = creationDate
            newLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save photo failed: \(error)")
                }
                if success, let identifier = newLocalIdentifier {
                    result(identifier)
                } else {
                    result(false)
                }
            }
        }
    }

    // MARK: - 写入视频到相册

    private func saveVideoToLibrary(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String,
              let creationDateTimeInterval = args["creationDate"] as? Double else {
            result(false)
            return
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            result(false)
            return
        }

        let creationDate = Date(timeIntervalSince1970: creationDateTimeInterval / 1000.0)
        var newLocalIdentifier: String?

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .video, fileURL: fileURL, options: nil)
            request.creationDate = creationDate
            newLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save video failed: \(error)")
                }
                if success, let identifier = newLocalIdentifier {
                    result(identifier)
                } else {
                    result(false)
                }
            }
        }
    }

    // MARK: - 写入 Live Photo 到相册

    private func saveLivePhotoToLibrary(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let photoPath = args["photoPath"] as? String,
              let videoPath = args["videoPath"] as? String,
              let creationDateTimeInterval = args["creationDate"] as? Double else {
            result(false)
            return
        }

        let photoURL = URL(fileURLWithPath: photoPath)
        let videoURL = URL(fileURLWithPath: videoPath)

        guard FileManager.default.fileExists(atPath: photoPath),
              FileManager.default.fileExists(atPath: videoPath) else {
            result(false)
            return
        }

        let creationDate = Date(timeIntervalSince1970: creationDateTimeInterval / 1000.0)
        var newLocalIdentifier: String?

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .photo, fileURL: photoURL, options: nil)
            try? request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            request.creationDate = creationDate
            newLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save Live Photo failed: \(error)")
                }
                if success, let identifier = newLocalIdentifier {
                    result(identifier)
                } else {
                    result(false)
                }
            }
        }
    }

    // MARK: - 本地网络权限

    private var bonjourBrowser: NWBrowser?

    /// 主动触发 iOS 的「本地网络」授权询问。
    ///
    /// iOS 14 起访问局域网需要用户授权，但单纯的单播 TCP 连接不足以让系统
    /// 弹出授权窗；未授权时连接会被沙盒直接丢弃，表现为
    /// `No route to host, errno = 65`。发起一次 Bonjour 浏览是明确需要该权限
    /// 的操作，可以稳定把系统询问逼出来。
    private func requestLocalNetworkPermission(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            if self.bonjourBrowser != nil {
                result(true)
                return
            }

            let browser = NWBrowser(
                for: .bonjour(type: "_http._tcp", domain: nil),
                using: NWParameters()
            )
            self.bonjourBrowser = browser
            browser.stateUpdateHandler = { state in
                print("PhotoBackup: 本地网络权限探测状态: \(state)")
            }
            browser.start(queue: .main)

            // 浏览 1.5 秒足以触发系统询问，之后主动收工
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                browser.cancel()
                self.bonjourBrowser = nil
                result(true)
            }
        }
    }

    // MARK: - 辅助方法

    /// 由资源 UTI 推导文件扩展名（HEIC / JPEG / PNG / RAW / DNG 等）
    private static func preferredExtension(forUTI uti: String) -> String {
        if let type = UTType(uti), let ext = type.preferredFilenameExtension, !ext.isEmpty {
            return ext
        }
        let fallback: [String: String] = [
            "public.heic": "heic",
            "public.heics": "heics",
            "public.heif": "heif",
            "public.jpeg": "jpg",
            "public.png": "png",
            "public.tiff": "tiff",
            "com.compuserve.gif": "gif",
            "public.mpeg-4": "mp4",
            "com.apple.quicktime-movie": "mov",
            "public.raw-image": "raw",
            "public.dng": "dng",
            "com.apple.private.dng-raw-image": "dng",
        ]
        return fallback[uti] ?? "jpg"
    }

    private func isPhotoLibraryAccessGranted(_ status: PHAuthorizationStatus) -> Bool {
        switch status {
        case .authorized:
            return true
        default:
            if #available(iOS 14, *) {
                return status == .limited
            }
            return false
        }
    }

    private func mediaTypeString(_ mediaType: PHAssetMediaType) -> String {
        switch mediaType {
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}
