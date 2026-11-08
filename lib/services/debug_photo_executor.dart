import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../managers/verify_manager.dart';
import '../models/backup_record.dart';
import '../models/photo_filter_info.dart';

/// 调试通道能执行的任务
///
/// 只有两种，且都**作用在调试会话里选中的照片**上：
///   · `inspect`   —— 只读。回读资源清单、编辑附件字节、解码后的配方
///   · `roundTrip` —— 会创建副本。备份 → 恢复到相册 → 与原图逐项对比
///
/// 没有"执行任意原生方法"的口子，也不提供删除原图的能力。
abstract class DebugExecutor {
  List<Map<String, String>> get copies;
  Future<Map<String, dynamic>> execute(
    String kind,
    String target, {
    String importVariant = 'baseline',
  });
}

/// 允许的导入变体
///
/// 本仓库只有基线。openai 基线里那几个编辑时间戳变体
/// （`fileDates` / `requestImportDate` / `requestModificationDate` …）
/// 需要原生侧对应的实验分支才能生效，主仓库没有这些分支。
///
/// 这里只保留 `baseline`：传别的值会被**明确拒绝**，而不是悄悄按基线跑 ——
/// 那种"以为在验证实验、其实跑的是基线"的静默降级，正是这个项目最容易
/// 得出错误结论的方式。
const debugImportVariants = <String>['baseline'];

/// 受限的照片操作执行器
///
/// ## 边界
/// · 只能操作本次会话里被用户勾选的照片，以及本会话自己创建的副本
/// · 副本 ID 落地在 `debug_copies.json`，断开后可在页面上手动清理
/// · 一次连接最多创建 10 个副本
class DebugPhotoExecutor implements DebugExecutor {
  DebugPhotoExecutor(
    Map<String, BackupRecord> records, {
    required this.allowRoundTrip,
  }) : records = Map.unmodifiable(records);

  final Map<String, BackupRecord> records;
  final bool allowRoundTrip;
  final Map<String, String> _copies = {};
  bool _running = false;
  int _attempts = 0;
  String? _journalError;

  @override
  List<Map<String, String>> get copies => [
        for (final entry in _copies.entries)
          {'key': entry.key, 'label': entry.value},
      ];

  static Future<File> _journal() async => File(
      '${(await FileHelper.getDocumentsDirectory()).path}/debug_copies.json');

  /// 读取本次/历史调试创建的副本 ID
  static Future<List<String>> loadCopyIds() async {
    final file = await _journal();
    if (!await file.exists()) return [];
    final value = jsonDecode(await file.readAsString());
    if (value is! List || value.any((id) => id is! String || id.isEmpty)) {
      throw const FormatException('调试副本记录无法读取');
    }
    return value.cast<String>();
  }

  static Future<void> saveCopyIds(List<String> ids) async {
    final destination = await _journal();
    final pending = File('${destination.path}.pending');
    await pending.writeAsString(jsonEncode(ids.toSet().toList()), flush: true);
    await pending.rename(destination.path);
  }

