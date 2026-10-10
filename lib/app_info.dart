/// App 构建标识
///
/// ## 为什么需要它
///
/// 侧载没有"版本升级"提示，装完看不出装的是哪一版，出问题时很难定位
/// （历史上就因为分不清版本，误判过"重复上传是新代码的 bug"）。
class AppInfo {
  const AppInfo._();

  /// 语义化版本号（与 pubspec.yaml 的 version 保持一致）
  static const String version = '1.1.0';

  /// 构建标识：编译时间（同一个版本多次编译时用它区分）
  static const String build = '2026-10-11-05:25';


  /// 界面上显示的一行摘要
  ///
  /// **刻意不含 git commit**：构建发生在提交之后，编译时无法预知自身 hash。
  /// 而这个字段一旦显示就会被当成版本依据 —— 之前就因为它（停在 38cc7e2，
  /// 实际构建已领先 31 个提交）导致误判「装的是旧版」。
  /// 要精确定位提交请看 GitHub 提交历史，或用 [build] 的时间戳对照。
  static String get display => 'v$version · build $build';

  /// 诊断报告里用的完整描述
  static String get diagnostics => 'PhotoBackup v$version（build $build）';
}
