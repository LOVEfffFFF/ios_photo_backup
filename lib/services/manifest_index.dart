import '../models/backup_record.dart';
import 'server_client.dart';

/// 资产指纹：与设备无关的「是不是同一个资产」判据
///
/// ## 为什么不能用 localIdentifier
///
/// iOS 的 `localIdentifier` 只在**原设备**上有意义。换手机、重装系统、
/// App 重装之后，同一张照片的 localIdentifier 完全不同。原实现用它判断
/// 「这张照片是不是已经备份/恢复过了」，于是：
/// - 沙盒一丢（侧载重装必然发生）→ 什么都认不出来 → 全量重传
/// - 换设备恢复 → 什么都认不出来 → 全量重复导入
///
/// ## 指纹的要素
///
/// | 要素 | 换设备后是否稳定 |
/// | --- | --- |
/// | 拍摄时间（毫秒，绝对时间戳） | ✅ 与时区无关 |
/// | 媒体类型 | ✅ |
/// | 像素宽高 | ✅ 拍摄尺寸不随设备变 |
/// | 资产 ID | ❌ **故意不用**，见上文 |
///
/// 实测（2026-10-09，48 个文件）：21 个不同的拍摄秒里**有 19 个秒内含多条**
/// —— 连拍确实产生同秒照片，所以时间必须精确到毫秒才有区分度。
class AssetFingerprint {
  /// 拍摄时间（毫秒，绝对时间戳）
  final int creationMillis;

  /// 归一化媒体类型：image / video / live_photo
  final String mediaType;

  final int? pixelWidth;
  final int? pixelHeight;

  const AssetFingerprint({
    required this.creationMillis,
    required this.mediaType,
    this.pixelWidth,
    this.pixelHeight,
  });

  /// 精确指纹键。
  ///
  /// 宽高缺失时（Backfill 从文件名反推的旧数据）会退化成 `?x?`，
  /// 与「有宽高」的记录产生不同的键 —— 这是**故意的**：宁可漏判成需要备份，
  /// 也不能因为要素不全而误判成已备份。
  String get key =>
      '$creationMillis|$mediaType|${pixelWidth ?? '?'}x${pixelHeight ?? '?'}';

  /// 宽松指纹键（不含宽高），仅用于宽高缺失时的兜底查询
  String get looseKey => '$creationMillis|$mediaType';

  /// 从备份记录生成指纹
  factory AssetFingerprint.fromRecord(BackupRecord r) => AssetFingerprint(
        creationMillis: (r.creationTimestamp * 1000).round(),
        mediaType: normalizeMediaType(r.mediaType),
        pixelWidth: r.pixelWidth,
        pixelHeight: r.pixelHeight,
      );

  /// 从 fetchAllAssets 返回的**本机资产**生成指纹
  ///
  /// [isLivePhoto] 为 true 时统一记为 live_photo，与 manifest 里
  /// 「主文件 mediaType=live_photo」的写法对齐。
  factory AssetFingerprint.fromAsset(
    Map<String, dynamic> asset, {
    required bool isLivePhoto,
  }) {
    final seconds = (asset['creationDate'] as num?)?.toDouble() ?? 0;
    final raw = (asset['mediaType'] as String?) ?? '';
    return AssetFingerprint(
      creationMillis: (seconds * 1000).round(),
      mediaType: isLivePhoto ? 'live_photo' : normalizeMediaType(raw),
      pixelWidth: (asset['pixelWidth'] as num?)?.toInt(),
      pixelHeight: (asset['pixelHeight'] as num?)?.toInt(),
    );
  }

  /// 媒体类型归一化
  ///
  /// 清单里主文件可能是 live_photo / image，配对视频单独标记 role；
  /// 本机资产只有 image / video + isLivePhoto 标记。两边统一到同一套叫法。
  static String normalizeMediaType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'image':
      case 'photo':
        return 'image';
      case 'video':
        return 'video';
      case 'live_photo':
      case 'livephoto':
        return 'live_photo';
      default:
        return raw.trim().toLowerCase();
    }
  }

  @override
  String toString() => key;
}

/// manifest.jsonl 的一条记录
class ManifestEntry {
  /// 电脑上的相对路径（备份文件的落盘位置）
  final String serverPath;

  /// 原设备的 localIdentifier
  final String assetId;

  /// 同一资产的多个文件共用（Live Photo 的照片与配对视频）
  final String pairKey;

  /// main / pairedVideo
  final String role;

  /// 清单里的原始媒体类型（未归一化）
  final String rawMediaType;

  /// 拍摄时间（Unix 秒，亚秒精度）
  final double? createdUnix;

  final int? pixelWidth;
  final int? pixelHeight;

  /// 文件字节数
  final int size;

