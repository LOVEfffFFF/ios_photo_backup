import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../helpers/file_helper.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// HTTP 服务器管理器
/// 提供 WiFi 局域网文件下载服务
class WebServerManager {
  HttpServer? _server;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// 获取设备本地 IP 地址
  static Future<String?> getLocalIp() async {
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      return wifiIP;
    } catch (e) {
      return null;
    }
  }

  /// 启动 HTTP 服务器
  /// [port] 端口号，默认 8080
  Future<String?> start({int port = 8080}) async {
    if (_isRunning) {
      return '服务器已在运行中';
    }

    try {
      final backupDir = await FileHelper.getBackupDirectory();
      final app = Router();

      // 主页 - 显示文件列表
      app.get('/', (Request request) {
        return _generateIndexPage(backupDir.path);
      });

      // 文件列表 API
      app.get('/list', (Request request) async {
        return _generateFileList(backupDir.path);
      });

      // 静态文件服务 - 提供备份文件下载
      final staticHandler = createStaticHandler(
        backupDir.parent.path,
        defaultDocument: 'index.html',
        listDirectories: true,
      );

      // 将静态文件处理器作为中间件
      final handler = Cascade()
          .add(app)
          .add(staticHandler)
          .handler;

      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
      _isRunning = true;

      final ip = await getLocalIp();
      return ip != null ? 'http://$ip:$port' : '服务器已启动（端口 $port）';
    } catch (e) {
      return '启动服务器失败: $e';
    }
  }

  /// 停止 HTTP 服务器
  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _isRunning = false;
    }
  }

  /// 生成目录索引页面
  Response _generateIndexPage(String backupPath) {
    final html = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>相册备份 - 文件浏览</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f5f5f7; color: #1d1d1f; }
  .header { background: #fff; padding: 20px 24px; border-bottom: 1px solid #e5e5e5; position: sticky; top: 0; z-index: 10; }
  .header h1 { font-size: 24px; font-weight: 600; }
  .header p { color: #86868b; margin-top: 4px; font-size: 14px; }
  .container { max-width: 900px; margin: 0 auto; padding: 24px; }
  .path-nav { background: #fff; padding: 12px 16px; border-radius: 10px; margin-bottom: 16px; font-size: 14px; color: #86868b; }
  .file-list { background: #fff; border-radius: 12px; overflow: hidden; }
  .file-item { display: flex; align-items: center; padding: 12px 16px; border-bottom: 1px solid #f0f0f0; transition: background 0.15s; text-decoration: none; color: inherit; }
  .file-item:last-child { border-bottom: none; }
  .file-item:hover { background: #f5f5f7; }
  .file-icon { width: 32px; height: 32px; margin-right: 12px; font-size: 24px; text-align: center; }
  .file-name { flex: 1; font-size: 15px; }
  .file-size { color: #86868b; font-size: 13px; margin-left: 12px; }
  .empty { text-align: center; padding: 60px 20px; color: #86868b; }
</style>
</head>
<body>
<div class="header">
  <h1>📷 相册备份浏览器</h1>
  <p>在同一 WiFi 下访问此页面浏览和下载备份文件</p>
</div>
<div class="container">
  <div class="path-nav">📍 /Backup/</div>
  <div class="file-list" id="fileList">
    <div class="empty">正在加载文件列表...</div>
  </div>
</div>
<script>
  async function loadFiles(path) {
    try {
      const resp = await fetch('/Backup/' + (path || ''));
      const text = await resp.text();
      const parser = new DOMParser();
      const doc = parser.parseFromString(text, 'text/html');
      const links = doc.querySelectorAll('a');
      const fileList = document.getElementById('fileList');
      fileList.innerHTML = '';

      if (links.length === 0) {
        fileList.innerHTML = '<div class="empty">📭 暂无备份文件</div>';
        return;
      }

      links.forEach(link => {
        const href = link.getAttribute('href');
        const text = link.textContent.trim();
        if (text === 'Parent Directory' || text === '../') return;

        const isDir = href.endsWith('/');
        const item = document.createElement('a');
        item.className = 'file-item';
        item.href = '/Backup/' + (path ? path + '/' : '') + href;
        if (!isDir) item.download = '';

        const ext = text.split('.').pop().toLowerCase();
        let icon = '📄';
        if (isDir) icon = '📁';
        else if (['jpg','jpeg','png','heic','gif','webp'].includes(ext)) icon = '🖼️';
        else if (['mov','mp4','avi'].includes(ext)) icon = '🎬';

        item.innerHTML = '<span class="file-icon">' + icon + '</span><span class="file-name">' + text + '</span>';
        fileList.appendChild(item);
      });
    } catch(e) {
      document.getElementById('fileList').innerHTML = '<div class="empty">❌ 加载失败</div>';
    }
  }
  loadFiles('');
</script>
</body>
</html>
''';
    return Response.ok(html, headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  /// 生成 JSON 格式的文件列表
  Response _generateFileList(String backupPath) {
    try {
      final dir = Directory(backupPath);
      if (!dir.existsSync()) {
        return Response.ok('{"files":[],"error":"目录不存在"}',
            headers: {'Content-Type': 'application/json'});
      }

      final files = <Map<String, dynamic>>[];
      _listFiles(dir, '', files);

      final json = '{"files":${_toJsonList(files)}}';
      return Response.ok(json,
          headers: {'Content-Type': 'application/json; charset=utf-8'});
    } catch (e) {
      return Response.ok('{"files":[],"error":"$e"}',
          headers: {'Content-Type': 'application/json'});
    }
  }

  void _listFiles(Directory dir, String prefix, List<Map<String, dynamic>> result) {
    final entries = dir.listSync();
    for (final entry in entries) {
      if (entry is Directory) {
        _listFiles(entry, '$prefix${p.basename(entry.path)}/', result);
      } else if (entry is File) {
        result.add({
          'name': p.basename(entry.path),
          'path': '$prefix${p.basename(entry.path)}',
          'size': entry.lengthSync(),
        });
      }
    }
  }

  String _toJsonList(List<Map<String, dynamic>> files) {
    final buffer = StringBuffer('[');
    for (int i = 0; i < files.length; i++) {
      if (i > 0) buffer.write(',');
      final f = files[i];
      buffer.write(
        '{"name":"${_escapeJson(f['name'])}",'
        '"path":"${_escapeJson(f['path'])}",'
        '"size":${f['size']}}',
      );
    }
    buffer.write(']');
    return buffer.toString();
  }

  String _escapeJson(dynamic value) {
    return value.toString().replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }
}
