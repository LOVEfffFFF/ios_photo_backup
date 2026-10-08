import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';
import 'record_store.dart';

/// 备份进度信息
class BackupProgress {
  final int completed;
  final int total;
  final double percentage;
  final String? currentFile;
  final String? error;

  /// 致命错误：整批备份无法继续（未配置服务器、连不上、无权限等），
  /// UI 应据此结束操作状态。单张文件失败只会是 false，备份继续跑。
  final bool fatal;

  /// 本次累计上传的字节数
  final int uploadedBytes;

  /// 需要写进操作日志的详细信息
  ///
  /// 与 [currentFile] 的区别：currentFile 只刷新进度条文字，
  /// 而 logMessage 会往日志框里追加一条记录（逐文件的结果都在这里）。
  final String? logMessage;

  BackupProgress({
    required this.completed,
    required this.total,
    required this.percentage,
    this.currentFile,
    this.error,
    this.fatal = false,
    this.uploadedBytes = 0,
    this.logMessage,
  });
}

/// 核心备份管理器
///
/// 流程：扫描相册 → 过滤已备份 → 逐个「导出到暂存目录 → 上传到电脑 → 删除暂存」。
/// 手机本地不再长期保留备份文件，因此不会出现「备份 N GB 需要额外 N GB 空间」。
class BackupManager {
  final RecordStore _recordStore = RecordStore();
  bool _isRunning = false;
  bool _isCancelled = false;

  /// 每积累这么多条记录批量刷盘一次（NDJSON 追加写，成本很低）
  static const int _recordFlushThreshold = 50;

  /// 进度回调的最小间隔，避免每张都刷新 UI
  static const Duration _progressInterval = Duration(milliseconds: 300);

  bool get isRunning => _isRunning;

  /// 开始备份（增量）
  ///
  /// [limit] 本次最多处理的资产数量，0 表示不限制。
  /// 主要用于测试：不想一次性把整个相册传完时设一个小值。
  Stream<BackupProgress> startBackup({int limit = 0}) async* {
    if (_isRunning) {
      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '备份正在进行中',
        fatal: true,
      );
      return;
    }

    _isRunning = true;
    _isCancelled = false;

    final pendingRecords = <BackupRecord>[];
    var uploadedBytes = 0;

    try {
      // 1. 服务器配置
      final config = await ServerConfig.load();
      if (!config.isConfigured) {
        yield BackupProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '尚未配置备份服务器地址，请先在上方「服务器设置」里填写并保存',
          fatal: true,
        );
        return;
      }

