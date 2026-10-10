import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 单个资产的完整信息（对比「备份 vs 原图」用）
class AssetDetail {
  final String localIdentifier;
  final double creationDate;
  final double modificationDate;
  final int pixelWidth;
  final int pixelHeight;
  final String mediaType;
  final double duration;
  final bool isFavorite;
  final bool isHidden;
  final String originalFilename;
  final List<String> subtypes;
  final bool hasLocation;
  final List<AssetResourceInfo> resources;

  const AssetDetail({
    required this.localIdentifier,
    required this.creationDate,
    required this.modificationDate,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.mediaType,
    required this.duration,
    required this.isFavorite,
    required this.isHidden,
    required this.originalFilename,
    required this.subtypes,
    required this.hasLocation,
    required this.resources,
  });

  /// 一张照片可能由多份文件组成（ProRAW 的 DNG+JPEG、人像深度图、HDR 增益图…）
  int get resourceCount => resources.length;

  String get sizeLabel => '${pixelWidth}×$pixelHeight';

  String get typeLabel => subtypes.isEmpty ? mediaType : subtypes.join('、');

  factory AssetDetail.fromMap(Map<String, dynamic> m) {
    final res = <AssetResourceInfo>[];
    final list = m['resources'] as List<dynamic>? ?? const [];
    for (final item in list) {
      if (item is Map) {
        res.add(AssetResourceInfo.fromMap(Map<String, dynamic>.from(item)));
      }
    }
    return AssetDetail(
      localIdentifier: (m['localIdentifier'] as String?) ?? '',
      creationDate: (m['creationDate'] as num?)?.toDouble() ?? 0,
      modificationDate: (m['modificationDate'] as num?)?.toDouble() ?? 0,
      pixelWidth: (m['pixelWidth'] as num?)?.toInt() ?? 0,
      pixelHeight: (m['pixelHeight'] as num?)?.toInt() ?? 0,
      mediaType: (m['mediaType'] as String?) ?? '',
      duration: (m['duration'] as num?)?.toDouble() ?? 0,
      isFavorite: m['isFavorite'] == true,
      isHidden: m['isHidden'] == true,
      originalFilename: (m['originalFilename'] as String?) ?? '',
      subtypes: ((m['subtypes'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      hasLocation: m['hasLocation'] == true,
      resources: res,
    );
  }
}

/// 一份资源文件的信息
class AssetResourceInfo {
  final int type;
  final String uti;
  final int fileSize;
  final String originalFilename;

  const AssetResourceInfo({
    required this.type,
    required this.uti,
    required this.fileSize,
    required this.originalFilename,
  });

  factory AssetResourceInfo.fromMap(Map<String, dynamic> m) => AssetResourceInfo(
        type: (m['type'] as num?)?.toInt() ?? 0,
        uti: (m['uti'] as String?) ?? '',
        fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
        originalFilename: (m['originalFilename'] as String?) ?? '',
      );

  String get typeLabel {
    // PHAssetResourceType 的 rawValue → 可读名称
    const names = {
      1: 'photo',
      2: 'video',
      3: 'pairedVideo',
      4: 'fullSizePhoto',
      5: 'fullSizeVideo',
      6: 'fullSizePairedVideo',
      7: 'poster',
      8: 'alternatePhoto',
      9: 'alternateVideo',
      10: 'alternatePairedVideo',
      11: 'adjustment',
      12: 'adjustmentBase',
      13: 'thumbnail',
      14: 'auxiliaryThumbnail',
      15: 'auxiliaryMetadata',
    };
    return names[type] ?? 'type$type';
  }

  String get sizeText {
    if (fileSize <= 0) return '—';
    if (fileSize >= 1024 * 1024) {
      return '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (fileSize >= 1024) return '${(fileSize / 1024).toStringAsFixed(0)} KB';
    return '$fileSize B';
  }
}

/// 照片库访问封装 - 通过 MethodChannel 调用原生 iOS API
class PhotoLibraryHelper {
  static const _channel = MethodChannel('com.photobackup/photo_library');

  /// 请求照片访问权限
  static Future<bool> requestPermission() async {
    // iOS 使用 permission_handler 请求照片权限
    final status = await Permission.photos.request();
    if (status.isGranted) return true;

    // 如果被拒绝，尝试有限访问
    if (status.isLimited) return true;

    return false;
  }

  /// 请求添加照片到相册的权限
  static Future<bool> requestAddOnlyPermission() async {
    // iOS 14+ 的添加照片权限
    final status = await Permission.photosAddOnly.request();
    return status.isGranted || status.isLimited;
  }

  /// 触发 iOS 本地网络访问授权（iOS 14+）
  ///
  /// 单纯的单播 HTTP 连接不足以让系统弹出授权窗；未授权时连接会被沙盒
  /// 直接丢弃，表现为 `No route to host, errno = 65`。这里双管齐下：
  /// 原生 Bonjour 浏览（主）+ Dart 侧 mDNS 探测包（兜底）。
  static Future<void> requestLocalNetworkPermission() async {
    try {
      await _channel.invokeMethod('requestLocalNetworkPermission');
    } catch (e) {
      print('[LocalNetwork] 原生权限探测失败: $e');
    }

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.send(const [0], InternetAddress('224.0.0.251'), 5353);
    } catch (e) {
      print('[LocalNetwork] 多播探测失败: $e');
    } finally {
      socket?.close();
    }
  }

  /// 批量查询这些 localIdentifier 是否仍然存在于相册中
  ///
  /// 恢复前用它跳过「照片本来就没删」的条目 —— 否则同一台手机上恢复
  /// 会把还在相册里的照片又导入一份，变成重复。
  /// 返回：仍然存在于相册中的 localIdentifier 集合。
  static Future<Set<String>> filterExistingAssets(
    List<String> localIdentifiers,
  ) async {
    if (localIdentifiers.isEmpty) {
      return <String>{};
    }
    try {
      final result = await _channel.invokeMethod('checkAssetsExist', {
        'localIdentifiers': localIdentifiers,
      });
      if (result is List) {
        return result.map((e) => e.toString()).toSet();
      }
    } catch (e) {
      print('[PhotoLibrary] 查询相册资产失败: $e');
    }
    return <String>{};
  }

  /// 取单个资产的完整信息；相册里找不到、或原生返回异常时返回 null
  static Future<AssetDetail?> fetchAssetDetail(String localIdentifier) async {
    if (localIdentifier.isEmpty) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod('getAssetDetail', {
        'localIdentifier': localIdentifier,
      });
      if (result is Map) {
        return AssetDetail.fromMap(Map<String, dynamic>.from(result));
      }
    } on PlatformException catch (e) {
      // 原生侧异常（如权限不足、资源被删）不应让整个页面崩掉
      print('[PhotoLibrary] 读取资产详情失败(PlatformException): ${e.message}');
    } catch (e) {
      print('[PhotoLibrary] 读取资产详情失败: $e');
    }
    return null;
  }

  /// 追加一行日志到沙盒日志文件（Documents/logs/app.log）
  ///
  /// 走原生通道而不是 Dart 直接写文件，是因为原生侧用的是 stdio 追加写，
  /// 与崩溃日志的写入方式一致 —— 同一个文件里既有运行日志又有崩溃现场，
  /// 才能还原「崩溃前最后做了什么」。
  ///
  /// 故意不做 await 也不抛异常：写日志本身失败不该影响业务，
  /// 而且崩溃路径上调用它时往往已经不能安全地等待异步结果了。
  static void appendLogNative(String line) {
    if (line.isEmpty) return;
    _channel.invokeMethod('appendLog', {'line': line}).catchError((_) {
      // 忽略：日志写不进去也不能让业务失败
      return false;
    });
  }


/// 判断某个资产当前是否还在相册里
  ///
  /// 往返验证与恢复去重都要用。
  static Future<bool> assetExists(String localIdentifier) async {
    if (localIdentifier.isEmpty) return false;
    if (_channel == null) return false;
    try {
      final result = await _channel.invokeMethod('checkAssetsExist', {
        'localIdentifiers': [localIdentifier],
      });
      if (result is List) return result.isNotEmpty;
    } catch (e) {
      print('[PhotoLibrary] 查询资产是否存在失败: $e');
    }
    return false;
  }

  /// 读取某个资产**当前**各资源的字节哈希（只读，不产生副作用）
  ///
  /// 往返验证的核心：恢复导入相册后拿副本的资源哈希与原图比对，
  /// 才能回答「恢复出来的 == 源文件吗」——包括 iOS 导入时是否重新编码、
  /// 是否剥离 EXIF 这类只有真走一遍才能发现的问题。
  ///
  /// [preferVideo] 为 true 时读 Live Photo 的配对视频，否则读主资源。
  static Future<AssetResourceHash?> hashAssetResources({
    required String localIdentifier,
    bool preferVideo = false,
  }) async {
    if (localIdentifier.isEmpty) return null;
    try {
      final result = await _channel.invokeMethod('hashAssetResources', {
        'localIdentifier': localIdentifier,
        'preferVideo': preferVideo,
      });
      if (result is Map) {
        return AssetResourceHash.fromMap(Map<String, dynamic>.from(result));
      }
    } on PlatformException catch (e) {
      print('[PhotoLibrary] 读取资源哈希失败(PlatformException): ${e.message}');
    } catch (e) {
      print('[PhotoLibrary] 读取资源哈希失败: $e');
    }
    return null;
  }

  /// 删除相册中的资产（**仅用于清理往返验证创建的副本**）
///
/// ## 这是本App 最危险的能力
/// 它能删除用户真实的照片，因此口子刻意做窄：
///   · 底层强制要求 confirm=true，否则直接拒绝
///   · 只接受调用方给出的 ID 列表，不做任何"顺便清理"
///   · 返回每个 ID 的成功/失败数，UI 必须如实展示
///
/// 正常使用：清掉本次验证创建的副本，保持相册干净。
/// 绝不应用于删除用户原有照片。
static Future<({int deleted, int failed, String? error})> deleteAssets(
  List<String> localIdentifiers,
) async {
  if (localIdentifiers.isEmpty) {
    return (deleted: 0, failed: 0, error: '没有要删除的资产 ID');
  }
  try {
    final result = await _channel.invokeMethod('deleteAssets', {
      'localIdentifiers': localIdentifiers,
      // 硬编码 true —— 调用方无法通过参数关掉这个保护
      'confirm': true,
    });
    if (result is Map) {
      final err = result['error'] as String?;
      if (err != null) {
        return (
          deleted: (result['deleted'] as num?)?.toInt() ?? 0,
          failed: (result['failed'] as num?)?.toInt() ?? 0,
          error: err
        );
      }
      return (
        deleted: (result['deleted'] as num?)?.toInt() ?? 0,
        failed: (result['failed'] as num?)?.toInt() ?? 0,
        error: null
      );
    }
    return (deleted: 0, failed: localIdentifiers.length, error: '原生返回格式异常');
  } on PlatformException catch (e) {
    return (deleted: 0, failed: localIdentifiers.length, error: e.message);
  } catch (e) {
    return (deleted: 0, failed: localIdentifiers.length, error: '$e');
  }
}

/// 写入照片的结果
class SaveWithExtrasResult {
  const SaveWithExtrasResult({
    required this.assetId,
    this.written = 0,
    this.failed = 0,
    this.warning,
    this.error,
  });

  /// 新资产的 localIdentifier（失败时为空串）
  final String assetId;

  /// 实际挂上去的附加资源数
  final int written;

  /// 被相册拒收的附加资源数
  final int failed;

  /// 部分降级时的说明（例如编辑指令未被接受）
  final String? warning;

  /// 完全失败的原因
  final String? error;

  bool get ok => assetId.isNotEmpty;
}

/// 写入照片到相册，并**把附加资源一起挂上去**（GAP-R1 / GAP-R2）
///
/// [extras] 里每一项是 `{restoreType, path}`：
///   · main 文件用 `.photo` 写入（最稳的路径）
///   · RAW 原图按 restoreType 映射成对应资源类型一并写入
///   · 编辑指令（.plist / .aae）iOS 没有公开的枚举成员，很可能被拒 ——
///     原生会逐级降级重试，绝不让「风格」拖累「原图」
///
/// 完全失败返回 [SaveWithExtrasResult] 里 `ok == false`。
static Future<SaveWithExtrasResult> savePhotoWithExtras({
  required String filePath,
  required double creationTimestamp,
  List<Map<String, String>> extras = const [],
}) async {
  try {
    final raw = await _channel.invokeMethod('savePhotoWithExtras', {
      'filePath': filePath,
      'creationDate': creationTimestamp * 1000,
      if (extras.isNotEmpty) 'extraResources': extras,
    });
    if (raw is String) {
      // 旧版原生只返回路径字符串
      return SaveWithExtrasResult(
        assetId: raw.isNotEmpty ? raw : '',
        error: raw.isEmpty ? '原生返回空结果' : null,
      );
    }
    if (raw is Map) {
      return SaveWithExtrasResult(
        assetId: '${raw['id'] ?? ''}',
        written: (raw['written'] as num?)?.toInt() ?? 0,
        failed: (raw['failed'] as num?)?.toInt() ?? 0,
        warning: raw['warning'] as String?,
        error: raw['error'] as String?,
      );
    }
    return const SaveWithExtrasResult(assetId: '', error: '原生返回格式异常');
  } on PlatformException catch (e) {
    return SaveWithExtrasResult(assetId: '', error: e.message ?? '$e');
  } catch (e) {
    return SaveWithExtrasResult(assetId: '', error: '$e');
  }
}

/// 获取照片资源信息（通过原生通道）
  static Future<List<Map<String, dynamic>>> fetchAllAssets() async {
    try {
      final result = await _channel.invokeMethod('fetchAllAssets');
      if (result is List) {
        return result.cast<Map<dynamic, dynamic>>().map((e) {
          return Map<String, dynamic>.from(e);
        }).toList();
      }
      return [];
    } catch (e) {
      // 如果原生通道未实现，返回空列表
      return [];
    }
  }

  /// 导出照片数据到文件
  /// [localIdentifier] 照片唯一标识
  /// [targetPath] 目标文件路径（扩展名仅作占位，最终以原生写入的为准）
  /// [isNetworkAccessAllowed] 是否允许下载 iCloud 原片
  ///
  /// 返回实际写入的文件路径（原生按资源真实类型推导扩展名），失败返回 null
  static Future<ExportResult?> exportPhotoAsset({
    required String localIdentifier,
    required String targetPath,
    bool isNetworkAccessAllowed = true,
  }) async {
    try {
      final result = await _channel.invokeMethod('exportPhotoAsset', {
        'localIdentifier': localIdentifier,
        'targetPath': targetPath,
        'isNetworkAccessAllowed': isNetworkAccessAllowed,
      });
      return ExportResult.fromChannel(result, targetPath);
    } catch (e) {
      return null;
    }
  }

  /// 导出视频资源到文件
  static Future<ExportResult?> exportVideoAsset({
    required String localIdentifier,
    required String targetPath,
    bool isNetworkAccessAllowed = true,
  }) async {
    try {
      final result = await _channel.invokeMethod('exportVideoAsset', {
        'localIdentifier': localIdentifier,
        'targetPath': targetPath,
        'isNetworkAccessAllowed': isNetworkAccessAllowed,
      });
      return ExportResult.fromChannel(result, targetPath);
    } catch (e) {
      return null;
    }
  }

  /// 导出 Live Photo 的配对视频
  static Future<ExportResult?> exportLivePhotoVideo({
    required String localIdentifier,
    required String targetPath,
  }) async {
    try {
      final result = await _channel.invokeMethod('exportLivePhotoVideo', {
        'localIdentifier': localIdentifier,
        'targetPath': targetPath,
      });
      return ExportResult.fromChannel(result, targetPath);
    } catch (e) {
      return null;
    }
  }

  /// 将照片写入系统相册
  /// [filePath] 照片文件路径
  /// [creationDate] 原始拍摄时间
  ///
  /// 返回新资产的 localIdentifier（用于追踪「导入的这张还在不在相册」），失败返回 null
  static Future<String?> savePhotoToLibrary({
    required String filePath,
    required double creationTimestamp,
  }) async {
    try {
      final result = await _channel.invokeMethod('savePhotoToLibrary', {
        'filePath': filePath,
        // 原生侧按毫秒解析；这里传 Double 以保留亚秒精度，避免同秒照片顺序错乱
        'creationDate': creationTimestamp * 1000,
      });
      if (result is String) {
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 将视频写入系统相册
  ///
  /// 返回新资产的 localIdentifier，失败返回 null
  static Future<String?> saveVideoToLibrary({
    required String filePath,
    required double creationTimestamp,
  }) async {
    try {
      final result = await _channel.invokeMethod('saveVideoToLibrary', {
        'filePath': filePath,
        'creationDate': creationTimestamp * 1000,
      });
      if (result is String) {
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 将 Live Photo（图片+视频）写入系统相册
  ///
  /// 返回新资产的 localIdentifier，失败返回 null
  static Future<String?> saveLivePhotoToLibrary({
    required String photoPath,
    required String videoPath,
    required double creationTimestamp,
  }) async {
    try {
      final result = await _channel.invokeMethod('saveLivePhotoToLibrary', {
        'photoPath': photoPath,
        'videoPath': videoPath,
        'creationDate': creationTimestamp * 1000,
      });
      if (result is String) {
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

  /// 导出结果：文件路径 + 内容哈希 + 资源构成
///
/// 这是**端到端校验**的基础：[sha256] 是原生侧在把资源写盘时**顺手**算出的
/// 「原图字节哈希」，与接收端对落盘字节算出的哈希是两个独立来源。
/// 两者一致才能证明「从原图到磁盘」没出错——只靠接收端自己算的哈希不行，
/// 那样只能证明传输没损坏，证明不了导出内容就是原图。
class ExportResult {
  const ExportResult({
    required this.path,
    required this.sha256,
    required this.bytes,
    required this.resourceTotal,
    required this.resourcePrimary,
    required this.resourceAuxiliary,
    this.extraResources = const [],
  });

  final String path;

  /// 原图资源的 SHA256（空串 = 原生没给，做不了端到端校验）
  final String sha256;
  final int bytes;

  /// 原图该资产共有几个 PHAssetResource
  final int resourceTotal;

  /// 备份了的主资源类型（照片/视频/配对视频…）
  final List<String> resourcePrimary;

  /// 原图里存在但**没有备份**的辅助资源类型
  /// （ProRAW 的第二份、深度图、HDR 增益图、海报…）
  final List<String> resourceAuxiliary;

  /// 主文件之外已导出的资源（GAP-R1 / GAP-R2）
  ///
  /// 实测一个开了「风格」的 ProRAW 资产有 4 个资源，主文件只是其中之一：
  /// RAW 原图（DNG）、Adjustments.plist（风格记录）、.aae（编辑数据）都在这里。
  final List<ExportedResource> extraResources;

  /// 实际备份了几个文件：主文件 + 附加资源
  int get backedResourceCount => 1 + extraResources.length;

  /// 资源完整度：备份了几个 / 原图共几个
  ///
  /// > 1 说明原图有多个资源而我们只导出了一个 —— 这就是 GAP-R1 的暴露方式。

  bool get isComplete => resourceTotal > 0 && backedResourceCount >= resourceTotal;

  /// 从原生返回的 Map 解析。兼容旧版只返回路径字符串的情况。
  static ExportResult? fromChannel(Object? raw, String? fallbackPath) {
    if (raw is String) {
      // 旧版原生：只返回路径，没有哈希也没有资源信息
      return ExportResult(
        path: raw.isNotEmpty ? raw : (fallbackPath ?? ''),
        sha256: '',
        bytes: 0,
        resourceTotal: 0,
        resourcePrimary: const [],
        resourceAuxiliary: const [],
      );
    }
    if (raw is! Map) return null;
    final path = (raw['path'] as String?) ?? fallbackPath ?? '';
    if (path.isEmpty) return null;

    List<String> splitList(Object? v) {
      if (v is List) return v.map((e) => '$e').toList();
      // 原生用 '|' 传列表（HTTP header 里逗号会被当分隔符）
      if (v is String && v.isNotEmpty) return v.split('|');
      return const [];
    }

    final extras = <ExportedResource>[];
    final rawExtras = raw['extraResources'];
    if (rawExtras is List) {
      for (final item in rawExtras) {
        if (item is Map) {
          extras.add(ExportedResource(
            role: '${item['role'] ?? 'alternate'}',
            path: '${item['path'] ?? ''}',
            sha256: '${item['sha256'] ?? ''}',
            bytes: (item['bytes'] as num?)?.toInt() ?? 0,
            uti: '${item['uti'] ?? ''}',
            filename: '${item['filename'] ?? ''}',
          ));
        }
      }
    }

    return ExportResult(
      path: path,
      sha256: (raw['sha256'] as String?) ?? '',
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      resourceTotal: (raw['total'] as num?)?.toInt() ?? 0,
      resourcePrimary: splitList(raw['primary']),
      resourceAuxiliary: splitList(raw['auxiliary']),
      extraResources: extras,
    );
  }
}

/// 某个资产当前资源的字节哈希（往返验证用）
///
/// 由原生侧在**不写入任何东西**的前提下算出：走
/// `PHAssetResourceManager.requestData` 把资源字节读一遍，边读边算 SHA256。
class AssetResourceHash {
  const AssetResourceHash({
    required this.sha256,
    required this.bytes,
    required this.uti,
    required this.filename,
    required this.resourceCount,
    required this.resourceSummary,
  });

  /// 资源原始字节的 SHA-256
  final String sha256;
  final int bytes;
  final String uti;
  final String filename;

  /// 该资产共有几个 PHAssetResource
  final int resourceCount;

  /// {total, primary, auxiliary} —— 用于资源完整度核对
  final Map<String, dynamic> resourceSummary;

  /// 辅助资源（ProRAW 第二份/深度图/增益图）是否未备份
  List<String> get unbackedAuxiliary {
    final aux = resourceSummary['auxiliary'];
    if (aux is List) return aux.map((e) => '$e').toList();
    return const [];
  }

  static AssetResourceHash fromMap(Map<String, dynamic> m) {
    final summary = <String, dynamic>{};
    final rawSummary = m['resourceSummary'];
    if (rawSummary is Map) {
      summary.addAll(Map<String, dynamic>.from(rawSummary));
    }
    return AssetResourceHash(
      sha256: (m['sha256'] as String?) ?? '',
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      uti: (m['uti'] as String?) ?? '',
      filename: (m['filename'] as String?) ?? '',
      resourceCount: (m['resourceCount'] as num?)?.toInt() ?? 0,
      resourceSummary: summary,
    );
  }
}

/// 原生导出时顺带导出的一个附加资源
///
/// 属于「资源导出结果」的一部分：主文件之外的那些资源（RAW 原图、
/// Adjustments.plist、.aae…），GAP-R1/R2 要求它们一起备份与恢复。
class ExportedResource {
  const ExportedResource({
    required this.role,
    required this.path,
    required this.sha256,
    required this.bytes,
    required this.uti,
    required this.filename,
  });

  /// raw / adjustment / adjustmentAAE / alternate
  final String role;

  /// 沙盒里的临时文件路径
  final String path;
  final String sha256;
  final int bytes;
  final String uti;

  /// iOS 里的原始文件名（如 IMG_6550.DNG）
  final String filename;

  /// 扩展名（含点），用于生成电脑端文件名
  String get extension {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i);
  }
}