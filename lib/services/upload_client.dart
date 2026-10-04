import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'server_config.dart';

/// 单次上传的结果
class UploadResult {
  /// 本次是否成功（含被服务器判定为已存在而跳过）
  final bool success;

  /// 服务器已有同名同大小文件，本次未重复传输
  final bool skipped;

  /// 失败原因
  final String? message;

  const UploadResult({
    required this.success,
    this.skipped = false,
    this.message,
  });
}

/// 上传客户端：把资产以原始字节 POST 给电脑端接收服务
///
/// 协议见接收端脚本 PhotoBackupReceiver.ps1：
///   POST {baseUrl}/upload
///     X-Auth-Token: <可选>
///     X-File-Path:  <URL 编码的相对路径>
///     body:         文件原始字节
class UploadClient {
  final ServerConfig config;

  /// 单个文件的上传超时（大视频留足时间）
  final Duration uploadTimeout;

  UploadClient(
    this.config, {
    this.uploadTimeout = const Duration(minutes: 15),
  });

  /// 连通性探测：返回 null 表示正常，否则返回错误描述
  Future<String?> testConnection() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse('${config.baseUrl}/ping'));
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      await response.drain();
      if (response.statusCode == 200) {
        return null;
      }
      if (response.statusCode == 401) {
        return '密钥不正确（HTTP 401），请与接收端 -Token 保持一致';
      }
      return '服务器返回 HTTP ${response.statusCode}';
    } on TimeoutException {
      return '连接超时：请确认电脑端服务已启动、手机与电脑在同一局域网';
    } catch (e) {
      return '连接失败：$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 上传单个文件
  Future<UploadResult> uploadFile({
    required File file,
    required String relativePath,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.postUrl(Uri.parse('${config.baseUrl}/upload'));
      request.headers
          .set('X-File-Path', Uri.encodeComponent(relativePath));
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }
      request.headers.contentType = ContentType.binary;
      final length = await file.length();
      request.contentLength = length;
      await request.addStream(file.openRead());

      final response = await request.close().timeout(uploadTimeout);
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        var skipped = false;
        try {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          skipped = decoded['skipped'] == true;
        } catch (_) {
          // 接收端返回体解析失败不影响「上传成功」的判定
        }
        return UploadResult(success: true, skipped: skipped);
      }

      var message = 'HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        message = (decoded['message'] as String?) ?? message;
      } catch (_) {
        // 忽略
      }
      if (response.statusCode == 401) {
        message = '鉴权失败：密钥与接收端不一致';
      }
      return UploadResult(success: false, message: message);
    } on TimeoutException {
      return const UploadResult(success: false, message: '上传超时');
    } catch (e) {
      return UploadResult(success: false, message: '$e');
    } finally {
      client.close(force: true);
    }
  }
}
