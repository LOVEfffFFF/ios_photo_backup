import 'package:flutter/services.dart';

/// 扫码解析出来的配对信息
class PairingInfo {
  /// 地址（host 或 host:port），可直接喂给 `ServerConfig.parseAddress`
  final String address;

  /// 访问密钥；接收端未启用鉴权时为空串
  final String token;

  /// 调试桥地址（形如 `http://192.168.1.10:18081`）；二维码里没带时为 null
  final String? debugAddress;

  /// 调试桥连接码（6 位数字）；二维码里没带时为 null
  final String? debugToken;

  const PairingInfo({
    required this.address,
    required this.token,
    this.debugAddress,
    this.debugToken,
  });

  bool get hasDebug =>
      (debugAddress ?? '').trim().isNotEmpty &&
      (debugToken ?? '').trim().isNotEmpty;

  @override
  String toString() => 'PairingInfo(address: $address, '
      'token: ${token.isEmpty ? '空' : '${token.length} 位'}'
      '${hasDebug ? '，调试 $debugAddress' : ''})';
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
  /// 认三种内容：
  ///   1. `pb1|地址|令牌` —— 旧版二维码，只有备份服务器
  ///   2. `pb2|地址|令牌|调试端口或地址|连接码` —— 一把填好备份与实时调试
  ///   3. 普通 URL（`http://ip:port` / `https://nas.local:8080`），没有令牌
  ///
  /// pb2 的第 4 段可以是纯端口（`18081`），此时主机名沿用第 2 段 ——
  /// 常见情况是备份接收端和调试桥跑在同一台电脑上，省下十来个字节，
  /// 二维码版本更低、模块更大，隔着屏幕反而更好扫。
  ///
  /// 为什么不做「猜」：扫到不认识的内容时直接报错，让用户知道扫错了，
  /// 而不是把一堆乱七八糟的字符串填进地址框里、等到连不上才发现。
  static PairingInfo parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const QrScanException('EMPTY', '二维码内容为空');
    }
    if (text.startsWith('pb1|') || text.startsWith('pb2|')) {
      final parts = text.split('|');
      if (parts.length < 2 || parts[1].trim().isEmpty) {
        throw const QrScanException('BAD_FORMAT', '配对码缺少地址段');
      }
      final address = parts[1].trim();
      final token = parts.length >= 3 ? parts[2].trim() : '';

      String? debugAddress;
      String? debugToken;
      if (text.startsWith('pb2|') && parts.length >= 5) {
        final debugTarget = parts[3].trim();
        final code = parts[4].trim();
        if (debugTarget.isNotEmpty && code.isNotEmpty) {
          // 只写了端口 → 复用备份地址里的主机名
          final host = debugTarget.contains(':')
              ? debugTarget
              : '${_hostOf(address)}:$debugTarget';
          debugAddress = host.startsWith('http') ? host : 'http://$host';
          debugToken = code;
        }
      }

      return PairingInfo(
        address: address,
        token: token,
        debugAddress: debugAddress,
        debugToken: debugToken,
      );
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final uri = Uri.tryParse(text);
      if (uri == null || uri.host.isEmpty) {
        throw const QrScanException('BAD_URL', '网址无法解析');
      }
      final address = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      return PairingInfo(address: address, token: '');
    }
    throw const QrScanException('UNKNOWN', '不是本 App 的配对码（应以 pb1| 或 pb2| 开头）');
  }

  /// 从 `host:port` / `[v6]:port` 里取主机名
  static String _hostOf(String address) {
    if (address.startsWith('[')) {
      final end = address.indexOf(']');
      if (end > 0) return address.substring(1, end);
    }
    final idx = address.lastIndexOf(':');
    return idx <= 0 ? address : address.substring(0, idx);
  }
}
