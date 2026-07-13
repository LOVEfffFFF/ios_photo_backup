/// 单条备份记录数据模型
class BackupRecord {
  /// 照片在相册中的唯一标识
  final String localIdentifier;

  /// 备份到本地的相对路径，如 "Backup/2024/03/20240315_182345_A1B2C3.jpg"
  final String relativePath;

  /// 原始拍摄时间
  final DateTime creationDate;

  /// 媒体类型: "photo" / "video" / "live_photo"
  final String mediaType;

  /// 如果是 Live Photo，记录配对视频的相对路径
  final String? livePhotoVideoRelativePath;

  BackupRecord({
    required this.localIdentifier,
    required this.relativePath,
    required this.creationDate,
    required this.mediaType,
    this.livePhotoVideoRelativePath,
  });

  /// 从 JSON 创建
  factory BackupRecord.fromJson(Map<String, dynamic> json) {
    return BackupRecord(
      localIdentifier: json['localIdentifier'] as String,
      relativePath: json['relativePath'] as String,
      creationDate: DateTime.parse(json['creationDate'] as String),
      mediaType: json['mediaType'] as String,
      livePhotoVideoRelativePath:
          json['livePhotoVideoRelativePath'] as String?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'localIdentifier': localIdentifier,
      'relativePath': relativePath,
      'creationDate': creationDate.toIso8601String(),
      'mediaType': mediaType,
      'livePhotoVideoRelativePath': livePhotoVideoRelativePath,
    };
  }
}
