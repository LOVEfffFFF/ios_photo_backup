import UIKit
import Flutter
import Photos
import UniformTypeIdentifiers
import Network
import ObjectiveC
import CryptoKit

// MARK: - 崩溃捕获的底层工具（顶层函数）
//
// 这些必须是顶层函数：signal() 要求 @convention(c) 函数指针，只有全局函数能传。
// 全部基于 stdio（fopen/fwrite/fputs/fclose 都属于 async-signal-safe），
// 因此在信号处理上下文里调用是安全的 —— 崩溃现场最忌讳的就是再崩溃一次。

/// 信号处理器写日志的路径。信号上下文里不能调 Objective-C API（可能死锁），
/// 所以在安装阶段就把路径备好。
private var g_signalLogPath: UnsafeMutablePointer<CChar>?

/// 安装前的系统异常处理器，崩溃记录完要交回给它
private var g_prevExceptionHandler: (@convention(c) (NSException) -> Void)?

/// 用 C stdio 追加写入文本。不用 Swift 的 File/Foundation 是为了 signal 安全。
private func appendCrashText(_ text: String, toPath path: String) {
    text.withCString { cstr in
        if let fp = fopen(path, "a") {
            fputs(cstr, fp)
            fclose(fp)
        }
    }
}

/// 同上，直接写字节（用于避免不必要的字符串拷贝）
private func appendCrashText(_ bytes: UnsafeRawPointer, length: Int, toPath path: String) {
    if let fp = fopen(path, "ab") {
        if length > 0 {
            _ = fwrite(bytes, 1, length, fp)
        }
        fclose(fp)
    }
}

/// 信号名（不用 strsignal：它未必是 async-signal-safe）
private let kSignalNames: [Int32: String] = [
    SIGSEGV: "SIGSEGV 非法内存访问", SIGABRT: "SIGABRT abort/断言失败",
    SIGBUS: "SIGBUS 总线错误", SIGILL: "SIGILL 非法指令",
    SIGFPE: "SIGFPE 算术错误", SIGTRAP: "SIGTRAP 陷阱（如强制解包 nil）",
]

