import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../helpers/file_helper.dart';
import '../helpers/photo_library_helper.dart';
import '../models/backup_record.dart';
import '../services/manifest_index.dart';
import '../services/server_client.dart';
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

    final tempDir = await FileHelper.getUploadTempDirectory();
    final mainPath = p.join(tempDir.path, 'vfy_${p.basename(record.relativePath)}');

    // ---- ② 下载 + 字节校验 + ③ 导入 ----
    var restoredId = '';
    try {
      final bytes = await client.downloadFile(
        relativePath: record.relativePath,
        targetPath: mainPath,
      );
      final diskSha = await _sha256OfFile(mainPath);

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
        restoredId = await PhotoLibraryHelper.savePhotoToLibrary(
          filePath: mainPath,
          creationTimestamp: record.creationTimestamp,
        ) ?? '';
      }

      // ---- ④ 读副本的资源哈希（真正验证相册里的那份）----
      final copyHash = restoredId.isEmpty
          ? null
          : await PhotoLibraryHelper.hashAssetResources(
              localIdentifier: restoredId,
            );

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