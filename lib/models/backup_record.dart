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

  /// 像素宽高（拍摄时的尺寸）
  ///
  /// 与设备无关的识别依据之一：换设备后 localIdentifier 全变，但「拍摄时间 +
  /// 尺寸」不变，可据此判断「本机这张是不是同一个资产」。旧记录没有这两个
  /// 字段时为 null，指纹会自动退化为「时间 + 类型」。
  final int? pixelWidth;
  final int? pixelHeight;

  /// 原图资源的 SHA256（原生导出时顺手算的，「原图侧」的哈希）
  ///
  /// 与电脑端 manifest 里的 sha256（对落盘字节算的）是**两个独立来源**。
  /// 两者一致才证明备份内容确实等于手机原图 —— 这正是 GAP-S4 要闭合的缺口。
  /// 旧记录没有这个字段时为空，表示「未做端到端校验」而非「校验失败」。
  final String contentSha256;

  /// 原图该资产共有几个 PHAssetResource
  final int? resourceTotal;

  /// 备份了的主资源类型（照片 / 视频 / 配对视频）
  final List<String> resourcePrimary;

  /// 原图里存在但未备份的辅助资源类型
  /// （ProRAW 的第二份、深度图、HDR 增益图、海报…）
  final List<String> resourceAuxiliary;

  /// 资源完整度：备份了 1（主文件）+ N（辅助）。
  /// 原图资源数大于这个值，说明有资源没被导出（GAP-R1 的暴露方式）。
  int get backedResourceCount => 1 + resourceAuxiliary.length;

  /// 资源是否完整导出。旧记录没有 resourceTotal 时返回 null（无法判断）。
  bool? get isResourceComplete {
    if (resourceTotal == null || resourceTotal == 0) return null;
    return backedResourceCount >= resourceTotal!;
  }

  /// 如果是 Live Photo，记录配对视频的相对路径
  final String? livePhotoVideoRelativePath;

  BackupRecord({
    required this.localIdentifier,
    required this.relativePath,
    required this.creationDate,
    required this.mediaType,
    this.livePhotoVideoRelativePath,
    this.pixelWidth,
    this.pixelHeight,
    this.contentSha256 = '',
    this.resourceTotal,
    this.resourcePrimary = const [],
    this.resourceAuxiliary = const [],
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
      pixelWidth: (json['pixelWidth'] as num?)?.toInt(),
      pixelHeight: (json['pixelHeight'] as num?)?.toInt(),
      contentSha256: json['contentSha256'] as String? ?? '',
      resourceTotal: (json['resourceTotal'] as num?)?.toInt(),
      resourcePrimary: ((json['resourcePrimary'] as List?) ?? const [])
          .map((e) => '$e').toList(),
      resourceAuxiliary: ((json['resourceAuxiliary'] as List?) ?? const [])
          .map((e) => '$e').toList(),
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
      'pixelWidth': pixelWidth,
      'pixelHeight': pixelHeight,
      'contentSha256': contentSha256,
      'resourceTotal': resourceTotal,
      'resourcePrimary': resourcePrimary,
      'resourceAuxiliary': resourceAuxiliary,
    };
  }
}
