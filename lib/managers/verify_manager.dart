import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import '../services/manifest_index.dart';
import '../services/server_client.dart';
import '../services/log_service.dart';
import '../services/server_config.dart';

/// 单个资源的往返验证结果
class ResourceVerifyResult {
  ResourceVerifyResult({
    required this.label,
    required this.phase,
    required this.ok,
    this.downloadedSha,
    this.originalSha,
    this.expectedFromBackup,
    this.restoredSha,
    this.restoredShaFrom = 'none',
    this.originalBytes,
    this.downloadedBytes,
    this.restoredBytes,
    this.restoredAssetId = '',
    this.note,
  });

  final String label;

  /// main / pairedVideo
  final String phase;

  /// 三方（下载文件 / 清单基准 / 原图）是否全部一致
  final bool ok;

  /// 下载回来的文件的哈希（= 备份文件本身）
  final String? downloadedSha;
  final int? downloadedBytes;

  /// 验证开始时从**原图**读到的资源哈希
  final String? originalSha;
  final int? originalBytes;

  /// 备份清单里记录的原图侧哈希（备份当时就固定下来的第三方基准）
  final String? expectedFromBackup;

  /// 恢复出来的副本的资源哈希
  final String? restoredSha;

  /// restoredSha 的来源：'copy' = 真的读了副本的资源；'file' = 用导入文件代替
  ///
  /// 两者可信度不同：前者证明「相册里的副本 == 原图」，
  /// 后者只证明「导入的文件 == 备份文件」。报告里必须区分。
  final String restoredShaFrom;
  final int? restoredBytes;

  /// 新导入副本的资产 ID（用于清理）
  final String restoredAssetId;
  final String? note;

  String get summary {
    final parts = <String>[];
    if (expectedFromBackup != null) parts.add('清单基准 ${_s(expectedFromBackup!)}');
    if (originalSha != null) parts.add('原图 ${_s(originalSha!)}');
    if (downloadedSha != null) parts.add('下载 ${_s(downloadedSha!)}');
    if (restoredSha != null) {
      parts.add('副本 ${_s(restoredSha!)}'
          '${restoredShaFrom == 'file' ? '(取自导入文件)' : ''}');
    }
    return parts.isEmpty ? '(无可比较的哈希)' : parts.join('  vs  ');
  }

  static String _s(String h) => h.length <= 12 ? h : '${h.substring(0, 12)}…';
}

/// 单个资产的验证结果
class AssetVerifyResult {
  AssetVerifyResult({
    required this.record,
    required this.resources,
    required this.originalStillThere,
    this.error,
  });

  final BackupRecord record;
  final List<ResourceVerifyResult> resources;
  final bool originalStillThere;
  final String? error;

  bool get ok => error == null && resources.isNotEmpty && resources.every((r) => r.ok);

  String get name => record.relativePath.split('/').last;
}

/// 验证进度
class VerifyProgress {
  VerifyProgress({
    required this.completed,
    required this.total,
    required this.currentFile,
    required this.results,
    this.restoredAssetIds = const [],
    this.logMessage,
  });

  final int completed;
  final int total;
  final String currentFile;
  final List<AssetVerifyResult> results;
  final List<String> restoredAssetIds;
  final String? logMessage;

  double get percentage => total == 0 ? 0 : completed / total * 100;
}

/// 往返验证：备份 → 恢复到相册 → 与原图逐项对比
///
/// ## 为什么必须真的导入相册
/// 字节级校验（恢复时拿清单里的原图侧哈希比对）已经能证明「备份内容 == 原图」，
/// 但它**验不出导入这一步有没有改变内容** —— 而这恰恰最容易出问题：
///   · iOS 导入时会不会重新编码
///   · 会不会剥离 EXIF（拍摄信息、GPS）
///   · Live Photo 的配对关系能不能正确重建
/// 只有真的写进相册、再读出来对比，才能发现这些。
///
/// ## 前置条件
/// **原图必须还在相册里**。原图已删时，相册级对比无法进行（退化��字节级校验），
/// 这一点会在报告里如实标注，不会假装通过。
///
/// ## 副作用
/// 会在相册里创建**副本**。副本 ID 收集在 [restoredAssetIds] 里，
/// 由调用方决定是否清理 —— **绝不自动删除**，那太危险。
class VerifyManager {
  VerifyManager();

