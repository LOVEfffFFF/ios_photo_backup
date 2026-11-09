import 'dart:convert';

import 'photo_filter_info.dart';

/// 「相册里已经用过哪些滤镜」的一次扫描结果
///
/// ## 为什么需要它
/// Apple 不公开滤镜清单，`effectName` 只存在于**真实配方**里 —— 没挂过的滤镜
/// 在系统里没有任何痕迹可枚举。所以要回答「一共几种、都叫什么」，只能把相册里
/// 所有已编辑资产的配方扫一遍、解出来去重。
///
/// 原生只负责把配方资源的原始字节读出来（见 `scanUsedEffects`），解压与映射
/// 全在 Dart 侧复用 [PhotoFilterInfo]，避免两张表漂移。
class EffectScanResult {
  const EffectScanResult({
    required this.scannedAssets,
    required this.editedAssets,
    required this.recipeResources,
    required this.totalBytes,
    required this.truncated,
    required this.timedOut,
    required this.samples,
    this.error = '',
  });

  /// 相册总资产数
  final int scannedAssets;

  /// 其中 `hasAdjustments == true` 的数量（真正被扫的对象）
  final int editedAssets;

  /// 这些资产上的配方类资源个数（Adjustments.plist / .aae）
  final int recipeResources;

  /// 回传的原始字节总数
  final int totalBytes;

  /// 因上限或超时只扫了一部分
  final bool truncated;

  /// 120 秒兜底触发（某个 iCloud 资源没回调）
  final bool timedOut;

  /// 原生侧错误描述，空 = 正常
  final String error;

  final List<EffectScanSample> samples;

