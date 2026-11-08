import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_info.dart';
import '../helpers/file_helper.dart';
import 'debug_photo_executor.dart';
import 'log_service.dart';

abstract class DebugTransport {
  Future<Map<String, dynamic>> post(String route, Map<String, dynamic> body);
  void close();
}

class DebugConnectionEnded implements Exception {
  const DebugConnectionEnded();
}

class HttpDebugTransport implements DebugTransport {
  HttpDebugTransport(this.address, this.token) {
    final uri = Uri.tryParse(address);
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !RegExp(r'^(?:[0-9]{6}|[a-fA-F0-9]{16})$').hasMatch(token)) {
      throw const FormatException('调试地址或连接码格式不正确');
    }
    _client.connectionTimeout = const Duration(seconds: 8);
  }
  final String address;
  final String token;
  final HttpClient _client = HttpClient();

  @override
  Future<Map<String, dynamic>> post(String route, Map<String, dynamic> body) async {
    final uri = Uri.parse(address).replace(path: route);
    final request = await _client.postUrl(uri).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 128 * 1024) throw const FormatException('调试响应过大');
      bytes.addAll(chunk);
    }
    if ([401, 403, 410].contains(response.statusCode)) throw const DebugConnectionEnded();
    if (response.statusCode != 200) throw StateError('调试服务返回 ${response.statusCode}');
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map<String, dynamic>) throw const FormatException('调试响应无效');
    return result;
  }

  @override
  void close() => _client.close(force: true);
}

/// One foreground phone session, one task at a time. Finished results are
/// retried after network loss; photo operations themselves are never replayed.
class LiveDebugSession extends ChangeNotifier {
  LiveDebugSession({required this.transport, required this.executor,
    required this.assets, required this.allowRoundTrip, this.automaticPolling = true,
    Future<String> Function()? logReader,
    Future<void> Function(Map<String, dynamic>)? resultSaver})
      : _logReader = logReader ?? readLogTail, _resultSaver = resultSaver ?? saveLastResult;
  final DebugTransport transport;
  final DebugExecutor executor;
  final List<Map<String, String>> assets;
  final bool allowRoundTrip;
  final bool automaticPolling;
  final Future<String> Function() _logReader;
  final Future<void> Function(Map<String, dynamic>) _resultSaver;
  Timer? _timer;
  String? _sessionId;
  int? _expiresAt;
  DateTime? get expiresAt => _expiresAt == null ? null : DateTime.fromMillisecondsSinceEpoch(_expiresAt!);
  bool _polling = false;
  bool _disposed = false;
  bool enabled = false;
  bool connecting = false;
  bool connected = false;
  bool foreground = true;
  String message = '尚未连接';
  String? _active;
  final Set<String> _seen = {};
  Map<String, dynamic>? _pending;
  bool _resultSaved = false;
  Map<String, dynamic>? lastResult;
  bool get busy => _active != null;

  void _changed() {if (!_disposed) notifyListeners();}

  Future<void> start() async {
    if (connecting || connected || _disposed) return;
    connecting = true; enabled = true; _changed();
    try {
      final reply = await transport.post('/device/connect', {
        'assets': assets, 'allowRoundTrip': allowRoundTrip, 'app': AppInfo.diagnostics,
        'importVariants': debugImportVariants,
      });
      if (reply['sessionId'] is! String || reply['expiresAt'] is! num || reply['protocol'] != 1) {
        throw const FormatException('不支持此调试协议');
      }
      _sessionId = reply['sessionId'] as String;
      _expiresAt = (reply['expiresAt'] as num).toInt();
      connected = true;
      message = '已连接，等待电脑端测试任务';
      if (automaticPolling) _timer = Timer.periodic(const Duration(seconds: 2), (_) { poll(); });
    } catch (_) {
      enabled = false;
      message = '连接失败，请核对调试地址、连接码及电脑防火墙';
      rethrow;
    } finally {
      connecting = false; _changed();
    }
  }

