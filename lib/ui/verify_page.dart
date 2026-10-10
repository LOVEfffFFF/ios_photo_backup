import 'dart:async';

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../helpers/photo_library_helper.dart';
import '../managers/record_store.dart';
import '../managers/verify_manager.dart';
import '../models/backup_record.dart';
import '../services/log_service.dart';
import '../services/manifest_index.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';

/// 往返验证页：自己选一张，验证「备份恢复到相册后 == 原图吗」
///
/// 流程是刻意做成手动逐张的 —— 每次验证都会在相册里留下一张副本，
/// 让用户自己控制节奏与取舍，比全量跑一遍再清理更安全。
class VerifyPage extends StatefulWidget {
  const VerifyPage({super.key});

  @override
  State<VerifyPage> createState() => _VerifyPageState();
}

class _VerifyPageState extends State<VerifyPage> {
  List<BackupRecord> _records = [];
  bool _loading = true;
  String? _loadError;
  ServerConfig _config = ServerConfig.empty;
  final VerifyManager _manager = VerifyManager();
  bool _ready = false;

  /// 本次会话创建过的副本（跨多次验证累积），供用户一次性清理
  final List<String> _allCopies = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      var records = await RecordStore().loadAllRecords();
      final config = await ServerConfig.load();
      if (records.isEmpty && config.isConfigured) {
        // 本机记录为空时退回用电脑清单重建
        final manifest = await ManifestIndex.fetch(ServerClient(config));
        if (manifest != null) {
          records = manifest.toRecords();
        }
      }
      final ready = config.isConfigured ? await _manager.prepare() : false;
      if (!mounted) return;
      setState(() {
        _config = config;
        _records = records;
        _ready = ready;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  /// 验证单张
  Future<void> _verifyOne(BackupRecord record) async {
    if (!_ready) {
      _toast('未配置服务器或连不上接收端', ok: false);
      return;
    }
    // 先告知会产生副本，避免用户事后才发现相册多了东西
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('即将做往返验证'),
        content: Text(
            '会对「${record.relativePath.split('/').last}」执行：\n\n'
            '1. 读取手机里原图的字节哈希（基准）\n'
            '2. 从电脑下载备份文件并校验\n'
            '3. **把它导入相册，产生一张副本**\n'
            '4. 读取副本的哈希，与原图逐项比对\n\n'
            '验证完你可以选择保留副本（看真实效果）或清理掉。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始验证'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final result = await showModalBottomSheet<AssetVerifyResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _VerifySheet(
        manager: _manager,
        record: record,
        onCopies: (ids) => setState(() => _allCopies.addAll(ids)),
      ),
    );
    if (result != null) {
      LogService.instance.write(
        LogLevel.info,
        'verify',
        '往返验证 ${result.name}: ${result.ok ? "通过" : "不通过"}'
            '${result.error != null ? " (${result.error})" : ""}',
      );
    }
  }

  /// 清理本次会话创建的所有副本
  Future<void> _cleanupAll() async {
    if (_allCopies.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${_allCopies.length} 个验证副本？'),
        content: const Text(
            '只删除「本次验证创建的副本」，不会碰你原有的照片。\n\n'
            '如果相册里已经手动整理过、其中某些副本你留下了，删除它们也会一起消失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final r = await PhotoLibraryHelper.deleteAssets(_allCopies);
    if (!mounted) return;
    if (r.error != null) {
      _toast('删除失败：${r.error}', ok: false);
      return;
    }
    setState(() => _allCopies.clear());
    _toast('已删除 ${r.deleted} 个副本'
        '${r.failed > 0 ? "，${r.failed} 个失败" : ""}');
  }

  void _toast(String msg, {bool ok = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? null : Colors.red.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('往返验证'),
        actions: [
          if (_allCopies.isNotEmpty)
            IconButton(
              tooltip: '清理本次创建的副本',
              onPressed: _cleanupAll,
              icon: Badge(
                label: Text('${_allCopies.length}'),
                child: const Icon(Icons.delete_sweep_outlined),
              ),
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _msg('加载失败：$_loadError')
              : !_config.isConfigured
                  ? _msg('未配置服务器地址，无法下载备份文件')
                  : !_ready
                      ? _msg('连不上接收端。\n请确认电脑上接收端已启动，'
                          '且手机与电脑在同一局域网。')
                      : _records.isEmpty
                          ? _msg('没有可验证的备份记录。\n请先做一次备份。')
                          : _list(),
    );
  }

  Widget _msg(String t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t, textAlign: TextAlign.center),
        ),
      );

  Widget _list() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: Colors.blue.shade50,
          child: Text(
            '逐张验证「备份恢复到相册后 == 原图吗」\n'
            '每次验证会在相册里留下一张副本，验证完可清理。\n'
            'build: ${AppInfo.build}',
            style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.5),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _records.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final r = _records[i];
              final name = r.relativePath.split('/').last;
              return ListTile(
                dense: true,
                leading: Icon(
                  r.mediaType == 'live_photo'
                      ? Icons.motion_photos_on_outlined
                      : r.mediaType == 'video'
                          ? Icons.videocam_outlined
                          : Icons.photo_outlined,
                ),
                title: Text(name,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace')),
                subtitle: Text(
                  '${_fmt(r.creationTimestamp)}  ·  ${r.mediaType}'
                  '${r.pixelWidth != null ? "  ·  ${r.pixelWidth}×${r.pixelHeight}" : ""}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _verifyOne(r),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _fmt(double unixSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch((unixSeconds * 1000).round());
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

/// 验证执行面板（底部弹窗）
class _VerifySheet extends StatefulWidget {
  const _VerifySheet({
    required this.manager,
    required this.record,
    required this.onCopies,
  });

  final VerifyManager manager;
  final BackupRecord record;
  final ValueChanged<List<String>> onCopies;

  @override
  State<_VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends State<_VerifySheet> {
  AssetVerifyResult? _result;
  bool _running = true;
  String _current = '准备中...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final stream = widget.manager.verifyRoundTrip([widget.record]);
      await for (final p in stream) {
        if (!mounted) return;
        setState(() {
          _current = p.currentFile.isEmpty ? '处理中...' : p.currentFile;
          if (p.results.isNotEmpty) {
            _result = p.results.last;
          }
          if (p.logMessage != null && p.completed == p.total) {
            _running = false;
          }
        });
        if (p.restoredAssetIds.isNotEmpty) {
          widget.onCopies(p.restoredAssetIds);
        }
      }
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = _result ?? widget.manager.lastResult;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (ctx, controller) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '往返验证',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                  ),
                  if (_running)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _running
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text('正在验证…', style: Theme.of(ctx).textTheme.bodyMedium),
                          const SizedBox(height: 6),
                          Text(
                            _current,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace'),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : SingleChildScrollView(
                      controller: controller,
                      padding: const EdgeInsets.all(16),
                      child: _error != null
                          ? Text('验证失败：$_error',
                              style: const TextStyle(color: Colors.red))
                          : _result == null
                              ? const Text('没有结果')
                              : _ResultView(result: _result!),
                    ),
            ),
            if (!_running)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(_result),
                    child: const Text('完成'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 验证结果展示
class _ResultView extends StatelessWidget {
  const _ResultView({required this.result});

  final AssetVerifyResult result;

  @override
  Widget build(BuildContext context) {
    final pass = result.ok;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 结论条
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: pass ? Colors.green.shade50 : Colors.red.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                pass ? Icons.check_circle : Icons.error,
                color: pass ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  pass ? '验证通过：恢复出来的 == 原图' : '验证不通过',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: pass ? Colors.green.shade800 : Colors.red.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (result.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('出错：${result.error}',
                style: const TextStyle(color: Colors.red)),
          ),
        if (!result.originalStillThere)
          Container(
            padding: const EdgeInsets.all(8),
            margin: const EdgeInsets.only(bottom: 8),
            color: Colors.orange.shade50,
            child: const Text(
              '注意：原图当前不在相册里（可能已删除）。\n'
              '本次只验证了「备份文件 == 清单基准」，未与原图实时比对。',
              style: TextStyle(fontSize: 11),
            ),
          ),

        // 逐资源哈希比对
        ...result.resources.map((r) => _ResourceCard(r: r)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          color: Colors.grey.shade100,
          child: const Text(
            '四方哈希说明：\n'
            '· 清单基准 = 备份当时手机端算的原图哈希\n'
            '· 原图 = 验证时从相册原图读到的哈希\n'
            '· 下载 = 从电脑下载回来的备份文件哈希\n'
            '· 副本 = 导入相册后那张新照片的哈希\n'
            '四者全一致 = 从原图→备份→恢复全程无损。',
            style: TextStyle(fontSize: 10, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({required this.r});

  final ResourceVerifyResult r;

  @override
  Widget build(BuildContext context) {
    final ok = r.ok;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 16,
                  color: ok ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.label,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _kv('清单基准', r.expectedFromBackup),
            _kv('原图', r.originalSha),
            _kv('下载', r.downloadedSha),
            _kv('副本${r.restoredShaFrom == 'file' ? '(取自导入文件)' : ''}',
                r.restoredSha),
            if (r.restoredBytes != null)
              Text('大小: ${r.restoredBytes} 字节',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            if (r.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                // 不用 const：Colors.orange.shade900 的 shade 是运行时
                // 计算的 getter，不是编译期常量
                child: Text(
                  r.note!,
                  style:
                      TextStyle(fontSize: 10, color: Colors.orange.shade900),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String? v) {
    final empty = v == null || v.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(k,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              empty ? '(无)' : v,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: empty ? Colors.grey : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}