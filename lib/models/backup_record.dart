/// 单条备份记录数据模型
class BackupRecord {
  /// 照片在相册中的唯一标识
  final String localIdentifier;

  /// 备份到服务器上的相对路径，如 "2026/10/20261008_120030_A1B2C3D4E5F6.heic"
  final String relativePath;

  /// 原始拍摄时间（毫秒精度，用于展示与汇总）
  final DateTime creationDate;

  /// 原始拍摄时间的高精度表示（Unix 秒，含亚秒小数）
  ///
  /// DateTime 只有毫秒精度，同一秒内连拍或批量导入的照片会退化成同一个
  /// 时间点，恢复时相册里的先后顺序就可能错乱。这里保留原始精度，
  /// 恢复时按它写回拍摄时间，尽可能还原原来的排列次序。
  final double creationTimestamp;

  /// 媒体类型: "image" / "video" / "live_photo"
  final String mediaType;

  /// 如果是 Live Photo，记录配对视频的相对路径
  final String? livePhotoVideoRelativePath;

  BackupRecord({
    required this.localIdentifier,
    required this.relativePath,
    required this.creationDate,
    required this.mediaType,
    this.livePhotoVideoRelativePath,
    double? creationTimestamp,
  }) : creationTimestamp =
            creationTimestamp ?? creationDate.millisecondsSinceEpoch / 1000.0;

  /// 从 JSON 创建（兼容没有 creationTimestamp 字段的旧记录）
  factory BackupRecord.fromJson(Map<String, dynamic> json) {
    final creationDate = DateTime.parse(json['creationDate'] as String);
    return BackupRecord(
      localIdentifier: json['localIdentifier'] as String,
      relativePath: json['relativePath'] as String,
      creationDate: creationDate,
      mediaType: json['mediaType'] as String,
      livePhotoVideoRelativePath:
          json['livePhotoVideoRelativePath'] as String?,
      creationTimestamp: (json['creationTimestamp'] as num?)?.toDouble() ??
          creationDate.millisecondsSinceEpoch / 1000.0,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'localIdentifier': localIdentifier,
      'relativePath': relativePath,
      'creationDate': creationDate.toIso8601String(),
      'creationTimestamp': creationTimestamp,
      'mediaType': mediaType,
      'livePhotoVideoRelativePath': livePhotoVideoRelativePath,
    };
  }
}