  ServerClient? _client;
  ServerConfig _config = ServerConfig.empty;
  ManifestIndex? _manifest;

  /// 本次验证创建的副本资产 ID（供调用方清理）
  final List<String> restoredAssetIds = [];

  /// 最近一次验证的结果（供 UI 在收尾时兜底读取）
  AssetVerifyResult? _lastResult;
  AssetVerifyResult? get lastResult => _lastResult;

  bool get ready => _client != null;

  /// 读配置并拉清单
  Future<bool> prepare() async {
    _config = await ServerConfig.load();
    restoredAssetIds.clear();
    if (!_config.isConfigured) {
      _client = null;
      _manifest = null;
      return false;
    }
    final c = ServerClient(_config);
    final probe = await c.testConnection();
    if (probe != null) {
      _client = null;
      _manifest = null;
      return false;
    }
    _client = c;
    _manifest = await ManifestIndex.fetch(c);
    return true;
  }

  /// 逐个资产做往返验证
  Stream<VerifyProgress> verifyRoundTrip(List<BackupRecord> records) async* {
    if (_client == null && !await prepare()) {
      yield VerifyProgress(
        completed: 0,
        total: records.length,
        currentFile: '',
        results: const [],
        logMessage: '未配置服务器或连不上接收端，无法验证',
      );
      return;
    }
    final client = _client!;
    final manifest = _manifest;
    final results = <AssetVerifyResult>[];
    final copies = <String>[];

    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      yield VerifyProgress(
        completed: i,
        total: records.length,
        currentFile: record.relativePath.split('/').last,
        results: List.unmodifiable(results),
        restoredAssetIds: List.unmodifiable(copies),
      );
      final r = await _verifyOne(record, client, manifest);
      _lastResult = r;
      results.add(r);
      copies.addAll(r.resources
          .map((x) => x.restoredAssetId)
          .where((id) => id.isNotEmpty));
    }

    restoredAssetIds
      ..clear()
      ..addAll(copies);

