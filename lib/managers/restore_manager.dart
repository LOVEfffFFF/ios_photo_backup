import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import '../services/manifest_index.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';
import 'record_store.dart';

/// 恢复进度信息
class RestoreProgress {
  final int completed;
  final int total;
  final double percentage;
  final String? currentFile;
  final String? error;

  /// 致命错误：整批恢复无法继续（未配置、连不上、无记录），UI 据此结束操作
  final bool fatal;

  /// 本次累计下载的字节数
  final int downloadedBytes;

  /// 需要写进操作日志的详细信息（逐文件结果都在这里，null 表示仅刷新进度）
  final String? logMessage;

  RestoreProgress({
    required this.completed,
    required this.total,
    required this.percentage,
    this.currentFile,
    this.error,
    this.fatal = false,
    this.downloadedBytes = 0,
    this.logMessage,
  });
}

/// 单条恢复的结果
class _RestoreOutcome {
  /// 写入相册后得到的新资产 localIdentifier（拿不到则为 null）
  final String? newAssetId;

  /// 本条下载的字节数
  final int bytes;

  _RestoreOutcome(this.newAssetId, this.bytes);
}

/// 把电脑上的备份拉回手机相册
///
/// **判断「要不要恢复」依据的是相册当前的实际状态 + 资产指纹**，而不是设备 ID：
///
/// | 情况 | 处理 |
/// | --- | --- |
/// | 原照片还在相册里（ID 对得上） | 跳过 |
/// | 原照片还在，但 ID 对不上（换设备/重装） | 按**指纹**（拍摄时间+类型+尺寸）匹配，命中即跳过 |
/// | 原照片没了，但之前导入的那张还在 | 跳过 —— 避免重复导入 |
/// | 原照片没了，之前导入的那张也被删了 | **重新恢复** ✓ |
/// | 本地记录为空（沙盒丢失） | 从**电脑上的清单**重建记录后继续 |
///
/// 第 2、3 条依赖 `restore_state.json` 里记录的「导入后新资产的
/// localIdentifier」—— 因为导入产出的是**新资产**，用原照片的 ID
/// 判断不出「用户是不是把恢复出来的又删了」。
class RestoreManager {
  final RecordStore _recordStore = RecordStore();
  bool _isRunning = false;
  bool _isCancelled = false;

  /// 每积累这么多条就刷一次恢复状态
  static const int _stateFlushThreshold = 20;

  bool get isRunning => _isRunning;

  /// 开始从电脑恢复照片到系统相册
  Stream<RestoreProgress> startRestore() async* {
    if (_isRunning) {
      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '恢复正在进行中',
        fatal: true,
      );
      return;
    }

    _isRunning = true;
    _isCancelled = false;

    final restoredNow = <String, String>{};
    var downloadedBytes = 0;

    try {
      // 1. 服务器配置与连通性
      final config = await ServerConfig.load();
      if (!config.isConfigured) {
        yield RestoreProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '尚未配置备份服务器地址，请先在上方「服务器设置」里填写并保存',
          fatal: true,
        );
        return;
      }

