import 'dart:convert';
import 'dart:io';

import '../helpers/file_helper.dart';

/// 备份接收端（电脑）的连接配置
///
/// 用户只需要填一个地址（IP 或域名，可带端口），其余交给解析：
///   "192.168.1.10"                → http://192.168.1.10:8080
///   "192.168.1.10:9000"           → http://192.168.1.10:9000
///   "http://nas.local:8080"       → http://nas.local:8080
///   "https://backup.example.com"  → https://backup.example.com:8080
class ServerConfig {
  final String scheme;
  final String host;
  final int port;

  /// 访问令牌，需与接收端 -Token 一致；为空表示接收端未启用鉴权
  final String token;

  /// 单次备份的数量上限；0 表示不限制（测试时设为小值很方便）
  final int backupLimit;

  const ServerConfig({
    this.scheme = 'http',
    this.host = '',
    this.port = 8080,
    this.token = '',
    this.backupLimit = 0,
  });

  static const ServerConfig empty = ServerConfig();

  bool get isConfigured => host.trim().isNotEmpty && port > 0;

  String get baseUrl => '$scheme://$host:$port';

  /// 解析用户输入的地址，非法时返回 null
  static ServerConfig? parseAddress(
    String input, {
    String token = '',
    int backupLimit = 0,
  }) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    var normalized = raw;
    if (!normalized.contains('://')) {
      normalized = 'http://$normalized';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
    final port = uri.hasPort ? uri.port : 8080;

    return ServerConfig(
      scheme: scheme,
      host: uri.host,
      port: port,
      token: token.trim(),
      backupLimit: backupLimit < 0 ? 0 : backupLimit,
    );
  }

  /// 供界面回显的地址文本
  String get displayAddress => '$host:$port';

  Map<String, dynamic> toJson() => {
        'scheme': scheme,
        'host': host,
        'port': port,
        'token': token,
        'backupLimit': backupLimit,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      scheme: (json['scheme'] as String?) ?? 'http',
      host: (json['host'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 8080,
      token: (json['token'] as String?) ?? '',
      backupLimit: (json['backupLimit'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<File> _configFile() async {
    final docDir = await FileHelper.getDocumentsDirectory();
    return File('${docDir.path}${Platform.pathSeparator}server_config.json');
  }

  /// 读取本地保存的配置，不存在或损坏时返回空配置
  static Future<ServerConfig> load() async {
    try {
      final file = await _configFile();
      if (!await file.exists()) return empty;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return empty;
      return ServerConfig.fromJson(
        jsonDecode(content) as Map<String, dynamic>,
      );
    } catch (e) {
      print('[ServerConfig] 配置读取失败: $e');
      return empty;
    }
  }

  /// 保存到本地
  Future<void> save() async {
    final file = await _configFile();
    await file.writeAsString(jsonEncode(toJson()), flush: true);
  }

  ServerConfig copyWith({
    String? scheme,
    String? host,
    int? port,
    String? token,
    int? backupLimit,
  }) {
    return ServerConfig(
      scheme: scheme ?? this.scheme,
      host: host ?? this.host,
      port: port ?? this.port,
      token: token ?? this.token,
      backupLimit: backupLimit ?? this.backupLimit,
    );
  }
}
