import 'dart:async';

import 'package:flutter/material.dart';

import '../helpers/photo_library_helper.dart';
import '../managers/record_store.dart';
import '../models/backup_record.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';

/// 备份信息对比页
///
/// 左：电脑上的备份记录（来自手机本地记录，或本地为空时从电脑清单重建）
/// 右：手机相册里的原图（原生 PHAsset 全量信息）
/// 中间逐字段标出「一致 / 不一致 / 备份未记录」
///
/// 顺带解决一个疑问：一份照片在手机里到底由哪些文件组成
/// （ProRAW 的 DNG+JPEG、人像深度图、HDR 增益图…）——
/// 「资源构成」卡片直接列出原生返回的全部资源与 UTI。
class ComparePage extends StatefulWidget {
  const ComparePage({super.key});

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  List<BackupRecord> _records = [];
  bool _loadingRecords = true;
  String? _recordError;

  AssetDetail? _phoneDetail;
  bool _loadingPhone = false;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _loadingRecords = true;
      _recordError = null;
    });
    try {
      var records = await RecordStore().loadAllRecords();
      if (records.isEmpty) {
        // 本地没有记录时，退回用电脑清单重建
        final config = await ServerConfig.load();
        if (config.isConfigured) {
          final client = ServerClient(config);
          final raw = await client.downloadManifest();
          if (raw != null) {
            records = ManifestRecords.fromManifest(raw);
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _records = records;
        _loadingRecords = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recordError = '$e';
        _loadingRecords = false;
      });
    }
  }

  /// 选中一条备份记录 → 去手机里找对应资产
  Future<void> _pick(BackupRecord record) async {
    setState(() {
      _phoneDetail = null;
      _loadingPhone = true;
    });
    final detail = await PhotoLibraryHelper.fetchAssetDetail(record.localIdentifier);
    if (!mounted) return;
    setState(() {
      _phoneDetail = detail;
      _loadingPhone = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份信息对比'),
        actions: [
          IconButton(
            onPressed: _loadRecords,
            icon: const Icon(Icons.refresh),
            tooltip: '重新读取备份记录',
          ),
        ],
      ),
      body: _loadingRecords
          ? const Center(child: CircularProgressIndicator())
          : _recordError != null
              ? _msg('读取备份记录失败：$_recordError')
              : _records.isEmpty
                  ? _msg('没有可对比的备份记录。\n'
                      '请先做一次备份，或确认接收端已启动、App 能拉到电脑清单。')
                  : Column(
                      children: [
                        _recordList(),
                        const Divider(height: 1),
                        _result(),
                      ],
                    ),
    );
  }

  Widget _msg(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );

  Widget _recordList() {
    return SizedBox(
      height: 200,
      child: ListView.separated(
        itemCount: _records.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final r = _records[index];
          final name = r.relativePath.split('/').last;
          return ListTile(
            dense: true,
            title: Text(name,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
            subtitle: Text(
              '${_fmtTime(r.creationTimestamp)}  ·  ${r.mediaType}'
              '${r.pixelWidth != null ? '  ·  ${r.pixelWidth}×${r.pixelHeight}' : ''}',
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => _pick(r),
          );
        },
      ),
    );
  }

  Widget _result() {
    if (_loadingPhone) {
      return const Expanded(child: Center(child: CircularProgressIndicator()));
    }
    final phone = _phoneDetail;
    if (phone == null) {
      return const Expanded(
        child: Center(
          child: Text('点击上方任意一条备份记录，\n自动与手机里的原图逐项对比',
              textAlign: TextAlign.center),
        ),
      );
    }
    return Expanded(child: _comparison(phone));
  }

  Widget _comparison(AssetDetail phone) {
    final matched = _records.where((r) => r.localIdentifier == phone.localIdentifier);
    final record = matched.isNotEmpty ? matched.first : null;

    final rows = <_Row>[
      _Row(
        '拍摄时间',
        record != null ? _fmtTime(record.creationTimestamp) : '无对应记录',
        _fmtTime(phone.creationDate),
        record != null ? _sameTime(record.creationTimestamp, phone.creationDate) : null,
      ),
      _Row(
        '像素尺寸',
        record != null && record.pixelWidth != null
            ? '${record.pixelWidth}×${record.pixelHeight}'
            : '未记录',
        phone.sizeLabel,
        record != null && record.pixelWidth != null
            ? '${record.pixelWidth}×${record.pixelHeight}' == phone.sizeLabel
            : null,
      ),
      _Row('媒体类型', record?.mediaType ?? '无对应记录', phone.typeLabel, null),
      _Row('拍摄模式', '未记录',
          phone.subtypes.isEmpty ? '（无特殊模式）' : phone.subtypes.join('、'), null),
      _Row('文件构成', '（备份侧只存了 1 个文件）',
          '${phone.resourceCount} 份资源', null),
      _Row('原始文件名', '未记录',
          phone.originalFilename.isEmpty ? '（无）' : phone.originalFilename, null),
      _Row('收藏', '未记录', phone.isFavorite ? '是' : '否', null),
      _Row('隐藏', '未记录', phone.isHidden ? '是' : '否', null),
      _Row('位置', '未记录', phone.hasLocation ? '有 GPS' : '无', null),
      _Row('时长', '未记录',
          phone.duration > 0 ? '${phone.duration.toStringAsFixed(1)} 秒' : '—', null),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _header('手机侧资源构成（GAP-R1 的直接证据）'),
        _resourceCard(phone),
        const SizedBox(height: 14),
        _header('逐项对比（备份 ↔ 原图）'),
        for (final r in rows) _row(r),
        const SizedBox(height: 10),
        Text(
          '✓ 一致　✗ 不一致　! 备份里没有这一项（GAP-M 系列待补）',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      );

  Widget _resourceCard(AssetDetail phone) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(phone.originalFilename.isEmpty
              ? phone.localIdentifier
              : phone.originalFilename),
          const SizedBox(height: 6),
          for (final r in phone.resources)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '· ${r.typeLabel.padRight(20)} ${r.sizeText.padRight(10)} ${r.uti}',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(_Row r) {
    Color color;
    String mark;
    if (r.same == true) {
      color = Colors.green.shade700;
      mark = '✓';
    } else if (r.same == false) {
      color = Colors.red.shade700;
      mark = '✗';
    } else {
      color = Colors.orange.shade800;
      mark = '!';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 64,
              child: Text(r.label, style: const TextStyle(fontSize: 12))),
          SizedBox(
            width: 16,
            child:
                Text(mark, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text('${r.backup}   ↔   ${r.phone}',
                style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  static bool _sameTime(double a, double b) {
    if (a <= 0 || b <= 0) return false;
    // 拍摄时间有亚秒精度，manifest 保留到微秒，允许 1 秒内差异
    return (a - b).abs() < 1.0;
  }

  static String _fmtTime(double unixSeconds) {
    if (unixSeconds <= 0) return '未知';
    final d =
        DateTime.fromMillisecondsSinceEpoch((unixSeconds * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

class _Row {
  final String label;
  final String backup;
  final String phone;
  /// true=一致，false=不一致，null=备份未记录该项
  final bool? same;

  const _Row(this.label, this.backup, this.phone, this.same);
}

/// 从电脑清单（/manifest 返回的行）重建备份记录
class ManifestRecords {
  static List<BackupRecord> fromManifest(List<Map<String, dynamic>> raw) {
    final pairedByKey = <String, String>{};
    for (final e in raw) {
      final key = e['pairKey'] as String? ?? '';
      if (e['role'] == 'pairedVideo' && key.isNotEmpty) {
        pairedByKey[key] = e['serverPath'] as String? ?? '';
      }
    }
    final out = <BackupRecord>[];
    for (final e in raw) {
      if (e['role'] == 'pairedVideo') continue;
      final ts = (e['createdUnix'] as num?)?.toDouble() ?? 0;
      final ms = (ts * 1000).round();
      final key = e['pairKey'] as String? ?? '';
      out.add(BackupRecord(
        localIdentifier: e['assetId'] as String? ?? '',
        relativePath: e['serverPath'] as String? ?? '',
        creationDate:
            DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal(),
        creationTimestamp: ts,
        mediaType: e['mediaType'] as String? ?? '',
        livePhotoVideoRelativePath: key.isEmpty ? null : pairedByKey[key],
        pixelWidth: (e['pixelWidth'] as num?)?.toInt(),
        pixelHeight: (e['pixelHeight'] as num?)?.toInt(),
      ));
    }
    return out;
  }
}