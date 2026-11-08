import 'dart:convert';
import 'dart:io';

import '../helpers/file_helper.dart';

/// 实时调试桥的连接信息（地址 + 6 位连接码）
///
/// 存在手机上是为了**一次扫码全填好**：接收端生成的配对二维码会把
/// 调试桥的端口和连接码一起带上，扫一次之后
///   · 「服务器设置」填好备份地址与令牌
///   · 「实时调试」页直接就能连，不用再敲一遍地址和六位数字
///
/// 连接码本身是短期凭据（默认 7 天），过期后重新扫一次即可。
class DebugBridgeConfig {
  const DebugBridgeConfig({required this.address, required this.token});

  /// 形如 `http://192.168.101.27:18081`
  final String address;

  /// 6 位数字连接码
  final String token;

  static const empty = DebugBridgeConfig(address: '', token: '');

  bool get isConfigured => address.trim().isNotEmpty && token.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'address': address, 'token': token};

  factory DebugBridgeConfig.fromJson(Map<String, dynamic> json) =>
      DebugBridgeConfig(
        address: '${json['address'] ?? ''}',
        token: '${json['token'] ?? ''}',
      );

  static Future<File> _file() async {
    final docDir = await FileHelper.getDocumentsDirectory();
    return File('${docDir.path}${Platform.pathSeparator}debug_bridge.json');
  }

  static Future<DebugBridgeConfig> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return empty;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return empty;
      return DebugBridgeConfig.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
    } catch (_) {
      return empty;
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(jsonEncode(toJson()), flush: true);
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
