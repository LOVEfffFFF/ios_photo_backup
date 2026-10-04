import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../helpers/file_helper.dart';
import '../models/backup_record.dart';

/// 备份记录存储管理器
///
/// 存储格式：NDJSON（每行一条 JSON 记录）。
/// 原实现「每追加一条就把整个 JSON 数组读出来重写一遍」，
/// 备份 N 张的总写入量是 O(N²)（3 万张约上百 GB），这里改为追加写 O(N)。
/// 读取兼容旧格式（JSON 数组），首次写入自动迁移为 NDJSON。
class RecordStore {
  /// 加载所有备份记录
  Future<List<BackupRecord>> loadAllRecords() async {
    final file = await FileHelper.getRecordsFile();

    if (!await file.exists()) {
      return [];
    }

    String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      print('[RecordStore] 记录文件读取失败: $e');
      return [];
    }

    if (content.trim().isEmpty) {
      return [];
    }

    // 旧格式（JSON 数组）兼容读取
    if (content.trimLeft().startsWith('[')) {
      try {
        final jsonList = jsonDecode(content) as List<dynamic>;
        return jsonList
            .map((e) => BackupRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        print('[RecordStore] 旧格式记录解析失败: $e');
        await _quarantineCorrupted(file);
        return [];
      }
    }

    // NDJSON：逐行解析，单行损坏只丢该行，不影响其余记录
    final records = <BackupRecord>[];
    var damaged = 0;
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        records.add(
          BackupRecord.fromJson(jsonDecode(trimmed) as Map<String, dynamic>),
        );
      } catch (e) {
        damaged++;
        print('[RecordStore] 跳过损坏记录行: $e');
      }
    }
    if (damaged > 0) {
      print('[RecordStore] 共跳过 $damaged 条损坏记录');
    }
    return records;
  }

  /// 追加一条备份记录
  Future<void> appendRecord(BackupRecord record) async {
    await appendRecords([record]);
  }

  /// 批量追加备份记录（单次追加写入，不重写整个文件）
  Future<void> appendRecords(List<BackupRecord> newRecords) async {
    if (newRecords.isEmpty) {
      return;
    }

    final file = await FileHelper.getRecordsFile();

    // 旧格式文件先整体迁移为 NDJSON，避免两种格式混写导致整体不可解析
    if (await _isLegacyFormat(file)) {
      final existing = await loadAllRecords();
      await _writeAll(<BackupRecord>[...existing, ...newRecords]);
      return;
    }

    final buffer = StringBuffer();
    for (final record in newRecords) {
      buffer.writeln(jsonEncode(record.toJson()));
    }

    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      print('[RecordStore] 记录追加失败，回退为全量重写: $e');
      final existing = await loadAllRecords();
      await _writeAll(<BackupRecord>[...existing, ...newRecords]);
    }
  }

  /// 全量重写记录文件（NDJSON，原子写入）
  Future<void> _writeAll(List<BackupRecord> records) async {
    final file = await FileHelper.getRecordsFile();
    final tempFile = File('${file.path}.tmp');

    final buffer = StringBuffer();
    for (final record in records) {
      buffer.writeln(jsonEncode(record.toJson()));
    }

    await tempFile.writeAsString(buffer.toString(), flush: true);

    // 同目录 rename 本身就是原子覆盖，正常情况下不需要先 delete；
    // 只有 rename 被拒绝（个别平台目标已存在）时才退化处理
    try {
      await tempFile.rename(file.path);
    } catch (e) {
      print('[RecordStore] 原子替换失败，退化为删除后重命名: $e');
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
    }
  }

  /// 判断记录文件是否为旧格式（JSON 数组，首字符为 '['）
  Future<bool> _isLegacyFormat(File file) async {
    if (!await file.exists()) {
      return false;
    }
    try {
      final handle = await file.open(mode: FileMode.read);
      final head = await handle.read(1);
      await handle.close();
      return head.isNotEmpty && head[0] == 0x5B;
    } catch (e) {
      return false;
    }
  }

  /// 隔离损坏的记录文件，避免「解析失败就当没备份过」导致全量重跑
  Future<void> _quarantineCorrupted(File file) async {
    try {
      final quarantined = File(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      await file.rename(quarantined.path);
      print('[RecordStore] 已隔离损坏记录文件: ${quarantined.path}');
    } catch (e) {
      print('[RecordStore] 记录文件隔离失败: $e');
    }
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
