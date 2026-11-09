import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../helpers/photo_library_helper.dart';
import '../models/effect_scan.dart';

/// 「相册已用滤镜」扫描页
///
/// ## 它回答什么问题
/// 相册里到底用过哪几种滤镜、原生标识叫什么、强度是多少 —— 这些没法靠界面
/// 数出来（Apple 不公开滤镜清单，`effectName` 只存在于真实配方里），只能把
/// 所有已编辑资产的配方读出来解码去重。
///
/// ## 为什么需要它
/// 程序里 effectName → 中文名的映射只收录「真机样本见过」的名字。想补齐剩下
/// 的滤镜，必须先知道它们叫什么 —— 这个页面就是干这个的，扫完把结果贴回来
/// 即可，不用人工逐张点开抄写。
class EffectScanPage extends StatefulWidget {
  const EffectScanPage({super.key});

  @override
  State<EffectScanPage> createState() => _EffectScanPageState();
}

class _EffectScanPageState extends State<EffectScanPage> {
  bool _running = false;
  EffectScanResult? _result;
  String? _error;

  Future<void> _scan() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await PhotoLibraryHelper.scanUsedEffects();
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = r;
        _error = r == null
            ? '扫描失败：没有相册权限，或原生通道异常（详见操作日志）'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '扫描异常：$e';
      });
    }
  }

  Future<void> _copyReport() async {
    final r = _result;
    if (r == null) return;
    await Clipboard.setData(ClipboardData(text: r.report));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('扫描结果已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('相册已用滤镜'),
        actions: [
          if (r != null)
            IconButton(
              tooltip: '复制扫描结果',
              onPressed: _copyReport,
              icon: const Icon(Icons.copy_all_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _introCard(),
          const SizedBox(height: 12),
          if (_running) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text(
              '正在遍历已编辑资产并读取配方…\n'
              'ProRAW 的配方很小（1~2 KB），但 iCloud 未下载的资产可能要等。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null)
            Card(
              color: Colors.red.shade50,
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style: TextStyle(color: Colors.red.shade900, fontSize: 13)),
              ),
            ),
          if (r != null) ..._resultViews(r),
        ],
      ),
    );
  }

  Widget _introCard() {
    return Card(
      elevation: 0,
      color: Colors.blue.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('能扫到什么',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            const Text(
              '只统计「相册里真的用过」的滤镜：配方（Adjustments.plist / .aae）里'
              '的 effectName 解码后去重。Apple 不公开滤镜清单，没用过的滤镜在系统里'
              '没有任何痕迹，扫不出来是正常的。',
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _running ? null : _scan,
                icon: const Icon(Icons.search, size: 18),
                label: Text(_running ? '扫描中…' : '开始扫描'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _resultViews(EffectScanResult r) {
    final stats = r.stats;
    final failed = r.samples.where((s) => !s.recipe.isKnown).toList();
    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('扫描概况',
                      style:
                          TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  Text('${r.samples.length} 个配方',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.black54)),
                ],
              ),
              const SizedBox(height: 6),
              _kv('相册资产', '${r.scannedAssets} 个'),
              _kv('其中已编辑', '${r.editedAssets} 个（有调整/滤镜）'),
              _kv('配方资源', '${r.recipeResources} 个'),
              _kv('回传体积', '${r.totalBytes} 字节'),
              if (r.truncated) _warn('因上限限制只扫了一部分，结果可能不全'),
              if (r.timedOut) _warn('120 秒兜底触发：部分 iCloud 原件未回调'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text('滤镜种类（${stats.where((s) => !s.isNoFilter).length} 个有名字的）',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      const SizedBox(height: 6),
      if (stats.isEmpty)
        const Text('没有解出任何配方', style: TextStyle(fontSize: 12)),
      for (final s in stats) _statCard(s),
      if (failed.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('解码失败（${failed.length}）',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        for (final s in failed.take(10))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('· ${s.filename}: ${s.recipe.description}',
                style: const TextStyle(fontSize: 11, color: Colors.red)),
          ),
      ],
    ];
  }

  Widget _statCard(EffectNameStat s) {
    final color = s.isNoFilter
        ? Colors.grey
        : (s.isMapped ? Colors.green : Colors.orange);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.shade200),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          s.isNoFilter ? Icons.filter_none : Icons.filter_vintage,
          color: color.shade600,
          size: 20,
        ),
        title: Text(s.display, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '样本 ${s.sampleCount} · 资产 ${s.assetCount}'
          '${s.intensities.isEmpty ? '' : ' · 强度 ${s.intensityText}'}',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(k,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
                child: Text(v, style: const TextStyle(fontSize: 12))),
          ],
        ),
      );

  Widget _warn(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('⚠ $text',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade900)),
      );
}
