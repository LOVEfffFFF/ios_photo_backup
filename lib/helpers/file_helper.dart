import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 文件路径、重命名等工具
class FileHelper {
  /// 获取 App 的 Documents 目录
  static Future<Directory> getDocumentsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(dir.path);
  }

  /// 获取备份根目录 Documents/Backup/
  static Future<Directory> getBackupDirectory() async {
    final docDir = await getDocumentsDirectory();
    final backupDir = Directory(p.join(docDir.path, 'Backup'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  /// 根据拍摄日期获取子目录路径 Documents/Backup/yyyy/MM/
  static Future<Directory> getDateSubDirectory(DateTime date) async {
    final backupDir = await getBackupDirectory();
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final subDir = Directory(p.join(backupDir.path, year, month));
    if (!await subDir.exists()) {
      await subDir.create(recursive: true);
    }
    return subDir;
  }

  /// 生成备份文件名 yyyyMMdd_HHmmss_本地标识前6位.扩展名
  static String generateFileName(
      DateTime creationDate, String localIdentifier, String extension) {
    final dateStr =
        '${creationDate.year}'
        '${creationDate.month.toString().padLeft(2, '0')}'
        '${creationDate.day.toString().padLeft(2, '0')}'
        '_${creationDate.hour.toString().padLeft(2, '0')}'
        '${creationDate.minute.toString().padLeft(2, '0')}'
        '${creationDate.second.toString().padLeft(2, '0')}';

    final idSuffix = localIdentifier.length >= 6
        ? localIdentifier.substring(0, 6).toUpperCase()
        : localIdentifier.toUpperCase();

    return '${dateStr}_$idSuffix.$extension';
  }

  /// 获取备份索引文件路径
  static Future<File> getRecordsFile() async {
    final docDir = await getDocumentsDirectory();
    return File(p.join(docDir.path, 'backup_records.json'));
  }
}
