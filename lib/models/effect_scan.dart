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
    final unknown = samples.where((s) => !s.recipe.isKnown).toList();
    if (unknown.isNotEmpty) {
      b.writeln('解码失败 ${unknown.length} 个：');
      for (final s in unknown.take(10)) {
        b.writeln('  ${s.filename}: ${s.recipe.description}');
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
    return EffectScanSample(
      assetId: '${m['assetId'] ?? ''}',
      creationDate: (m['creationDate'] as num?)?.toDouble() ?? 0,
      filename: '${m['filename'] ?? ''}',
      uti: '${m['uti'] ?? ''}',
      typeRawValue: (m['typeRawValue'] as num?)?.toInt() ?? 0,
      bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      truncated: m['truncated'] == true,
      error: transportError,
      recipe: _decode(
        bytes,
        decodeError.isNotEmpty ? decodeError : transportError,
      ),
    );
  }

  /// 先按 XML plist 解（`<key>adjustmentData</key><data>…</data>`），
  /// 解不开再把这批字节本身当作裸配方 envelope 试一次。
  static PhotoFilterInfo _decode(List<int> bytes, String transportError) {
    if (transportError.isNotEmpty) {
      return PhotoFilterInfo.unknown('读取失败：$transportError');
    }
    if (bytes.isEmpty) return PhotoFilterInfo.unknown('资源为空');

    final text = utf8.decode(bytes, allowMalformed: true);
    final fromPlist = PhotoFilterInfo.fromPlistText(text);
    if (fromPlist.isKnown) return fromPlist;

    final direct = PhotoFilterInfo.fromEnvelopeBytes(bytes);
    if (direct.isKnown) return direct;
    return fromPlist;
  }
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
