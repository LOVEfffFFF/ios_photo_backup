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

/// 接收端（电脑）客户端：上传、下载、连通性探测
///
/// 协议见 windows-receiver/PhotoBackupReceiver.ps1：
///   GET  /ping                              连通性探测
///   POST /upload    X-File-Path: <相对路径>   上传文件原始字节
///   GET  /download?path=<相对路径>            下载文件（恢复用）
class ServerClient {
  final ServerConfig config;

  /// 单个文件的上传超时（大视频留足时间）
  final Duration uploadTimeout;

  /// 单个文件的下载超时
  final Duration downloadTimeout;

  ServerClient(
    this.config, {
    this.uploadTimeout = const Duration(minutes: 15),
    this.downloadTimeout = const Duration(minutes: 15),
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

  /// 将本地文件上传到接收端
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
          // 响应体解析失败不影响「上传成功」的判定
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

  /// 从接收端下载文件到 [targetPath]
  ///
  /// 返回实际写入的字节数；返回 -1 表示失败（不存在 / 鉴权失败 / 超时等）
  Future<int> downloadFile({
    required String relativePath,
    required String targetPath,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final uri = Uri.parse('${config.baseUrl}/download')
          .replace(queryParameters: {'path': relativePath});
      final request = await client.getUrl(uri);
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }

      final response = await request.close().timeout(downloadTimeout);
      if (response.statusCode != 200) {
        await response.drain();
        return -1;
      }

      final file = File(targetPath);
      await file.parent.create(recursive: true);
      sink = file.openWrite();

      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return received;
    } on TimeoutException {
      return -1;
    } catch (e) {
      return -1;
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 忽略关闭异常
      }
      client.close(force: true);
    }
  }
}