/// POSIX 信号处理器：覆盖 Swift 运行时的内存错误（ObjC 异常处理器拦不住这些）
private func photoBackupSignalHandler(_ sig: Int32) {
    if let path = g_signalLogPath, let fp = fopen(path, "a") {
        var now = time(nil)
        var tbuf = [CChar](repeating: 0, count: 32)
        strftime(&tbuf, tbuf.count, "%Y-%m-%d %H:%M:%S", localtime(&now))
        let name = kSignalNames[sig] ?? "未知信号"
        // 用 fputs 而非 fprintf：fprintf 是变参（variadic）函数，Swift 不可用
        fputs("\n===== 信号崩溃 =====\n", fp)
        fputs("[\(String(cString: tbuf))] signal=\(sig) (\(name))\n", fp)

        // 回溯调用栈。这里只打印地址，不做符号解析 —— backtrace 是
        // async-signal-safe 的，而 dladdr/backtrace_symbols 涉及动态链接器，不安全。
        // 地址本身已经足够定位到崩溃点：配合下面的「崩溃前操作日志」看上下文即可。
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
        let n = backtrace(&frames, Int32(frames.count))
        for i in 0..<Int(n) {
            if let f = frames[i] {
                fputs("    frame \(i)  addr=0x\(String(UInt(bitPattern: f), radix: 16))\n", fp)
            }
        }
        fputs("（上面是内存地址而非符号名；结合崩溃前的操作日志定位）\n", fp)
        fclose(fp)
    }
    // 交回默认行为，让系统照常记录这次崩溃
    signal(sig, SIG_DFL)
    raise(sig)
}

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

        // 最先装崩溃捕获器：后面任何一步崩掉都要能留下记录
        installCrashCapture()

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

    /// 正常退出（用户手动关闭 / 被系统终止）时清掉启动标记。
    /// 被 iOS 后台直接回收时不会走到这里 —— 标记会残留，下次启动据此提示「疑似异常退出」。
    override func applicationWillTerminate(_ application: UIApplication) {
        clearRunMarker()
        super.applicationWillTerminate(application)
    }

    // MARK: - 崩溃捕获与日志落盘
    //
    // 崩溃时进程直接死掉，任何「崩溃后再上传」的方案都不可行。真正靠得住的做法是
    // **崩溃现场把信息写进沙盒文件，下次启动再上报**。分三层覆盖：
    //
    //  ① Objective-C 异常（NSSetUncaughtExceptionHandler）
    //     例如 KVC 读未定义 key 抛的 NSUnknownKeyException。这类异常能拿到完整的
    //     callStackSymbols，是排查崩溃最有价值的信息。
    //
    //  ② POSIX 信号（Swift 运行时的内存错误）
    //     数组越界、强制解包 nil、栈溢出等，ObjC 异常处理器拦不住，只能靠信号兜底。
    //     信号上下文里只调 async-signal-safe 函数，因此只写最小必要信息。
    //
    //  ③ 异常退出标记
    //     前两层都没触发但进程没了时兜底。诚实说明：iOS 后台回收**不会**调用
    //     applicationWillTerminate，会留下标记，所以这一条标为「疑似」而非确证。

    /// 日志目录：Documents/logs（Dart 侧也写同一目录，便于统一上报）
    static func logsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 时间戳：文件名与日志行都用它，保证同一份日志里的时间可排序
    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// 追加一行运行日志（与 Dart 侧写入同一批文件）
    @discardableResult
    static func appendLogLine(_ line: String) {
        let path = logsDirectory().appendingPathComponent("app.log").path
        let text = line.hasSuffix("\n") ? line : line + "\n"
        if let data = text.data(using: .utf8) {
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress {
                    appendCrashText(base, length: raw.count, toPath: path)
                }
            }
        }
    }

    /// 列出日志文件（崩溃日志优先），供 Dart 侧展示与上报
    static func listLogs() -> [[String: Any]] {
        let dir = logsDirectory()
        var items: [[String: Any]] = []
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return items }
        for f in files where f.pathExtension == "log" {
            let attrs = try? FileManager.default.attributesOfItem(atPath: f.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            items.append([
                "name": f.lastPathComponent,
                "size": size,
                "modified": modified.timeIntervalSince1970,
                "isCrash": f.lastPathComponent.hasPrefix("crash"),
            ])
        }
        // 崩溃日志排前面，其余按修改时间倒序。
        // 用 as? 而不是 as!：字典是 [String: Any]，强转失败会崩 ——
        // 而这个方法正是崩溃后要调用的，绝不能自己再崩一次。
        return items.sorted { a, b in
            let ac = (a["isCrash"] as? Bool) ?? false
            let bc = (b["isCrash"] as? Bool) ?? false
            if ac != bc {
                return ac
            }
            let am = (a["modified"] as? Double) ?? 0
            let bm = (b["modified"] as? Double) ?? 0
            return am > bm
        }
    }

    /// 读取某个日志文件的全部内容
    static func readLog(_ name: String) -> String? {
        // 防目录穿越：只允许纯文件名，不接受任何分隔符
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              name.hasSuffix(".log") else { return nil }
        let path = logsDirectory().appendingPathComponent(name).path
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// 启动时检查上次运行是否异常结束，并安装崩溃捕获器
    func installCrashCapture() {
        // ③ 异常退出标记：残留即说明上次没走到正常终止
        let marker = Self.logsDirectory().appendingPathComponent("running.marker")
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path),
           let attrs = try? fm.attributesOfItem(atPath: marker.path),
           let created = attrs[.creationDate] as? Date {
            Self.appendLogLine(
                "[warn] 上次运行的启动标记仍然存在（标记于 \(Self.stamp(created))）→ "
                + "上次未走到正常终止。可能是崩溃，也可能是被 iOS 后台回收"
                + "（iOS 回收进程不调用 applicationWillTerminate），因此不作崩溃确证。")
        }
        try? "started \(Self.stamp())".write(to: marker, atomically: true, encoding: .utf8)

        // ① Objective-C 异常
        g_prevExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            var text = "\n===== Objective-C 崩溃 =====\n"
            text += "时间: \(AppDelegate.stamp())\n"
            text += "name: \(exception.name.rawValue)\n"
            text += "reason: \(exception.reason ?? "无")\n"
            text += "userInfo: \(exception.userInfo)\n"
            text += "callStack:\n"
            for s in exception.callStackSymbols {
                text += "  \(s)\n"
            }
            let path = AppDelegate.logsDirectory()
                .appendingPathComponent("crash-objc-\(AppDelegate.stamp()).log").path
            appendCrashText(text, toPath: path)
            AppDelegate.appendLogLine("[fatal] Objective-C 崩溃: \(exception.name.rawValue) / \(exception.reason ?? "无")")

            // 交回原处理器（通常是系统的崩溃报告器），否则退回 abort
            if let prev = g_prevExceptionHandler {
                prev(exception)
            } else {
                abort()
            }
        }

        // ② POSIX 信号：Swift 运行时的内存错误走这里
        let crashPath = Self.logsDirectory().appendingPathComponent("crash-signal.log").path
        g_signalLogPath = strdup(crashPath)
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, photoBackupSignalHandler)
        }

        Self.appendLogLine("[info] 崩溃捕获器已安装（NSException + 信号 + 异常退出标记）")
    }

    /// 正常退出时清掉启动标记（被系统回收时不会走到这里）
    func clearRunMarker() {
        let marker = Self.logsDirectory().appendingPathComponent("running.marker")
        try? FileManager.default.removeItem(at: marker)
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
        case "hashAssetResources":
            hashAssetResources(call: call, result: result)
        case "deleteAssets":
            deleteAssets(call: call, result: result)
        case "savePhotoWithExtras":
            savePhotoWithExtras(call: call, result: result)
        case "listLogs":
            DispatchQueue.global().async { result(AppDelegate.listLogs()) }
        case "readLog":
            let args = call.arguments as? [String: Any]
            let name = args?["name"] as? String ?? ""
            result(AppDelegate.readLog(name))
        case "appendLog":
            let args = call.arguments as? [String: Any]
            let line = args?["line"] as? String ?? ""
            if !line.isEmpty {
                AppDelegate.appendLogLine(line)
                result(true)
            } else {
                result(false)
            }
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
                    // PHAssetResource 没有公开的文件大小属性，只能留 0。
                    // 曾经试过用 KVC (value(forKey: "fileSize")) 取，key 不存在时会抛
                    // Objective-C 异常直接闪退——KVC 读未定义 key 是崩溃，不是返回 nil。
                    "fileSize": 0,
                    "originalFilename": r.originalFilename,
                    ])
            }

            let location = asset.location
            // PHAsset 没有公开的 originalFilename / formatDescriptions 属性，
            // 但用 KVC 直接读有风险：key 不存在会抛 Objective-C 异常导致闪退。
            // 因此先走运行时检查确认属性真的存在，再读。
            var originalFilename = (Self.safeKVC(asset, "originalFilename") as? String) ?? ""
            if originalFilename.isEmpty, let first = resourceList.first {
                // 兜底：用资源级文件名（PHAssetResource.originalFilename 是公开的）
                originalFilename = (first["originalFilename"] as? String) ?? ""
            }
            let formatDescriptions =
                (Self.safeKVC(asset, "formatDescriptions") as? [String]) ?? []
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
                "originalFilename": originalFilename,
                "subtypes": Self.subtypeNames(asset),
                "hasLocation": location != nil,
                "latitude": location?.coordinate.latitude ?? 0,
                "longitude": location?.coordinate.longitude ?? 0,
                "formatDescriptions": formatDescriptions,
                "resourceCount": resourceList.count,
                "resources": resourceList,
            ]
            DispatchQueue.main.async { result(detail) }
        }
    }

    /// 安全读取私有属性：先确认类里真的定义了这个属性，再用 KVC 取
    ///
    /// 为什么需要它：Objective-C 的 `value(forKey:)` 在 key 不存在时会抛
    /// `NSUnknownKeyException`，这是**崩溃**，不是返回 nil。
    /// 逐个属性先 `class_getProperty` 确认存在（沿继承链向上找），
    /// 不存在就直接返回 nil，从而把「可能闪退」变成「拿不到就留空」。
    private static func safeKVC(_ obj: NSObject, _ key: String) -> Any? {
        var cls: AnyClass? = object_getClass(obj)
        while let c = cls {
            if class_getProperty(c, key) != nil {
                return obj.value(forKey: key)
            }
            cls = class_getSuperclass(c)
        }
        return nil
    }

    /// mediaSubtypes 转成可读名称（判断是否 Live Photo / HDR / 人像 / RAW …）
    ///
    /// 用 `rawValue` 判断而不是直接引用枚举成员：不同 iOS 版本可用的成员不同
    /// （例如 `photoHDRGainMap` 在旧 SDK 上不存在），直接引用会编译失败。
    private static func subtypeNames(_ asset: PHAsset) -> [String] {
        // PHAssetMediaSubtype 的 rawValue 对照（Apple 未公开文档，故按已知值标注）
        let names: [Int: String] = [
            1: "实况照片",        // photoLive
            2: "全景",                    // photoPanorama
            3: "HDR",                       // photoHDR
            4: "增益图",                // photoHDRGainMap
            5: "人像深度效果",    // photoDepthEffect
            6: "主体识别",          // photoContentAware
            8: "RAW 原片",                // photoRAW
            9: "视频流",                // videoStream
            10: "Live Photo 视频",        // videoLive
            11: "高帧率",                // videoHighFps
            12: "延时摄影",          // videoTimelapse
            13: "电影效果",          // videoCinematic
        ]
        // PHAssetMediaSubtype 的集合在 Swift 里无法直接遍历（元素类型不遵循
        // Hashable、也不能桥接成 NSSet）。改为逐个询问是否包含已知值——
        // contains 是集合自带的 API，不需要遍历，兼容性最好。
        var result: [String] = []
        let subtypes = asset.mediaSubtypes
        let probes: [(UInt, String)] = [
            (1, "实况照片"), (2, "全景"), (3, "HDR"), (4, "增益图"),
            (5, "人像深度效果"), (6, "主体识别"), (8, "RAW 原片"),
            (9, "视频流"), (10, "Live Photo 视频"), (11, "高帧率"),
            (12, "延时摄影"), (13, "电影效果"),
        ]
        for (raw, name) in probes {
            // PHAssetMediaSubtype(rawValue:) 返回非可选值，直接构造后判断
            let subtype = PHAssetMediaSubtype(rawValue: raw)
            if subtypes.contains(subtype) {
                result.append(name)
            }
        }
        return result
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

    // MARK: - 资源导出与端到端校验

    /// PHAssetResourceType → 可读名称（与 Dart 侧 AssetResourceInfo.typeLabel 保持一致）
    private static func resourceTypeName(_ t: PHAssetResourceType) -> String {
        switch t {
        case .photo: return "photo"
        case .video: return "video"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizeVideo: return "fullSizeVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .alternatePhoto: return "alternatePhoto"
        // 注意：poster / alternateVideo / alternatePairedVideo / fullSizePoster
        // 在 PHAssetResourceType 里并不存在（它们只出现在旧文档与网络资料里），
        // 写进 switch 会编译失败。遇到未知值由 default 兜底。
        default: return "type(\(t.rawValue))"
        }
    }

    /// 导出单个资源：边接收边写盘边算 SHA256
    ///
    /// ## 为什么不用 writeData(for:toFile:)
    /// 它不给流式回调，无法在写盘的同时算哈希，只能事后再把文件读一遍
    /// （一张 59MB 的 DNG 就多读一次）。`requestData` 的 dataReceivedHandler
    /// 是分块给的，可以边收边更新哈希 —— **零额外 IO**。
    ///
    /// ## 这个 hash 有什么用
    /// 它是「手机原图资源」的哈希，与接收端对**落盘字节**算出的哈希是
    /// 两个**独立来源**。两者一致才能证明：从原图到磁盘这条链路没出错。
    /// 接收端自己算的哈希只能证明传输没损坏，证明不了「导出的内容就是原图」。
    private func exportResource(
        _ resource: PHAssetResource,
        to targetURL: URL,
        options: PHAssetResourceRequestOptions,
        completion: @escaping (Result<(sha256: String, bytes: Int), Error>) -> Void
    ) {
        let directory = targetURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.removeItem(at: targetURL)

        guard FileManager.default.createFile(atPath: targetURL.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: targetURL.path) else {
            completion(.failure(NSError(
                domain: "PhotoBackup", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "无法创建文件 \(targetURL.lastPathComponent)"])))
            return
        }

        var hasher = SHA256()
        var total = 0
        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in
                hasher.update(data: data)
                handle.write(data)
                total += data.count
            },
            completionHandler: { error in
                handle.closeFile()
                if let error = error {
                    // 半截文件留在沙盒里会被下次上传当成正常文件，先清掉
                    try? FileManager.default.removeItem(at: targetURL)
                    completion(.failure(error))
                    return
                }
                let hex = hasher.finalize()
                    .map { String(format: "%02x", $0) }.joined()
                completion(.success((sha256: hex, bytes: total)))
            }
        )
    }

    /// 统计一个资产的全部资源构成（用于「资源完整度」核对）
    ///
    /// 只取类型与文件名，不读内容，因此很快，可以每次备份都算。
    private static func resourceSummary(_ asset: PHAsset) -> [String: Any] {
        let resources = PHAssetResource.assetResources(for: asset)
        var primaryTypes: [String] = []
        var auxiliaryTypes: [String] = []
        for r in resources {
            let label = resourceTypeName(r.type)
            switch r.type {
            case .photo, .video, .pairedVideo, .fullSizePhoto, .fullSizeVideo:
                primaryTypes.append(label)
            default:
                // 深度图 / 增益图 / 海报等：这些是「多出来的资源」，
                // ProRAW 的 DNG+JPEG 也落在这里 —— 少导了就是丢内容
                auxiliaryTypes.append(label)
            }
        }
        return [
            "total": resources.count,
            "primary": primaryTypes,
            "auxiliary": auxiliaryTypes,
        ]
    }

    /// 计算已落盘文件的 SHA256（分块读，不把大文件整个塞进内存）
    ///
    /// 用于「系统导出」的路径：AVAssetExportSession 自己写文件，不给流式回调，
    /// 只能在导出完成后读回来算。这是权衡后的取舍 —— 视频走的是系统转封装，
    /// 想边写边算就得自己重写封装逻辑，代价远大于多读一次。
    private func sha256OfFile(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)  // 1MB 一块
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 判断一个资源是否值得备份，并给它一个 role。返回 nil = 不备份。
    ///
    /// ## 为什么不能只看 PHAssetResourceType 的优先级
    /// 实测（2026-10-11）：一个开了「风格」的 ProRAW 资产有 4 个资源
    ///   photo         IMG_6550.DNG      com.adobe.raw-image       ← RAW 原图
    ///   poster        Adjustments.plist  com.apple.property-list   ← 编辑指令（风格记在这）
    ///   type(16)      IMG_6550O.aae     apple-adjustment-envelope ← 编辑数据
    ///   fullSizeVideo FullSizeRender.jpg public.jpeg              ← 渲染结果
    ///
    /// 旧逻辑「按 type 优先级挑一个」挑中的是渲染后的 JPEG，
    /// **真正的 DNG 被跳过** —— 恢复后相册认不出 RAW。
    ///
    /// ## role 含义
    ///   main          主演示资源（相册里看到的那份）
    ///   raw           RAW 原图（ProRAW 的 DNG）
    ///   pairedVideo   Live Photo 配对视频
    ///   adjustment    Adjustments.plist（用户选的风格）
    ///   adjustmentAAE .aae 编辑数据封装
    ///   alternate     其他格式版本
    private static func classifyResource(_ r: PHAssetResource) -> String? {
        let uti = r.uniformTypeIdentifier.lowercased()

        // 编辑指令：体积很小但决定了「风格」，绝不能丢
        if uti.contains("adjustment-envelope") { return "adjustmentAAE" }
        if uti.contains("property-list") { return "adjustment" }

        // RAW 原图
        if uti.contains("raw-image") || uti.contains("dng")
            || uti.contains("adobe.raw") || uti.contains("x-adobe") {
            return "raw"
        }

        switch r.type {
        case .pairedVideo, .fullSizePairedVideo:
            return "pairedVideo"
        case .photo, .fullSizePhoto, .alternatePhoto:
            return "main"
        case .video, .fullSizeVideo, .alternateVideo:
            return "main"
        default:
            // 枚举里未识别的类型：只有 UTI 确实是媒体格式时才备份，
            // 纯数据类（缩略图描述、内部索引）跳过，避免备份垃圾
            if uti.contains("image") || uti.contains("video")
                || uti.contains("quicktime") || uti.contains("audio") {
                return "alternate"
            }
            return nil
        }
    }

    /// 选出「主演示文件」—— 用户在相册里看到的那一份。
    ///
    /// 这与「RAW 原图」是**两件事**：编辑过的照片，主文件是渲染后的 JPEG，
    /// 而 RAW 原图作为附加资源一起备份（GAP-R1）。
    private static func pickPrimaryResource(
        _ classified: [(resource: PHAssetResource, role: String)]
    ) -> PHAssetResource? {
        let order: [PHAssetResourceType] = [
            .fullSizePhoto, .photo, .alternatePhoto,
            .fullSizeVideo, .video, .alternateVideo,
        ]
        for t in order {
            if let hit = classified.first(where: { $0.resource.type == t }) {
                return hit.resource
            }
        }
        return classified.first(where: { $0.role == "main" })?.resource
    }

    /// 组装导出结果（路径 + 内容哈希 + 资源构成），返回给 Dart
    private func exportResult(
        path: String, sha256: String, bytes: Int, summary: [String: Any]
    ) -> [String: Any] {
        var out: [String: Any] = [
            "path": path,
            "sha256": sha256,
            "bytes": bytes,
        ]
        for (k, v) in summary { out[k] = v }
        return out
    }

    // MARK: - 写入照片到相册