  factory EffectScanResult.fromChannel(Map<String, dynamic> raw) {
    final rows = ((raw['samples'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => EffectScanSample.fromChannel(Map<String, dynamic>.from(e)))
        .toList();
    return EffectScanResult(
      scannedAssets: (raw['scannedAssets'] as num?)?.toInt() ?? 0,
      editedAssets: (raw['editedAssets'] as num?)?.toInt() ?? 0,
      recipeResources: (raw['recipeResources'] as num?)?.toInt() ?? 0,
      totalBytes: (raw['totalBytes'] as num?)?.toInt() ?? 0,
      truncated: raw['truncated'] == true,
      timedOut: raw['timedOut'] == true,
      samples: rows,
      error: '${raw['error'] ?? ''}',
    );
  }

  /// 按 effectName 汇总。
  ///
  /// `identifier == null` 的样本（配方里没有 `Effect` 项，只有裁剪/调整/RAW 解码）
  /// 单独归成一栏，不冒充「滤器」。
  List<EffectNameStat> get stats {
    final byName = <String, List<EffectScanSample>>{};
    for (final s in samples) {
      final key = s.recipe.identifier ?? '';
      byName.putIfAbsent(key, () => []).add(s);
    }
    final list = byName.entries.map((e) {
      final rows = e.value;
      final assetIds = rows.map((r) => r.assetId).toSet();
      final intensities = <double>{
        for (final r in rows)
          if (r.recipe.intensity != null) r.recipe.intensity!,
      }.toList()
        ..sort();
      // 同一 effectName 的中文名以「已映射」的那条为准
      String? label;
      for (final r in rows) {
        if (r.recipe.status == 'known') {
          label = r.recipe.description;
          break;
        }
      }
      return EffectNameStat(
        effectName: e.key,
        label: label,
        sampleCount: rows.length,
        assetCount: assetIds.length,
        intensities: intensities,
      );
    }).toList();
    // 已知中文名的排前面，再按样本数降序
    list.sort((a, b) {
      if ((a.label != null) != (b.label != null)) {
        return a.label != null ? -1 : 1;
      }
      return b.sampleCount.compareTo(a.sampleCount);
    });
    return list;
  }

  /// 可直接复制给他人（或贴进对话）的纯文本摘要
  String get report {
    final b = StringBuffer()
      ..writeln('相册已用滤镜扫描（配方 raw DEFLATE → JSON 解码）')
      ..writeln('资产 ${scannedAssets} 个，其中已编辑 ${editedAssets} 个；'
          '配方资源 ${recipeResources} 个，读回 ${samples.length} 个'
          '（${_kb(totalBytes)}）');
    if (truncated) b.writeln('⚠ 因上限/体积限制只扫了一部分');
    if (timedOut) b.writeln('⚠ 120 秒兜底触发，部分资源未回调（多半是 iCloud 原件）');
    if (error.isNotEmpty) b.writeln('✗ $error');
    b.writeln('滤镜：');
    for (final s in stats) {
      b.writeln('  ${s.display} · 样本 ${s.sampleCount}'
          ' · 资产 ${s.assetCount}'
          '${s.intensities.isEmpty ? '' : ' · 强度 ${s.intensityText}'}');
    }
    // 慢动作 / NSKeyedArchiver 归档：读懂了，只是不是滤镜，单独说明
    final notFilter =
        samples.where((s) => s.recipe.status == 'notFilter').toList();
    if (notFilter.isNotEmpty) {
      final kinds =
          notFilter.map((s) => s.recipe.description).toSet().join('；');
      b.writeln('非滤镜配方 ${notFilter.length} 个（算作原片）：$kinds');
    }
    final unknown = samples.where((s) => !s.recipe.isKnown).toList();
    if (unknown.isNotEmpty) {
      b.writeln('解码失败 ${unknown.length} 个：');
      for (final s in unknown.take(20)) {
        b.writeln('  ${s.filename}: ${s.recipe.description}');
        if (s.headHex.isNotEmpty) b.writeln('      file=${s.headHex}');
        if (s.payloadHeadHex.isNotEmpty) {
          b.writeln('      payload=${s.payloadHeadHex}');
        }
      }
    }
    return b.toString();
  }

  static String _kb(int bytes) => bytes < 1024
      ? '$bytes B'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';
}

/// 一条配方样本（一个资源文件）
class EffectScanSample {
  const EffectScanSample({
    required this.assetId,
    required this.creationDate,
    required this.filename,
    required this.uti,
    required this.typeRawValue,
    required this.bytes,
    required this.truncated,
    required this.error,
    required this.headHex,
    required this.payloadHeadHex,
    required this.recipe,
  });

  final String assetId;
  final double creationDate;
  final String filename;
  final String uti;

  /// `PHAssetResourceType.rawValue`：7 = adjustmentData，这里只作证据，不作判据
  final int typeRawValue;
  final int bytes;
  final bool truncated;
  final String error;

  /// 资源前 24 字节的十六进制。
  ///
  /// 解压失败时这是唯一的格式线索：`62 70 6c 69 73 74` = `bplist`、
  /// `50 4b` = zip、`1f 8b` = gzip、`78 9c` = 带头的 zlib …… 只看
  /// 「不是裸 DEFLATE」这一句永远查不下去。
  final String headHex;

  /// plist 里 `<data>` 解码后（即配方载荷）的前 24 字节十六进制。
  ///
  /// 资源文件头永远是 `3c 3f 78 6d 6c`（`<?xml`），只有载荷头才能说明
  /// 配方到底用的什么容器：`78 9c` = zlib 带头、`1f 8b` = gzip、
  /// `7b 22` = 未压缩 JSON。
  final String payloadHeadHex;

  /// 解码后的配方（见 [PhotoFilterInfo]）
  final PhotoFilterInfo recipe;

  factory EffectScanSample.fromChannel(Map<String, dynamic> m) {
    final b64 = '${m['base64'] ?? ''}';
    // 单条 base64 坏掉不能让整次扫描失败：返回一条「解析失败」样本即可
    List<int> bytes = const <int>[];
    var decodeError = '';
    if (b64.isNotEmpty) {
      try {
        bytes = base64Decode(b64);
      } catch (e) {
        decodeError = 'base64 解码失败：$e';
      }
    }
    final transportError = '${m['error'] ?? ''}';
    final decoded = _decode(
      bytes,
      decodeError.isNotEmpty ? decodeError : transportError,
    );
    return EffectScanSample(
      assetId: '${m['assetId'] ?? ''}',
      creationDate: (m['creationDate'] as num?)?.toDouble() ?? 0,
      filename: '${m['filename'] ?? ''}',
      uti: '${m['uti'] ?? ''}',
      typeRawValue: (m['typeRawValue'] as num?)?.toInt() ?? 0,
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      truncated: m['truncated'] == true,
      error: transportError,
      headHex: '${m['headHex'] ?? ''}',
      payloadHeadHex: decoded.payloadHead,
      recipe: decoded.info,
    );
  }

  /// 先按 XML plist 解（`<key>adjustmentData</key><data>…</data>`），
  /// 解不开再把这批字节本身当作裸配方 envelope 试一次。
  static _Decoded _decode(List<int> bytes, String transportError) {
    if (transportError.isNotEmpty) {
      return _Decoded(PhotoFilterInfo.unknown('读取失败：$transportError'));
    }
    if (bytes.isEmpty) return _Decoded(PhotoFilterInfo.unknown('资源为空'));

    final text = utf8.decode(bytes, allowMalformed: true);
    final fromPlist = PhotoFilterInfo.fromPlistText(text);
    if (fromPlist.isKnown) return _Decoded(fromPlist);

    // 走到这里说明配方解不开。此时**资源文件头永远是 `<?xml`**，没有诊断价值；
    // 真正能说明问题的是 `<data>` 里那段的头：
    //   78 9c / 78 01 / 78 da → zlib 带头（不是裸 DEFLATE）
    //   1f 8b                → gzip
    //   7b 22                → 未压缩的 JSON（`{"`）
    //   其它                 → 未知容器
    final payloadHead = _plistPayloadHead(text);

    final direct = PhotoFilterInfo.fromEnvelopeBytes(bytes);
    if (direct.isKnown) return _Decoded(direct, payloadHead);
    return _Decoded(fromPlist, payloadHead);
  }

  /// 从 XML plist 文本里抠出 `adjustmentData` 的 base64，返回解码后的前 24 字节
  static String _plistPayloadHead(String text) {
    final m = RegExp(
      r'<key>\s*adjustmentData\s*</key>\s*<data>([\s\S]*?)</data>',
    ).firstMatch(text);
    if (m == null) return '';
    try {
      final raw = base64Decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
      if (raw.isEmpty) return '';
      return raw
          .take(24)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
    } catch (_) {
      return '';
    }
  }
}

/// `_decode` 的返回值：配方结果 + 载荷字节头（只有失败时才有诊断意义）
class _Decoded {
  const _Decoded(this.info, [this.payloadHead = '']);

  final PhotoFilterInfo info;
  final String payloadHead;
}

/// 一个 effectName 的汇总
class EffectNameStat {
  const EffectNameStat({
    required this.effectName,
    required this.label,
    required this.sampleCount,
    required this.assetCount,
    required this.intensities,
  });

  /// Apple 的 effectName；空串表示配方里没有 `Effect` 项
  final String effectName;

  /// 已实测映射的中文名；null = 名字尚未采集
  final String? label;

  final int sampleCount;
  final int assetCount;

  /// 出现过的强度值（0..1），已去重排序
  final List<double> intensities;

  bool get isNoFilter => effectName.isEmpty;

  bool get isMapped => label != null;

  String get display {
    if (isNoFilter) return '原片（未套用滤镜）';
    if (label != null) return '$label（$effectName）';
    return '$effectName（中文名未采集）';
  }

  String get intensityText => intensities
      .map((e) => '${(e * 100).toStringAsFixed(1)}%')
      .join(' / ');
}
