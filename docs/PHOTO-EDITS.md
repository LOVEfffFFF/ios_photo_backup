# ProRAW 编辑数据与恢复

2026-10-19 用户进一步确认：该鲜明样本的恢复副本具有 RAW 标记，可在系统相册还原原始状态，重新选择另一种滤镜保存后再次进入编辑，名称和强度正确且能继续调整。这使本样本的功能验收更完整；不改变编辑时间未保留的字节校验结论，也不能推广到其他资源组合。后续 [0.2.3 实时调试](LIVE-DEBUG.md) 用于直接回读附件并执行受限测试。

0.2.0 增加当前滤镜名称显示及资源恢复回读。当前解析范围来自 iPhone 14 Pro Max、iOS 17.7.2 的实测结构；编译通过与真机恢复成功是不同验收条件。

## AAE 与 plist

AAE 是相册编辑附件的常见扩展名。本次 AAE 和 Adjustments.plist 都是 XML property list：其中 adjustmentData 是 Base64 编码的二进制。Base64 解码后，以 raw DEFLATE 解压可以取得 JSON 编辑配方。压缩数据没有明文滤镜名称，不代表它被加密或无法解析。二进制 plist 也交给系统 PropertyListSerialization 读取。

扩展名不决定哪份是当前编辑。样本中的公开 adjustmentData 资源（Adjustments.plist）含当前相册编辑；相机 AAE 含较早的相机记录。它们都备份，界面分开显示。不能把 AAE 改名为 plist 就获得更好的恢复能力，也不能用 AAE 哈希相同来判断当前滤镜相同。

目前按配方版本限制解析：当前 com.apple.photo/1.9.1，较早相机记录 com.apple.photo/1.4；内部 formatVersion 为 1。已识别当前鲜明、反差色，较早相机记录鲜暖色。未知名称保留标识并显示未知；资源读取失败、格式不支持、解压失败均不能显示“无滤镜”。有效配方中没有启用的 Effect 才显示“无显式滤镜项”，它仍可能有 RAW 显影等其他处理。

2026-10-20 的另一张 RAW 样本说明上述版本划分仅描述早期样本和当前解析器限制：公开当前 `adjustmentData` 资源也可能是 `com.apple.photo/1.4`，其中 `Effect=3DSilverplate`，不能按版本就断定它不是当前编辑。该样本的当前原片和恢复副本 plist 字节一致，但比电脑备份多出 `adjustmentRenderTypes=3072`；完整压缩配方一致。当前解析器仍对该当前配方显示版本不支持，相机 AAE 未导入，不能宣称完整恢复或摄影风格识别成功。详见 [0.2.6 实测](VALIDATION-0.2.6.md)。

用户随后确认：这张 100% 原片是在拍摄时就选用了滤镜，没有事后在相册添加。其最初效果记录与拍摄时间相同是合理的，不可当作时间丢失证据。用于区分时间是否保留的样本，是后来在恢复副本上通过相册保存为 50% 强度的那张；其备份实际 plist 已保留新的编辑时间。拍摄时使用滤镜的用户事实不等于已确认 Apple“摄影风格”类别或内部标识的中文映射。

这里的滤镜是相册 Effect 操作，不承诺识别摄影风格或任意第三方编辑。

## 为什么保留渲染图

相册可以使用已渲染结果和预览缓存，编辑时也可以根据原图、配方重新渲染。Apple 的编辑模型保存原始资源、最近编辑配方以及渲染结果，并没有承诺跨设备、跨系统仅靠 Apple 内部配方就能得到完全相同的图像。

因此同时备份：DNG 保留原始数据，当前配方保留编辑操作，渲染 JPEG 保留当前呈现；较早相机 AAE 也原样归档。保留渲染图可以在无法解释编辑配方时仍查看当前效果。

## Apple 公开说明与实现选择

