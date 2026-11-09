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

/// 本 App 的协议身份标识
///
/// **必须与 `windows-receiver/PhotoBackupReceiver.ps1` 里的 `$script:ImplId` 完全一致。**
///
/// ## 为什么需要它
///
/// 同一个局域网里可能同时跑着好几个「相册备份」实现（不同分支、不同 AI 写的版本，
/// 典型例子是 `ios_photo_backup` 与 `ios_photo_backup_openai`）。它们的分层、
/// 端点名甚至 `/ping` 的返回都一样，区别只在行为细节。
///
/// 没有标识时会出现两种"静默错配"：
///
///   · App 连上**别人的接收端**，上传成功、状态 200，但文件落在别人的目录里；
///   · 本项目的接收端收下**别人的 App** 传来的文件，manifest 混进陌生条目。
///
/// 两种情况都不会报错，直到核对数据时才发现对不上。所以标识必须是
/// **双向、强制**的：App 校验服务端返回的 `impl`，服务端校验请求头里的 `X-Client-Impl`。
const String clientImplId = 'photobackup-main';

/// 协议版本号
///
/// 服务端 `/ping` 会返回 `proto`。不一致说明两端行为可能有出入
/// （例如资源槽位映射变了），直接拒绝比半路出错更容易排查。
const int protocolVersion = 2;

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

  /// 每个请求都带上身份标识与令牌
  ///
  /// 服务端会对 /upload 等业务端点核对 [clientImplId]，不带标识的请求会被 403。
  void _applyIdentity(HttpClientRequest request) {
    request.headers.set('X-Client-Impl', clientImplId);
    if (config.token.isNotEmpty) {
      request.headers.set('X-Auth-Token', config.token);
    }
  }

  /// 连通性探测：返回 null 表示正常，否则返回错误描述
  ///
  /// 注意这里**不只看 HTTP 200**：任何 HTTP 服务（包括别的 AI 写的接收端）
  /// 都能返回 200。必须核对响应里的 `impl` / `proto` 才能确定
  /// 「这台服务器是不是本项目的那一套」。
  Future<String?> testConnection() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse('${config.baseUrl}/ping'));
      _applyIdentity(request);
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 401) {
        return '密钥不正确（HTTP 401），请与接收端 -Token 保持一致';
      }
      if (response.statusCode != 200) {
        return '服务器返回 HTTP ${response.statusCode}';
      }
      return checkServerIdentity(body);
    } on TimeoutException {
      return '连接超时：请确认电脑端服务已启动、手机与电脑在同一局域网';
    } catch (e) {
      return '连接失败：$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 校验 `/ping` 的响应确实来自「本项目的接收端」
  ///
  /// 返回 null 表示通过，否则返回给人看的失败原因。抽成静态方法是为了
  /// 让扫码配对、设置页、自动化测试都用同一套判定。
  static String? checkServerIdentity(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! Map) {
      return '这台服务器没有返回项目标识，不是本 App 配套的接收端'
          r'（请更新 windows-receiver\PhotoBackupReceiver.ps1）';
    }

    final impl = '${decoded['impl'] ?? ''}';
    if (impl.isEmpty) {
      return '接收端版本过旧：/ping 里没有 impl 标识，无法确认是不是本项目的一套'
          r'（请更新 windows-receiver\PhotoBackupReceiver.ps1 后重启服务）';
    }
    if (impl != clientImplId) {
      return '连到了另一个版本的服务（impl=$impl），本 App 只接受 $clientImplId';
    }

    final proto = (decoded['proto'] as num?)?.toInt() ?? 0;
    if (proto != protocolVersion) {
      return '协议版本不一致（服务器 $proto / 本 App $protocolVersion），'
          '请让 App 与接收端脚本使用同一份代码';
    }
    return null;
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
    String? contentSha256,
    int? resourceTotal,
    /// 该资产所属的用户相册标题（GAP-M1）
    List<String>? albums,
    List<String>? resourcePrimary,
    List<String>? resourceAuxiliary,
    String? resourceUti,
    String? resourceFilename,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.postUrl(Uri.parse('${config.baseUrl}/upload'));
      request.headers
          .set('X-File-Path', Uri.encodeComponent(relativePath));
      _applyIdentity(request);
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
      // 端到端校验与资源完整度（缺省不发，旧版接收端会忽略未知头）
      if (contentSha256 != null && contentSha256.isNotEmpty) {
        request.headers.set('X-Content-Sha256', contentSha256);
      }
      if (resourceTotal != null && resourceTotal > 0) {
        request.headers.set('X-Resource-Total', '$resourceTotal');
      }
      if (resourcePrimary != null && resourcePrimary.isNotEmpty) {
        // 用 '|' 而不是 ','：HTTP 头里逗号是标准分隔符，会被服务端拆开
        request.headers.set('X-Resource-Primary', resourcePrimary.join('|'));
      }
      if (resourceAuxiliary != null && resourceAuxiliary.isNotEmpty) {
        request.headers.set('X-Resource-Auxiliary', resourceAuxiliary.join('|'));
      }
      if (resourceUti != null && resourceUti.isNotEmpty) {
        // 附加资源的真实 UTI —— 恢复时要靠它判断该用哪种资源类型写入
        // （PHAssetResourceType 没有公开的 adjustment 枚举成员）
        request.headers.set('X-Resource-Uti', resourceUti);
      }
      if (resourceFilename != null && resourceFilename.isNotEmpty) {
        request.headers.set('X-Resource-Filename', resourceFilename);
      }
      if (albums != null && albums.isNotEmpty) {
        // 相册名常含中文，不能直接塞 HTTP 头：整组 JSON → UTF-8 → base64。
        // 接收端解码后写进 manifest 的 albums 字段，恢复时据此把照片放回原相册。
        request.headers.set(
          'X-Albums-B64',
          base64Encode(utf8.encode(jsonEncode(albums))),
        );
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
      _applyIdentity(request);

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
      _applyIdentity(request);
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
      _applyIdentity(request);
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
      _applyIdentity(request);

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