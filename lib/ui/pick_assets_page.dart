import 'package:flutter/material.dart';

import '../helpers/photo_library_helper.dart';

/// 选择要备份的照片
///
/// 只做「勾选」一件事：本 App 没有缩略图通道（读缩略图要额外的
/// PHImageManager 请求），所以用拍摄时间 + 类型 + 尺寸来区分。
///
/// 返回：被选中资产的 `localIdentifier` 列表（点击「备份所选」时）。
class PickAssetsPage extends StatefulWidget {
  const PickAssetsPage({super.key});

  @override
  State<PickAssetsPage> createState() => _PickAssetsPageState();
}

class _PickAssetsPageState extends State<PickAssetsPage> {
  List<Map<String, dynamic>> _assets = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final assets = await PhotoLibraryHelper.fetchAllAssets();
      assets.sort((a, b) => (b['creationDate'] as num)
          .toDouble()
          .compareTo((a['creationDate'] as num).toDouble()));
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取相册失败：$e';
      });
    }
  }

  String _label(Map<String, dynamic> asset) {
    final seconds = (asset['creationDate'] as num).toDouble();
    final dt = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).toInt());
    final isLive = asset['isLivePhoto'] == true;
    final type = isLive
        ? '实况照片'
        : (asset['mediaType'] == 'video' ? '视频' : '照片');
    final w = asset['pixelWidth'];
    final h = asset['pixelHeight'];
    final size = (w is num && h is num && w > 0)
        ? ' · ${w.toInt()}×${h.toInt()}'
        : '';
    final t = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    return '${dt.year}/${dt.month}/${dt.day} $t · $type$size';
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _assets.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_assets.map((a) => a['localIdentifier'] as String));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final allSelected =
        _assets.isNotEmpty && _selected.length == _assets.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('选择要备份的照片（${_selected.length}）'),
        actions: [
          if (_assets.isNotEmpty)
            TextButton(
              onPressed: _toggleAll,
              child: Text(allSelected ? '取消全选' : '全选'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _assets.isEmpty
                  ? const Center(child: Text('相册里没有可备份的内容'))
                  : ListView.builder(
                      itemCount: _assets.length,
                      itemBuilder: (context, index) {
                        final asset = _assets[index];
                        final id = asset['localIdentifier'] as String;
                        return CheckboxListTile(
                          dense: true,
                          value: _selected.contains(id),
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            });
                          },
                          title: Text(
                            _label(asset),
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, _selected.toList(growable: false)),
                  child: Text('备份所选的 ${_selected.length} 张'),
                ),
              ),
            ),
    );
  }
}
