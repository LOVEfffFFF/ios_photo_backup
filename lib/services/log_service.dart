import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../helpers/photo_library_helper.dart';
import 'server_client.dart';

/// 日志等级
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warn('WARN'),
  error('ERROR'),
  fatal('FATAL');

  const LogLevel(this.label);
  final String label;
}

/// 本机日志服务：写文件 + 全局错误捕获 + 上报到电脑
///
/// **为什么必须落盘而不是只 print**：崩溃时进程直接死掉，「崩溃后再上报」不可行。
/// 原生侧的三层捕获（NSException / POSIX 信号 / 异常退出标记）在崩溃现场把信息写进
/// 沙盒文件，这里负责：
///   ① 提供 Dart 侧的写入入口，并接住所有未捕获错误
///   ② 上传日志到电脑（崩溃日志与运行日志一起上报）
///   ③ 给 UI 提供查看/手动上传
///
/// 日志目录 `Documents/logs` 与原生侧共用 —— 这样两边写的内容在同一个文件里，
/// 能还原「崩溃前最后做了什么」。
class LogService {
  LogService._();

  static final LogService instance = LogService._();

  ServerClient? _client;
  bool _installed = false;

  /// 内存中的环形缓冲：崩溃时最后若干条操作留在这里，
  /// 供 UI 展示「崩溃前现场」，即使文件写入失败也有记录。
  final List<LogEntry> _recent = [];

  static const int _recentLimit = 100;

  /// 初始化并安装全局捕获。必须在 runApp 之前调用。
  ///
  /// 不需要 ServerClient：写日志只依赖原生通道，与网络无关。
  /// 上传才需要 client，而 client 要等用户配置读出来才能构造，
  /// 所以两者分开 —— 用 [attachClient] 在配置就绪后绑定。
  Future<void> init() async {
    if (_installed) return;
    _installed = true;

    // 1) Flutter 框架内的异常（build 失败、setState 误用等）
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      write(
        LogLevel.fatal,
        'flutter',
        details.exceptionAsString(),
        details.exception,
        details.stack,
      );
      prevOnError?.call(details);
    };

    // 2) 引擎层未捕获错误
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      write(LogLevel.fatal, 'engine', '未捕获的引擎异常', error, stack);
      return true;
    };

    // 3) 初始化日志目录，并记一条启动日志
    try {
      final dir = await logsDirectory();
      await dir.create(recursive: true);
      write(LogLevel.info, 'app', '日志服务启动，目录=${dir.path}');
    } catch (e) {
      write(LogLevel.warn, 'app', '日志目录初始化失败: $e');
    }
  }

  /// 用 runZonedGuarded 包住整个应用，兜住异步未 await 的异常。
  ///
  /// 注意：捕获后**不阻止程序继续运行** —— 绝大多数 Dart 异常（如越界、状态错乱）
  /// 应该被记录下来而不是让整个 App 挂掉。
  static void runGuarded(FutureOr<void> Function() body) {
    runZonedGuarded(body, (error, stack) {
      LogService.instance.write(
        LogLevel.fatal,
        'zone',
        '未捕获的异步异常',
        error,
        stack,
      );
    });
  }

  /// 绑定用于上传日志的 client（配置就绪后调用）
  void attachClient(ServerClient client) {
    _client = client;
  }

  /// 日志目录：Documents/logs（与原生侧同一目录）
  Future<Directory> logsDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}${Platform.pathSeparator}logs');
  }

  /// 写一条日志：内存缓冲 + 落盘（经原生通道，与崩溃日志同文件）
  void write(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final entry = LogEntry(level, tag, message, error, stack);
    final line = entry.toLine();

    _recent.add(entry);
    if (_recent.length > _recentLimit) {
      _recent.removeAt(0);
    }

    if (kDebugMode) {
      debugPrint(line);
    }
    // 落盘走原生：原生侧用的是 stdio 追加写，与崩溃日志的写入方式一致，
    // 也避免 Dart 与原生同时持有同一文件的不同句柄。
    PhotoLibraryHelper.appendLogNative(line);
  }

  /// 最近若干条日志（UI 展示"崩溃前现场"）
  List<LogEntry> get recentEntries => List.unmodifiable(_recent);

  /// 列出日志文件（崩溃日志优先）
  Future<List<LogFileInfo>> listLogs() async {
    final dir = await logsDirectory();
    if (!dir.existsSync()) return [];
    final items = <LogFileInfo>[];
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.log')) continue;
      final stat = f.statSync();
      items.add(
        LogFileInfo(
          name: name,
          size: stat.size,
          modified: stat.modified,
          isCrash: name.startsWith('crash'),
        ),
      );
    }
    // 崩溃日志排前面，其余按修改时间倒序
    items.sort((a, b) {
      if (a.isCrash != b.isCrash) return a.isCrash ? -1 : 1;
      return b.modified.compareTo(a.modified);
    });
    return items;
  }

  /// 读取日志内容
  Future<String?> readLog(String name) async {
    // 防目录穿越
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        !name.endsWith('.log')) {
      return null;
    }
    final dir = await logsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    if (!f.existsSync()) return null;
    return f.readAsString();
  }

  /// 上传日志到电脑。
  ///
  /// 先用 /logs 拉电脑侧已有的崩溃日志清单做对比——实际上不用那么复杂：
  /// 直接把本机所有日志文件全量上传（幂等，覆盖式写入），最简单也最可靠。
  /// 返回上传成功的文件数。
  Future<int> upload() async {
    final client = _client;
    if (client == null) throw StateError('日志服务未初始化');
    final dir = await logsDirectory();
    if (!dir.existsSync()) return 0;

    var uploaded = 0;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.log')) continue;
      try {
        final content = await f.readAsString();
        final ok = await client.uploadLog(name, content);
        if (ok) uploaded++;
      } catch (e) {
        write(LogLevel.warn, 'log', '上传 $name 失败: $e');
      }
    }
    write(
      LogLevel.info,
      'log',
      '已上传 $uploaded 个日志文件到 $client',
    );
    return uploaded;
  }

  /// 清空本机日志（上传成功后调用，避免日志无限增长）
  Future<void> clear() async {
    final dir = await logsDirectory();
    if (!dir.existsSync()) return;
    for (final f in dir.listSync()) {
      if (f is File && f.uri.pathSegments.last.endsWith('.log')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    _recent.clear();
  }
}

/// 一条结构化日志
class LogEntry {
  LogEntry(this.level, this.tag, this.message, this.error, this.stack);

  final LogLevel level;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stack;

  /// 单行文本（写文件用）：堆栈压成一行，避免日志结构被冲散
  String toLine() {
    final t = DateTime.now().toIso8601String();
    final buf = StringBuffer('$t [${level.label}] [$tag] $message');
    if (error != null) {
      buf.write(' | error=$error');
    }
    if (stack != null) {
      final frames =
          stack.toString().split('\n').where((s) => s.trim().isNotEmpty).take(12);
      buf.write(' | stack=${frames.join(' ↦ ')}');
    }
    return buf.toString();
  }

  String get summary =>
      '[${level.label}] $tag: $message${error != null ? ' ($error)' : ''}';
}

/// 一个日志文件的信息
class LogFileInfo {
  LogFileInfo({
    required this.name,
    required this.size,
    required this.modified,
    required this.isCrash,
  });

  final String name;
  final int size;
  final DateTime modified;
  final bool isCrash;

  String get sizeText {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String get modifiedText {
    final p = modified.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${p.year}-${two(p.month)}-${two(p.day)} ${two(p.hour)}:${two(p.minute)}:${two(p.second)}';
  }
}