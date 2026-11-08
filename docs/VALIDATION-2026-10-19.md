# 2026-10-19 验证记录

本次开发、测试、构建和产物均属于独立的 `ios_photo_backup_openai` 仓库，没有在原项目目录运行或写入。所有测试素材均为合成数据；没有访问手机相册。

## 验证通过的代码

- 代码提交：`278a4262b2e1116b62410f2c29f3db9502ef99e9`。
- [完整构建记录](https://github.com/LOVEfffFFF/ios_photo_backup_openai/actions/runs/39146661224)，结果为 success。
- Flutter `3.47.6`，Dart `3.13.5`，Xcode `26.6`，iPhoneOS SDK `26.5`。
- Release 编译于北京时间 2026-10-19 00:53 完成。后续仅更新本验证文档和进度文档，不改变该安装包中的代码。

| 检查 | 结果 |
| --- | --- |
| Windows 接收端合成检查 | 22 项通过，0 失败；本地与云端均通过 |
| Dart 分析 | 无错误；继承代码仍有 3 条警告、7 条提示 |
| Flutter 自动化测试 | 29 项通过 |
| 锁定依赖安装 | Linux 分析任务与 macOS 构建任务均通过 |
| 自定义代码保留检查 | Flutter 生成工程前后，AppDelegate、Info.plist、pubspec.yaml、lib/main.dart 哈希一致 |
| iOS Release | Xcode BUILD SUCCEEDED |
| 独立应用检查 | 名称、bundle identifier、版本符合本仓库配置 |
| 下载后的 IPA 结构 | 包含非空 Runner、App.framework/App 和 Info.plist |

自动化覆盖包括：不同内容同长度、重复请求、内容哈希不符、NoHash 不能绕过校验、清单写入失败与补记、文件/清单丢失后的重试、清单半行中断、附件上传/导出失败、Live Photo 配对失败、同时间不同资产、同 ID 的编辑内容、视频资源缺失、本机记录保存失败。

## 安装包

文件：仓库根目录 `PhotoBackup-OpenAI.ipa`，仅保存在本地及 GitHub 构建产物中，不进入 Git 历史。

- 大小：7,331,789 字节。
- SHA256：`3a32ef2841efef301b42d67a507dc18251c41f88035d83e6a1741e27d561ec20`。
- 应用名称：`相册备份 OpenAI`。
- Bundle identifier：`com.photobackup.openai.photoBackup`。
- App 版本：`0.1.0`，界面显示实际构建时间与提交号。
- 安装包未签名，需个人签名后侧载；签名时保留独立标识，才能与原版并存。
- 需配套本仓库当前 Windows 接收端，默认端口 `18080`。旧接收端的简化成功回执不会被新版 App 接受。

## 尚未验证

没有执行真机安装、PhotoKit 运行、真实照片备份恢复、相册副本回读、iCloud 原件下载或锁屏中断测试。Flutter 测试中的原生通道与接收端用合成替身验证流程，不能代替这些真机证据。

资源版本关系、资产级完成标记、可靠且节省传输的增量查询、恢复准确性仍需开发。当前重新传输用于核验；同内容避免重复保存，编辑后的不同内容会保留冲突并报错。详见 [RELIABILITY.md](RELIABILITY.md) 和 [ROADMAP.md](ROADMAP.md)。