| 官方资料 | 对本项目的意义 |
| --- | --- |
| [PHAssetCreationRequest](https://developer.apple.com/documentation/photos/phassetcreationrequest) | 明确说明可配合 PHAssetResource 对资产底层资源进行 complete copy / backup and restore。 |
| [PHAssetResourceType.adjustmentData](https://developer.apple.com/documentation/photos/phassetresourcetype/adjustmentdata) | 是公开枚举成员，用于重建最近编辑；旧代码关于“没有公开类型”的说明有误。 |
| [addResource](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:fileurl:options:)) | 不合法的文件或资源组合由 performChanges 完成回调报告失败。 |
| [PHContentEditingOutput.renderedContentURL](https://developer.apple.com/documentation/photos/phcontenteditingoutput/renderedcontenturl) | 图片编辑输出需要写入正确朝向的 JPEG 渲染结果。 |
| [PHContentEditingOutput.adjustmentData](https://developer.apple.com/documentation/photos/phcontenteditingoutput/adjustmentdata) | 写入新编辑必须提供新的、不同的 PHAdjustmentData；直接传入描述早期编辑的既有对象会导致未定义行为。 |
| [PHAdjustmentData](https://developer.apple.com/documentation/photos/phadjustmentdata) / [Editing asset content](https://developer.apple.com/documentation/photokit/editing-asset-content) | 编辑配方由编辑应用定义；不理解配方的编辑器可以使用渲染结果。 |

上述已查文档并未给出 Apple 内部 effectName JSON 格式的公开稳定规范。资源 API 是公开的，内部配方解析仍是有限样本支持，需要按版本保守处理。

恢复走资源复制创建：原图 → photo，当前配方 → adjustmentData，渲染图 → fullSizePhoto，同一次创建提交。不会把 plist 当成 alternatePhoto，也不会把旧配方伪装为新编辑通过 PHContentEditingOutput 重放。两项当前编辑资源需要同时提供。若系统拒绝组合，明确失败，不静默降级成成功。

本次相机 AAE 的资源类型为 16，在已查公开创建接口中没有确认可用的对应类型。它保留在电脑；导入成功也会标为部分恢复。暂不尝试私有类型编号。带编辑附件的视频、实况照片暂不支持该恢复路径，明确报错。

## 实机验收

1. 安装 0.2.0 独立版本，在“对比”页依次选择三张样本。应显示鲜明、反差色、无显式滤镜项；较早相机记录应单独显示鲜暖色。
2. 保留三张原照片，在“往返验证”页逐张执行。此操作会创建新副本，不删除原照片。逐项检查 DNG、当前配方、渲染图、副本回读和当前滤镜操作。
3. 相机 AAE 未导入时，应显示未完全确认，而非全部恢复成功。导入接口拒绝时保留错误日志。
4. 到系统相册检查副本的画面、RAW 标记，打开编辑面板核对滤镜名称、强度以及能否撤销编辑。不要仅凭 App 里配方一致就认定系统编辑器已识别。
5. 上传日志后，可用 App 的清理按钮删除本次验证副本；保留原照片和电脑备份。

自动化测试使用合成数据覆盖解析、来源区分、附件损坏、缺少副本回读、同 DNG 不同滤镜、AAE 缺失、Live Photo 不降级及暂存清理。它们不能代替以上真机结果。

## 用户真机反馈与 0.2.1 报告修正

2026-10-19，用户在 iPhone 14 Pro Max / iOS 17.7.2 上使用 0.2.0 执行一次鲜明样本往返验证。上传日志显示 DNG 与渲染 JPEG 四方哈希一致，编辑附件的原图/备份/下载哈希一致，副本附件哈希不同，解码后的编辑操作一致。用户进一步确认新副本在系统相册的“编辑 → 滤镜”中显示“鲜明”。这支持该样本的系统滤镜识别成功，不只是预先渲染的画面相同；仍未确认其他滤镜、RAW 标记、撤销编辑或跨系统表现。

对本例做了离线哈希复现：在原始备份附件中仅将 adjustmentTimestamp 改为该照片的拍摄时间，候选文件的完整 SHA256 精确匹配截图中的副本 SHA256。这支持本例差异为编辑时间戳变化；未独立导出手机副本附件，不能推广到所有编辑附件变化。

0.2.1 保留严格的字节不一致结果，另提供橙色说明“原图、成片与编辑操作一致；编辑附件字节有变化”。触发该说明必须同时满足：原图仍在、DNG 与渲染图逐字节一致、当前附件原图/备份/下载一致、实际读回副本附件、全部已解析编辑操作一致，以及解析出的配方资源哈希与本次读回资源绑定。没有渲染图、缺少附件、配方未知、RAW 操作改变、读取到过期配方或导入范围不完整时不会使用该说明。

橙色说明不代表所有附件字节相同，也不把完整配方元数据或系统可编辑性等同于已解析操作。新增日志同时记录附件及压缩配方的哈希，帮助进一步区分数据部分与封装变化；批量恢复日志也区分“资源缺失”和“已读回但字节不同”。

恢复状态会记录部分恢复原因，避免重复导入副本；已有副本被跳过不代表编辑资源完整。指纹匹配仍是时间、类型、尺寸的启发式判断，不是资源内容一致的证明。批量恢复的普通无附件照片/视频仍沿用原有路径，重点验收先用上述往返验证。

## 原编辑时间保留现状

0.2.4 已直接导出原片和副本的实际附件，确认所选样本的 plist 唯一差异是 `adjustmentTimestamp`，原图、渲染图及完整配方一致。0.2.5 又完成六项真机实验，仍未保住此字段。其中两个非公开实验能设置资产数据库的秒级 `modificationDate`，但附件时间继续变为拍摄时间；这两个时间不能混同。原编辑时间恢复尚未解决，普通恢复没有启用这些实验。详见 [0.2.5 真机结果与限制](VALIDATION-0.2.5.md)。

2026-10-20，0.2.6 在另一张已保存为 50% 效果强度、已备份且配方为 `1.9.1` 的 RAW 上执行一次主 DNG 导入时间实验，仍失败：实际 plist 的编辑时间由 06:39:47 变为拍摄时间 06:28:05。独立回读确认完整 plist 仅日期变化，DNG、当前渲染图、完整压缩及解压配方和拍摄时间保留，两张源片未改变。详见 [0.2.6 真机结果](VALIDATION-0.2.6.md)。0.2.7 根据第三方反编译线索增加固定持久化字段实验，在同一 50% 源片上只创建一份新副本，仍得到相同的时间重置；独立回读和源片检查均已完成，见 [0.2.7 结果](VALIDATION-0.2.7.md)。请求字段 getter 成功不等于编辑 plist 被重写，普通恢复未启用该实验。