/// 写入照片，**并把附加资源一起挂上去**（GAP-R1 / GAP-R2）
///
/// ## 为什么不能只写主文件
/// 一个 ProRAW 资产由多个文件组成：RAW 原图（DNG）、Adjustments.plist（用户选的
/// 风格）、.aae（编辑数据）。只写主文件的话，恢复后相册认不出 RAW、风格也没了。
///
/// ## 附加资源怎么写
/// PHAssetCreationRequest.addResource 的第二个参数是 [PHAssetResourceType]。
/// 我们在 Dart 侧按 UTI 判定好「语义类型」传进来（如 adjustmentEnvelope），
/// 这里映射成对应的枚举值——**不用 rawValue 硬编码**，因为该枚举在不同 iOS
/// 版本上成员有增减（实测 poster / type16 就不在公开枚举里）。
private func savePhotoWithExtras(call: FlutterMethodCall, result: @escaping FlutterResult) {
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

    // 附加资源：[{restoreType, path, uti, filename}]
    var extras: [(type: PHAssetResourceType, url: URL)] = []
    if let list = args["extraResources"] as? [[String: Any]] {
        for item in list {
            guard let p = item["path"] as? String,
                  FileManager.default.fileExists(atPath: p) else { continue }
            let kind = item["restoreType"] as? String ?? "alternate"
            guard let t = Self.phAssetResourceType(forRestoreType: kind) else { continue }
            extras.append((t, URL(fileURLWithPath: p)))
        }
    }

    let creationDate = Date(timeIntervalSince1970: creationDateTimeInterval / 1000.0)
    var newLocalIdentifier: String?

    PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        try? request.addResource(with: .photo, fileURL: fileURL, options: nil)
        for e in extras {
            try? request.addResource(with: e.type, fileURL: e.url, options: nil)
        }
        request.creationDate = creationDate
        newLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
    } completionHandler: { success, error in
        DispatchQueue.main.async {
            if let error = error {
                print("PhotoBackup: Save photo(with extras) failed: \(error)")
            }
            if success, let id = newLocalIdentifier {
                result(id)
            } else {
                result(false)
            }
        }
    }
}