  Future<void> _track(String id) async {
    if (!_copies.containsValue(id)) _copies['copy-${_copies.length + 1}'] = id;
    try {
      await saveCopyIds([...await loadCopyIds(), id]);
    } catch (error) {
      _journalError = '$error';
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> execute(
    String kind,
    String target, {
    String importVariant = 'baseline',
  }) async {
    if (_running) throw StateError('已有调试任务正在执行');
    final record = records[target];
    final id = record?.localIdentifier ?? _copies[target];
    if (id == null || !['inspect', 'roundTrip'].contains(kind)) {
      throw StateError('任务或照片不在本次授权范围');
    }
    if (!debugImportVariants.contains(importVariant)) {
      throw StateError('本机只支持基线往返（$importVariant 未实现）');
    }
    if (kind == 'roundTrip' &&
        (record == null ||
            !allowRoundTrip ||
            _attempts >= 10 ||
            _journalError != null)) {
      throw StateError('未允许创建副本、已达十次上限或副本记录写入失败');
    }

    _running = true;
    try {
      if (kind == 'inspect') return await inspect(id, record: record);

      _attempts++;
      final manager = VerifyManager();
      AssetVerifyResult? result;
      await for (final progress in manager.verifyRoundTrip([record!])) {
        if (progress.results.isNotEmpty) result = progress.results.last;
      }
      if (result == null) throw StateError('接收服务未连接，未能执行往返测试');

      for (final restoredId in result.resources
          .map((r) => r.restoredAssetId)
          .where((v) => v.isNotEmpty)
          .toSet()) {
        await _track(restoredId);
      }

      return {
        'importVariant': 'baseline',
        'strictBytesMatch': result.ok,
        'error': result.error,
        'originalStillThere': result.originalStillThere,
        'resources': [
          for (final r in result.resources)
            {
              'phase': r.phase,
              'label': r.label,
              'ok': r.ok,
              'expectedSha256': r.expectedFromBackup,
              'originalSha256': r.originalSha,
              'downloadedSha256': r.downloadedSha,
              'restoredSha256': r.restoredSha,
              'originalBytes': r.originalBytes,
              'downloadedBytes': r.downloadedBytes,
              'restoredBytes': r.restoredBytes,
              'restoredShaFrom': r.restoredShaFrom,
              'restoredAssetId': r.restoredAssetId,
              'note': r.note,
            },
        ],
        'originalEditing': await readEditing(id),
        'copies': [
          for (final copy in _copies.entries)
            if (result.resources.any((r) => r.restoredAssetId == copy.value))
              {
                'key': copy.key,
                'assetId': copy.value,
                'editing': await readEditing(copy.value),
              },
        ],
      };
    } finally {
      _running = false;
    }
  }

  /// 只读回读：资源清单 + 各资源哈希 + 编辑附件（解码后的配方）
  static Future<Map<String, dynamic>> inspect(String id,
      {BackupRecord? record}) async {
    final detail = await PhotoLibraryHelper.fetchAssetDetail(id);
    if (detail == null) throw StateError('照片不存在或无法读取');
    final full = await PhotoLibraryHelper.getAssetFullInfo(id);

    return {
      'assetId': id,
      'createdUnix': detail.creationDate,
      'modifiedUnix': detail.modificationDate,
      'width': detail.pixelWidth,
      'height': detail.pixelHeight,
      'mediaType': detail.mediaType,
      'filename': detail.originalFilename,
      'subtypes': detail.subtypes,
      // ---- 以下字段一直都读到了，只是以前没往通道里返回 ----
      // 「逐项对比」要能对得上，缺一项就会变成「看起来一致，其实没比」。
      'duration': detail.duration,
      'isFavorite': detail.isFavorite,
      'isHidden': detail.isHidden,
      'hasLocation': detail.hasLocation,
      'latitude': full?.latitude ?? 0,
      'longitude': full?.longitude ?? 0,
      'formatDescriptions': full?.formatDescriptions ?? const <String>[],
      'resourceCount': detail.resourceCount,
      // iOS 自己那份编辑输入（PHContentEditingInput）。
      // 判「相册是否认为这张被编辑过」靠它，与资源里的 plist 是两条独立证据。
      'iosEditing': full?.editing ?? const <String, dynamic>{},
      'resources': [
        for (final r in (full?.resources ?? const <AssetResourceDetail>[]))
          {
            'typeRawValue': r.typeRawValue,
            'typeName': r.typeName,
            'uti': r.uti,
            'filename': r.filename,
            'bytes': r.bytes,
            'sha256': r.sha256,
            'truncated': r.inlineTruncated,
            'error': r.error,
          },
      ],
      // 原生通道只提供「主资源 / 配对视频」两种哈希，附加资源（配方、AAE、
      // 渲染图）的哈希在 resources 行里逐条给出，不在这里重复读一遍。
      'hashes': {
        'main': _hash(
            await PhotoLibraryHelper.hashAssetResources(localIdentifier: id)),
        if (record?.livePhotoVideoRelativePath != null)
          'pairedVideo': _hash(await PhotoLibraryHelper.hashAssetResources(
            localIdentifier: id,
            preferVideo: true,
          )),
      },
      'editing': await readEditing(id),
    };
  }

  static Map<String, dynamic>? _hash(AssetResourceHash? value) =>
      value == null
          ? null
          : {'sha256': value.sha256, 'bytes': value.bytes, 'uti': value.uti};

  /// 回读编辑附件并**解码配方**
  ///
  /// 两种附件的读法不同，必须分开：
  ///   · type 7  `adjustmentData`：裸 DEFLATE + JSON → [PhotoFilterInfo.fromEnvelopeBytes]
  ///   · type 16 相机 AAE：XML plist，里面再套一段 base64 的 adjustmentData
  ///     → 先当文本读，再走 [PhotoFilterInfo.fromPlistText]
  ///
  /// 用「解码后的编辑操作」比对而不是字节比对：iOS 导入时一定会重置
  /// `adjustmentTimestamp`，字节必然不同，但编辑操作完全一致。
  static Future<Map<String, dynamic>> readEditing(String id) async {
    final full = await PhotoLibraryHelper.getAssetFullInfo(id);
    if (full == null) return {'error': '读不到资源明细'};

    final out = <String, dynamic>{};
    for (final r in full.resources) {
      final isCurrent = r.typeRawValue == 7;
      final isCamera = r.typeRawValue == 16;
      if (!isCurrent && !isCamera) continue;

      Map<String, dynamic>? recipe;
      if (r.base64.isEmpty) {
        recipe = {'error': r.error.isEmpty ? '没有回读到字节' : r.error};
      } else if (r.inlineTruncated) {
        // 附件被 4KB 上限截断，解出来的配方不可信 —— 如实标注，不要假装解开了
        recipe = {'error': '附件超过回读上限被截断（${r.bytes} 字节）'};
      } else {
        try {
          final bytes = base64Decode(r.base64);
          // ⚠ 两种附件**都是 XML plist**（type 7 = Adjustments.plist，
          // type 16 = .aae），配方在里面的 `<data>` 段才是 base64 的裸 DEFLATE。
          // 所以必须先当文本读、走 fromPlistText；直接把整个 plist 喂给
          // fromEnvelopeBytes 会得到「配方解压失败（不是裸 DEFLATE）」
          // —— 2026-11-08 第一次真机 inspect 就是这么错的。
          final text = utf8.decode(bytes, allowMalformed: true);
          final info = text.contains('adjustmentData')
              ? PhotoFilterInfo.fromPlistText(text)
              : PhotoFilterInfo.fromEnvelopeBytes(bytes);
          recipe = {
            'status': info.status,
            'display': info.display,
            'identifier': info.identifier,
            'intensity': info.intensity,
            'operations': info.operationCount,
            'signature': info.signature,
          };
        } catch (e) {
          recipe = {'error': '$e'};
        }
      }

      out[isCurrent ? 'current' : 'camera'] = {
        'typeRawValue': r.typeRawValue,
        'filename': r.filename,
        'uti': r.uti,
        'bytes': r.bytes,
        'sha256': r.sha256,
        'truncated': r.inlineTruncated,
        'recipe': recipe,
      };
    }
    return out;
  }

  static Object? jsonSafe(Object? value) {
    if (value is Uint8List) {
      return {
        'encoding': 'base64',
        'bytes': value.length,
        'sha256': sha256.convert(value).toString(),
        'base64': base64Encode(value),
      };
    }
    if (value is Map) {
      return {for (final e in value.entries) '${e.key}': jsonSafe(e.value)};
    }
    if (value is List) return value.map(jsonSafe).toList();
    return value;
  }
}
