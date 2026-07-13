import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../helpers/file_helper.dart';
import '../models/backup_record.dart';

/// 备份记录存储管理器
/// 负责读取/写入 backup_records.json
class RecordStore {
  /// 加载所有备份记录
  Future<List<BackupRecord>> loadAllRecords() async {
    final file = await FileHelper.getRecordsFile();

    if (!await file.exists()) {
      return [];
    }

    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return [];
      }

      final List<dynamic> jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList
          .map((e) => BackupRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // 文件损坏时返回空列表
      return [];
    }
  }

  /// 追加一条备份记录（原子写入）
  Future<void> appendRecord(BackupRecord record) async {
    final records = await loadAllRecords();
    records.add(record);

    await _writeRecords(records);
  }

  /// 批量追加备份记录
  Future<void> appendRecords(List<BackupRecord> newRecords) async {
    final records = await loadAllRecords();
    records.addAll(newRecords);

    await _writeRecords(records);
  }

  /// 写入所有记录到文件（使用原子写入策略）
  Future<void> _writeRecords(List<BackupRecord> records) async {
    final file = await FileHelper.getRecordsFile();
    final tempFile = File('${file.path}.tmp');

    final jsonList = records.map((r) => r.toJson()).toList();
    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonList);

    // 先写入临时文件
    await tempFile.writeAsString(jsonString, flush: true);

    // 如果目标文件存在，先删除
    if (await file.exists()) {
      await file.delete();
    }

    // 重命名临时文件为正式文件（原子操作）
    await tempFile.rename(file.path);
  }

  /// 获取已备份的 localIdentifier 集合
  Future<Set<String>> getBackedIds() async {
    final records = await loadAllRecords();
    return records.map((r) => r.localIdentifier).toSet();
  }

  /// 获取备份记录总数
  Future<int> getRecordCount() async {
    final records = await loadAllRecords();
    return records.length;
  }

  /// 清空所有备份记录
  Future<void> clearAllRecords() async {
    final file = await FileHelper.getRecordsFile();
    if (await file.exists()) {
      await file.delete();
    }
  }
}
