import 'package:flutter/material.dart';

import '../app_info.dart';
import '../services/log_service.dart';

/// 日志与崩溃分析页
///
/// 用途：闪退后手机上不方便取日志，这里提供
///   ① 查看本机所有日志（含崩溃日志）
///   ② 一键上报到电脑（落到 iPhoneBackup\logs\）
///   ③ 查看「崩溃前最后若干条操作」——这是定位崩溃点最直接的线索
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<LogFileInfo> _files = [];
  bool _loading = true;
  bool _uploading = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final files = await LogService.instance.listLogs();
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _upload() async {
    setState(() {
      _uploading = true;
      _hint = null;
    });
    var count = 0;
    String? err;
    try {
      count = await LogService.instance.upload();
    } catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _hint = err != null
          ? '❌ 上传失败：$err'
          : '✅ 已上传 $count 个日志文件到电脑 iPhoneBackup\\logs\\';
    });
    _refresh();
  }

  Future<void> _openFile(LogFileInfo f) async {
    final content = await LogService.instance.readLog(f.name);
    if (!mounted) return;
    if (content == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('读取失败')),
      );
      return;
    }
    // 内容可能很长，用可滚动 + 可选中的文本，崩溃栈需要逐行看
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _LogDetailPage(info: f, content: content),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = LogService.instance;
    final crashCount = _files.where((f) => f.isCrash).length;
    final recent = logs.recentEntries.reversed.take(30).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('日志与崩溃分析'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _Header(
                  fileCount: _files.length,
                  crashCount: crashCount,
                  build: AppInfo.display,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _uploading ? null : _upload,
                  icon: _uploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload),
                  label: Text(_uploading ? '上传中...' : '一键上报到电脑'),
                ),
                if (_hint != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _hint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _hint!.startsWith('❌')
                          ? Colors.red
                          : Colors.green,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  '日志文件（${_files.length}）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                if (_files.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无日志文件', style: TextStyle(color: Colors.grey)),
                  )
                else
                  ..._files.map(
                    (f) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        f.isCrash
                            ? Icons.report_gmailerrorred
                            : Icons.description,
                        color: f.isCrash ? Colors.red : Colors.blueGrey,
                      ),
                      title: Text(f.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${f.sizeText} · ${f.modifiedText}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => _openFile(f),
                      trailing: f.isCrash
                          ? Text(
                              '崩溃',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.red,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  '当前会话记录（${recent.length}）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                if (recent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无', style: TextStyle(color: Colors.grey)),
                  )
                else
                  ...recent.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        e.summary,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: e.level == LogLevel.fatal
                              ? Colors.red
                              : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.fileCount,
    required this.crashCount,
    required this.build,
  });

  final int fileCount;
  final int crashCount;
  final String build;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: crashCount > 0 ? Colors.red.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            crashCount > 0 ? '发现 $crashCount 个崩溃日志' : '未发现崩溃日志',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: crashCount > 0 ? Colors.red : Colors.blue,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'build: $build',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          const Text(
            '日志上传是排查崩溃的关键手段：闪退时进程已死，'
            '不可能在崩溃后上传，因此日志是「崩溃现场写文件、下次启动再上传」。',
            style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _LogDetailPage extends StatelessWidget {
  const _LogDetailPage({required this.info, required this.content});

  final LogFileInfo info;
  final String content;

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');
    return Scaffold(
      appBar: AppBar(
        title: Text(info.name, style: const TextStyle(fontSize: 15)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Text(
                  '${info.sizeText} · ${lines.length} 行',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制全部',
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                content,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}