  void setForeground(bool value) {
    foreground = value;
    if (!value) message = '已暂停接收任务，返回此页面后继续';
    _changed();
  }

  Future<void> poll() async {
    if (_disposed || _polling || !connected || _sessionId == null) return;
    _polling = true;
    try {
      if (DateTime.now().millisecondsSinceEpoch >= (_expiresAt ?? 0)) enabled = false;
      if (_pending != null) {
        await transport.post('/device/result', _pending!);
        _pending = null; _active = null;
        message = enabled ? '结果已送达，等待下一项任务' : '已断开';
      }
      final reply = await transport.post('/device/tick', {
        'sessionId': _sessionId,
        'status': {'enabled': enabled, 'foreground': foreground, 'busy': busy,
          'activeJob': _active, 'message': message},
        'copies': executor.copies, 'logTail': await _logReader(),
      });
      final job = reply['job'];
      if (job is Map && job['id'] is String && !_seen.contains(job['id']) && !busy) {
        _active = job['id'] as String;
        _seen.add(_active!);
        unawaited(_execute(Map<String, dynamic>.from(job)));
      }
      if (!enabled && !busy) {
        connected = false; _timer?.cancel(); transport.close(); message = '已断开';
      }
    } on DebugConnectionEnded {
      enabled = false;
      message = '连接已失效；当前任务结果保留在手机，请结束后重新连接';
      if (!busy || _pending != null) {
        // The result is retained locally; expired sessions never re-import.
        connected = false; _active = null; _timer?.cancel(); transport.close();
      }
    } catch (_) {
      message = enabled ? '电脑暂时未连接，正在重试；不会重复执行测试' : '正在结束连接';
      // Stopping an idle session must not trap the user behind a failed socket.
      if (!enabled && (!busy || (_pending != null && _resultSaved))) {
        connected = false; _active = null; _timer?.cancel(); transport.close();
        message = _pending == null ? '已断开' : '已断开；未送达的结果保存在手机';
      }
    } finally {
      _polling = false; _changed();
    }
  }

  Future<void> _execute(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    message = '正在执行 ${job['kind']} · ${job['target']}'; _changed();
    Map<String, dynamic> completion;
    try {
      if (!enabled || !foreground) throw StateError('手机已暂停，任务未执行');
      final data = await executor.execute('${job['kind']}', '${job['target']}',
        importVariant: job['importVariant'] is String ? job['importVariant'] as String : 'baseline');
      completion = {'sessionId': _sessionId, 'jobId': id, 'ok': true, 'data': data};
    } catch (error) {
      completion = {'sessionId': _sessionId, 'jobId': id, 'ok': false, 'error': '$error'};
    }
    lastResult = completion;
    _resultSaved = false;
    try {await _resultSaver(completion); _resultSaved = true;} catch (_) {
      completion['localSaveError'] = '结果未能写入手机，请保持连接以传回电脑';
    }
    _pending = completion;
    message = '任务已结束，正在传回结果';
    _changed();
  }

  Future<void> stop() async {
    enabled = false;
    message = busy ? '当前任务结束并传回结果后断开' : '正在断开';
    _changed();
    await poll();
  }

  @override
  void dispose() {
    _disposed = true; enabled = false; _timer?.cancel(); transport.close();
    super.dispose();
  }

  static Future<String> readLogTail() async {
    try {
      final file = File('${(await LogService.instance.logsDirectory()).path}/app.log');
      if (!await file.exists()) return '';
      final handle = await file.open();
      try {
        final length = await handle.length();
        await handle.setPosition(length > 24000 ? length - 24000 : 0);
        return utf8.decode(await handle.read(24000), allowMalformed: true);
      } finally {await handle.close();}
    } catch (_) {return '';}
  }

  static Future<void> saveLastResult(Map<String, dynamic> result) async {
    final directory = await FileHelper.getDocumentsDirectory();
    await File('${directory.path}/debug_last_result.json').writeAsString(jsonEncode(result), flush: true);
  }
}
