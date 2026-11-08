import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../helpers/photo_library_helper.dart';
import '../managers/record_store.dart';
import '../models/backup_record.dart';
import '../services/debug_bridge_config.dart';
import '../services/debug_photo_executor.dart';
import '../services/live_debug_session.dart';
import '../services/manifest_index.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';

class LiveDebugPage extends StatefulWidget {
  const LiveDebugPage({super.key});
  @override
  State<LiveDebugPage> createState() => _LiveDebugPageState();
}

class _LiveDebugPageState extends State<LiveDebugPage> with WidgetsBindingObserver {
  final _address = TextEditingController();
  final _token = TextEditingController();
  final Set<String> _selected = {};
  List<BackupRecord> _records = [];
  List<String> _copyIds = [];
  bool _loading = true;
  bool _allowRoundTrip = true;
  String? _error;
  LiveDebugSession? _session;
  bool get _locked => _session?.connected == true || _session?.connecting == true || _session?.busy == true;

  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this); _load();
  }

  Future<void> _load() async {
    try {
      final config = await ServerConfig.load();
      final bridge = await DebugBridgeConfig.load();
      var records = await RecordStore().loadAllRecords();
      if (records.isEmpty && config.isConfigured) {
        records = (await ManifestIndex.fetch(ServerClient(config)))?.toRecords() ?? [];
      }
      final copyIds = await DebugPhotoExecutor.loadCopyIds();
      records.sort((a, b) => b.creationTimestamp.compareTo(a.creationTimestamp));
      if (!mounted) return;
      setState(() {
        _records = records; _copyIds = copyIds; _loading = false;
        // 优先用配对二维码带下来的调试桥配置（扫一次全填好）；
        // 没扫过就退化成「同一台电脑的 18081 端口」，连接码仍需手填。
        if (bridge.isConfigured) {
          _address.text = bridge.address;
          _token.text = bridge.token;
        } else if (config.isConfigured) {
          _address.text =
              Uri(scheme: config.scheme, host: config.host, port: 18081).toString();
        }
      });
    } catch (_) {
      if (mounted) setState(() {_loading = false; _error = '无法读取备份或调试副本记录，请检查电脑连接';});
    }
  }

  void _update() {
    if (!mounted) return;
    setState(() {});
    if (_session?.connected == false && _session?.connecting == false) {
      WakelockPlus.disable();
      DebugPhotoExecutor.loadCopyIds().then((ids) {
        if (mounted) setState(() {_copyIds = ids;});
      }).catchError((Object _) {
        if (mounted) setState(() {_error = '无法读取副本记录，请保留当前页面';});
      });
    }
  }

  Future<void> _connect() async {
    if (_selected.isEmpty || _selected.length > 10 || _locked) return;
    _session?.removeListener(_update); _session?.dispose();
    try {
      final chosen = _records.where((r) => _selected.contains(r.localIdentifier)).toList();
      final scope = {for (var i = 0; i < chosen.length; i++) 'asset-${i + 1}': chosen[i]};
      final executor = DebugPhotoExecutor(scope, allowRoundTrip: _allowRoundTrip);
      final session = LiveDebugSession(
        transport: HttpDebugTransport(_address.text.trim(), _token.text.trim()),
        executor: executor, allowRoundTrip: _allowRoundTrip,
        assets: [for (final e in scope.entries) {'key': e.key, 'label': e.value.relativePath.split('/').last}],
      );
      _session = session; session.addListener(_update);
      setState(() {_error = null;});
      await WakelockPlus.enable();
      await session.start();
    } catch (_) {
      await WakelockPlus.disable();
      if (mounted) setState(() {_error = '连接失败，请核对地址、6 位数字连接码和电脑防火墙';});
    }
  }

  Future<void> _stop() async {
    await _session?.stop();
    final ids = await DebugPhotoExecutor.loadCopyIds();
    if (mounted) setState(() {_copyIds = ids;});
  }

  Future<void> _cleanup() async {
    if (_locked) return;
    final ids = await DebugPhotoExecutor.loadCopyIds();
    if (ids.isEmpty || !mounted) return;
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('清理调试副本？'),
      content: Text('将删除调试通道记录的 ${ids.length} 个测试副本。原照片保留。系统还会请求删除确认。'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理副本'))],
    ));
    if (confirmed != true) return;
    final existing = await PhotoLibraryHelper.filterExistingAssets(ids);
    if (existing.isEmpty) {
      await DebugPhotoExecutor.saveCopyIds([]);
    } else {
      final result = await PhotoLibraryHelper.deleteAssets(existing.toList());
      if (result.error != null) {
        if (mounted) setState(() {_error = '清理未完成：${result.error}';});
        return;
      }
      // Re-read existence; a partial deletion must retain the remaining IDs.
      final remaining = await PhotoLibraryHelper.filterExistingAssets(ids);
      await DebugPhotoExecutor.saveCopyIds(remaining.toList());
    }
    final remaining = await DebugPhotoExecutor.loadCopyIds();
    if (mounted) setState(() {_copyIds = remaining;});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _session?.setForeground(state == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.removeListener(_update); _session?.dispose();
    _address.dispose(); _token.dispose(); WakelockPlus.disable(); super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _session?.lastResult;
    final data = last?['data'];
    final expiry = _session?.expiresAt;
    final expiryText = expiry == null ? '连接码默认有效 7 天，可主动断开。'
        : '连接码有效至 ${expiry.year}/${expiry.month}/${expiry.day} '
          '${expiry.hour.toString().padLeft(2, '0')}:${expiry.minute.toString().padLeft(2, '0')}';
    return PopScope(
      canPop: !_locked,
      child: Scaffold(
        appBar: AppBar(title: const Text('实时调试')),
        body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('连接电脑后，可自动读取所选照片的资源、编辑附件和日志，并执行往返对比。'
                '请保持本页在前台；切到后台会暂停接收新任务。'),
            const SizedBox(height: 12),
            TextField(controller: _address, enabled: !_locked, autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: '电脑调试地址', hintText: 'http://192.168.1.4:18081')),
            TextField(controller: _token, enabled: !_locked, autocorrect: false,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '6 位数字连接码')),
            const SizedBox(height: 12),
            CheckboxListTile(value: _allowRoundTrip, onChanged: _locked ? null
                : (value) => setState(() {_allowRoundTrip = value ?? false;}),
              title: const Text('允许创建恢复副本进行往返测试'),
              subtitle: const Text('本次连接最多十次；原照片保留，副本可在断开后手动清理。')),
            Text('选择测试照片（${_selected.length}/10）', style: Theme.of(context).textTheme.titleMedium),
            if (_records.isEmpty) const Text('没有备份记录，请先备份测试照片。'),
            SizedBox(height: 250, child: ListView.builder(
              itemCount: _records.length,
              itemBuilder: (context, index) {
                final record = _records[index];
                final selected = _selected.contains(record.localIdentifier);
                return CheckboxListTile(value: selected,
                  onChanged: _locked || (!selected && _selected.length >= 10) ? null : (value) => setState(() {
                    if (value == true) {_selected.add(record.localIdentifier);} else {_selected.remove(record.localIdentifier);}
                  }),
                  title: Text(record.relativePath.split('/').last, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${record.creationDate.toLocal()} · ${record.mediaType}'),
                );
              },
            )),
            const SizedBox(height: 12),
            if (!_locked) FilledButton(onPressed: _selected.isEmpty ? null : _connect,
              child: const Text('开启本次调试')),
            if (_locked) FilledButton.tonal(onPressed: _session?.connecting == true ? null : _stop,
              child: Text(_session?.busy == true ? '完成当前任务后断开' : '断开调试')),
            Padding(padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('${_session?.message ?? '尚未连接'}\n$expiryText')),
            if (last != null) Card(child: Padding(padding: const EdgeInsets.all(12),
              child: Text(last['ok'] != true ? '任务未完成：${last['error']}'
                  : data is Map
                      ? '${(data['resources'] is List && (data['resources'] as List).isNotEmpty) ? '往返结果：${data['strictBytesMatch'] == true ? '一致' : '不一致'}' : '资源与配方已回读'}，详细结果已发往电脑'
                      : '任务已完成'))),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            OutlinedButton(onPressed: _locked || _copyIds.isEmpty ? null : _cleanup,
              child: Text('清理调试副本（${_copyIds.length}）')),
          ],
        ),
      ),
    );
  }
}