      final client = ServerClient(config);

      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '正在连接 ${config.displayAddress} ...',
        logMessage: '开始恢复 ← ${config.baseUrl}',
      );

      final connError = await client.testConnection();
      if (connError != null) {
        yield RestoreProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: connError,
          fatal: true,
        );
        return;
      }

      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '服务器连接正常',
        logMessage: '服务器连接正常（${config.displayAddress}）',
      );

      // 2. 备份记录
      //
      // 优先用本地记录；本地为空（App 重装 / 沙盒被清）时，
      // 退回到「电脑上的清单」重建 —— 侧载场景下沙盒丢失是常态，
      // 不能因此就完全无法恢复。
      var records = await _recordStore.loadAllRecords();
      var rebuiltFromManifest = false;
      if (records.isEmpty) {
        final manifest = await ManifestIndex.fetch(client);
        if (manifest != null && !manifest.isEmpty) {
          records = manifest.toRecords();
          rebuiltFromManifest = true;
        }
      }
      if (records.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: rebuiltFromManifest
              ? '电脑清单里没有可恢复的条目'
              : '手机上没有备份记录，且无法从电脑获取清单（请确认接收端已启动、'
                  'App 与电脑在同一局域网，或先用新版 App 备份一次以生成清单）',
          fatal: true,
        );
        return;
      }

      // 3. 核对相册当前状态，决定哪些需要恢复
      final state = await _loadRestoreState();

      yield RestoreProgress(
        completed: 0,
        total: records.length,
        percentage: 0,
        currentFile: '正在核对相册状态...',
        logMessage: '备份记录 ${records.length} 条'
            '${rebuiltFromManifest ? '（来自电脑清单）' : ''}｜'
            '历史恢复记录 ${state.length} 条｜正在核对相册...',
      );

      final originalStillThere = await PhotoLibraryHelper.filterExistingAssets(
        records.map((r) => r.localIdentifier).toList(),
      );
      // 批量一次性问原生，避免在循环里逐条调用造成 N 次跨语言往返
      final restoredStillThere = await PhotoLibraryHelper.filterExistingAssets(
        state.values.where((v) => v.isNotEmpty).toList(),
      );

      // 指纹兜底：localIdentifier 换设备后必然全部失效，
      // 因此再按「拍摄时间 + 类型 + 尺寸」判断本机是否已经有这张照片。
      final localPrints = await _loadLibraryFingerprints();

      final pending = <BackupRecord>[];
      var skippedOriginal = 0;
      var skippedByPrint = 0;
      var skippedRestored = 0;

      for (final record in records) {
        if (originalStillThere.contains(record.localIdentifier)) {
          skippedOriginal++;
          continue;
        }
        // 原图还在，但 ID 对不上（换设备 / 重装系统）：用指纹确认
        final fp = AssetFingerprint.fromRecord(record);
        if (localPrints.contains(fp.key) ||
            (fp.pixelWidth == null && localPrints.contains(fp.looseKey))) {
          skippedByPrint++;
          continue;
        }
        final restoredAssetId = state[record.localIdentifier];
        if (restoredAssetId != null &&
            restoredAssetId.isNotEmpty &&
            restoredStillThere.contains(restoredAssetId)) {
          skippedRestored++;
          continue;
        }
        pending.add(record);
      }

      yield RestoreProgress(
        completed: 0,
        total: records.length,
        percentage: 0,
        currentFile: '待恢复 ${pending.length} 条',
        logMessage: '核对完成：原照片仍在相册 $skippedOriginal 条（跳过）｜'
            '指纹匹配到本机已有 $skippedByPrint 条（跳过）｜'
            '已导入且仍在相册 $skippedRestored 条（跳过）｜待恢复 ${pending.length} 条'
            '${rebuiltFromManifest ? '｜记录来自电脑清单' : ''}',
      );

      if (pending.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: records.length,
          percentage: 100,
          currentFile: '相册里该有的都还在，无需从电脑导入',
          logMessage: '无需导入：所有记录对应的照片当前都已在相册中',
        );
        return;
      }

      // 4. 逐条下载并写入相册（备份与恢复互斥运行，共用同一个暂存目录）
      final tempDir = await FileHelper.getUploadTempDirectory();
      var completed = 0;
      var failed = 0;
      final total = pending.length;
      // 记录每个时间戳已出现的次数，用于给同一时刻的照片分配微秒级偏移
      final timestampSeen = <String, int>{};

      for (final record in pending) {
        if (_isCancelled) {
          await _flushRestored(restoredNow);
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: '已取消，已恢复 $completed 个',
            downloadedBytes: downloadedBytes,
            logMessage: '恢复已取消：已完成 $completed 个',
          );
          return;
        }

        final stopwatch = Stopwatch()..start();
        _RestoreOutcome? outcome;
        String? failure;

        // 同一时间戳的多张照片，按备份记录里的先后顺序加微秒级偏移，
        // 保证恢复后它们在相册中的相对次序与原相册一致、且每次结果可复现
        final timestampKey = record.creationTimestamp.toStringAsFixed(6);
        final duplicateIndex = timestampSeen[timestampKey] ?? 0;
        timestampSeen[timestampKey] = duplicateIndex + 1;
        final effectiveTimestamp =
            record.creationTimestamp + duplicateIndex * 0.000001;

        try {
          outcome = await _restoreOne(
            client: client,
            tempDir: tempDir,
            record: record,
            effectiveTimestamp: effectiveTimestamp,
          );
          stopwatch.stop();

          if (outcome.newAssetId != null) {
            completed++;
            downloadedBytes += outcome.bytes;
            restoredNow[record.localIdentifier] = outcome.newAssetId!;
            if (restoredNow.length >= _stateFlushThreshold) {
              await _flushRestored(restoredNow);
            }
          } else {
            failed++;
            failure = '写入相册未成功';
          }
        } catch (e) {
          stopwatch.stop();
          failed++;
          failure = '$e';
        }

        final fileName = p.basename(record.relativePath);
        if (failure == null && outcome != null) {
          // 每个文件一条日志：序号 / 文件名 / 类型 / 大小 / 耗时 / 相对路径
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: fileName,
            downloadedBytes: downloadedBytes,
            logMessage: '✅ [$completed/$total] $fileName'
                '｜${_mediaLabel(record)}'
                '｜${_fmtBytes(outcome.bytes)}'
                '｜${stopwatch.elapsedMilliseconds}ms'
                '｜${record.relativePath}',
          );
        } else {
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: record.relativePath,
            error: failure,
            downloadedBytes: downloadedBytes,
            logMessage: '❌ [$completed/$total] $fileName —— $failure'
                '（${record.relativePath}）',
          );
        }
      }

      // 5. 收尾
      await _flushRestored(restoredNow);

      final summary = failed > 0
          ? '恢复结束：成功 $completed 个，失败 $failed 个'
          : '恢复完成：共导入 $completed 个到相册';
      yield RestoreProgress(
        completed: completed,
        total: total,
        percentage: 100,
        currentFile: summary,
        downloadedBytes: downloadedBytes,
        logMessage: '📊 $summary｜累计下载 ${_fmtBytes(downloadedBytes)}'
            '｜跳过：原图仍在相册 $skippedOriginal 条、已导入仍在 $skippedRestored 条',
      );
    } catch (e) {
      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '恢复过程出错: $e',
        fatal: true,
      );
    } finally {
      await _flushRestored(restoredNow);
      _isRunning = false;
    }
  }

  /// 恢复单条记录：下载（含 Live Photo 配对视频）→ 写入相册 → 清理暂存
  ///
  /// 返回写入相册产生的新资产 ID 与下载字节数；失败抛异常
  Future<_RestoreOutcome> _restoreOne({
    required ServerClient client,
    required Directory tempDir,
    required BackupRecord record,
    required double effectiveTimestamp,
  }) async {
    final mainName = p.basename(record.relativePath);
    final mainPath = p.join(tempDir.path, mainName);

    final mainBytes = await client.downloadFile(
      relativePath: record.relativePath,
      targetPath: mainPath,
    );
    if (mainBytes <= 0) {
      throw Exception('下载失败（电脑上可能已无此文件）');
    }

    var totalBytes = mainBytes;
    String? videoPath;

    try {
      // Live Photo 的配对视频
      if (record.mediaType == 'live_photo' &&
          record.livePhotoVideoRelativePath != null) {
        final videoName = p.basename(record.livePhotoVideoRelativePath!);
        final candidate = p.join(tempDir.path, videoName);
        final videoBytes = await client.downloadFile(
          relativePath: record.livePhotoVideoRelativePath!,
          targetPath: candidate,
        );
        if (videoBytes > 0) {
          videoPath = candidate;
          totalBytes += videoBytes;
        } else {
          print('[RestoreManager] 配对视频下载失败，降级为普通照片: $videoName');
        }
      }

      // 写入系统相册，拿到新资产的 localIdentifier
      String? newAssetId;
      if (record.mediaType == 'video') {
        newAssetId = await PhotoLibraryHelper.saveVideoToLibrary(
          filePath: mainPath,
          creationTimestamp: effectiveTimestamp,
        );
      } else if (videoPath != null) {
        newAssetId = await PhotoLibraryHelper.saveLivePhotoToLibrary(
          photoPath: mainPath,
          videoPath: videoPath,
          creationTimestamp: effectiveTimestamp,
        );
      } else {
        newAssetId = await PhotoLibraryHelper.savePhotoToLibrary(
          filePath: mainPath,
          creationTimestamp: effectiveTimestamp,
        );
      }

      if (newAssetId == null) {
        throw Exception('写入相册失败');
      }
      return _RestoreOutcome(newAssetId, totalBytes);
    } finally {
      await _safeDelete(File(mainPath));
      if (videoPath != null) {
        await _safeDelete(File(videoPath));
      }
    }
  }

  /// 采集本机相册的全部资产指纹，用于判断「这张照片是不是已经在手机上了」
  ///
  /// 把 `fetchAllAssets` 的每个资产转成指纹键；精确键与宽松键都放进集合，
  /// 这样宽高缺失的旧记录也能匹配上。
  Future<Set<String>> _loadLibraryFingerprints() async {
    final result = <String>{};
    try {
      final assets = await PhotoLibraryHelper.fetchAllAssets();
      for (final asset in assets) {
        final isLive = asset['isLivePhoto'] as bool? ?? false;
        final fp = AssetFingerprint.fromAsset(asset, isLivePhoto: isLive);
        result.add(fp.key);
        result.add(fp.looseKey);
      }
    } catch (e) {
      print('[RestoreManager] 采集本机指纹失败: $e');
    }
    return result;
  }

  // ------------------------------------------------------------ 恢复状态

  Future<File> _stateFile() async {
    final docDir = await FileHelper.getDocumentsDirectory();
    return File(p.join(docDir.path, 'restore_state.json'));
  }

  /// 清空本机的恢复状态（与备份记录一起重置，保证两侧一致）
  Future<void> clearRestoreState() async {
    try {
      final file = await _stateFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('[RestoreManager] 恢复状态清空失败: $e');
    }
  }

  /// 读取「原资产 ID → 导入后新资产 ID」的映射
  Future<Map<String, String>> _loadRestoreState() async {
    final result = <String, String>{};
    try {
      final file = await _stateFile();
      if (!await file.exists()) {
        return result;
      }
      final content = await file.readAsString();
      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
          final id = decoded['localIdentifier'] as String?;
          final newId = decoded['restoredAssetId'] as String?;
          if (id != null && newId != null && newId.isNotEmpty) {
            // 后写入的覆盖先前的（同一原资产只关心最新一次导入）
            result[id] = newId;
          }
        } catch (e) {
          print('[RestoreManager] 跳过损坏的恢复状态行: $e');
        }
      }
    } catch (e) {
      print('[RestoreManager] 恢复状态读取失败: $e');
    }
    return result;
  }

  /// 批量追加恢复状态（NDJSON 追加写）
  Future<void> _flushRestored(Map<String, String> restored) async {
    if (restored.isEmpty) {
      return;
    }
    try {
      final file = await _stateFile();
      final buffer = StringBuffer();
      final now = DateTime.now().toIso8601String();
      for (final entry in restored.entries) {
        buffer.writeln(jsonEncode({
          'localIdentifier': entry.key,
          'restoredAssetId': entry.value,
          'restoredAt': now,
        }));
      }
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
      restored.clear();
    } catch (e) {
      print('[RestoreManager] 恢复状态落盘失败，稍后重试: $e');
    }
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('[RestoreManager] 暂存文件删除失败: $e');
    }
  }

  /// 取消恢复
  void cancel() {
    _isCancelled = true;
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
String _mediaLabel(BackupRecord record) {
  switch (record.mediaType) {
    case 'video':
      return '视频';
    case 'live_photo':
      return '实况照片';
    case 'image':
    case 'photo':
      return '照片';
    default:
      return record.mediaType;
  }
}
