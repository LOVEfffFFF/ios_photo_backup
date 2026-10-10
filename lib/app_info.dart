/// App 构建标识
///
/// ## 为什么需要它
///
/// 侧载没有"版本升级"提示，装完看不出装的是哪一版，出问题时很难定位
/// （历史上就因为分不清版本，误判过"重复上传是新代码的 bug"）。
///
/// 约定：**每次编译前更新这里的 build 与 commit**，界面上会直接显示，
/// 诊断日志里也会带上，用户报问题时只要说这串号就能精确定位。
class AppInfo {
  const AppInfo._();

  /// 语义化版本号（与 pubspec.yaml 的 version 保持一致）
  static const String version = '1.1.0';

  /// 构建标识：编译时间（同一个版本多次编译时用它区分）
  static const String build = '2026-10-10-05:35';

  /// 对应的 git 提交短 hash
  ///
  /// 注意：这是**引入/更新本文件的那次提交**，不是最终构建所在的提交
  /// （填入它时构建还没发生，无法预知自身 hash）。
  /// 精确定位以 build 时间戳 + GitHub 提交历史为准。
  static const String commit = '38cc7e2';

  /// 界面上显示的一行摘要
  static String get display =>
      'v$version · build $build · $commit';

  /// 诊断报告里用的完整描述
  static String get diagnostics =>
      'PhotoBackup v$version（build $build, commit $commit）';
}