  /// 该文件的 SHA-256（清单里没有时为空串）
  ///
  /// 两种来源，要分清：
  ///  · [sha256]           接收端对**落盘字节**算的 → 验证"下载回来的 == 上传时的"
  ///  · [clientSha256]     手机端对**原图资源**算的   → 验证"备份内容 == 手机原图"
  ///
  /// 后者才是端到端的那个「原图侧」基准，恢复时拿它比对就能证明
  /// 「原图 → 备份 → 下载」全程字节无损，且不依赖原图现在是否还在手机上。
  final String sha256;

  /// 手机端导出时算的原图字节哈希（旧版 App 备份的条目为空串）
  final String clientSha256;

  /// 端到端校验结果：verified / mismatch / unchecked
  ///
  /// unchecked 是「未校验」（旧版 App 没提供原图侧哈希），
  /// 与 mismatch（校验失败）含义完全不同，不能混为一谈。
  final String verifyState;

  /// true = 这条是从文件名反推的（Backfill），不是 App 上传的权威数据
  final bool inferred;

  const ManifestEntry({
    required this.serverPath,
    required this.assetId,
    required this.pairKey,
    required this.role,
    required this.rawMediaType,
    this.createdUnix,
    this.pixelWidth,
    this.pixelHeight,
    this.size = 0,
    this.sha256 = '',
    this.clientSha256 = '',
    this.verifyState = 'unchecked',
    this.inferred = false,
  });

  bool get isPairedVideo => role == 'pairedVideo';

  factory ManifestEntry.fromJson(Map<String, dynamic> e) => ManifestEntry(
        serverPath: (e['serverPath'] as String?) ?? '',
        assetId: (e['assetId'] as String?) ?? '',
        pairKey: (e['pairKey'] as String?) ?? '',
        role: (e['role'] as String?) ?? 'main',
        rawMediaType: (e['mediaType'] as String?) ?? '',
        createdUnix: (e['createdUnix'] as num?)?.toDouble(),
        pixelWidth: (e['pixelWidth'] as num?)?.toInt(),
        pixelHeight: (e['pixelHeight'] as num?)?.toInt(),
        size: (e['size'] as num?)?.toInt() ?? 0,
        sha256: (e['sha256'] as String?) ?? '',
        clientSha256: (e['clientSha256'] as String?) ?? '',
        verifyState: (e['verifyState'] as String?) ?? 'unchecked',
        inferred: e['inferred'] == true,
      );

  /// 该条目对应的资产指纹
  AssetFingerprint get fingerprint => AssetFingerprint(
        creationMillis: ((createdUnix ?? 0) * 1000).round(),
        mediaType: isPairedVideo
            ? 'video'
            : AssetFingerprint.normalizeMediaType(rawMediaType),
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
      );
}

/// 电脑上的元数据清单（manifest.jsonl）的内存索引
///
/// 作用：让「已经备份过哪些」这个判断**不再依赖手机沙盒**。
/// 沙盒被清空（侧载重装、换机、系统清理）后，只要电脑和清单还在，
/// 就能正确判断增量范围与恢复范围。
class ManifestIndex {
  /// 全部条目（已按 serverPath 去重，保留最后一条 = 最新/最权威记录）
  final List<ManifestEntry> entries;

  /// 指纹 → 主文件条目（只收 role != pairedVideo，避免配对视频顶掉主文件）
  final Map<String, ManifestEntry> _byFingerprint = <String, ManifestEntry>{};

  /// 宽松指纹 → 主文件条目
  final Map<String, ManifestEntry> _byLooseFingerprint =
      <String, ManifestEntry>{};

  /// 服务器路径 → 该文件的 sha256（恢复时校验用）
  ///
  /// 建在**全部**条目上（含配对视频），因为恢复时主文件和配对视频都要校验。
  final Map<String, String> _shaByPath = <String, String>{};

  /// 服务器路径 → 完整条目（恢复校验要取原图侧哈希与校验状态）
  final Map<String, ManifestEntry> _byPath = <String, ManifestEntry>{};

  /// 查某个服务器路径的**原图侧**哈希（手机端导出时算的）
  ///
  /// 恢复时拿它校验下载回来的文件，就能证明「原图 → 备份 → 下载」字节无损。
  /// 返回 null = 清单里没有这个基准（旧版 App 备份的），此时无法做该校验，
  /// 调用方应放行而不是报错 —— 校验能力缺失不等于内容有问题。
  String? clientSha256Of(String serverPath) {
    final v = _byPath[serverPath]?.clientSha256 ?? '';
    return v.isEmpty ? null : v;
  }

  /// 端到端校验结果（verified / mismatch / unchecked）
  String verifyStateOf(String serverPath) =>
      _byPath[serverPath]?.verifyState ?? 'unchecked';

