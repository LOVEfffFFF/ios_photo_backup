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
  /// ## 槽位真值（真机 SDK 枚举，2026-10-20 校正）
  ///
  /// ```
  /// 1 photo       2 video        3 audio          4 alternatePhoto
  /// 5 fullSizePhoto             6 fullSizeVideo  7 adjustmentData
  /// 8 adjustmentBasePhoto       9 pairedVideo   10 fullSizePairedVideo
  /// 11 adjustmentBasePairedVideo
  /// ```
  ///
  /// **7 是公开的 `.adjustmentData`，8 才是 `.adjustmentBasePhoto`（基图槽）。**
  /// 之前把 7 当成基图槽，才误判成「编辑指令一写就坏图」。
  ///
  /// ## 为什么不再一律交回 iOS（`auto`）
  ///
  /// 2026-10-20 之前这里全部返回 `auto`（不写），依据是四轮实验都是坏图。
  /// 真因是**槽位映射错了**，不是公开 API 不行：
  ///
  ///   · 配方写进 7 号本身没错，但当时误以为 7 是基图槽；
  ///   · 没有公开创建类型的相机 AAE 被一起硬塞进去；
  ///   · 渲染图被塞进 `.alternatePhoto`，而不是 `.fullSizePhoto`。
  ///
  /// ios_photo_backup_openai 的真机结论（用户已确认副本在系统相册里
  /// 滤镜名、强度、RAW 标记、还原再编辑全部正常）：
  ///
  ///   主文件（DNG）→ `.photo`
  ///   当前配方      → `.adjustmentData`   ← 必须与渲染图成对
  ///   渲染图        → `.fullSizePhoto`
  ///   相机 AAE      → 无公开创建类型，不导入，只留备份
  String get restoreType {
    switch (role) {
      // 当前编辑配方：写回官方槽位，并与渲染图成对提交
      case 'adjustment':
        return 'adjustmentData';
      // 相机内嵌 .aae：原图里占 type(16)，公开枚举没有对应创建类型。
      // 不能猜编号硬塞 —— `PHAssetResourceType(rawValue: 16)` 返回 nil。
      case 'adjustmentAAE':
        return 'cameraEnvelope';
      // 渲染图：`.fullSizePhoto`(5)。早先写它报 3300 是因为配方没配对，
      // 不是这个槽不收 —— 三者一次性提交时 iOS 全部接受。
      case 'render':
        return 'fullSizePhoto';
      case 'pairedVideo':
        return 'pairedVideo';
      // 旧记录兜底：2026-10-18 起新备份的 ProRAW 把 DNG 当主文件，
      // 不会进 extraResources。
      case 'raw':
        return 'alternatePhoto';
      case 'alternate':
        return 'alternatePhoto';
      default:
        return 'unsupported';
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