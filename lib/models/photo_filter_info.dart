import 'dart:convert';
import 'dart:io';

/// Apple 相册编辑配方（`adjustmentData`）的解析结果
///
/// ## 它究竟是什么（2026-10-20 更正）
///
/// `Adjustments.plist` 和 `.aae` 都是 XML plist，其中 `adjustmentData`
/// 的值是 base64 的二进制。此前把它判成"高熵私有二进制、程序读不出来"，
/// 是因为按 **zlib** 去解 —— 它是**裸 DEFLATE**（没有 zlib 头），
/// 必须用 `ZLibDecoder(raw: true)` 才解得开。
///
/// 解开后是一段 UTF-8 JSON：
///
/// ```json
/// {"formatVersion": 1,
///  "adjustments": [
///    {"identifier": "Effect", "enabled": true,
///     "settings": {"effectName": "3DVivid", "effectIntensity": 0.5}}
///  ]}
/// ```
///
/// 所以滤镜名、强度、编辑操作**都读得出来**。
///
/// ## 那么判据该是什么
///
/// 不是"附件字节一致"。iOS 导入时会把 plist 里的 `adjustmentTimestamp`
/// 重置成拍摄时间（文件时间、资源 import date、request import date、
/// request modification date、`unmanagedAdjustment.adjustmentTimestamp`
/// 五类实验都留不住），所以字节**必然**不同，而编辑操作完全一致。
///
/// 正确判据：**解码后的编辑操作一致** —— 即 [signature] 相同。
class PhotoFilterInfo {
  const PhotoFilterInfo._(
    this.status,
    this.description, {
    this.identifier,
    this.intensity,
    this.operationCount = 0,
    this.signature,
  });

  /// `known` 已知滤镜 / `none` 无显式滤镜项 / `unknown` 解析不了
  final String status;

  final String description;

  /// Apple 的 effectName，如 `3DVivid`
  final String? identifier;

  /// 效果强度 0..1
  final double? intensity;

  /// 配方里一共有几个编辑操作
  final int operationCount;

  /// 归一化后的编辑操作签名（排序 key 的 JSON），用于跨副本比对
  final String? signature;

  /// 解码后配方上限，防止解压炸弹
  static const int maxBytes = 1024 * 1024;

  /// 是否成功解析出配方（`none` 也算：只是没有显式的 Effect 项）
  bool get isKnown => status != 'unknown';

  String get display =>
      intensity == null ? description : '$description · ${(intensity! * 100).round()}%';

  static PhotoFilterInfo unknown(String reason) =>
      PhotoFilterInfo._('unknown', '滤镜未知：$reason');

  /// 已知的 effectName → 中文名（iOS 17.7.2 样本实测）
  static const Map<String, String> _names = {
    '3DVivid': '鲜明',
    '3DDramatic': '反差色',
    '3DVividWarm': '鲜暖色',
  };

  /// 从 plist 文本（`Adjustments.plist` / `.aae`）解析
  ///
  /// 不抛异常：任何异常都收敛成 [unknown]，因为"解析不了"和"没有滤镜"
  /// 是两件完全不同的事，不能混为一谈。
  static PhotoFilterInfo fromPlistText(String text) {
    try {
      final dataMatch = RegExp(
        r'<key>\s*adjustmentData\s*</key>\s*<data>([\s\S]*?)</data>',
      ).firstMatch(text);
      if (dataMatch == null) {
        return unknown('plist 里没有 adjustmentData');
      }
      final raw = dataMatch.group(1)!.replaceAll(RegExp(r'\s'), '');
      if (raw.isEmpty) return unknown('adjustmentData 为空');
      return fromEnvelopeBytes(base64Decode(raw));
    } catch (e) {
      return unknown('plist 解析失败（$e）');
    }
  }

  /// 从 `adjustmentData` 的原始二进制解析（裸 DEFLATE + JSON）
  static PhotoFilterInfo fromEnvelopeBytes(List<int> envelope) {
    if (envelope.isEmpty) return unknown('配方数据为空');
    if (envelope.length > maxBytes) return unknown('配方数据过大');

    late final List<int> inflated;
    try {
      inflated = ZLibDecoder(raw: true).convert(envelope);
    } catch (_) {
      // 裸 DEFLATE 解不开，说明不是 iOS 17 的配方结构
      return unknown('配方解压失败（不是裸 DEFLATE）');
    }
    if (inflated.length > maxBytes) return unknown('解压后过大');

    try {
      return _fromRecipeJson(jsonDecode(utf8.decode(inflated)));
    } catch (e) {
      return unknown('配方解析失败（$e）');
    }
  }

  static PhotoFilterInfo _fromRecipeJson(Object? recipe) {
    if (recipe is! Map) return unknown('配方不是对象');
    if (recipe['adjustments'] is! List) return unknown('配方缺少 adjustments');
    final operations = recipe['adjustments'] as List;

    final effects = <Map>[];
    for (final op in operations) {
      if (op is! Map) return unknown('编辑操作结构不支持');
      if (op['identifier'] == 'Effect' &&
          op['enabled'] == true &&
          op['settings'] is Map) {
        effects.add(op['settings'] as Map);
      }
    }

    final signature = jsonEncode(_canonical(operations));

    if (effects.isEmpty) {
      return PhotoFilterInfo._(
        'none',
        '无显式滤镜项',
        operationCount: operations.length,
        signature: signature,
      );
    }
    if (effects.length != 1) {
      return PhotoFilterInfo.unknown('存在 ${effects.length} 项滤镜');
    }

    final effect = effects.first;
    final intensity = effect['effectIntensity'];
    if (intensity is! num || !intensity.isFinite || intensity < 0 || intensity > 1) {
      return unknown('滤镜强度不合法');
    }
    final name = effect['effectName'];
    final label = name is String ? _names[name] : null;
    if (label == null) {
      // 名称未知不影响"配方是否一致"的判断，签名照给
      return PhotoFilterInfo._(
        'unknown',
        '未识别滤镜：${name ?? '(无名称)'}',
        identifier: name is String ? name : null,
        intensity: intensity.toDouble(),
        operationCount: operations.length,
        signature: signature,
      );
    }
    return PhotoFilterInfo._(
      'known',
      label,
      identifier: name as String,
      intensity: intensity.toDouble(),
      operationCount: operations.length,
      signature: signature,
    );
  }

  /// 递归排序 map 的 key，让签名与字段顺序无关
  static Object? _canonical(Object? value) {
    if (value is List) return value.map(_canonical).toList();
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    return value;
  }

  @override
  String toString() => 'PhotoFilterInfo($status, $description, '
      'ops=$operationCount, intensity=$intensity)';
}
