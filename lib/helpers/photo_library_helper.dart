import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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
  /// 直接丢弃，表现为 `No route to host, errno = 65`。
  /// 这里双管齐下：原生 Bonjour 浏览（主）+ Dart 侧 mDNS 探测包（兜底）。
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

  /// 获取所有照片资源信息（通过原生通道）
  /// 返回 List<Map>，包含 localIdentifier, creationDate, mediaType, isLivePhoto
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
  static Future<String?> exportPhotoAsset({
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
      if (result is String) {
        return result;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 导出视频资源到文件
  static Future<bool> exportVideoAsset({
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
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// 导出 Live Photo 的配对视频
  static Future<bool> exportLivePhotoVideo({
    required String localIdentifier,
    required String targetPath,
  }) async {
    try {
      final result = await _channel.invokeMethod('exportLivePhotoVideo', {
        'localIdentifier': localIdentifier,
        'targetPath': targetPath,
      });
      return result == true;
    } catch (e) {
      return false;
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