    final pass = results.where((r) => r.ok).length;
    yield VerifyProgress(
      completed: records.length,
      total: records.length,
      currentFile: '',
      results: List.unmodifiable(results),
      restoredAssetIds: List.unmodifiable(copies),
      logMessage: '验证完成：通过 $pass / ${results.length}'
          '${copies.isEmpty ? '' : '；在相册里创建了 ${copies.length} 个副本，可选择清理'}',
    );
  }

  /// 单个资产的往返验证
  Future<AssetVerifyResult> _verifyOne(
    BackupRecord record,
    ServerClient client,
    ManifestIndex? manifest,
  ) async {
    final resources = <ResourceVerifyResult>[];
    final originalStillThere =
        await PhotoLibraryHelper.assetExists(record.localIdentifier);

    // ---- 验证输入：完整记下来 ----
    // 往返验证的结论只有配上「当时验的是什么」才有意义。
    // 以前只有结果被记下来，出问题后无法复现输入，只能干瞪眼。
    _log('════════ 开始验证单个资产 ════════');
    _log('资产ID: ${record.localIdentifier}');
    _log('主文件: ${record.relativePath}');
    _log('媒体类型: ${record.mediaType}  拍摄时间: ${record.creationTimestamp}');
    _log('原图仍在相册: $originalStillThere');
    _log('记录声明原图资源数: ${record.resourceTotal ?? "未知"}'
        '  实际附加资源: ${record.extraResources.length} 个');
    for (final e in record.extraResources) {
      _log('  附加资源 ${e.role}: ${e.relativePath}'
          ' uti=${e.uti} ${e.bytes}字节 写入槽位=${e.restoreType}');
    }

    // ---- ① 读原图基准 ----
    final origMain = await PhotoLibraryHelper.hashAssetResources(
      localIdentifier: record.localIdentifier,
    );
    final isLive = record.mediaType == 'live_photo';
    final origVideo = isLive
        ? await PhotoLibraryHelper.hashAssetResources(
            localIdentifier: record.localIdentifier,
            preferVideo: true,
          )
        : null;

    // 清单里备份当时记下的原图侧哈希（第三方基准）
    final expectMain = manifest?.clientSha256Of(record.relativePath);
    final expectVideo = (isLive && record.livePhotoVideoRelativePath != null)
        ? manifest?.clientSha256Of(record.livePhotoVideoRelativePath!)
        : null;

    // ---- 基准记录：原图实际读到的槽位构成，是判断「结构是否一致」的依据 ----
    _log('原图基准: ${_short(origMain?.sha256)} ${origMain?.bytes ?? 0} 字节'
        ' uti=${origMain?.uti} 文件=${origMain?.filename}');
    _log('清单基准: ${_short(expectMain)}');
    if (origMain != null) {
      origMain.logLayout('原图侧');
    } else {
      _log('原图侧: 读不到基准（资产可能已被删除）', LogLevel.warn);
    }

    final tempDir = await FileHelper.getUploadTempDirectory();
    final mainPath = p.join(tempDir.path, 'vfy_${p.basename(record.relativePath)}');

    // ---- ② 下载 + 字节校验 + ③ 导入 ----
    var restoredId = '';
    try {
      final sw = Stopwatch()..start();
      final bytes = await client.downloadFile(
        relativePath: record.relativePath,
        targetPath: mainPath,
      );
      final diskSha = await _sha256OfFile(mainPath);
      sw.stop();
      _log('下载主文件: ${p.basename(record.relativePath)} $bytes 字节'
          ' 用时 ${sw.elapsedMilliseconds}ms 磁盘哈希=${_short(diskSha)}');

      if (isLive && record.livePhotoVideoRelativePath != null) {
        final videoPath = '$mainPath.mov';
        try {
          await client.downloadFile(
            relativePath: record.livePhotoVideoRelativePath!,
            targetPath: videoPath,
          );
          restoredId = await PhotoLibraryHelper.saveLivePhotoToLibrary(
            photoPath: mainPath,
            videoPath: videoPath,
            creationTimestamp: record.creationTimestamp,
          ) ?? '';
          _safeDelete(videoPath);
        } catch (_) {
          restoredId = '';
        }
      }
      if (restoredId.isEmpty) {
        // 附加资源（GAP-R1/R2）：RAW 原图 / Adjustments.plist / .aae
        //
        // 之前这里只用 savePhotoToLibrary 写主文件，于是往返验证导入的副本
        // 永远是「只有 JPEG 的半个资产」—— 相册认不出 RAW，
        // 看起来像恢复失败，其实是这个验证环节自己没覆盖全。
        final extras = <Map<String, String>>[];
        final tempFiles = <String>[];
        for (final res in record.extraResources) {
          if (res.relativePath.isEmpty) continue;
          final target = p.join(tempDir.path,
              'vfy_${p.basenameWithoutExtension(record.relativePath)}.${res.role}${res.extension}');
          try {
            await client.downloadFile(
              relativePath: res.relativePath,
              targetPath: target,
            );
            final sz = await _sizeOfFile(target);
            extras.add({
              'restoreType': res.restoreType,
              'path': target,
            });
            tempFiles.add(target);
            _log('下载附加资源 ${res.role}: ${p.basename(target)}'
                ' $sz 字节 写入槽位=${res.restoreType}');
          } catch (e) {
            LogService.instance.write(
              LogLevel.warn,
              'verify',
              '附加资源 ${res.role} 下载失败（不影响验证主文件）: $e',
            );
          }
        }

        if (extras.isNotEmpty) {
          _log('写入副本: savePhotoWithExtras'
              ' 附加 ${extras.length} 个 槽位='
              '${extras.map((e) => e['restoreType']).join(",")}');
          final r = await PhotoLibraryHelper.savePhotoWithExtras(
            filePath: mainPath,
            creationTimestamp: record.creationTimestamp,
            extras: extras,
          );
          restoredId = r.assetId;
          _log('写入结果: ok=${r.ok} written=${r.written} failed=${r.failed}'
              ' warning=${r.warning} error=${r.error} assetId=$restoredId');
          for (final f in tempFiles) {
            _safeDelete(f);
          }
          if (!r.ok) {
            // 降级：至少把主文件写进去，别让整个验证失败
            _log('写入失败，降级为只写主文件: ${r.error}', LogLevel.warn);
            restoredId = await PhotoLibraryHelper.savePhotoToLibrary(
              filePath: mainPath,
              creationTimestamp: record.creationTimestamp,
            ) ?? '';
            _log('降级写入结果: ${restoredId.isEmpty ? "仍失败" : "ok assetId=$restoredId"}');
          } else if (r.failed > 0) {
            LogService.instance.write(
              LogLevel.warn,
              'verify',
              '副本写入时 ${r.failed} 个附加资源被相册拒收'
              '${r.warning != null ? "：${r.warning}" : ""}',
            );
          }
        } else {
          _log('无附加资源，写入副本: savePhotoToLibrary（仅主文件）');
          restoredId = await PhotoLibraryHelper.savePhotoToLibrary(
            filePath: mainPath,
            creationTimestamp: record.creationTimestamp,
          ) ?? '';
          _log('写入结果: ${restoredId.isEmpty ? "失败" : "ok assetId=$restoredId"}');
        }
      }

      // ---- ④ 读副本的资源哈希（真正验证相册里的那份）----
      final copyHash = restoredId.isEmpty
          ? null
          : await PhotoLibraryHelper.hashAssetResources(
              localIdentifier: restoredId,
            );
      _log('副本基准: ${_short(copyHash?.sha256)} ${copyHash?.bytes ?? 0} 字节'
          ' uti=${copyHash?.uti} 文件=${copyHash?.filename}');
      if (copyHash != null) {
        copyHash.logLayout('副本侧');
        // 结构对照：副本槽位与原图槽位是否一致，比 sha256 更能说明问题
        if (origMain != null) {
          final sameLayout = origMain.layoutLabel == copyHash.layoutLabel;
          _log(sameLayout
              ? '结构对照: 副本与原图槽位一致'
              : '结构对照: **不一致**'
                  '\n    原图 → ${origMain.layoutLabel}'
                  '\n    副本 → ${copyHash.layoutLabel}',
              sameLayout ? LogLevel.info : LogLevel.warn);
        }
      }

      // ---- ④a-2 渲染图重建校验：iOS 有没有真用上这份编辑指令 ----
      //
      // 写入时我们把渲染图**交回 iOS 自己生成**（restoreType=auto），
      // 所以副本里唯一能显示的就是它按 [1]DNG + [7]编辑指令重建的结果。
      // 这意味着副本里渲染图的**大小**就是一个现成的判据：
      //
      //   与备份里的渲染图同一量级 → 重建成功，指令与基图配对正确
      //   远小于备份（例如只有 0.3%）→ 重建出来是空白/纯色，配对失败
      //
      // 没有这一条的话，只能靠肉眼看图 —— 前两次实验就是这么发现的，
      // 代价是白白装两轮包。
      if (restoredId.isNotEmpty) {
        await _checkRebuiltRender(record, restoredId);
      }

      // ---- ④a-3 编辑数据变体探测（GAP-R2 最后一轮）----
      //
      // 只对「RAW 主文件 + 备份里有编辑指令」的资产有意义 ——
      // 普通 HEIC 照片没有这套东西，跑了也只是浪费一轮。
      await _probeVariants(record, mainPath, client, tempDir);

      // ---- ④b 编辑（滤镜）信息对比 ----
      // 这是「滤镜对不对」的决定性证据：哈希一致说明编辑指令一个字节没丢，
      // 若显示仍不同，那就是 iOS 不认我们写入的槽位（平台限制）；
      // 不一致则说明是我们写丢了，还得继续查。
      final origEdit = await PhotoLibraryHelper.analyzeAssetEditing(
        record.localIdentifier,
      );
      PhotoLibraryHelper.logEditingInfo('原图编辑', origEdit);
      final copyEdit = restoredId.isEmpty
          ? null
          : await PhotoLibraryHelper.analyzeAssetEditing(restoredId);
      PhotoLibraryHelper.logEditingInfo('副本编辑', copyEdit);

      if (origEdit != null && copyEdit != null) {
        final same = origEdit.contentAdjustmentSha256.isNotEmpty &&
            origEdit.contentAdjustmentSha256 ==
                copyEdit.contentAdjustmentSha256;
        _log(
          same
              ? '编辑数据对照: **一致**  adj=${origEdit.contentAdjustmentBytes}B'
                  ' ${origEdit.shortAdjSha}（滤镜指令逐字节相同）'
              : '编辑数据对照: **不一致**'
                  '\n    原图 → ${origEdit.summary}'
                  '\n    副本 → ${copyEdit.summary}'
                  '\n    原图有编辑=${origEdit.hasAdjustments} 副本有编辑=${copyEdit.hasAdjustments}',
          same ? LogLevel.info : LogLevel.warn,
        );
      }

      resources.add(ResourceVerifyResult(
        label: p.basename(record.relativePath),
        phase: 'main',
        ok: _allEqual([diskSha, expectMain, origMain?.sha256, copyHash?.sha256]),
        downloadedSha: diskSha,
        downloadedBytes: bytes,
        originalSha: origMain?.sha256,
        originalBytes: origMain?.bytes,
        expectedFromBackup: expectMain,
        restoredSha: copyHash?.sha256 ?? diskSha,
        restoredShaFrom: copyHash != null ? 'copy' : 'file',
        restoredBytes: copyHash?.bytes ?? bytes,
        restoredAssetId: restoredId,
        note: origMain == null
            ? '原图已删除，无法读取当前原图基准（仅验证了备份与清单基准）'
            : null,
      ));
    } catch (e) {
      resources.add(ResourceVerifyResult(
        label: p.basename(record.relativePath),
        phase: 'main',
        ok: false,
        note: '下载或导入失败：$e',
      ));
    } finally {
      _safeDelete(mainPath);
    }

    // ---- 配对视频 ----
    if (isLive && record.livePhotoVideoRelativePath != null) {
      final videoPath = '$mainPath.mov';
      try {
        final bytes = await client.downloadFile(
          relativePath: record.livePhotoVideoRelativePath!,
          targetPath: videoPath,
        );
        final diskSha = await _sha256OfFile(videoPath);
        final expectV = expectVideo;
        final copyV = restoredId.isEmpty
            ? null
            : await PhotoLibraryHelper.hashAssetResources(
                localIdentifier: restoredId,
                preferVideo: true,
              );

        resources.add(ResourceVerifyResult(
          label: p.basename(record.livePhotoVideoRelativePath!),
          phase: 'pairedVideo',
          ok: _allEqual([diskSha, expectV, origVideo?.sha256, copyV?.sha256]),
          downloadedSha: diskSha,
          downloadedBytes: bytes,
          originalSha: origVideo?.sha256,
          originalBytes: origVideo?.bytes,
          expectedFromBackup: expectV,
          restoredSha: copyV?.sha256 ?? diskSha,
          restoredShaFrom: copyV != null ? 'copy' : 'file',
          restoredBytes: copyV?.bytes ?? bytes,
          restoredAssetId: '', // 副本 ID 已在 main 资源里记录，不重复计入清理列表
          note: origVideo == null ? '原图配对视频已删除' : null,
        ));
      } catch (e) {
        resources.add(ResourceVerifyResult(
          label: p.basename(record.livePhotoVideoRelativePath!),
          phase: 'pairedVideo',
          ok: false,
          note: '下载或导入失败：$e',
        ));
      } finally {
        _safeDelete(videoPath);
      }
    }

    // ---- 结论：把每个阶段的判定和哈希都落下来，事后不用复现 ----
    final bad = resources.where((r) => !r.ok).length;
    _log('── 单资产验证结束 ──');
    for (final r in resources) {
      _log('  [${r.ok ? "通过" : "不通过"}] ${r.phase} ${r.label}',
          r.ok ? LogLevel.info : LogLevel.warn);
      _log('    下载=${_short(r.downloadedSha)} ${r.downloadedBytes ?? 0}B'
          ' 清单=${_short(r.expectedFromBackup)}'
          ' 原图=${_short(r.originalSha)} ${r.originalBytes ?? 0}B'
          ' 副本=${_short(r.restoredSha)}(${r.restoredShaFrom})'
          '${r.note != null ? " 备注=${r.note}" : ""}');
    }
    _log(bad == 0
        ? '结论: 全部 ${resources.length} 个阶段通过'
        : '结论: ${resources.length} 个阶段中 $bad 个不通过',
        bad == 0 ? LogLevel.info : LogLevel.warn);
    _log('══════════════════════════════════════');

    return AssetVerifyResult(
      record: record,
      resources: resources,
      originalStillThere: originalStillThere,
    );
  }

  /// 多个哈希是否全部非空且相等
  ///
  /// 允许部分为 null（旧版备份没有原图侧哈希、原图已删除等），
  /// 只比较存在的那些。**一个都没有**才视为无法判定（false）。
  bool _allEqual(List<String?> values) {
    final present = values.where((v) => v != null && v.isNotEmpty).toList();
    if (present.isEmpty) return false;
    return present.every((v) => v == present.first);
  }

  /// 验证过程的统一日志出口（tag 固定 verify）
  static void _log(String msg, [LogLevel level = LogLevel.info]) {
    LogService.instance.write(level, 'verify', msg);
  }

  /// 哈希太长，日志里只留前 16 位便于肉眼比对
  /// 编辑数据变体探测：一次跑完全部变体，输出「哪张是真图」的结论表
  ///
  /// 生成的副本以 `probe_` 开头，会留在相册里 —— 用户想亲眼看看哪张是真图。
  /// 清理按钮要能一并删掉（见 verify_page 的清理逻辑）。
  static Future<void> _probeVariants(
    BackupRecord record,
    String dngPath,
    ServerClient client,
    Directory tempDir,
  ) async {
    if (!dngPath.toLowerCase().endsWith('.dng')) return;
    BackupResource? plist;
    for (final e in record.extraResources) {
      if (e.role == 'adjustment') {
        plist = e;
        break;
      }
    }
    if (plist == null) return;

    final plistLocal =
        p.join(tempDir.path, 'probe_${p.basename(plist.relativePath)}');
    try {
      await client.downloadFile(
        relativePath: plist.relativePath,
        targetPath: plistLocal,
      );
    } catch (e) {
      LogService.instance.write(
        LogLevel.warn,
        'verify',
        '变体探测: 编辑指令下载失败，跳过（$e）',
      );
      return;
    }

    LogService.instance.write(
      LogLevel.info,
      'verify',
      '════════ 编辑数据变体探测开始 ════════\n'
      '    背景：四轮实验（黑图/纯灰白/灰白/逐槽对齐仍灰白）全部失败，\n'
      '    结构已排除嫌疑。剩下最可能是 plist 字段与新建资产对不上，\n'
      '    尤其 adjustmentTimestamp（记的是原图被编辑那一刻的时间）。\n'
      '    每组写一个 probe_ 副本，再按亮度方差自动判定真假图。',
    );

    final rows = await PhotoLibraryHelper.probeAdjustmentVariants(
      dngPath: dngPath,
      plistPath: plistLocal,
      tag: (record.creationTimestamp.toStringAsFixed(0)),
      created: record.creationTimestamp,
    );
    if (rows.isEmpty) {
      LogService.instance.write(
        LogLevel.warn,
        'verify',
        '变体探测: 没有结果',
      );
      return;
    }

    final sb = StringBuffer('════════ 变体探测结果 ════════\n');
    var winner = '';
    for (final r in rows) {
      final name = '${r['name'] ?? '?'}';
      final status = '${r['status'] ?? '?'}';
      final variance = (r['variance'] as num?)?.toDouble() ?? -1;
      final bytes = (r['bytes'] as num?)?.toInt() ?? 0;
      sb.writeln('    ${name.padRight(14)} $status'
          '${variance >= 0 ? '  方差=${variance.toStringAsFixed(1)}' : ''}'
          '${bytes > 0 ? '  ${_mb(bytes)}' : ''}');
      if (variance >= 60 && winner.isEmpty) winner = name;
    }
    sb.writeln(winner.isEmpty
        ? '    → 全部变体都渲染失败：plist 字段假设不成立，得换思路（逆向/换主文件）'
        : '    → **可用变体：$winner**（方差阈值 60 以上判为真图）');
    sb.writeln('    副本以 probe_ 开头留在相册，可自行肉眼复核。');
    LogService.instance.write(
      winner.isEmpty ? LogLevel.warn : LogLevel.info,
      'verify',
      sb.toString(),
    );
  }

  static String _short(String? sha) =>
      (sha == null || sha.isEmpty) ? '(无)' : '${sha.substring(0, 16)}…';

  /// 渲染图重建校验：副本里 iOS 自己生成的渲染图，够不够「一张真图」的大小
  ///
  /// ## 为什么这个判据成立
  ///
  /// 写入时渲染图被刻意**不写**（`restoreType=auto`），副本里唯一能显示的
  /// 就是 iOS 拿 `[1]DNG` + `[7]编辑指令` 现场渲染的结果。于是：
  ///
  ///  · 重建成功 → 与备份里的渲染图同一量级（同一张照片的 JPEG 编码）
  ///  · 重建失败 → 空白/纯色，体积会掉到零头（实测坏图只有几十 KB 级）
  ///
  /// 拿它和备份记录里 `role=render` 的字节数一比，结论是确定的，
  /// 不用靠肉眼盯屏幕 —— 前两次实验（黑图、纯灰白）都是肉眼发现的，
  /// 每次都要装一轮包，代价太大。
  static Future<void> _checkRebuiltRender(
    BackupRecord record,
    String restoredId,
  ) async {
    // 基准：备份里那张「正确答案」渲染图有多大
    var expect = 0;
    for (final e in record.extraResources) {
      if (e.role == 'render') {
        expect = e.bytes;
        break;
      }
    }
    if (expect <= 0) {
      LogService.instance.write(
        LogLevel.info,
        'verify',
        '渲染图重建校验: 备份记录里没有渲染图（role=render），跳过'
        '（本次不适用该判据）',
      );
      return;
    }

    // iOS 生成 FullSizeRender.jpg 是**异步派生**的：写入刚结束就去读，
    // 它还没被真正生成，requestData 会回 3302（PHPhotosErrorInterrupted）。
    // 先给它一点时间，否则每次都只能读到「读不到」，判据等于没有。
    await Future<void>.delayed(const Duration(seconds: 4));

    final info = await PhotoLibraryHelper.getAssetFullInfo(restoredId);
    if (info == null) {
      LogService.instance.write(
        LogLevel.warn,
        'verify',
        '渲染图重建校验: 读不到副本的资源明细，无法判断',
      );
      return;
    }

    // 副本里的显示图：可能是 iOS 自己重建的（type 5 fullSizePhoto），
    // 也可能是我们写进去的（type 4 alternatePhoto，当前采用的方案）。
    AssetResourceDetail? got;
    for (final r in info.resources) {
      if (r.typeRawValue == 5 || r.typeRawValue == 4) {
        got = r;
        break;
      }
    }
    if (got == null) {
      LogService.instance.write(
        LogLevel.warn,
        'verify',
        '渲染图校验: 副本里**没有可显示的图像资源**'
        '（资源共 ${info.resourceCount} 个：'
        '${info.resources.map((e) => 'type(${e.typeRawValue})/${e.filename}').join(' · ')}）',
      );
      return;
    }

    if (got.failed || got.bytes <= 0) {
      // 读到 0 字节可能是读取失败，不是「重建出了空白图」——
      // 这两件事的结论完全相反，不能混为一谈。
      LogService.instance.write(
        LogLevel.warn,
        'verify',
        '渲染图重建校验: 副本渲染图读取失败（${got.error.isEmpty ? '0 字节' : got.error}），'
        '无法判断重建结果',
      );
      return;
    }

    final ratio = got.bytes / expect;
    // 同一张照片的 JPEG，体积差几成很正常；掉到零头基本就是空白图
    final ok = ratio > 0.5;
    LogService.instance.write(
      ok ? LogLevel.info : LogLevel.warn,
      'verify',
      '渲染图重建校验: 备份渲染图 ${_mb(expect)}'
      ' / 副本 iOS 重建 ${_mb(got.bytes)}'
      ' = ${(ratio * 100).toStringAsFixed(1)}%'
      '\n    ${ok ? "体积正常 → iOS 用上了这份编辑指令，配对成功" : "**体积异常** → 重建出来的多半是空白/纯色图，指令与基图没配上"}',
    );
  }

  static String _mb(int b) =>
      b >= 1024 * 1024
          ? '${(b / 1024 / 1024).toStringAsFixed(2)}MB'
          : '${(b / 1024).toStringAsFixed(1)}KB';

  /// 取文件大小，失败返回 0（只用于日志，不影响验证结论）
  static Future<int> _sizeOfFile(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _sha256OfFile(String path) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      return (await sha256.bind(f.openRead()).first).toString();
    } catch (_) {
      return null;
    }
  }

  void _safeDelete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}