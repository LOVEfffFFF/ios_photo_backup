import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import '../services/log_service.dart';
import '../services/manifest_index.dart';
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
            //
            // ## limit 的语义：**关注窗口**，不是「分批推进」
            //
            // limit > 0 时只关心「拍摄时间最新的 N 个」，窗口内的传完后，
            // 再点备份会显示"窗口内全部已备份"而**不会**继续往更老的传。
            // 想继续备份更老的照片，调大 limit 或填 0（不限制）即可。
            //
            // ## 已备份的判定依据：**设备无关的资产指纹**（拍摄时间 + 类型 + 像素尺寸）
            //
            // 而不是 localIdentifier —— 后者换设备/重装后全变，会导致：
            //   · 沙盒一丢→ 认不出已备份 → 全量重传（实测浪费 148MB）
            //   · 换设备 → 认不出已恢复 → 恢复时产生大量重复
            //
            // 两级判断：
            //   ① 先用本地记录的 localIdentifier 快速过滤（同一设备上最准、零开销）
            //   ② 仍有疑似未备份的，才去问电脑上的清单（manifest.jsonl）核对
            //      —— 沙盒丢失后本地 ID 全失效，这一步才是真正的兜底
            // 清单拿不到时（连不上 /旧版接收端没有该接口）自动退化为只看本地记录。

            // 先划定关注窗口：最新 N 个（assets 已按拍摄时间从新到旧排序）
            final window = (limit > 0 && assets.length > limit)
                ? assets.take(limit).toList(growable: false)
                : assets;
            final outsideCount = assets.length - window.length;

            final backedRecords = await _recordStore.loadAllRecords();
            final backedIds = backedRecords.map((r) => r.localIdentifier).toSet();
            var unbacked =
                window.where((a) => !backedIds.contains(a['localIdentifier'] as String))
                    .toList();

            // 只有确实还有东西要传时才拉清单，避免每次点备份都白拉一次
            ManifestIndex? manifest;
            if (unbacked.isNotEmpty) {
              manifest = await ManifestIndex.fetch(client);
            }
            if (manifest != null && !manifest.isEmpty) {
              final localPrints = <String>{
                for (final r in backedRecords) AssetFingerprint.fromRecord(r).key,
                // 旧记录没有宽高字段时会生成 '?x?' 的退化键，与本机带宽高的指纹
                // 不相等；再补一份宽松键，保证「宁可多传一次也不漏传」
                for (final r in backedRecords)
                  AssetFingerprint.fromRecord(r).looseKey,
              };
              final manifestPrints = <String>{
                ...manifest.fingerprintKeys,
                ...manifest.looseFingerprintKeys,
              };

              unbacked = unbacked.where((a) {
                final isLive = a['isLivePhoto'] as bool? ?? false;
                final fp = AssetFingerprint.fromAsset(a, isLivePhoto: isLive);
                if (localPrints.contains(fp.key) ||
                    manifestPrints.contains(fp.key)) {
                  return false;
                }
                // 指纹退化（清单里是 Backfill 数据、没有宽高）时用宽松键兜底
                return !(localPrints.contains(fp.looseKey) ||
                    manifestPrints.contains(fp.looseKey));
              }).toList();
            }

            final total = unbacked.length;
            final windowBacked = window.length - total;

            if (total == 0) {
              yield BackupProgress(
                completed: 0,
                total: window.length,
                percentage: 100,
                currentFile: limit > 0
                    ? '最新 $limit 个已全部备份'
                    : '所有照片均已备份，无需重复传输',
                logMessage: limit > 0
                    ? '关注窗口：最新 $limit 个资产，其中已备份 $windowBacked 个，无需再传'
                        '${outsideCount > 0 ? '｜窗口外还有 $outsideCount 个（调大上限或留空可继续备份）' : ''}'
                        '${manifest != null && !manifest.isEmpty ? '｜电脑清单已核对 ${manifest.assetCount} 个资产' : ''}'
                    : '相册共 ${assets.length} 个资产，全部已备份'
                        '（本地记录 ${backedRecords.length} 条'
                        '${manifest != null && !manifest.isEmpty ? '、电脑清单 ${manifest.assetCount} 个资产' : '、电脑清单不可用'}）',
              );
              return;
            }

            yield BackupProgress(
              completed: 0,
              total: total,
              percentage: 0,
              currentFile: limit > 0
                  ? '最新 $limit 个里还有 $total 个未备份，开始传输...'
                  : '待备份 $total 个，开始传输...',
              logMessage: limit > 0
                  ? '关注窗口：最新 $limit 个资产（相册共 ${assets.length} 个）｜'
                      '窗口内已备份 $windowBacked 个｜本次待传 $total 个'
                      '${outsideCount > 0 ? '｜窗口外还有 $outsideCount 个，调大上限或留空可继续备份' : ''}'
                      '${manifest != null && !manifest.isEmpty ? '｜电脑清单已核对 ${manifest.assetCount} 个资产' : '｜电脑清单不可用，仅凭本地记录判断'}'
                  : '相册共 ${assets.length} 个资产｜已备份 $windowBacked 个｜本次待传 $total 个'
                      '${manifest != null && !manifest.isEmpty ? '｜电脑清单已核对 ${manifest.assetCount} 个资产' : '｜电脑清单不可用，仅凭本地记录判断'}',
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
        // 像素宽高：设备无关指纹的要素之一，随元数据一起发给电脑端记账
        final pixelWidth = (asset['pixelWidth'] as num?)?.toInt();
        final pixelHeight = (asset['pixelHeight'] as num?)?.toInt();

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
              pixelWidth: pixelWidth,
              pixelHeight: pixelHeight,
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
              pixelWidth: pixelWidth,
              pixelHeight: pixelHeight,
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
            '${limit > 0 ? '｜关注窗口：最新 $limit 个，已全部备份（不会往更老的传）' : ''}'
            '${outsideCount > 0 ? '｜窗口外还有 $outsideCount 个未备份，调大上限或留空可继续' : ''}',
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
    required int? pixelWidth,
    required int? pixelHeight,
    required List<BackupRecord> pendingRecords,
  }) async {
    // 扩展名只是占位，原生会按资源真实类型写入并返回实际路径
    final placeholder =
        FileHelper.generateFileName(creationDate, localIdentifier, 'jpg');
    final tempPath = p.join(tempDir.path, placeholder);

    final exportResult = await PhotoLibraryHelper.exportPhotoAsset(
      localIdentifier: localIdentifier,
      targetPath: tempPath,
    );
    if (exportResult == null) {
      throw Exception('照片导出失败');
    }
    final actualPath = exportResult.path;

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
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        // 端到端校验：把「原图侧」的哈希与资源构成一起发上去。
        // 接收端会拿它与落盘字节的哈希比对，这是唯一能证明
        // 「备份内容 == 手机原图」的检查。
        contentSha256: exportResult.sha256,
        resourceTotal: exportResult.resourceTotal,
        resourcePrimary: exportResult.resourcePrimary,
        resourceAuxiliary: exportResult.resourceAuxiliary,
      );
      if (!result.success) {
        throw Exception(result.message ?? '上传失败');
      }

      // 资源完整度告警：原图有多个资源而我们只导出了一个（ProRAW 双份、
      // 深度图、增益图…）。这不是错误，但必须让用户知道备份不完整。
      if (!exportResult.isComplete) {
        LogService.instance.write(
          LogLevel.warn,
          'backup',
          '资源不完整：${p.basename(actualPath)} 原图共 ${exportResult.resourceTotal} 个资源，'
          '已备份主文件 1 个，未备份 ${exportResult.resourceAuxiliary.join(', ')}',
        );
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

      final videoExport = await PhotoLibraryHelper.exportLivePhotoVideo(
            localIdentifier: localIdentifier,
            targetPath: videoTempPath,
          );

          if (videoExport != null) {
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
              // 配对视频沿用照片的宽高：它与照片是同一个资产、同一尺寸，
                      // 指纹必须与主文件一致，否则会被当成两个不同资产
                      pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight,
                      contentSha256: videoExport.sha256,
                      resourceTotal: videoExport.resourceTotal,
                      resourcePrimary: videoExport.resourcePrimary,
                      resourceAuxiliary: videoExport.resourceAuxiliary,
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
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        contentSha256: exportResult.sha256,
        resourceTotal: exportResult.resourceTotal,
        resourcePrimary: exportResult.resourcePrimary,
        resourceAuxiliary: exportResult.resourceAuxiliary,
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
    required int? pixelWidth,
    required int? pixelHeight,
    required List<BackupRecord> pendingRecords,
  }) async {
    final fileName =
        FileHelper.generateFileName(creationDate, localIdentifier, 'mov');
    final tempPath = p.join(tempDir.path, fileName);

    final exportResult = await PhotoLibraryHelper.exportVideoAsset(
      localIdentifier: localIdentifier,
      targetPath: tempPath,
    );
    if (exportResult == null) {
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
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        contentSha256: exportResult.sha256,
        resourceTotal: exportResult.resourceTotal,
        resourcePrimary: exportResult.resourcePrimary,
        resourceAuxiliary: exportResult.resourceAuxiliary,
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
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        contentSha256: exportResult.sha256,
        resourceTotal: exportResult.resourceTotal,
        resourcePrimary: exportResult.resourcePrimary,
        resourceAuxiliary: exportResult.resourceAuxiliary,
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
