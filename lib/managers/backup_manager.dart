import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import 'record_store.dart';

/// 备份进度信息
class BackupProgress {
  final int completed;
  final int total;
  final double percentage;
  final String? currentFile;
  final String? error;

  BackupProgress({
    required this.completed,
    required this.total,
    required this.percentage,
    this.currentFile,
    this.error,
  });
}

/// 核心备份管理器
class BackupManager {
  final RecordStore _recordStore = RecordStore();
  bool _isRunning = false;
  bool _isCancelled = false;

  bool get isRunning => _isRunning;

  /// 开始备份（增量）
  /// [onProgress] 进度回调
  Stream<BackupProgress> startBackup() async* {
    if (_isRunning) {
      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '备份正在进行中',
      );
      return;
    }

    _isRunning = true;
    _isCancelled = false;

    try {
      // 1. 获取所有照片资源
      yield BackupProgress(completed: 0, total: 0, percentage: 0,
          currentFile: '正在扫描相册...');

      final assets = await PhotoLibraryHelper.fetchAllAssets();
      if (assets.isEmpty) {
        yield BackupProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '未找到任何照片或权限不足',
        );
        _isRunning = false;
        return;
      }

      // 2. 加载已备份记录
      final backedRecords = await _recordStore.loadAllRecords();
      final backedIds = backedRecords.map((r) => r.localIdentifier).toSet();

      // 3. 过滤未备份的资源
      final unbackedAssets = assets
          .where((a) => !backedIds.contains(a['localIdentifier'] as String))
          .toList();

      final total = unbackedAssets.length;
      if (total == 0) {
        yield BackupProgress(
          completed: 0,
          total: assets.length,
          percentage: 100,
          currentFile: '所有照片已备份完成',
        );
        _isRunning = false;
        return;
      }

      yield BackupProgress(
        completed: 0,
        total: total,
        percentage: 0,
        currentFile: '开始备份 $total 个项目...',
      );

      // 4. 遍历备份
      int completed = 0;
      for (final asset in unbackedAssets) {
        if (_isCancelled) {
          yield BackupProgress(
            completed: completed,
            total: total,
            percentage: completed / total * 100,
            error: '备份已取消',
          );
          break;
        }

        final localId = asset['localIdentifier'] as String;
        final creationDateSeconds = asset['creationDate'] as num;
        final creationDate = DateTime.fromMillisecondsSinceEpoch(
          (creationDateSeconds * 1000).toInt(),
        );
        final mediaType = asset['mediaType'] as String;
        final isLivePhoto = asset['isLivePhoto'] as bool? ?? false;

        try {
          // 获取目标目录
          final subDir = await FileHelper.getDateSubDirectory(creationDate);
          String? relativePath;
          String? livePhotoVideoRelativePath;

          if (mediaType == 'video') {
            // 导出视频
            final fileName = FileHelper.generateFileName(
                creationDate, localId, 'mov');
            final targetPath = p.join(subDir.path, fileName);
            final success = await PhotoLibraryHelper.exportVideoAsset(
              localIdentifier: localId,
              targetPath: targetPath,
            );
            if (success) {
              relativePath = p.relative(targetPath,
                  from: (await FileHelper.getDocumentsDirectory()).path);
            }
          } else if (mediaType == 'image') {
            String ext = 'jpg';
            // 尝试获取文件扩展名
            final fileName = FileHelper.generateFileName(
                creationDate, localId, ext);
            final targetPath = p.join(subDir.path, fileName);
            final success = await PhotoLibraryHelper.exportPhotoAsset(
              localIdentifier: localId,
              targetPath: targetPath,
            );
            if (success) {
              // 检查实际文件扩展名
              final file = File(targetPath);
              if (await file.exists()) {
                // HEIC 文件可能被保存
                relativePath = p.relative(targetPath,
                    from: (await FileHelper.getDocumentsDirectory()).path);
              }

              // 如果是 Live Photo，导出配对视频
              if (isLivePhoto) {
                final videoFileName = FileHelper.generateFileName(
                    creationDate, '${localId}_video', 'mov');
                final videoTargetPath = p.join(subDir.path, videoFileName);
                final videoSuccess =
                    await PhotoLibraryHelper.exportLivePhotoVideo(
                  localIdentifier: localId,
                  targetPath: videoTargetPath,
                );
                if (videoSuccess) {
                  livePhotoVideoRelativePath = p.relative(
                      videoTargetPath,
                      from: (await FileHelper.getDocumentsDirectory()).path);
                }
              }
            }
          }

          // 记录备份
          if (relativePath != null) {
            final record = BackupRecord(
              localIdentifier: localId,
              relativePath: relativePath,
              creationDate: creationDate,
              mediaType: isLivePhoto ? 'live_photo' : mediaType,
              livePhotoVideoRelativePath: livePhotoVideoRelativePath,
            );
            await _recordStore.appendRecord(record);
            completed++;
          }
        } catch (e) {
          // 单个文件备份失败不中断整体流程
          yield BackupProgress(
            completed: completed,
            total: total,
            percentage: completed / total * 100,
            currentFile: localId,
            error: '备份文件失败: $e',
          );
        }

        // 更新进度
        final percentage = total > 0 ? (completed / total * 100) : 100.0;
        yield BackupProgress(
          completed: completed,
          total: total,
          percentage: percentage,
          currentFile: localId,
        );

        // 短暂延迟，避免过于频繁更新 UI
        await Future.delayed(const Duration(milliseconds: 10));
      }

      yield BackupProgress(
        completed: completed,
        total: total,
        percentage: 100,
        currentFile: '备份完成！共备份 $completed 个文件',
      );
    } catch (e) {
      yield BackupProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '备份过程出错: $e',
      );
    } finally {
      _isRunning = false;
    }
  }

  /// 取消备份
  void cancel() {
    _isCancelled = true;
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
