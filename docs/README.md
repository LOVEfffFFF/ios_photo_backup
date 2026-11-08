# docs 索引

本目录的文档来自独立基线仓库 `ios_photo_backup_openai`（2026-11-08 同步），
记录的是 **ProRAW 编辑配方、编辑时间戳、接收端可靠性** 三件事的真机实验证据。

> **权威性说明**：文档是实验记录，不是规格说明。
> 代码行为以本仓库当前的 `lib/` 与 `ios/Runner/AppDelegate.swift` 为准；
> 文档里出现的版本号（0.2.x）、bundle id、端口（18080）属于那条独立基线，
> 与本项目（`com.photobackup.photoBackup`、端口 8080）无关。

## 配方与恢复

| 文件 | 内容 |
| --- | --- |
| `PHOTO-EDITS.md` | 核心结论：`adjustmentData` 是 **base64 → 裸 DEFLATE → JSON 配方**；公开资源写入映射（DNG→`.photo`、配方→`.adjustmentData`、渲染图→`.fullSizePhoto`，且后两者必须成对）；相机 AAE（资源类型 16）无公开创建类型 |
| `VALIDATION-0.2.0.md` | 首次真机确认「副本在系统相册显示正确滤镜名 + RAW 标记 + 可还原再编辑」 |
| `VALIDATION-2026-10-19.md` | 首轮真机验收记录 |

## 编辑时间戳（`adjustmentTimestamp` 为什么保不住）

| 文件 | 内容 |
| --- | --- |
| `TIMESTAMP-COMMUNITY-RESEARCH.md` | 社区与反编译线索的调研汇总 |
| `TIMESTAMP-EXPERIMENTS-0.2.5.md` | 六项真机实验（文件时间 / 资源 import date / request import date / request modification date / unmanagedAdjustment 等）全部失败 |
| `VALIDATION-0.2.5.md` | 上述实验的真机结果与限制 |
| `TIMESTAMP-EXPERIMENTS-0.2.7.md` | 固定持久化字段实验（依据第三方反编译线索） |
| `VALIDATION-0.2.7.md` | 上述实验的真机结果：仍被重置为拍摄时间 |
| `VALIDATION-0.2.6.md` | 另一张 RAW 样本：当前配方也可能是 `com.apple.photo/1.4`，版本号不能用来判定「是不是当前编辑」 |

**结论**：在 iOS 17.7.2 的公开 API 下，`adjustmentTimestamp` 无解。
验收应比对**解码后的配方内容**，不要比对附件字节。

## 可靠性边界

| 文件 | 内容 |
| --- | --- |
| `RELIABILITY.md` | 备份/恢复「什么情况下才算成功」的判定边界，以及已知的降级路径 |
| `LIVE-DEBUG.md` | 实时调试桥的设计与用法（本仓库暂未接入该功能，仅作设计参考） |

## 相关代码位置

| 能力 | 位置 |
| --- | --- |
| 配方解码（裸 DEFLATE + JSON） | `lib/models/photo_filter_info.dart` |
| 资源角色分类与槽位映射 | `ios/Runner/AppDelegate.swift`（`classifyResource`） |
| 接收端严格校验 | 工作区 `windows-receiver/PhotoBackupReceiver.ps1`（不入库） |
| 接收端回归测试 | `tests/receiver-upload.tests.ps1` |
