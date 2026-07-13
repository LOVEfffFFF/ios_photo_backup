import UIKit
import Flutter
import Photos

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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 获取所有照片资源

    private func fetchAllAssets(result: @escaping FlutterResult) {
        PHPhotoLibrary.requestAuthorization { status in
            guard self.isPhotoLibraryAccessGranted(status) else {
                result([])
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

            result(assetsList)
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

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        options.deliveryMode = .highQualityFormat
        options.version = .original

        PHImageManager.default().requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, dataUTI, orientation, info in
            guard let imageData = data else {
                result(false)
                return
            }

            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }

            do {
                let targetURL = URL(fileURLWithPath: targetPath)
                let directory = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try imageData.write(to: targetURL)
                result(true)
            } catch {
                print("PhotoBackup: Failed to write photo: \(error)")
                result(false)
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

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .photo, fileURL: fileURL, options: nil)
            request.creationDate = creationDate
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save photo failed: \(error)")
                }
                result(success)
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

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .video, fileURL: fileURL, options: nil)
            request.creationDate = creationDate
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save video failed: \(error)")
                }
                result(success)
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

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            try? request.addResource(with: .photo, fileURL: photoURL, options: nil)
            try? request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            request.creationDate = creationDate
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("PhotoBackup: Save Live Photo failed: \(error)")
                }
                result(success)
            }
        }
    }

    // MARK: - 辅助方法

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
