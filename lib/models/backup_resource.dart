/// 备份记录里挂的**一个资源文件**
///
/// ## 为什么需要它
/// 一个相册资产（PHAsset）可以由**多个**文件组成。实测一个开了「风格」的
/// ProRAW 资产有 4 个资源：
///
/// ```
/// photo       IMG_6550.DNG       com.adobe.raw-image       ← RAW 原图
/// poster      Adjustments.plist  com.apple.property-list   ← 编辑指令（风格记在这）
/// type(16)    IMG_6550O.aae      apple-adjustment-envelope ← 编辑数据
/// fullSizeVideo FullSizeRender.jpg public.jpeg             ← 渲染结果
/// ```
///
/// 旧设计一条记录只对应一个文件，于是按 type 优先级挑中渲染后的 JPEG，
/// **RAW 原图和风格数据全丢了**（GAP-R1 + GAP-R2）。
/// 现在一条记录可以挂多个资源文件，恢复时全部导入。
class BackupResource {
  const BackupResource({
    required this.role,
    required this.relativePath,
    this.sha256 = '',
    this.bytes = 0,
    this.uti = '',
    this.filename = '',
  });

  /// 资源角色
  ///
  /// | role | 含义 | 丢了会怎样 |
  /// | --- | --- | --- |
  /// | `raw` | RAW 原图（ProRAW 的 DNG） | **相册认不出 RAW，等于废了** |
  /// | `adjustment` | `Adjustments.plist`，记录用户选的风格 | 风格丢失，恢复成原片观感 |
  /// | `adjustmentAAE` | `.aae` 编辑数据封装 | 部分编辑信息丢失 |
  /// | `alternate` | 其他格式版本 | 兼容性下降 |
  ///
  /// 注意 `main` 与 `pairedVideo` 不在这里 —— 它们分别由
  /// [BackupRecord.relativePath] 与 `livePhotoVideoRelativePath` 承载，
  /// 保持旧字段不变以兼容已有记录。
  final String role;

  /// 该资源在电脑上的相对路径
  final String relativePath;

  /// 原图侧字节哈希（导出时顺手算的）
  final String sha256;
  final int bytes;

  /// 原始 UTI（如 `com.adobe.raw-image`）
  final String uti;

  /// iOS 里的原始文件名（如 `IMG_6550.DNG`）
  final String filename;

  /// 扩展名（从 relativePath 取，含点）
  String get extension {
    final i = relativePath.lastIndexOf('.');
    return i < 0 ? '' : relativePath.substring(i);
  }

  /// 恢复时这个资源该用什么 PHAssetResourceType 写入
  ///
  /// 我们刻意**按 UTI 判断而不是记 type 数字**：PHAssetResourceType 在不同
  /// iOS 版本上成员有增减（实测 poster / type16 就不在公开枚举里），
  /// 而 UTI 是稳定的。写入时按下面的映射挑一个「语义正确」的 type。
  String get restoreType {
    switch (role) {
      case 'adjustmentAAE':
        return 'adjustmentEnvelope';
      case 'adjustment':
        return 'adjustmentPlist';
      case 'pairedVideo':
        return 'pairedVideo';
      case 'raw':
        return 'alternatePhoto';
      default:
        return 'alternate';
    }
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'relativePath': relativePath,
        'sha256': sha256,
        'bytes': bytes,
        'uti': uti,
        'filename': filename,
      };

  factory BackupResource.fromJson(Map<String, dynamic> json) => BackupResource(
        role: json['role'] as String? ?? 'alternate',
        relativePath: json['relativePath'] as String? ?? '',
        sha256: json['sha256'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        uti: json['uti'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
      );

  @override
  String toString() => 'BackupResource($role, $relativePath)';
}