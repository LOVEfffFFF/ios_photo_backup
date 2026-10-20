import 'package:flutter/services.dart';

/// 扫码解析出来的配对信息
class PairingInfo {
  /// 地址（host 或 host:port），可直接喂给 `ServerConfig.parseAddress`
  final String address;

  /// 访问密钥；接收端未启用鉴权时为空串
  final String token;

  const PairingInfo({required this.address, required this.token});

  @override
  String toString() =>
      'PairingInfo(address: $address, token: ${token.isEmpty ? '空' : '${token.length} 位'})';
}

/// 扫码失败：相机不可用，或扫到的内容不是配对码
class QrScanException implements Exception {
  /// 机读码：CAMERA_DENIED / EMPTY / BAD_FORMAT / BAD_URL / UNKNOWN
  final String code;
  final String message;

  const QrScanException(this.code, this.message);

  @override
  String toString() => 'QrScanException($code): $message';
}

/// App 内原生扫码（iOS 侧 AVFoundation，通道 com.photobackup/scanner）
///
/// 与「电脑浏览器打开 /qr 页面」是两条并列的入口，二维码内容完全一致：
///   pb1|<host>:<port>|<token>
class QrScanner {
  static const _channel = MethodChannel('com.photobackup/scanner');

  /// 弹出扫码界面。
  ///
  /// 返回 null = 用户取消；抛 [QrScanException] / [PlatformException]
  /// 表示相机不可用或内容不认识。
  static Future<PairingInfo?> scan() async {
    final raw = await _channel.invokeMethod<String>('scanQrCode');
    if (raw == null) return null;
    return parse(raw);
  }

  /// 解析扫到的字符串（纯函数，便于测试）
  ///
  /// 认两种内容：
  ///   1. 接收端 /qr 的配对格式：`pb1|地址|令牌`
  ///   2. 普通 URL（`http://ip:port` / `https://nas.local:8080`），没有令牌
  ///
  /// 为什么不做「猜」：扫到不认识的内容时直接报错，让用户知道扫错了，
  /// 而不是把一堆乱七八糟的字符串填进地址框里、等到连不上才发现。
  static PairingInfo parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const QrScanException('EMPTY', '二维码内容为空');
    }
    if (text.startsWith('pb1|')) {
      final parts = text.split('|');
      if (parts.length < 2 || parts[1].trim().isEmpty) {
        throw const QrScanException('BAD_FORMAT', '配对码缺少地址段');
      }
      final token = parts.length >= 3 ? parts[2].trim() : '';
      return PairingInfo(address: parts[1].trim(), token: token);
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) {
        throw const QrScanException('BAD_URL', '网址无法解析');
      }
      final address = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      return PairingInfo(address: address, token: '');
    }
    throw const QrScanException('UNKNOWN', '不是本 App 的配对码（应以 pb1| 开头）');
  }
}
