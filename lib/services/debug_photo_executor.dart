import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../managers/verify_manager.dart';
import '../models/backup_record.dart';
import '../models/photo_filter_info.dart';

/// 调试通道能执行的任务
///
/// 前两种**作用在调试会话里选中的照片**上：
///   · `inspect`   —— 只读。回读资源清单、编辑附件字节、解码后的配方
///   · `roundTrip` —— 会创建副本。备份 → 恢复到相册 → 与原图逐项对比
///
/// 第三种覆盖全库（只读，不建副本、不写相册）：
///   · `scanEffects` —— 扫出相册里**已经用过**的全部滤镜（effectName + 强度），
///     用于补齐「effectName → 中文名」的实测表。它不受选中范围限制，因为
///     滤镜清单只能从真实配方里反推，抽样十张没有意义。
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
    // 全库滤镜扫描：不作用于「会话里选中的照片」，所以不受 target 白名单限制。
    // 它只读（不建副本、不写相册），且必须覆盖全库才有意义 ——
    // Apple 不公开滤镜清单，effectName 只能从「已经用过的配方」里反推。
    if (kind == 'scanEffects') {
      _running = true;
      try {
        return await scanEffectsAll();
      } finally {
        _running = false;
      }
    }
    // 滤镜写入实验：目标必须是本次会话勾选的照片（拿它当母本），
    // 参数用 importVariant 编码成 `probe:<effectName>:<intensity>`，
    // 这样不必改动任务结构就能把参数传进来。
    if (kind == 'filterProbe' || kind == 'filterMatrix') {
      final record = records[target];
      if (record == null) throw StateError('目标照片不在本次授权范围');
      final probe = RegExp(r'^probe:([^:]+):([0-9]*\.?[0-9]+)(?::(norender))?$')
          .firstMatch(importVariant);
      final matrix = RegExp(r'^matrix:([0-9A-Za-z_.,:]+)$').firstMatch(importVariant);
      if (probe == null && matrix == null) {
        throw StateError('需要 probe:<effect>:<0..1>[:norender] 或 matrix:<effect>:<0..1>,…');
      }
      _running = true;
      try {
        if (probe != null) {
          return await probeFilter(
            record,
            effectName: probe.group(1)!,
            intensity: double.parse(probe.group(2)!),
            writeRender: probe.group(3) == null,
          );
        }
        final items = <String, double>{};
        for (final part in matrix!.group(1)!.split(',')) {
          final seg = part.split(':');
          if (seg.length != 2) throw StateError('矩阵项格式错误：$part');
          items[seg[0]] = double.parse(seg[1]);
        }
        return await probeMatrix(record, items, writeRender: false);
      } finally {
        _running = false;
      }
    }
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

  /// 全库只读扫描：相册里已经用过的滤镜，按 effectName 去重汇总
  ///
  /// 回传里**不带配方原始字节**（调试结果要过 JSON 通道，塞进去毫无用处）：
  /// 解码在手机侧完成，电脑只需拿到「有哪些滤镜、各出现几次、强度多少」。
  static Future<Map<String, dynamic>> scanEffectsAll() async {
    final result = await PhotoLibraryHelper.scanUsedEffects();
    if (result == null) {
      throw StateError('扫描失败：没有相册权限，或原生通道异常');
    }
    return {
      'scannedAssets': result.scannedAssets,
      'editedAssets': result.editedAssets,
      'recipeResources': result.recipeResources,
      'totalBytes': result.totalBytes,
      'truncated': result.truncated,
      'timedOut': result.timedOut,
      'stats': [
        for (final s in result.stats)
          {
            'effectName': s.effectName,
            'label': s.label,
            'sampleCount': s.sampleCount,
            'assetCount': s.assetCount,
            'intensities': s.intensities,
            'isNoFilter': s.isNoFilter,
          },
      ],
      // 明细只留前 300 条：够看清每条配方的强度与来源，又不至于把结果撑爆
      'samples': [
        for (final s in result.samples.take(300))
          {
            'assetId': s.assetId,
            'filename': s.filename,
            'typeRawValue': s.typeRawValue,
            'status': s.recipe.status,
            'effectName': s.recipe.identifier,
            'intensity': s.recipe.intensity,
            'note': s.recipe.description,
            // 只对解压/解析失败的样本回传字节头：成功的不需要，省通道体积
            if (!s.recipe.isKnown) 'headHex': s.headHex,
            if (!s.recipe.isKnown) 'payloadHeadHex': s.payloadHeadHex,
          },
      ],
      'report': result.report,
    };
  }

  /// 构造一份配方写进相册副本，验证 iOS 是否接受任意 `effectName`
  ///
  /// ## 为什么只能这么测
  /// 公开 API 没有「给照片选一个系统滤镜」的入口 —— 相册编辑的写入协议是
  /// `PHContentEditingOutput.adjustmentData` **由编辑方自己提供**。所以要穷举
  /// 9 个滤镜 × 各档强度，只能自己造配方写副本，再读回看 iOS 认不认。
  ///
  /// ## 配方不凭空编
  /// 把**原图那份配方**解成 JSON，只替换 `Effect.settings` 的 `effectName` /
  /// `effectIntensity`；`metadata`、`versionInfo`、`RKRawDecodeOperation` 的
  /// `boostParams` 全部原样保留。少一个字段都可能被 iOS 拒收，那样测出来的
  /// 「失败」是假的。
  ///
  /// ## 副本必须三件套
  /// DNG（`.photo`）+ 配方（`.adjustmentData`）+ 渲染图（`.fullSizePhoto`）。
  /// 配方与渲染图缺一不可，只写配方会被拒。
  Future<Map<String, dynamic>> probeFilter(
    BackupRecord record, {
    required String effectName,
    required double intensity,
    bool writeRender = true,
  }) async {
    final out = <String, dynamic>{
      'requestedEffect': effectName,
      'requestedIntensity': intensity,
    };
    final id = record.localIdentifier;

    // ---- 1. 取原配方（plist 文本 → adjustmentData → envelope → JSON）
    final full = await PhotoLibraryHelper.getAssetFullInfo(id);
    String? plistB64;
    var templateName = '';
    for (final r in full?.resources ?? const <AssetResourceDetail>[]) {
      final u = r.uti.toLowerCase();
      if (r.base64.isNotEmpty &&
          (u.contains('adjustment') || u.contains('property-list'))) {
        plistB64 = r.base64;
        templateName = r.filename;
        break;
      }
    }
    if (plistB64 == null) {
      throw StateError('原图没有可读的调整配方资源，做不了模板');
    }
    out['template'] = templateName;

    final plistText = utf8.decode(base64Decode(plistB64), allowMalformed: true);
    final dataMatch = RegExp(
      r'<key>\s*adjustmentData\s*</key>\s*<data>([\s\S]*?)</data>',
    ).firstMatch(plistText);
    if (dataMatch == null) throw StateError('模板 plist 里没有 adjustmentData');

    final envelope =
        base64Decode(dataMatch.group(1)!.replaceAll(RegExp(r'\s'), ''));
    final recipe = PhotoFilterInfo.rawRecipeJson(envelope);
    if (recipe == null) throw StateError('模板配方解不开（不是裸 DEFLATE）');
    out['templateAdjustments'] = [
      for (final a
          in ((recipe['adjustments'] as List?) ?? const []).whereType<Map>())
        '${a['identifier']}',
    ];

    // ---- 2. 只替换 Effect 项，其余字段原样保留
    final adjustments = ((recipe['adjustments'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    var replaced = false;
    for (final a in adjustments) {
      if (a['identifier'] != 'Effect') continue;
      final settings =
          Map<String, dynamic>.from((a['settings'] as Map?) ?? const {});
      settings['effectName'] = effectName;
      settings['effectIntensity'] = intensity;
      a['settings'] = settings;
      a['enabled'] = true;
      replaced = true;
      break;
    }
    if (!replaced) {
      // 母本是「原片」时没有 Effect 项，补一个（字段形状照抄实测样本）
      adjustments.add({
        'formatVersion': 1,
        'enabled': true,
        'formatIdentifier': 'com.apple.photo',
        'identifier': 'Effect',
        'settings': {
          'effectVersion': 1,
          'effectName': effectName,
          'effectIntensity': intensity,
        },
      });
    }
    recipe['adjustments'] = adjustments;
    final newEnvelope = PhotoFilterInfo.encodeRecipeJson(recipe);
    if (newEnvelope == null) throw StateError('配方重新压缩失败');
    out['envelopeBytes'] = newEnvelope.length;

    // ---- 3. 写 plist（结构照抄系统产物，只换 data 与时间）
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final plistPath = '${tmp.path}/probe_recipe_$stamp.plist';
    await File(plistPath).writeAsString(
      _plistTemplate(base64Encode(newEnvelope), record.creationTimestamp),
    );

    // ---- 4. 导出主文件（DNG 当母本）
    final exported = await PhotoLibraryHelper.exportPhotoAsset(
      localIdentifier: id,
      targetPath: '${tmp.path}/probe_main_$stamp.dng',
    );
    if (exported == null) throw StateError('导出原图失败');
    out['mainPath'] = exported.path;
    out['mainBytes'] = exported.bytes;

    // ---- 5. 渲染图：默认与配方成对写；norender 变体只写 DNG + 配方，
    //          用来验证 iOS 会不会自己按配方重渲染（缓存图不一致时的关键实验）
    var renderPath = '';
    if (writeRender) {
      final editing = await PhotoLibraryHelper.analyzeAssetEditing(id);
      renderPath = editing?.renderedImagePath ?? '';
      if (renderPath.isEmpty) {
        throw StateError('拿不到 iOS 渲染图，配方无法成对写入');
      }
      out['renderPath'] = renderPath;
    } else {
      out['renderPath'] = '(未写入，仅 DNG + 配方)';
    }

    // ---- 6. 写副本
    final saved = await PhotoLibraryHelper.savePhotoWithExtras(
      filePath: exported.path,
      creationTimestamp: record.creationTimestamp,
      extras: [
        {
          'restoreType': 'adjustmentData',
          'path': plistPath,
          'filename': 'Adjustments.plist',
        },
        if (writeRender)
          {
            'restoreType': 'fullSizePhoto',
            'path': renderPath,
            'filename': 'FullSizeRender.jpg',
          },
      ],
      mainFilename: record.relativePath.split('/').last,
    );
    out['written'] = saved.written;
    out['failed'] = saved.failed;
    out['warning'] = saved.warning;
    out['error'] = saved.error;
    final newId = saved.assetId;
    out['newAssetId'] = newId;
    if (newId.isEmpty) return out;
    await _track(newId);

    // ---- 7. 读回：副本里那份配方到底被 iOS 认成了什么
    final back = await PhotoLibraryHelper.getAssetFullInfo(newId);
    String? backB64;
    for (final r in back?.resources ?? const <AssetResourceDetail>[]) {
      final u = r.uti.toLowerCase();
      if (r.base64.isNotEmpty &&
          (u.contains('adjustment') || u.contains('property-list'))) {
        backB64 = r.base64;
        break;
      }
    }
    if (backB64 == null) {
      out['readBack'] = '副本里没有调整配方资源';
      return out;
    }
    final backText = utf8.decode(base64Decode(backB64), allowMalformed: true);
    final info = PhotoFilterInfo.fromPlistText(backText);
    final backEditing = await PhotoLibraryHelper.analyzeAssetEditing(newId);
    out['readBack'] = {
      'status': info.status,
      'description': info.description,
      'effectName': info.identifier,
      'intensity': info.intensity,
      'hasAdjustments': backEditing?.hasAdjustments ?? false,
      'resources': [
        for (final r in back?.resources ?? const <AssetResourceDetail>[])
          '${r.typeRawValue}:${r.filename}',
      ],
    };
    return out;
  }

  /// 批量：同一母本、多个「滤镜 + 强度」组合各写一个副本
  ///
  /// 与 [probeFilter] 的差别只有两点：DNG 只导出一次（64 MB 母本，导出比写
  /// 副本还慢），并且**不逐个读回**（读回要把 64 MB DNG 整个读一遍，9 个组合
  /// 要好几分钟）。名字对不对由事后一次 `scanEffects` 全库核对 —— 那只要 2 秒。
  ///
  /// 上限 12 个：写太多副本既占空间，也让相册索引变慢。
  Future<Map<String, dynamic>> probeMatrix(
    BackupRecord record,
    Map<String, double> items, {
    bool writeRender = false,
  }) async {
    if (items.isEmpty || items.length > 12) {
      throw StateError('批量项必须 1..12 个');
    }
    final out = <String, dynamic>{
      'writeRender': writeRender,
      'items': <Map<String, dynamic>>[],
    };

    // 模板配方（一次）
    final full =
        await PhotoLibraryHelper.getAssetFullInfo(record.localIdentifier);
    String? plistB64;
    for (final r in full?.resources ?? const <AssetResourceDetail>[]) {
      final u = r.uti.toLowerCase();
      if (r.base64.isNotEmpty &&
          (u.contains('adjustment') || u.contains('property-list'))) {
        plistB64 = r.base64;
        break;
      }
    }
    if (plistB64 == null) throw StateError('原图没有可读的调整配方资源');
    final plistText = utf8.decode(base64Decode(plistB64), allowMalformed: true);
    final dataMatch = RegExp(
      r'<key>\s*adjustmentData\s*</key>\s*<data>([\s\S]*?)</data>',
    ).firstMatch(plistText);
    if (dataMatch == null) throw StateError('模板 plist 里没有 adjustmentData');
    final baseRecipe = PhotoFilterInfo.rawRecipeJson(
      base64Decode(dataMatch.group(1)!.replaceAll(RegExp(r'\s'), '')),
    );
    if (baseRecipe == null) throw StateError('模板配方解不开');

    // 母本与渲染图各取一次
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final exported = await PhotoLibraryHelper.exportPhotoAsset(
      localIdentifier: record.localIdentifier,
      targetPath: '${tmp.path}/matrix_main_$stamp.dng',
    );
    if (exported == null) throw StateError('导出原图失败');
    out['mainBytes'] = exported.bytes;
    var renderPath = '';
    if (writeRender) {
      final e = await PhotoLibraryHelper.analyzeAssetEditing(
        record.localIdentifier,
      );
      renderPath = e?.renderedImagePath ?? '';
      if (renderPath.isEmpty) throw StateError('拿不到 iOS 渲染图');
    }

    var index = 0;
    for (final entry in items.entries) {
      index++;
      final effect = entry.key;
      final intensity = entry.value;
      // 深拷贝模板：每份组合都要独立改，不能共享同一份 map
      final recipe =
          jsonDecode(jsonEncode(baseRecipe)) as Map<String, dynamic>;
      final adjustments = ((recipe['adjustments'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      var replaced = false;
      for (final a in adjustments) {
        if (a['identifier'] != 'Effect') continue;
        final s = Map<String, dynamic>.from((a['settings'] as Map?) ?? const {});
        s['effectName'] = effect;
        s['effectIntensity'] = intensity;
        a['settings'] = s;
        a['enabled'] = true;
        replaced = true;
        break;
      }
      if (!replaced) {
        adjustments.add({
          'formatVersion': 1,
          'enabled': true,
          'formatIdentifier': 'com.apple.photo',
          'identifier': 'Effect',
          'settings': {
            'effectVersion': 1,
            'effectName': effect,
            'effectIntensity': intensity,
          },
        });
      }
      recipe['adjustments'] = adjustments;
      final envelope = PhotoFilterInfo.encodeRecipeJson(recipe);
      if (envelope == null) continue;

      final plistPath = '${tmp.path}/matrix_${stamp}_$index.plist';
      await File(plistPath).writeAsString(
        _plistTemplate(base64Encode(envelope), record.creationTimestamp),
      );
      final saved = await PhotoLibraryHelper.savePhotoWithExtras(
        filePath: exported.path,
        creationTimestamp: record.creationTimestamp,
        extras: [
          {
            'restoreType': 'adjustmentData',
            'path': plistPath,
            'filename': 'Adjustments.plist',
          },
          if (writeRender)
            {
              'restoreType': 'fullSizePhoto',
              'path': renderPath,
              'filename': 'FullSizeRender.jpg',
            },
        ],
        mainFilename: 'probe_${effect}_${(intensity * 100).round()}.dng',
      );
      if (saved.assetId.isNotEmpty) await _track(saved.assetId);
      (out['items'] as List).add({
        'effect': effect,
        'intensity': intensity,
        'assetId': saved.assetId,
        'written': saved.written,
        'failed': saved.failed,
        'error': saved.error,
      });
    }
    return out;
  }

  /// 复刻相册写出的 `Adjustments.plist` 结构，只替换 data 与时间
  static String _plistTemplate(String base64Data, double createdUnix) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (createdUnix * 1000).round(),
      isUtc: true,
    );
    final iso = '${dt.toIso8601String().split('.').first}Z';
    final lines = <String>[];
    for (var i = 0; i < base64Data.length; i += 68) {
      final end = i + 68 < base64Data.length ? i + 68 : base64Data.length;
      lines.add(base64Data.substring(i, end));
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '\t<key>adjustmentBaseVersion</key>\n'
        '\t<integer>0</integer>\n'
        '\t<key>adjustmentData</key>\n'
        '\t<data>\n'
        '${lines.join('\n')}\n'
        '\t</data>\n'
        '\t<key>adjustmentEditorBundleID</key>\n'
        '\t<string>com.apple.mobileslideshow</string>\n'
        '\t<key>adjustmentFormatIdentifier</key>\n'
        '\t<string>com.apple.photo</string>\n'
        '\t<key>adjustmentFormatVersion</key>\n'
        '\t<string>1.9.1</string>\n'
        '\t<key>adjustmentRenderTypes</key>\n'
        '\t<integer>3072</integer>\n'
        '\t<key>adjustmentTimestamp</key>\n'
        '\t<date>$iso</date>\n'
        '</dict>\n'
        '</plist>\n';
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
      'subtypeRawValue': full?.subtypeRawValue ?? 0,
      'assetHasAdjustments': full?.hasAdjustments ?? false,
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
