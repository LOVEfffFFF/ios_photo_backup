import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../helpers/photo_library_helper.dart';

/// 选择要备份的照片
///
/// 用缩略图网格，而不是列表：图片库的问题从来不是「信息不够」，
/// 而是「认不出是哪张」。只给时间 + 尺寸的话，一天拍两百张时
/// 每一行都长得一模一样，根本没法挑（用户实测反馈）。
///
/// 缩略图走原生批量通道，按 60 个一批，每批回来就 [setState] 一次，
/// 所以滚动时是新图不断填进来，而不是先干等几十秒。
///
/// 返回：被选中资产的 `localIdentifier` 列表（点击「备份所选」时）。
class PickAssetsPage extends StatefulWidget {
  const PickAssetsPage({super.key});

  @override
  State<PickAssetsPage> createState() => _PickAssetsPageState();
}

class _PickAssetsPageState extends State<PickAssetsPage> {
  List<Map<String, dynamic>> _assets = const [];

  /// localIdentifier → 缩略图 JPEG 字节
  ///
  /// 存的是**同一个 Uint8List 实例**，`Image.memory` 会拿它当缓存键，
  /// 重建时不会重复解码。每张 160px 缩略图约 6KB，三千张约 18MB。
  final Map<String, Uint8List> _thumbs = {};
  final Set<String> _selected = {};

  bool _loading = true;
  bool _thumbDone = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final assets = await PhotoLibraryHelper.fetchAllAssets();
      assets.sort((a, b) {
        final da = (a['creationDate'] as num?)?.toDouble() ?? 0;
        final db = (b['creationDate'] as num?)?.toDouble() ?? 0;
        return db.compareTo(da);
      });
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
      _loadThumbnails();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取相册失败：$e';
      });
    }
  }

  Future<void> _loadThumbnails() async {
    final ids = _assets
        .map((a) => a['localIdentifier'])
        .whereType<String>()
        .where((e) => e.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    await PhotoLibraryHelper.fetchThumbnails(
      ids,
      onBatch: (batch) {
        if (!mounted) return;
        setState(() => _thumbs.addAll(batch));
      },
    );
    if (!mounted) return;
    setState(() => _thumbDone = true);
  }

  String _timeLabel(Map<String, dynamic> asset) {
    final seconds = (asset['creationDate'] as num?)?.toDouble() ?? 0;
    final dt = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).toInt());
    final t = '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    return '${dt.year}/${dt.month}/${dt.day} $t';
  }

  bool _isVideo(Map<String, dynamic> asset) => asset['mediaType'] == 'video';

  String _durationLabel(Map<String, dynamic> asset) {
    final d = (asset['duration'] as num?)?.toDouble() ?? 0;
    if (d <= 0) return '';
    final total = d.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _assets.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(
            _assets
                .map((a) => a['localIdentifier'])
                .whereType<String>()
                .where((e) => e.isNotEmpty),
          );
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
        bottom: _loading || _thumbDone
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _assets.isEmpty
                      ? 0
                      : _thumbs.length / _assets.length,
                  minHeight: 2,
                ),
              ),
      ),
      body: _buildBody(),
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

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_assets.isEmpty) {
      return const Center(child: Text('相册里没有可备份的内容'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _assets.length,
      // 预建一屏的量，滚动时新格子直接有图，不会白闪
      cacheExtent: 800,
      itemBuilder: (context, index) {
        final asset = _assets[index];
        final id = (asset['localIdentifier'] as String?) ?? '';
        return _ThumbCell(
          bytes: _thumbs[id],
          selected: _selected.contains(id),
          isVideo: _isVideo(asset),
          durationLabel: _durationLabel(asset),
          isLive: asset['isLivePhoto'] == true,
          timeLabel: _timeLabel(asset),
          onTap: id.isEmpty ? null : () => _toggle(id),
        );
      },
    );
  }
}

/// 网格里的一格：缩略图 + 选中标记 + 视频/实况角标
class _ThumbCell extends StatelessWidget {
  const _ThumbCell({
    required this.bytes,
    required this.selected,
    required this.isVideo,
    required this.isLive,
    required this.timeLabel,
    required this.durationLabel,
    required this.onTap,
  });

  final Uint8List? bytes;
  final bool selected;
  final bool isVideo;
  final bool isLive;
  final String timeLabel;
  final String durationLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image.memory(
              bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // 限死解码尺寸：原图给的是 160px，这里留 2 倍余量，
              // 避免高倍屏上按需解码出更大的位图吃内存
              cacheWidth: 320,
              errorBuilder: (_, __, ___) => const _ThumbPlaceholder(),
            )
          else
            const _ThumbPlaceholder(),

          // 选中：半透明蓝罩 + 边框，缩略图本身很杂，只靠角标看不清
          if (selected)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.28),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
              ),
            ),

          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black26,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),

          if (isVideo || isLive)
            Positioned(
              left: 4,
              bottom: 4,
              child: Row(
                children: [
                  Icon(
                    isVideo ? Icons.videocam : Icons.motion_photos_on,
                    size: 12,
                    color: Colors.white,
                  ),
                  if (durationLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text(
                        durationLabel,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          shadows: [Shadow(blurRadius: 2)],
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // 时间戳：没有它，同一天的连拍完全分不出先后
          Positioned(
            left: 4,
            top: 4,
            child: Text(
              timeLabel,
              style: const TextStyle(
                fontSize: 9,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 3)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade300,
      alignment: Alignment.center,
      child: Icon(Icons.image_outlined, size: 20, color: Colors.grey.shade500),
    );
  }
}
