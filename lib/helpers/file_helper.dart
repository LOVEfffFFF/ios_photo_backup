import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 文件路径、命名等工具
class FileHelper {
  /// 上传暂存目录名（位于 Documents 下，传输完成后立即删除）
  static const String uploadTempDirName = '.upload_tmp';

  /// 获取 App 的 Documents 目录
  static Future<Directory> getDocumentsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory(dir.path);
  }

  /// 获取上传暂存目录 Documents/.upload_tmp/
  ///
  /// 备份不再往手机里堆文件：这里同一时刻只容纳「正在传输的那一个资产」，
  /// 传完即删，从根上避开沙盒与相册同卷导致的「备份 N GB 需要额外 N GB」。
  static Future<Directory> getUploadTempDirectory() async {
    final docDir = await getDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, uploadTempDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 清理暂存目录中的残留文件（上次异常退出留下的），返回清理的文件数
  static Future<int> cleanUploadTemp() async {
    var removed = 0;
    try {
      final dir = await getUploadTempDirectory();
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            await entity.delete();
            removed++;
          } catch (_) {
            // 单个文件删除失败不影响整体清理
          }
        }
      }
    } catch (_) {
      // 目录不可用时忽略
    }
    return removed;
  }

  /// 生成上传文件名 yyyyMMdd_HHmmss_<相册标识前12位>.<扩展名>
  static String generateFileName(
      DateTime creationDate, String localIdentifier, String extension) {
    final dateStr = '${creationDate.year}'
        '${creationDate.month.toString().padLeft(2, '0')}'
        '${creationDate.day.toString().padLeft(2, '0')}'
        '_${creationDate.hour.toString().padLeft(2, '0')}'
        '${creationDate.minute.toString().padLeft(2, '0')}'
        '${creationDate.second.toString().padLeft(2, '0')}';

    // 仅保留字母数字并取前 12 位：原实现只取 6 位，
    // 在 3 万张量级下碰撞概率约 0.2%，碰撞会静默覆盖同名备份
    final compactId =
        localIdentifier.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    final idSuffix =
        compactId.length >= 12 ? compactId.substring(0, 12) : compactId;

    return '${dateStr}_$idSuffix.$extension';
  }

  /// 生成服务器端相对路径 yyyy/MM/<文件名>（保持按年月归档）
  static String buildServerPath(DateTime creationDate, String fileName) {
    final year = creationDate.year.toString();
    final month = creationDate.month.toString().padLeft(2, '0');
    return '$year/$month/$fileName';
  }

  /// 获取备份记录文件路径
  static Future<File> getRecordsFile() async {
    final docDir = await getDocumentsDirectory();
    return File(p.join(docDir.path, 'backup_records.json'));
  }
}