/// Dart 侧传来的语义类型 → PHAssetResourceType
///
/// ## 只用编译期校验过的枚举成员
/// PHAssetResourceType 里**没有** poster / alternateVideo /
/// alternatePairedVideo / fullSizePoster 这几个成员（写进去编译器会报错），
/// 所以「编辑指令」这类只能落到语义最接近的通用成员上，让相册按 UTI 自行识别。
private static func phAssetResourceType(forRestoreType kind: String) -> PHAssetResourceType? {
    switch kind {
    case "adjustmentEnvelope", "adjustmentPlist":
        // Adjustments.plist / .aae —— 编辑指令与数据。
        // 没有对应的公开枚举成员，用 alternatePhoto 承载。
        return .alternatePhoto
    case "pairedVideo":
        return .pairedVideo
    case "fullSizePhoto":
        return .fullSizePhoto
    case "photo":
        return .photo
    case "video":
        return .video
    case "fullSizeVideo":
        return .fullSizeVideo
    default:
        return .alternatePhoto
    }
}

// MARK: - 往返验证：清理验证副本

/// 删除指定的资产（仅用于清理「往返验证」创建的副本）
///
/// ## 安全约束
/// 这是**删除相册照片**的能力，风险最高，因此刻意做成最窄的口子：
///   · 必须显式传 confirm=true 才执行，否则直接拒绝
///   · 只删调用方给出的 ID 列表，不做任何"顺便清理"
///   · 删完回传每个 ID 的成功/失败，让 UI 如实展示
///
/// 调用方（VerifyManager）只会传入本次验证自己创建、且记录在
/// restoredAssetIds 里的 ID —— 绝不涉及用户原有照片。
private func deleteAssets(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          args["confirm"] as? Bool == true else {
        result(["error": "必须显式确认（confirm=true）才会执行删除"])
        return
    }
    let ids = args["localIdentifiers"] as? [String] ?? []
    // 空列表直接拒绝：避免"删了 0 个"被误当成成功
    guard !ids.isEmpty else {
        result(["error": "没有要删除的资产 ID"])
        return
    }

    PHPhotoLibrary.requestAuthorization { status in
        guard self.isPhotoLibraryAccessGranted(status) else {
            DispatchQueue.main.async { result(["error": "没有相册访问权限"]) }
            return
        }
        var ok = 0
        var failed = 0
        // 逐个删：PHPhotoLibrary 的 performChanges 不支持按 ID 批量删
        for id in ids {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = fetch.firstObject else {
                failed += 1
                continue
            }
            var done = false
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }, completionHandler: { success, _ in
                if success { ok += 1 } else { failed += 1 }
                done = true
            })
            // performChanges 是异步的，这里等它完成再进行下一个，
            // 避免并发 performChanges 造成不确定行为
            let deadline = Date().addingTimeInterval(10)
            while !done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        DispatchQueue.main.async {
            result(["deleted": ok, "failed": failed])
        }
    }
}