      final client = ServerClient(config);

      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '正在连接 ${config.displayAddress} ...',
        logMessage: '开始备份 → ${config.baseUrl}',
      );

      final connError = await client.testConnection();
      if (connError != null) {
        yield BackupProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: connError,
          fatal: true,
        );
        return;
      }

      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '服务器连接正常',
        logMessage: '服务器连接正常（${config.displayAddress}）',
      );

      // 2. 清理上次异常退出遗留的暂存文件
      final cleaned = await FileHelper.cleanUploadTemp();
      if (cleaned > 0) {
        print('[BackupManager] 已清理上次残留的暂存文件 $cleaned 个');
      }

      // 3. 扫描相册
      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '正在扫描相册...',
        logMessage: '正在扫描相册...',
      );

      final assets = await PhotoLibraryHelper.fetchAllAssets();
      if (assets.isEmpty) {
        yield BackupProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '未找到任何照片，或未授予相册访问权限',
          fatal: true,
        );
        return;
      }

      // 4. 过滤已备份的资产
      final backedRecords = await _recordStore.loadAllRecords();
      final backedIds = backedRecords.map((r) => r.localIdentifier).toSet();
      var unbacked = assets
          .where((a) => !backedIds.contains(a['localIdentifier'] as String))
          .toList();

      final remaining = unbacked.length;
      if (remaining == 0) {
        yield BackupProgress(
          completed: 0,
          total: assets.length,
          percentage: 100,
          currentFile: '所有照片均已备份，无需重复传输',
          logMessage:
              '相册共 ${assets.length} 个资产，全部已备份（本地记录 ${backedRecords.length} 条）',
        );
        return;
      }

      // 单次数量上限（0 = 不限制）：只影响这一次，没传完的下次继续
      if (limit > 0 && unbacked.length > limit) {
        unbacked = unbacked.take(limit).toList();
      }

      final total = unbacked.length;
      yield BackupProgress(
        completed: 0,
        total: total,
        percentage: 0,
        currentFile: limit > 0 && remaining > total
            ? '本次上限 $total 个（共 $remaining 个待备份），开始传输...'
            : '待备份 $total 个，开始传输...',
        logMessage: '相册共 ${assets.length} 个资产｜已备份 ${assets.length - remaining} 个｜'
            '本次待传 $total 个${remaining > total ? '（另有 ${remaining - total} 个留待下次）' : ''}',
      );

      // 5. 逐个导出并上传
      final tempDir = await FileHelper.getUploadTempDirectory();
      var completed = 0;
      var failed = 0;
      var lastYieldAt = DateTime.now();

      for (final asset in unbacked) {
        if (_isCancelled) {
          await _flushRecords(pendingRecords);
          yield BackupProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: '已取消，已完成 $completed 个',
            uploadedBytes: uploadedBytes,
          );
          return;
        }

        final localId = asset['localIdentifier'] as String;
        final creationSeconds = asset['creationDate'] as num;
        // 保留亚秒精度：相册里的先后顺序靠它还原
        final creationTimestamp = creationSeconds.toDouble();
        final creationDate = DateTime.fromMillisecondsSinceEpoch(
          (creationSeconds * 1000).toInt(),
        );
        final mediaType = asset['mediaType'] as String;
        final isLivePhoto = asset['isLivePhoto'] as bool? ?? false;

        var bytesThisAsset = 0;
        String? failure;
        final assetStopwatch = Stopwatch()..start();

        try {
          if (mediaType == 'video') {
            bytesThisAsset = await _exportAndUploadVideo(
              client: client,
              tempDir: tempDir,
              localIdentifier: localId,
              creationDate: creationDate,
              creationTimestamp: creationTimestamp,
              pendingRecords: pendingRecords,
            );
          } else if (mediaType == 'image') {
            bytesThisAsset = await _exportAndUploadPhoto(
              client: client,
              tempDir: tempDir,
              localIdentifier: localId,
              creationDate: creationDate,
              creationTimestamp: creationTimestamp,
              isLivePhoto: isLivePhoto,
              pendingRecords: pendingRecords,
            );
          } else {
            // audio / unknown：直接跳过，避免进度永远到不了 100%
            print('[BackupManager] 跳过不支持的类型 $mediaType: $localId');
            failed++;
            failure = '不支持的类型 $mediaType';
          }
        } catch (e) {
          failed++;
          failure = '$e';
        }

        assetStopwatch.stop();

        if (bytesThisAsset > 0) {
          completed++;
          uploadedBytes += bytesThisAsset;
          // 每个文件一条日志：序号 / 文件名 / 类型 / 大小 / 耗时 / 服务器相对路径
          final lastRecord =
              pendingRecords.isNotEmpty ? pendingRecords.last : null;
          final doneName =
              lastRecord != null ? p.basename(lastRecord.relativePath) : localId;
          yield BackupProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: doneName,
            uploadedBytes: uploadedBytes,
            logMessage: '✅ [$completed/$total] $doneName'
                '｜${_mediaLabel(mediaType, isLivePhoto)}'
                '｜${_fmtBytes(bytesThisAsset)}'
                '｜${assetStopwatch.elapsedMilliseconds}ms'
                '｜${lastRecord?.relativePath ?? localId}',
          );
          lastYieldAt = DateTime.now();
        } else if (failure == null) {
          failed++;
          failure = '导出或上传未成功';
        }

        // 失败的也要能看到具体是哪一个
        if (failure != null) {
          yield BackupProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: localId,
            error: failure,
            uploadedBytes: uploadedBytes,
            logMessage:
                '❌ [$completed/$total] $localId —— $failure',
          );
          lastYieldAt = DateTime.now();
        }

        if (pendingRecords.length >= _recordFlushThreshold) {
          await _flushRecords(pendingRecords);
        }
      }

      // 6. 收尾
      await _flushRecords(pendingRecords);

      final summary = failed > 0
          ? '备份结束：成功 $completed 个，失败 $failed 个'
          : '备份完成：共传输 $completed 个文件';
      yield BackupProgress(
        completed: completed,
        total: total,
        percentage: 100,
        currentFile: summary,
        uploadedBytes: uploadedBytes,
        logMessage: '📊 $summary｜累计传输 ${_fmtBytes(uploadedBytes)}'
            '${limit > 0 ? '｜本次上限 $limit 个' : ''}'
            '${remaining > total ? '｜另有 ${remaining - total} 个留待下次' : ''}',
      );
    } catch (e) {
      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '备份过程出错: $e',
        fatal: true,
      );
    } finally {
      // 兜底：把已成功的记录落盘，避免重复传输
      await _flushRecords(pendingRecords);
      _isRunning = false;
    }
  }

  /// 导出照片（含 Live Photo 配对视频）并上传，返回上传字节数
  Future<int> _exportAndUploadPhoto({
    required ServerClient client,
    required Directory tempDir,
    required String localIdentifier,
    required DateTime creationDate,
    required double creationTimestamp,
    required bool isLivePhoto,
    required List<BackupRecord> pendingRecords,
  }) async {
    // 扩展名只是占位，原生会按资源真实类型写入并返回实际路径
    final placeholder =
        FileHelper.generateFileName(creationDate, localIdentifier, 'jpg');
    final tempPath = p.join(tempDir.path, placeholder);

    final actualPath = await PhotoLibraryHelper.exportPhotoAsset(
      localIdentifier: localIdentifier,
      targetPath: tempPath,
    );
    if (actualPath == null) {
      throw Exception('照片导出失败');
    }

    final photoFile = File(actualPath);
    if (!await photoFile.exists()) {
      throw Exception('导出文件不存在');
    }

    final serverPath = FileHelper.buildServerPath(
      creationDate,
      p.basename(actualPath),
    );
    final photoBytes = await photoFile.length();

    try {
      final result = await client.uploadFile(
        file: photoFile,
        relativePath: serverPath,
        assetId: localIdentifier,
        pairKey: localIdentifier,
        role: 'main',
        mediaType: isLivePhoto ? 'live_photo' : 'image',
        creationTimestamp: creationTimestamp,
      );
      if (!result.success) {
        throw Exception(result.message ?? '上传失败');
      }
    } finally {
      // 无论成功失败都删除暂存文件，手机不长期占用空间
      await _safeDelete(photoFile);
    }

    // Live Photo 的配对视频
    var videoBytes = 0;
    String? videoServerPath;
    if (isLivePhoto) {
      final videoPlaceholder = FileHelper.generateFileName(
        creationDate,
        '${localIdentifier}_live',
        'mov',
      );
      final videoTempPath = p.join(tempDir.path, videoPlaceholder);

      final exported = await PhotoLibraryHelper.exportLivePhotoVideo(
        localIdentifier: localIdentifier,
        targetPath: videoTempPath,
      );

      if (exported) {
        final videoFile = File(videoTempPath);
        if (await videoFile.exists()) {
          videoServerPath = FileHelper.buildServerPath(
            creationDate,
            p.basename(videoTempPath),
          );
          try {
            final videoResult = await client.uploadFile(
              file: videoFile,
              relativePath: videoServerPath,
              assetId: localIdentifier,
              pairKey: localIdentifier,
              role: 'pairedVideo',
              mediaType: 'video',
              creationTimestamp: creationTimestamp,
            );
            if (videoResult.success) {
              videoBytes = await videoFile.length();
            } else {
              // 配对视频失败不阻断照片本身，降级为普通照片
              videoServerPath = null;
              print('[BackupManager] 配对视频上传失败: ${videoResult.message}');
            }
          } finally {
            await _safeDelete(videoFile);
          }
        }
      }
    }

    pendingRecords.add(
      BackupRecord(
        localIdentifier: localIdentifier,
        relativePath: serverPath,
        creationDate: creationDate,
        creationTimestamp: creationTimestamp,
        mediaType: isLivePhoto && videoServerPath != null
            ? 'live_photo'
            : 'image',
        livePhotoVideoRelativePath: videoServerPath,
      ),
    );

    return photoBytes + videoBytes;
  }

  /// 导出视频并上传，返回上传字节数
  Future<int> _exportAndUploadVideo({
    required ServerClient client,
    required Directory tempDir,
    required String localIdentifier,
    required DateTime creationDate,
    required double creationTimestamp,
    required List<BackupRecord> pendingRecords,
  }) async {
    final fileName =
        FileHelper.generateFileName(creationDate, localIdentifier, 'mov');
    final tempPath = p.join(tempDir.path, fileName);

    final exported = await PhotoLibraryHelper.exportVideoAsset(
      localIdentifier: localIdentifier,
      targetPath: tempPath,
    );
    if (!exported) {
      throw Exception('视频导出失败');
    }

    final videoFile = File(tempPath);
    if (!await videoFile.exists()) {
      throw Exception('导出文件不存在');
    }

    final serverPath = FileHelper.buildServerPath(creationDate, fileName);
    final bytes = await videoFile.length();

    try {
      final result = await client.uploadFile(
        file: videoFile,
        relativePath: serverPath,
        assetId: localIdentifier,
        pairKey: localIdentifier,
        role: 'main',
        mediaType: 'video',
        creationTimestamp: creationTimestamp,
      );
      if (!result.success) {
        throw Exception(result.message ?? '上传失败');
      }
    } finally {
      await _safeDelete(videoFile);
    }

    pendingRecords.add(
      BackupRecord(
        localIdentifier: localIdentifier,
        relativePath: serverPath,
        creationDate: creationDate,
        creationTimestamp: creationTimestamp,
        mediaType: 'video',
      ),
    );

    return bytes;
  }

  /// 批量落盘（失败时保留待写记录，下次继续尝试）
  Future<void> _flushRecords(List<BackupRecord> pending) async {
    if (pending.isEmpty) {
      return;
    }
    try {
      await _recordStore.appendRecords(List<BackupRecord>.from(pending));
      pending.clear();
    } catch (e) {
      print('[BackupManager] 记录落盘失败，稍后重试: $e');
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('[BackupManager] 暂存文件删除失败: $e');
    }
  }

  /// 取消备份
  void cancel() {
    _isCancelled = true;
  }

  /// 清空本机的备份记录（不影响服务器设置，也不动电脑上的文件）
  ///
  /// 重置后下次备份会重新核对全部照片；电脑上已存在的文件会被接收端
  /// 按「同名同大小」识别并跳过，因此不会重复占用空间、也不会真的重传。
  Future<void> resetRecords() async {
    await _recordStore.clearAllRecords();
  }

  /// 获取备份统计信息
  Future<Map<String, int>> getBackupStats() async {
    final records = await _recordStore.loadAllRecords();
    int photos = 0;
    int videos = 0;
    int livePhotos = 0;

    for (final r in records) {
      switch (r.mediaType) {
        case 'image':
        case 'photo':
          photos++;
          break;
        case 'video':
          videos++;
          break;
        case 'live_photo':
          livePhotos++;
          break;
      }
    }

    return {
      'total': records.length,
      'photos': photos,
      'videos': videos,
      'livePhotos': livePhotos,
    };
  }
}

/// 字节数格式化（仅用于日志显示）
String _fmtBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}

/// 媒体类型的中文标签（仅用于日志显示）
String _mediaLabel(String mediaType, bool isLivePhoto) {
  if (isLivePhoto) {
    return '实况照片';
  }
  switch (mediaType) {
    case 'video':
      return '视频';
    case 'image':
    case 'photo':
      return '照片';
    default:
      return mediaType;
  }
}
