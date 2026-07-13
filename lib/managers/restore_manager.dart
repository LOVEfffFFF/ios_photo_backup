import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import 'record_store.dart';

/// 恢复进度信息
class RestoreProgress {
  final int completed;
  final int total;
  final double percentage;
  final String? currentFile;
  final String? error;

  RestoreProgress({
    required this.completed,
    required this.total,
    required this.percentage,
    this.currentFile,
    this.error,
  });
}

/// 核心恢复管理器
class RestoreManager {
  final RecordStore _recordStore = RecordStore();
  bool _isRunning = false;
  bool _isCancelled = false;

  bool get isRunning => _isRunning;

  /// 开始恢复照片到系统相册
  Stream<RestoreProgress> startRestore() async* {
    if (_isRunning) {
      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '恢复正在进行中',
      );
      return;
    }

    _isRunning = true;
    _isCancelled = false;

    try {
      // 1. 加载备份记录
      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        currentFile: '正在加载备份记录...',
      );

      final records = await _recordStore.loadAllRecords();
      if (records.isEmpty) {
        yield RestoreProgress(
          completed: 0,
          total: 0,
          percentage: 0,
          error: '没有找到备份记录',
        );
        _isRunning = false;
        return;
      }

      final total = records.length;

      yield RestoreProgress(
        completed: 0,
        total: total,
        percentage: 0,
        currentFile: '开始恢复 $total 个文件...',
      );

      // 2. 遍历恢复
      int completed = 0;
      final docDir = await FileHelper.getDocumentsDirectory();

      for (final record in records) {
        if (_isCancelled) {
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: completed / total * 100,
            error: '恢复已取消',
          );
          break;
        }

        try {
          final filePath = p.join(docDir.path, record.relativePath);
          final file = File(filePath);

          if (!await file.exists()) {
            yield RestoreProgress(
              completed: completed,
              total: total,
              percentage: completed / total * 100,
              currentFile: record.relativePath,
              error: '文件不存在，跳过: ${record.relativePath}',
            );
            continue;
          }

          bool success = false;

          if (record.mediaType == 'live_photo') {
            // 恢复 Live Photo
            if (record.livePhotoVideoRelativePath != null) {
              final videoPath = p.join(
                  docDir.path, record.livePhotoVideoRelativePath!);
              final videoFile = File(videoPath);

              if (await videoFile.exists()) {
                success = await PhotoLibraryHelper.saveLivePhotoToLibrary(
                  photoPath: filePath,
                  videoPath: videoPath,
                  creationDate: record.creationDate,
                );
              } else {
                // 视频文件不存在，降级为普通照片
                success = await PhotoLibraryHelper.savePhotoToLibrary(
                  filePath: filePath,
                  creationDate: record.creationDate,
                );
              }
            } else {
              success = await PhotoLibraryHelper.savePhotoToLibrary(
                filePath: filePath,
                creationDate: record.creationDate,
              );
            }
          } else if (record.mediaType == 'video') {
            // 恢复视频
            success = await PhotoLibraryHelper.saveVideoToLibrary(
              filePath: filePath,
              creationDate: record.creationDate,
            );
          } else {
            // 恢复照片
            success = await PhotoLibraryHelper.savePhotoToLibrary(
              filePath: filePath,
              creationDate: record.creationDate,
            );
          }

          if (success) {
            completed++;
          }
        } catch (e) {
          yield RestoreProgress(
            completed: completed,
            total: total,
            percentage: completed / total * 100,
            currentFile: record.relativePath,
            error: '恢复文件失败: $e',
          );
        }

        // 更新进度
        final percentage = total > 0 ? (completed / total * 100) : 100.0;
        yield RestoreProgress(
          completed: completed,
          total: total,
          percentage: percentage,
          currentFile: record.relativePath,
        );

        // 短暂延迟
        await Future.delayed(const Duration(milliseconds: 10));
      }

      yield RestoreProgress(
        completed: completed,
        total: total,
        percentage: 100,
        currentFile: '恢复完成！成功恢复 $completed 个文件到系统相册',
      );
    } catch (e) {
      yield RestoreProgress(
        completed: 0,
        total: 0,
        percentage: 0,
        error: '恢复过程出错: $e',
      );
    } finally {
      _isRunning = false;
    }
  }

  /// 取消恢复
  void cancel() {
    _isCancelled = true;
  }
}
