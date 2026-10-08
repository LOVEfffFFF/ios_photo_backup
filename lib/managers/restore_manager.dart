import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
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

/// 把电脑上的备份拉回手机相册
///
/// 流程：读备份记录 → 过滤出「尚未恢复」的 → 逐条下载到暂存目录 →
/// 写入系统相册 → 删除暂存。
///
/// 幂等性：已恢复的 localIdentifier 记录在 `restore_state.json`（NDJSON 追加写），
/// 重复点击不会把同一张照片导入两次。
class RestoreManager {
  final RecordStore _recordStore = RecordStore();
  bool _isRunning = false;
  bool _isCancelled = false;

  /// 每积累这么多条就刷一次恢复状态
  static const int _stateFlushThreshold = 20;

  /// 进度上报的最小间隔
  static const Duration _progressInterval = Duration(milliseconds: 300);

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

    final restoredNow = <String>[];
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
      final records = await _recordStore.loadAllRecords();
      if (records.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '手机上没有备份记录，无法恢复（记录文件丢失时可用电脑上的文件手动导入）',
          fatal: true,
        );
        return;
      }

      // 3. 过滤掉两类不需要恢复的：
      //    a) 之前已经恢复过的（restore_state.json）
      //    b) 相册里本来就还在的 —— 照片没删，不该从电脑再导一份回来
      final alreadyRestored = await _loadRestoredIds();
      final candidates = records
          .where((r) => !alreadyRestored.contains(r.localIdentifier))
          .toList();

      yield RestoreProgress(
        completed: 0,
        total: records.length,
        percentage: 0,
        currentFile: '正在核对相册中已有的照片...',
        logMessage: '备份记录 ${records.length} 条｜其中已恢复过 ${records.length - candidates.length} 条｜'
            '待核对 ${candidates.length} 条',
      );

      if (candidates.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: records.length,
          percentage: 100,
          currentFile: '所有备份记录都已恢复到相册，无需重复导入',
          logMessage: '所有备份记录都已恢复过，无需重复导入',
        );
        return;
      }

      final stillInLibrary = await PhotoLibraryHelper.filterExistingAssets(
        candidates.map((r) => r.localIdentifier).toList(),
      );
      final pending = candidates
          .where((r) => !stillInLibrary.contains(r.localIdentifier))
          .toList();
      final skippedExisting = candidates.length - pending.length;

      if (pending.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: records.length,
          percentage: 100,
          currentFile: '相册里这些照片都还在，无需从电脑导入',
          logMessage: '核对结果：这 $skippedExisting 张在相册里都还在，无需导入',
        );
        return;
      }

      final total = pending.length;
      yield RestoreProgress(
        completed: 0,
        total: total,
        percentage: 0,
        currentFile: skippedExisting > 0
            ? '相册中仍有 $skippedExisting 个（已跳过），待恢复 $total 个，开始下载...'
            : '待恢复 $total 个，开始下载...',
        logMessage: skippedExisting > 0
            ? '核对结果：相册中仍存在 $skippedExisting 张（跳过）｜待从电脑导入 $total 张'
            : '核对结果：待从电脑导入 $total 张',
      );

      // 4. 逐条下载并写入相册
      //    备份与恢复互斥运行，共用同一个暂存目录
      final tempDir = await FileHelper.getUploadTempDirectory();
      var completed = 0;
      var failed = 0;
      var lastYieldAt = DateTime.now();

      for (final record in pending) {
        if (_isCancelled) {
          await _flushRestored(restoredNow);
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: '已取消，已恢复 $completed 个',
            downloadedBytes: downloadedBytes,
          );
          return;
        }

        var bytes = 0;
        String? failure;

        try {
          bytes = await _restoreOne(
            client: client,
            tempDir: tempDir,
            record: record,
          );
          if (bytes > 0) {
            completed++;
            downloadedBytes += bytes;
            restoredNow.add(record.localIdentifier);
            if (restoredNow.length >= _stateFlushThreshold) {
              await _flushRestored(restoredNow);
            }
          } else {
            failed++;
            failure = '写入相册未成功';
          }
        } catch (e) {
          failed++;
          failure = '$e';
        }

        if (failure == null) {
          // 每恢复一个文件写一条日志
          final doneName = p.basename(record.relativePath);
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: doneName,
            downloadedBytes: downloadedBytes,
            logMessage:
                '✅ [$completed/$total] $doneName  ${_fmtBytes(bytes)} → 已写入相册',
          );
          lastYieldAt = DateTime.now();
        } else {
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: total > 0 ? completed / total * 100 : 0,
            currentFile: record.relativePath,
            error: failure,
            downloadedBytes: downloadedBytes,
            logMessage: '❌ [$completed/$total] '
                '${p.basename(record.relativePath)} —— $failure',
          );
          lastYieldAt = DateTime.now();
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
        currentFile: skippedExisting > 0
            ? '$summary（相册中已有 $skippedExisting 张，已跳过）'
            : summary,
        downloadedBytes: downloadedBytes,
        logMessage: '📊 $summary｜累计下载 ${_fmtBytes(downloadedBytes)}'
            '${skippedExisting > 0 ? '｜相册中已存在的 $skippedExisting 张跳过未导入' : ''}',
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
  /// 返回下载的总字节数；失败抛异常
  Future<int> _restoreOne({
    required ServerClient client,
    required Directory tempDir,
    required BackupRecord record,
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

      // 写入系统相册（原生侧按内容判断类型，扩展名已与实际格式一致）
      bool ok;
      if (record.mediaType == 'video') {
        ok = await PhotoLibraryHelper.saveVideoToLibrary(
          filePath: mainPath,
          creationDate: record.creationDate,
        );
      } else if (videoPath != null) {
        ok = await PhotoLibraryHelper.saveLivePhotoToLibrary(
          photoPath: mainPath,
          videoPath: videoPath,
          creationDate: record.creationDate,
        );
      } else {
        ok = await PhotoLibraryHelper.savePhotoToLibrary(
          filePath: mainPath,
          creationDate: record.creationDate,
        );
      }

      if (!ok) {
        throw Exception('写入相册失败');
      }
      return totalBytes;
    } finally {
      await _safeDelete(File(mainPath));
      if (videoPath != null) {
        await _safeDelete(File(videoPath));
      }
    }
  }

  // ------------------------------------------------------------ 恢复状态

  Future<File> _stateFile() async {
    final docDir = await FileHelper.getDocumentsDirectory();
    return File(p.join(docDir.path, 'restore_state.json'));
  }

  /// 清空本机的恢复状态（哪些资产已经导回相册）
  ///
  /// 与备份记录一起重置，保证两侧状态一致。
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

  /// 读取已恢复的 localIdentifier 集合
  Future<Set<String>> _loadRestoredIds() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) {
        return <String>{};
      }
      final content = await file.readAsString();
      final ids = <String>{};
      for (final line in content.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(trimmed) as Map<String, dynamic>;
          final id = decoded['localIdentifier'] as String?;
          if (id != null) {
            ids.add(id);
          }
        } catch (e) {
          print('[RestoreManager] 跳过损坏的恢复状态行: $e');
        }
      }
      return ids;
    } catch (e) {
      print('[RestoreManager] 恢复状态读取失败: $e');
      return <String>{};
    }
  }

  /// 批量追加恢复状态（NDJSON 追加写）
  Future<void> _flushRestored(List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }
    try {
      final file = await _stateFile();
      final buffer = StringBuffer();
      for (final id in ids) {
        buffer.writeln(jsonEncode({
          'localIdentifier': id,
          'restoredAt': DateTime.now().toIso8601String(),
        }));
      }
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
      ids.clear();
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
