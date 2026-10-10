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
///   GET  /manifest[?since=<ISO时间>]          读取元数据清单（NDJSON）
///
/// /upload 还会带上一组元数据头，接收端把它们写进 manifest.jsonl ——
/// 那份清单是手机沙盒丢失后，唯一还能说清「哪个文件是什么照片」的地方：
///   X-Asset-Id             原设备的 localIdentifier
///   X-Pair-Key             同一资产（含 Live Photo 的照片与配对视频）共用
///   X-Role                 main | pairedVideo
///   X-Media-Type           image | video | live_photo
///   X-Creation-Timestamp   拍摄时间，Unix 秒（亚秒精度）
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
  ///
  /// 传入 [assetId] / [mediaType] / [creationTimestamp] / [role] / [pairKey]
  /// 后，接收端会把它们记入元数据清单。缺失时只是清单里对应字段为空，
  /// 不影响文件接收本身。
  Future<UploadResult> uploadFile({
    required File file,
    required String relativePath,
    String? assetId,
    String? mediaType,
    double? creationTimestamp,
    String? role,
    String? pairKey,
    int? pixelWidth,
    int? pixelHeight,
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
      _setHeaderIfPresent(request, 'X-Asset-Id', assetId);
      _setHeaderIfPresent(request, 'X-Media-Type', mediaType);
      _setHeaderIfPresent(request, 'X-Role', role);
      _setHeaderIfPresent(request, 'X-Pair-Key', pairKey);
      if (creationTimestamp != null) {
        // 固定小数点表示，避免 Dart 在极端数值下输出科学计数法
        request.headers
            .set('X-Creation-Timestamp', creationTimestamp.toStringAsFixed(6));
      }
      if (pixelWidth != null && pixelWidth > 0) {
        request.headers.set('X-Pixel-Width', '$pixelWidth');
      }
      if (pixelHeight != null && pixelHeight > 0) {
        request.headers.set('X-Pixel-Height', '$pixelHeight');
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

  /// 把 App 端的诊断日志上传到电脑，追加保存为 app_diagnostics.log
  ///
  /// 用途：排查问题时手机上不方便取日志，让用户一键把完整的判断过程
  /// （含 App 版本、记录状态、清单核对结果）送到电脑上留存。
  /// 返回 null 表示成功，否则返回错误描述。
  Future<String?> uploadDiagnostics(String content) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request =
          await client.postUrl(Uri.parse('${config.baseUrl}/diagnostics'));
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }
      final bytes = utf8.encode(content);
      // 直接写Content-Type 头：ContentType.text 需要两个位置参数
      // （primaryType, subType），少写一个会编译失败
      request.headers.set('Content-Type', 'text/plain; charset=utf-8');
      request.contentLength = bytes.length;
      request.add(bytes);

      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        return null;
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
      return message;
    } on TimeoutException {
      return '上传日志超时（接收端可能没启动）';
    } catch (e) {
      return '上传日志失败：$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 上传单个日志文件到电脑（覆盖写，同一份重复上传不会膨胀）
  ///
  /// 与 [uploadDiagnostics] 的分工：
  ///   · /diagnostics 追加一段文本到单个文件，用于人工上报诊断摘要
  ///   · /log      按文件名覆盖写入 logs\ 目录，用于同步完整的日志/崩溃日志
  ///
  /// 返回 true 表示成功。日志上传失败不应影响主流程，因此这里返回 bool
  /// 而不是抛异常（抛异常只能由调用方决定要不要吞掉，反而更容易漏）。
  Future<bool> uploadLog(String name, String content) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request =
          await client.postUrl(Uri.parse('${config.baseUrl}/log'));
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }
      request.headers.set('X-Log-Name', name);
      request.headers.set('Content-Type', 'text/plain; charset=utf-8');
      final bytes = utf8.encode(content);
      request.contentLength = bytes.length;
      request.add(bytes);

      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      await response.drain<void>();
      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } catch (_) {
      // 接收端没启动 / 网络不通：日志传不上去不是错误，下次启动再试
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取电脑上的元数据清单（manifest.jsonl）
  ///
  /// 返回解析后的条目列表；连接失败 / 非 200 时返回 null。
  ///
  /// 清单里每条形如：
  /// ```json
  /// {"v":1,"serverPath":"2026/10/xxx.heic","size":2094563,"sha256":"ab...",
  ///  "assetId":"...","pairKey":"...","role":"main","mediaType":"live_photo",
  ///  "createdUnix":1791413632.123456,"receivedAt":"...","inferred":false}
  /// ```
  /// 同一个 serverPath 可能出现多行（重复上传 / backfill 后被补记），
  /// 调用方需按 serverPath 取最后一条。
  ///
  /// [since] 为 ISO8601 时间，只取该时间之后收到的条目（增量同步）。
  Future<List<Map<String, dynamic>>?> downloadManifest({String? since}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var uri = Uri.parse('${config.baseUrl}/manifest');
      if (since != null && since.isNotEmpty) {
        uri = uri.replace(queryParameters: {'since': since});
      }
      final request = await client.getUrl(uri);
      if (config.token.isNotEmpty) {
        request.headers.set('X-Auth-Token', config.token);
      }

      final response = await request.close().timeout(downloadTimeout);
      if (response.statusCode != 200) {
        await response.drain();
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final entries = <Map<String, dynamic>>[];
      for (final line in const LineSplitter().convert(body)) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            // 清单里每条必须有 serverPath；缺字段的（异常行 / 旧版返回格式）
            // 直接丢弃，避免污染调用方的记录重建
            if (decoded['serverPath'] is String &&
                (decoded['serverPath'] as String).isNotEmpty) {
              entries.add(decoded);
            }
          }
        } catch (_) {
          // 跳过损坏的行，不影响其余条目
        }
      }
      return entries;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 仅在值非空时设置请求头（HTTP 头不能为空值）
  void _setHeaderIfPresent(HttpClientRequest request, String name, String? value) {
    if (value != null && value.isNotEmpty) {
      request.headers.set(name, value);
    }
  }
}