// MARK: - 往返验证：读取原图资源的哈希

/// 读取某个资产**当前**各资源的字节哈希（不写入任何东西）
///
/// 这是「往返验证」的关键：恢复导入相册后，拿副本的资源哈希与原图比对，
/// 就能回答「恢复出来的 == 源文件吗」——包括 iOS 导入时是否重新编码、
/// 是否剥离 EXIF 这类只有真正走一遍才能发现的问题。
///
/// 只读，不产生任何副作用（不导入、不修改相册）。
private func hashAssetResources(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let localIdentifier = args["localIdentifier"] as? String else {
        result(nil)
        return
    }
    let preferVideo = args["preferVideo"] as? Bool ?? false

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
        let resources = PHAssetResource.assetResources(for: asset)
        let target: PHAssetResource?
        if preferVideo {
            target = resources.first(where: {
                $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
            })
        } else {
            target = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .alternatePhoto })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
        }
        guard let resource = target else {
            DispatchQueue.main.async { result(nil) }
            return
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        var hasher = SHA256()
        var total = 0
        var failed = false
        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in
                hasher.update(data: data)
                total += data.count
            },
            completionHandler: { error in
                if let error = error {
                    print("PhotoBackup: 读取资源哈希失败: \(error)")
                    failed = true
                }
                DispatchQueue.main.async {
                    if failed {
                        result(nil)
                        return
                    }
                    let hex = hasher.finalize()
                        .map { String(format: "%02x", $0) }.joined()
                    result([
                        "sha256": hex,
                        "bytes": total,
                        "uti": resource.uniformTypeIdentifier,
                        "filename": resource.originalFilename,
                        "resourceCount": resources.count,
                        "resourceSummary": Self.resourceSummary(asset),
                    ])
                }
            }
        )
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

        // GAP-R1/R2：**导出全部值得备份的资源**，而不是按 type 挑一个。
        // 旧逻辑挑中渲染后的 JPEG，把 RAW 原图和编辑指令全丢了。
        let classified: [(resource: PHAssetResource, role: String)] = resources
            .compactMap { r in
                guard let role = Self.classifyResource(r) else { return nil }
                return (resource: r, role: role)
            }

        guard let primary = Self.pickPrimaryResource(classified) else {
            result(false)
            return
        }
        // 主文件之外的其他资源（DNG / Adjustments.plist / .aae …）
        let extras = classified.filter { $0.resource !== primary }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = isNetworkAccessAllowed
        let summary = Self.resourceSummary(asset)
        let assetId = asset.localIdentifier

        // 先导主文件，拿到路径后再导出附加资源（附加资源的文件名基于主文件）
        exportResource(primary, to: Self.targetURL(for: targetPath, resource: primary),
                       options: options) { outcome in
            switch outcome {
            case .failure(let error):
                DispatchQueue.main.async {
                    print("PhotoBackup: Failed to write photo: \(error)")
                    result(false)
                }
            case .success(let info):
                let mainURL = Self.targetURL(for: targetPath, resource: primary)
                // 导出附加资源（逐个，失败不阻断主文件）
                var extraResults: [[String: Any]] = []
                let group = DispatchGroup()
                let lock = NSLock()
                for item in extras {
                    group.enter()
                    let url = Self.extraResourceURL(mainURL: mainURL, role: item.role, resource: item.resource)
                    self.exportResource(item.resource, to: url, options: options) { r in
                        if case .success(let info2) = r {
                            lock.lock()
                            extraResults.append([
                                "role": item.role,
                                "path": url.path,
                                "sha256": info2.sha256,
                                "bytes": info2.bytes,
                                "uti": item.resource.uniformTypeIdentifier,
                                "filename": item.resource.originalFilename,
                            ])
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .global()) {
                    var payload = self.exportResult(
                        path: mainURL.path, sha256: info.sha256,
                        bytes: info.bytes, summary: summary)
                    payload["extraResources"] = extraResults
                    DispatchQueue.main.async { result(payload) }
                }
            }
        }
    }

    /// 主文件的目标路径：按资源真实 UTI 推导扩展名
    private static func targetURL(for targetPath: String, resource: PHAssetResource) -> URL {
        let ext = preferredExtension(forUTI: resource.uniformTypeIdentifier)
        return URL(fileURLWithPath: targetPath)
            .deletingPathExtension()
            .appendingPathExtension(ext)
    }

    /// 附加资源的文件名：主文件名 + 角色后缀，避免与主文件重名
    private static func extraResourceURL(
        mainURL: URL, role: String, resource: PHAssetResource
    ) -> URL {
        let ext = preferredExtension(forUTI: resource.uniformTypeIdentifier)
        let base = mainURL.deletingPathExtension().lastPathComponent
        return mainURL.deletingLastPathComponent()
            .appendingPathComponent("\(base).\(role).\(ext)")
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
                switch session.status {
                case .completed:
                    // 系统导出拿不到流式回调，只能导出后读回来算 hash
                    let hash = self.sha256OfFile(at: targetURL.path) ?? ""
                    let attrs = try? FileManager.default
                        .attributesOfItem(atPath: targetURL.path)
                    let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                    let summary = Self.resourceSummary(asset)
                    DispatchQueue.main.async {
                        result(self.exportResult(
                            path: targetURL.path,
                            sha256: hash,
                            bytes: bytes,
                            summary: summary))
                    }
                case .failed, .cancelled:
                    print("PhotoBackup: Video export failed: \(session.error?.localizedDescription ?? "unknown")")
                    DispatchQueue.main.async { result(false) }
                default:
                    DispatchQueue.main.async { result(false) }
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
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        // 资源构成只对主照片有意义（配对视频本身就是 asset 的一个资源），
        // 这里仍然附上，好让接收端知道这个文件的来源
        let summary = Self.resourceSummary(asset)

        var responded = false
        exportResource(videoResource, to: targetURL, options: options) { outcome in
            DispatchQueue.main.async {
                guard !responded else { return }
                responded = true
                switch outcome {
                case .success(let info):
                    result(self.exportResult(
                        path: targetURL.path,
                        sha256: info.sha256,
                        bytes: info.bytes,
                        summary: summary))
                case .failure(let error):
                    print("PhotoBackup: Live Photo video export failed: \(error)")
                    result(false)
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