  /// 查某个服务器路径记录的 sha256；没有记录时返回 null
  String? sha256Of(String serverPath) {
    final v = _shaByPath[serverPath];
    return (v == null || v.isEmpty) ? null : v;
  }

  ManifestIndex(this.entries) {
    _buildIndex();
  }

  /// 空清单
  factory ManifestIndex.empty() => ManifestIndex(const <ManifestEntry>[]);

  /// 从电脑拉取清单并建立索引
  ///
  /// 拉取失败（未配置、连不上、旧版接收端没有该接口）时返回 **null**，
  /// 调用方应回退到「仅用本地记录」的旧逻辑，不因此中断备份。
  static Future<ManifestIndex?> fetch(ServerClient client, {String? since}) async {
    try {
      final raw = await client.downloadManifest(since: since);
      if (raw == null) {
        return null;
      }

      // 同一 serverPath 可能有多行（重复上传、Backfill 后被权威数据补记），
      // 保留最后一次出现的那条
      final byPath = <String, ManifestEntry>{};
      final order = <String>[];
      for (final item in raw) {
        final path = item['serverPath'] as String? ?? '';
        if (path.isEmpty) {
          continue;
        }
        final entry = ManifestEntry.fromJson(item);
        if (!byPath.containsKey(path)) {
          order.add(path);
        }
        byPath[path] = entry;
      }

      return ManifestIndex(
        order.map((path) => byPath[path]!).toList(growable: false),
      );
    } catch (e) {
      print('[ManifestIndex] 清单拉取失败: $e');
      return null;
    }
  }

  void _buildIndex() {
    for (final e in entries) {
      // 全量索引：恢复校验需要按路径取到整条记录（原图侧哈希、校验状态）
      _byPath[e.serverPath] = e;
      if (e.sha256.isNotEmpty) {
        _shaByPath[e.serverPath] = e.sha256;
      }
      // 配对视频与主文件是同一个资产，指纹相同甚至更弱（没有宽高），
      // 放进索引会顶掉主文件条目，因此只收主文件
      if (e.isPairedVideo) {
        continue;
      }
      final fp = e.fingerprint;
      _byFingerprint[fp.key] = e;
      _byLooseFingerprint[fp.looseKey] = e;
    }
  }

  bool get isEmpty => entries.isEmpty;

  int get length => entries.length;

  /// 已备份主文件的指纹集合
  Set<String> get fingerprintKeys => _byFingerprint.keys.toSet();

  /// 已备份主文件的宽松指纹集合
  Set<String> get looseFingerprintKeys => _byLooseFingerprint.keys.toSet();

  /// 精确指纹是否已在电脑上
  bool containsFingerprint(AssetFingerprint fp) =>
      _byFingerprint.containsKey(fp.key);

  /// 宽松指纹是否已在电脑上（宽高缺失时兜底）
  bool containsLooseFingerprint(AssetFingerprint fp) =>
      _byLooseFingerprint.containsKey(fp.looseKey);

  /// 主文件数量（不含配对视频）= 已备份的资产数
  int get assetCount => _byFingerprint.length;

  /// 配对视频数量
  int get pairedVideoCount => entries.where((e) => e.isPairedVideo).length;

  /// 推断数据（Backfill 补录）条数
  int get inferredCount => entries.where((e) => e.inferred).length;

  /// 从清单重建备份记录列表
  ///
  /// 用于「手机沙盒丢了，但电脑上有清单」的场景：据此恢复备份与恢复功能，
  /// 完全不依赖原来的 `backup_records.json`。
  ///
  /// 归并规则：同一 `pairKey` 下 role=main 的行是主体，
  /// role=pairedVideo 的行填进它的 `livePhotoVideoRelativePath`。
  List<BackupRecord> toRecords() {
    final pairedByKey = <String, String>{};
    for (final e in entries) {
      if (e.isPairedVideo && e.pairKey.isNotEmpty) {
        pairedByKey[e.pairKey] = e.serverPath;
      }
    }

    final result = <BackupRecord>[];
    for (final e in entries) {
      if (e.isPairedVideo) {
        continue;
      }
      final paired = e.pairKey.isEmpty ? null : pairedByKey[e.pairKey];
      final ts = e.createdUnix;
      final ms = ((ts ?? 0) * 1000).round();

      result.add(
        BackupRecord(
          localIdentifier: e.assetId,
          relativePath: e.serverPath,
          // Unix 毫秒 → 本地时间，与 App 直接生成的 DateTime 同义
          creationDate: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
              .toLocal(),
          creationTimestamp: (ts != null && ts > 0) ? ts : ms / 1000.0,
          mediaType: AssetFingerprint.normalizeMediaType(e.rawMediaType),
          livePhotoVideoRelativePath: paired,
          pixelWidth: e.pixelWidth,
          pixelHeight: e.pixelHeight,
        ),
      );
    }
    return result;
  }
}