import 'dart:async';

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../helpers/photo_library_helper.dart';
import '../managers/record_store.dart';
import '../models/backup_record.dart';
import '../services/log_service.dart';
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

  /// 当前选中的备份记录。单独存一份是因为 _pick 里只把 localIdentifier
  /// 拿去向原生查询了，record 本身被丢弃了 —— 而导出报告需要它。
  BackupRecord? _picked;

  ServerConfig _config = ServerConfig.empty;
  bool _uploading = false;

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
      final config = await ServerConfig.load();
      var records = await RecordStore().loadAllRecords();
      if (records.isEmpty) {
        // 本地没有记录时，退回用电脑清单重建
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
        _config = config;
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
      _picked = record;
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

  /// 生成对比结果报告（纯文本，用于上传到电脑留档）
  ///
  /// 为什么需要导出：对比结果是**一次性观察**——想拿它去查问题时，
  /// 往往已经不在那台手机上了。留在手机里等于没留。
  String _buildReport() {
    final sb = StringBuffer();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';

    sb.writeln('=== PhotoBackup 备份信息对比报告 ===');
    sb.writeln('生成时间: ${now.toString()}');
    sb.writeln('App 版本: ${AppInfo.display}');
    sb.writeln('服务器: ${_config.isConfigured ? _config.baseUrl : '未配置'}');
    sb.writeln('记录来源: ${_records.isEmpty ? '无' : (_picked == null ? '本地记录/电脑清单' : '本地记录/电脑清单')}');

    // ---- 备份记录总览 ----
    sb.writeln('');
    sb.writeln('--- 备份记录总览（共 ${_records.length} 条）---');
    if (_records.isNotEmpty) {
      final byType = <String, int>{};
      var live = 0, withPrints = 0, withHash = 0, complete = 0, unverifiable = 0;
      var minT = double.infinity, maxT = 0.0;
      for (final r in _records) {
        byType[r.mediaType] = (byType[r.mediaType] ?? 0) + 1;
        if (r.mediaType == 'live_photo') live++;
        if (r.pixelWidth != null) withPrints++;
        if (r.contentSha256.isNotEmpty) withHash++;
        final ok = r.isResourceComplete;
        if (ok == null) {
          unverifiable++;
        } else if (ok) {
          complete++;
        }
        if (r.creationTimestamp < minT) minT = r.creationTimestamp;
        if (r.creationTimestamp > maxT) maxT = r.creationTimestamp;
      }
      byType.forEach((k, v) => sb.writeln('  $k: $v 条'));
      sb.writeln('  实况照片: $live 条');
      sb.writeln('  含像素宽高: $withPrints / ${_records.length}'
          '${withPrints == 0 ? '  ← 旧版 App 写的记录，指纹会退化' : ''}');
      sb.writeln('  含原图哈希(可端到端校验): $withHash / ${_records.length}');
      if (unverifiable > 0) {
        sb.writeln('  资源完整度: $complete 条完整'
            '${unverifiable > 0 ? '、$unverifiable 条无法判断（缺 resourceTotal）' : ''}');
      } else {
        sb.writeln('  资源完整度: $complete / ${_records.length} 完整');
      }
      if (minT.isFinite) {
        sb.writeln('  时间跨度: ${_fmtTime(minT)} ~ ${_fmtTime(maxT)}');
      }

      // 同一秒多条的情况：这是 GAP-O1 的实证数据，顺序信息只存在于记录里
      final bySecond = <int, int>{};
      for (final r in _records) {
        final s = r.creationTimestamp.floor();
        bySecond[s] = (bySecond[s] ?? 0) + 1;
      }
      final multi = bySecond.values.where((v) => v > 1).length;
      sb.writeln('  同秒多条: $multi 组 / ${bySecond.length} 个不同的秒'
          '${multi > 0 ? '（同秒照片的先后顺序只存在于记录中）' : ''}');
    }

    // ---- 逐项对比结果 ----
    final rec = _picked;
    final phone = _phoneDetail;
    sb.writeln('');
    if (rec == null) {
      sb.writeln('--- 逐项对比 ---');
      sb.writeln('（未选中任何记录，报告只含总览）');
    } else {
      final name = rec.relativePath.split('/').last;
      sb.writeln('--- 逐项对比：$name ---');
      sb.writeln('');
      sb.writeln('[备份记录侧]');
      sb.writeln('  相对路径: ${rec.relativePath}');
      sb.writeln('  资产 ID: ${rec.localIdentifier}');
      sb.writeln('  拍摄时间: ${_fmtTime(rec.creationTimestamp)}'
          '  (亚秒 ${rec.creationTimestamp.toStringAsFixed(6)})');
      sb.writeln('  媒体类型: ${rec.mediaType}');
      sb.writeln('  像素宽高: ${rec.pixelWidth}x${rec.pixelHeight}');
      if (rec.livePhotoVideoRelativePath != null) {
        sb.writeln('  配对视频: ${rec.livePhotoVideoRelativePath}');
      }

      sb.writeln('');
      if (phone == null) {
        sb.writeln('[手机原图侧]');
        sb.writeln('  未取到（照片可能已被删除，或查询失败）');
      } else {
        sb.writeln('[手机原图侧]');
        sb.writeln('  资产 ID: ${phone.localIdentifier}');
        sb.writeln('  拍摄时间: ${_fmtTime(phone.creationDate)}');
        sb.writeln('  修改时间: ${_fmtTime(phone.modificationDate)}');
        sb.writeln('  媒体类型: ${phone.mediaType}');
        sb.writeln('  像素宽高: ${phone.pixelWidth}x${phone.pixelHeight}');
        sb.writeln('  时长: ${phone.duration} 秒');
        sb.writeln('  收藏: ${phone.isFavorite ? '是' : '否'}');
        sb.writeln('  隐藏: ${phone.isHidden ? '是' : '否'}');
        sb.writeln('  原始文件名: ${phone.originalFilename.isEmpty ? '(取不到)' : phone.originalFilename}');
        sb.writeln('  有位置信息: ${phone.hasLocation ? '是' : '否'}');
        sb.writeln('  特殊类型: ${phone.subtypes.isEmpty ? '(无)' : phone.subtypes.join(', ')}');

        // 资源构成：这是判断「一份照片到底由哪些文件组成」的关键
        // （ProRAW = DNG+JPEG、人像深度图、HDR 增益图等）
        sb.writeln('');
        sb.writeln('  资源构成（${phone.resources.length} 个文件）:');
        for (final res in phone.resources) {
          sb.writeln('    - [${res.typeLabel}] ${res.originalFilename}');
          sb.writeln('      UTI: ${res.uti}');
        }

        // 资源完整度：备份侧只导出了主文件，原图的辅助资源（ProRAW 第二份、
        // 深度图、增益图）并没有被导出 —— 这正是 GAP-R1 的暴露方式，
        // 以前报告里看不到，现在明确列出。
        sb.writeln('');
        sb.writeln('  资源完整度:');
        sb.writeln('    原图资源总数: ${phone.resources.length}');
        sb.writeln('    已备份: 主文件 1 个（${rec.relativePath.split('/').last}）');
        if (rec.livePhotoVideoRelativePath != null) {
          sb.writeln('已备份: 配对视频 1 个（${rec.livePhotoVideoRelativePath.split('/').last}）');
        }
        final auxCount = phone.resources.where((r) {
          const primaryTypes = {
            'photo', 'video', 'pairedVideo',
            'fullSizePhoto', 'fullSizeVideo', 'fullSizePairedVideo',
          };
          return !primaryTypes.contains(r.typeLabel);
        }).length;
        if (auxCount > 0) {
          final auxNames = phone.resources
              .where((r) => const {
                    'photo', 'video', 'pairedVideo',
                    'fullSizePhoto', 'fullSizeVideo', 'fullSizePairedVideo',
                  }.contains(r.typeLabel) == false)
              .map((r) => r.typeLabel)
              .toList();
          sb.writeln('    未备份: $auxCount 个辅助资源（${auxNames.join(', ')}）');
          sb.writeln('    → 判定: **不完整** —— 原图比备份多出这些资源，'
              '恢复后会丢失对应信息（深度/动态范围/第二份格式）');
        } else {
          sb.writeln('    未备份: 无');
          sb.writeln('    → 判定: 完整');
        }

        // 一致性判定：哪些字段对不上
        sb.writeln('');
        sb.writeln('  一致性判定:');
        _cmp(sb, '资产 ID', rec.localIdentifier, phone.localIdentifier);
        _cmp(sb, '媒体类型', rec.mediaType, phone.mediaType);
        _cmp(sb, '像素宽高',
            '${rec.pixelWidth}x${rec.pixelHeight}',
            '${phone.pixelWidth}x${phone.pixelHeight}');
        // 拍摄时间允许亚秒级差异（备份侧保留 6 位小数）
        final dt = (rec.creationTimestamp - phone.creationDate).abs();
        _cmp(sb, '拍摄时间',
            rec.creationTimestamp.toStringAsFixed(6),
            phone.creationDate.toStringAsFixed(6),
            note: dt < 0.001 ? null : '相差 ${dt.toStringAsFixed(3)} 秒');
      }
    }

    sb.writeln('');
    sb.writeln('--- 报告结束 ---');
    return sb.toString();
  }

  /// 写一行对比结果，不一致时标出差异
  void _cmp(StringBuffer sb, String label, String a, String b, {String? note}) {
    final same = a == b;
    sb.writeln('    $label: $a  vs  $b   → ${same ? '一致' : '不一致'}${note != null ? '  ($note)' : ''}');
  }

  /// 把对比报告上传到电脑（落到 iPhoneBackup\logs\）
  ///
  /// 复用日志上传通道：/log 按文件名覆盖写，同一份报告重复上传不会膨胀。
  Future<void> _uploadReport() async {
    if (_uploading) return;
    if (!_config.isConfigured) {
      _toast('未配置服务器地址，无法上传');
      return;
    }
    setState(() => _uploading = true);
    var ok = false;
    var msg = '';
    try {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name = 'compare-${now.year}${two(now.month)}${two(now.day)}'
          '-${two(now.hour)}${two(now.minute)}${two(now.second)}.log';
      final client = ServerClient(_config);
      ok = await client.uploadLog(name, _buildReport());
      msg = ok
          ? '已上传：iPhoneBackup\\logs\\$name'
          : '上传失败（接收端未启动或地址不可达）';
    } catch (e) {
      msg = '上传失败：$e';
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    _toast(msg, ok: ok);
    // 顺带记进日志，这样日志里也能看到用户做过对比分析
    LogService.instance.write(
      LogLevel.info,
      'compare',
      '导出对比报告: $msg',
    );
  }

  void _toast(String msg, {bool ok = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? null : Colors.red.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份信息对比'),
        actions: [
          IconButton(
            onPressed: _uploading ? null : _uploadReport,
            icon: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_upload),
            tooltip: '导出对比结果到电脑',
          ),
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