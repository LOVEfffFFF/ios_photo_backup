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
  ///
  /// ## 为什么 raw 不再映射成 alternatePhoto
  ///
  /// 旧映射把 `raw` / `adjustment` / `adjustmentAAE` 全映射到
  /// `alternatePhoto` —— 三个语义完全不同的资源挤进同一个槽位，
  /// iOS 只能收下一个，其余静默失败。一张带风格的 ProRAW 必然在
  /// 「RAW 原图」和「编辑指令」之间二选一。
  ///
  /// 现在：RAW 用 `.fullSizePhoto`（该资产的完整尺寸版本，语义最贴近原图本体），
  /// `.alternatePhoto` 只留给编辑指令，冲突消失。
  ///
  /// 注：2026-10-18 起新备份的 ProRAW 走的是「DNG 当主文件」的路，
  /// 根本不会进 extraResources；本分支是**旧记录的兜底**。
  String get restoreType {
    switch (role) {
      case 'adjustmentAAE':
        return 'adjustmentEnvelope';
      case 'adjustment':
        return 'adjustmentPlist';
      case 'pairedVideo':
        return 'pairedVideo';
      case 'raw':
        return 'fullSizePhoto';
      case 'render':
        // ProRAW 的渲染图（FullSizeRender.jpg）
        //
        // ## 写哪个槽位：实测只有 .alternatePhoto 收得下JPEG
        //
        // 实测（2026-10-18，build 23:31 往返验证，逐次尝试的原文）：
        //   · `.alternatePhoto`（实测 rawValue **4**）写 JPEG → ✓ 写入成功
        //   · `.fullSizePhoto`（实测 rawValue **5**）写 JPEG   → ✗ PHPhotosErrorDomain **3300**
        //     连「DNG 走 .photo + JPEG 走 .fullSizePhoto」这种最朴素的两件套
        //     都整批失败，降级到「只写主文件」才成功 —— 副本只剩 1 个资源，
        //     比不写还糟。推测 iOS 要求 fullSizePhoto 槽与 photo 槽同源同格式，
        //     塞一张 JPEG 进去与 DNG 打架。
        //
        // **踩过一次的坑**：曾把这里写成 'fullSizePhoto'（语义上「完整尺寸版本」
        // 听着最对），结果副本直接空掉。语义对不代表 iOS 收，写入槽位只能靠实测。
        //
        // 代价：这里回到 'alternate' 就又和两份编辑指令（adjustmentPlist /
        // adjustmentEnvelope，同为 .alternatePhoto）撞同一个槽位。
        // 写入前的 slot 去重会把编辑指令排到后面舍弃 —— 这是 GAP-R2 的账，
        // 要解决得给编辑指令另找一个 iOS 肯收的槽（例如原图所在的 7 号 .adjustment）。
        return 'alternate';
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