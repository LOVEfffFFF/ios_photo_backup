import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../helpers/photo_library_helper.dart';

/// 照片详情页：把一个资产在系统里的**真实全貌**摊开
///
/// ## 这个页面存在的理由
///
/// 在此之前，「这份照片到底由哪些文件组成、各自多大、内容长什么样」
/// 这个问题**没有可信答案**：
///
///  · 导出诊断里的资源 `bytes` 恒为 0。`PHAssetResource` 没有公开的
///    文件大小属性，之前用 KVC 取 `fileSize` 会抛 Objective-C 异常闪退，
///    于是干脆填 0 —— 看着像资源是空的，其实**从没读过内容**。
///  · 编辑指令（滤镜）只能看到一个「0 字节」。而 `adjustmentData` 是
///    Apple 私有二进制，不把字节摊开就无从判断到底读到了没有。
///
/// 所以这个页面做两件事：
///   1. 用 `requestData` 把每个资源**真读一遍**，给出字节数与 SHA256
///   2. 小资源（编辑指令那几百字节）附十六进制转储 + base64，可完整还原
///
/// 代价是慢：ProRAW 资产要流式读完 70MB DNG，几秒。所以只有主动点开才读。
class AssetDetailPage extends StatefulWidget {
  const AssetDetailPage({
    super.key,
    required this.localIdentifier,
    this.title = '照片详情',
  });

  final String localIdentifier;
  final String title;

  @override
  State<AssetDetailPage> createState() => _AssetDetailPageState();
}

class _AssetDetailPageState extends State<AssetDetailPage> {
  AssetFullInfo? _info;
  bool _loading = true;
  String? _error;
  String? _copied;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final info =
        await PhotoLibraryHelper.getAssetFullInfo(widget.localIdentifier);
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
      if (info == null) _error = '读不到这个资产（可能已从相册删除，或没有相册权限）';
    });
  }

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = label);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '重新读取',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 14),
                  Text(
                    '正在逐个真读资源…\n'
                    'ProRAW 要流式读完 70MB 原图，几秒钟',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : _error != null
              ? _msg(_error!)
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: _sections(),
                ),
    );
  }

  List<Widget> _sections() {
    final i = _info!;
    final ed = i.editing;
    return [
      _header('基础信息'),
      _kv('资产 ID', i.localIdentifier, copyable: true),
      _kv('原始文件名', i.originalFilename.isEmpty ? '（无）' : i.originalFilename),
      _kv('媒体类型', i.mediaType),
      _kv('媒体子类型',
          i.subtypes.isEmpty ? '（无）' : i.subtypes.join('、')),
      _kv('像素', '${i.pixelWidth}×${i.pixelHeight}'),
      _kv('拍摄时间', _fmt(i.creationDate)),
      _kv('修改时间', _fmt(i.modificationDate)),
      _kv('时长', i.duration > 0 ? '${i.duration.toStringAsFixed(2)} 秒' : '—'),
      _kv('收藏', i.isFavorite ? '是' : '否'),
      _kv('隐藏', i.isHidden ? '是' : '否'),
      _kv('位置', i.hasLocation ? '${i.latitude.toStringAsFixed(5)}, '
          '${i.longitude.toStringAsFixed(5)}' : '无'),
      _kv('格式描述',
          i.formatDescriptions.isEmpty ? '（无）' : i.formatDescriptions.join('、')),

      _header('资源构成（${i.resourceCount} 个 · 合计 ${_size(i.totalBytes)}）'),
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          '字节数与 SHA256 都是 requestData 真读一遍算出来的，'
          '不是查属性得到的。\n'
          '⚠ typeRawValue 只是编号，不要据此推断语义'
          '（4=alternatePhoto、5=fullSizePhoto 是实测值，其余未验证）。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ),
      ...i.resources.map(_resourceCard),

      _header('编辑（滤镜）信息'),
      _kv('iOS adjustmentData', ed['hasAdjustmentData'] == true ? '有' : '无'),
      if (ed['hasAdjustmentData'] == true) ...[
        _kv('指令字节数', '${ed['adjustmentBytes'] ?? 0}'),
        _kv('指令 SHA256', '${ed['adjustmentSha256'] ?? ''}',
            copyable: true),
        _kv('格式标识', '${ed['adjustmentFormat'] ?? ''}'),
        _kv('格式版本', '${ed['adjustmentVersion'] ?? ''}'),
      ],
      _kv('iOS 渲染成片', _size((ed['renderedBytes'] as num?)?.toInt() ?? 0)),
      _kv('编辑类资源', '${i.adjustmentResources.length} 个'),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '⚠ adjustmentData 为 nil ≠ 没有编辑：实测这张 ProRAW 回调成功但为 nil，'
          '而资源里明明挂着 Adjustments.plist 与 .aae。'
          '滤镜名程序读不出来（Apple 私有格式），要确认名字请在照片编辑界面看。',
          style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
        ),
      ),
    ];
  }

  Widget _resourceCard(AssetResourceDetail r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${r.index} ${r.filename}',
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace'),
                  ),
                ),
                if (r.isAdjustment)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('编辑指令',
                        style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'type(${r.typeRawValue})/${r.typeName}   ${_size(r.bytes)}',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            Text('UTI: ${r.uti}',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            Text('SHA256: ${r.sha256.isEmpty ? '（未读到）' : r.sha256}',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            if (r.failed)
              Text('读取失败：${r.error}',
                  style: TextStyle(fontSize: 11, color: Colors.red.shade700)),
            if (r.hex.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('前 ${r.inlineTruncated ? '若干' : ''}字节转储',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _copy('hex', r.hex),
                    child: const Text('复制 hex', style: TextStyle(fontSize: 11)),
                  ),
                  TextButton(
                    onPressed: () => _copy('base64', r.base64),
                    child: const Text('复制 base64',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(6),
                color: Colors.grey.shade100,
                child: SelectableText(
                  r.hex,
                  style: const TextStyle(
                      fontSize: 10, fontFamily: 'monospace', height: 1.25),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
        child: Text(t,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
      );

  Widget _kv(String k, String v, {bool copyable = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(k,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 12, fontFamily: 'monospace')),
            ),
            if (copyable)
              GestureDetector(
                onTap: () => _copy(k, v),
                child: const Icon(Icons.copy, size: 14),
              ),
            if (_copied == k)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text('已复制',
                    style: TextStyle(fontSize: 10, color: Colors.green)),
              ),
          ],
        ),
      );

  Widget _msg(String t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t, textAlign: TextAlign.center),
        ),
      );

  static String _fmt(double unix) {
    if (unix <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(
        (unix * 1000).round(), isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '0 字节';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}