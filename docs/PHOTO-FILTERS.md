# 相册滤镜对照表（effectName ↔ 界面中文名）

> 记录日期：2026-11-09
> 设备：iPhone 14 Pro Max / iOS 17.7.2
> 数据来源：真机全库扫描（不是命名规律推测）

本文回答三个问题：相册里**一共几个滤镜**、**每个滤镜在配方里叫什么**、**配方里还有哪些参数项**。

---

## 1. 结论：9 个滤镜 + 「原片」

相册编辑界面的滤镜共 9 项，全部在真机配方里命中，并与用户按 IMG 编号给出的名字一一对应。

| IMG 编号 | 界面中文名 | `effectName` | 强度样本 | 证据 |
| --- | --- | --- | --- | --- |
| 7685 | **原片** | *（无 Enabled 的 Effect 项）* | — | 配方有效、无滤镜项，仍可能带裁剪/调整/RAW 解码 |
| 7686 | 鲜明 | `3DVivid` | 100% | 用户确认 + 配方命中 |
| 7687 | 鲜暖色 | `3DVividWarm` | 100% | 用户确认 + 相机 AAE 命中 |
| 7688 | 鲜冷色 | `3DVividCool` | 100% | `IMG_7688O.aae` 直接命中 |
| 7689 | 反差色 | `3DDramatic` | 100% | 用户确认 + 配方命中 |
| 7690 | 反差暖色 | `3DDramaticWarm` | 24.9% / 100% | 用户确认 + 配方与 AAE 双命中 |
| 7691 | 反差冷色 | `3DDramaticCool` | 100% | `IMG_7691O.aae` 直接命中 |
| 7692 | 单色 | **`Mono`**（无 `3D` 前缀） | 100% | `IMG_7692O.aae` 直接命中 |
| 7693 | 银色调 | `3DSilverplate` | 100% | `IMG_7693O.aae` 直接命中 |
| 7694 | 黑白 | `3DNoir` | 50% / 100% | 用户确认 + 配方与 AAE 双命中 |

**「原片」不是滤镜**：配方有效、`adjustments` 数组存在，但没有任何 `enabled == true` 的 `Effect` 项。它可能仍包含裁剪、旋转、调整、RAW 解码等操作，所以不能因为「没有滤镜」就当作未编辑。

### 一次扫描的实测数据

| 项 | 数值 |
| --- | --- |
| 相册资产总数 | 33,420 |
| 其中「已编辑」（`PHAsset.hasAdjustments == true`） | 168 |
| 配方类资源（`Adjustments.plist` / `.aae`） | 252 |
| 成功读回并解码 | 252（276.2 KB） |
| 截断 / 超时 | 否 / 否 |

分项：9 个滤镜共 24 个配方样本，「原片」228 个样本（覆盖 156 个资产），合计 252，与配方资源数一致。

---

## 2. 配方（`adjustmentData`）的实际结构

`Adjustments.plist` / `.aae` 都是 XML plist，`<key>adjustmentData</key><data>` 里是 base64。
base64 → **裸 DEFLATE（没有 zlib 头）** → UTF-8 JSON。本地备份解出的完整样本：

```json
{
  "metadata": { "masterHeight": 3024, "masterWidth": 4032, "orientation": 1 },
  "formatVersion": 1,
  "versionInfo": {
    "buildNumber": "21H221",
    "appVersion": "662.0.141",
    "schemaRevision": 0,
    "platform": "iOS"
  },
  "adjustments": [
    {
      "formatVersion": 1,
      "enabled": true,
      "settings": {
        "effectVersion": 1,
        "effectName": "3DDramaticWarm",
        "effectIntensity": 0.24907407407407406
      },
      "identifier": "Effect",
      "formatIdentifier": "com.apple.photo"
    },
    {
      "formatVersion": 1,
      "enabled": true,
      "settings": {
        "boostVersion": "FB3",
        "boostParams": [0.1380615234375, 0.47900387644767761, 0.828125],
        "inputMethodVersion": "8"
      },
      "identifier": "RKRawDecodeOperation",
      "formatIdentifier": "com.apple.photo"
    }
  ]
}
```

### 参数项说明

| 位置 | 字段 | 含义 |
| --- | --- | --- |
| 顶层 | `formatVersion` | 配方结构版本，实测为数字 `1`。注意它与 `PHAdjustmentData.formatVersion`（字符串，如 `1.9.1`）**不是同一个东西** |
| 顶层 | `metadata` | 原图尺寸与方向（`masterWidth` / `masterHeight` / `orientation`） |
| 顶层 | `versionInfo` | 写入者的系统与 App 版本（`buildNumber` / `appVersion` / `schemaRevision` / `platform`） |
| 每项 | `identifier` | 操作类型。滤镜固定是 `Effect`；RAW 解码是 `RKRawDecodeOperation` |
| 每项 | `enabled` | 是否启用。`false` 不算滤镜 |
| 每项 | `formatIdentifier` | 固定 `com.apple.photo` |
| Effect | `settings.effectName` | **滤镜身份，唯一区分滤镜的字段** |
| Effect | `settings.effectIntensity` | 强度，0..1（样本见过 0.249 / 0.499 / 1.0） |
| Effect | `settings.effectVersion` | 效果参数版本，实测 `1` |
| RKRaw | `settings.boostVersion` / `boostParams` / `inputMethodVersion` | RAW 显影参数，与滤镜无关 |

### 判定规则（程序里实际采用）

1. 只认 `identifier == "Effect" && enabled == true && settings is Map`；
2. **0 项** → `none`，显示「原片（未套用滤镜）」；
3. **≥2 项** → `unknown`（多滤镜叠加暂不解析），不猜其中某一个；
4. `effectIntensity` 缺失、非数字或不在 0..1 → `unknown`，不当 0 处理；
5. `effectName` 未收录 → 显示原始 `3DXXX`，**不按命名规律补中文名**；
6. 跨副本比对不比字节：iOS 导入时会把 `adjustmentTimestamp` 重置成拍摄时间，字节必然不同。比的是**解码后的操作签名**（`adjustments` 键名递归排序后序列化）。

---

## 3. 怎么扫出来的（可复现）

Apple 不公开滤镜清单，`effectName` 只存在于**真实配方**里 —— 没用过的滤镜在系统里没有任何痕迹，无法凭空枚举。所以做法是扫全库已编辑资产的配方。

- 手机端：主界面「操作日志」卡片 → **滤镜扫描** → 开始扫描 → 右上角复制结果
- 电脑端（需手机在「实时调试」页连上）：

```powershell
cd debug-bridge
$c = (Get-Content .\data\latest.json -Raw | ConvertFrom-Json).connectionFile
node control.cjs $c scanEffects          # 下发任务
node control.cjs $c job <jobId>          # 取结果
```

链路分工：原生 `scanUsedEffects` 只负责按 `PHAsset.hasAdjustments` 筛资产、按 UTI / `.aae` 后缀挑配方资源并读字节；解压、结构校验、名称映射全在 Dart 侧（`PhotoFilterInfo`），避免两处实现漂移。

相关代码：

- `ios/Runner/AppDelegate.swift` — `scanUsedEffects`（读配方字节，带上限与 120 秒兜底）
- `lib/models/photo_filter_info.dart` — 解码 + `effectName → 中文名` 映射表
- `lib/models/effect_scan.dart` — 扫描结果模型、按 effectName 汇总
- `lib/ui/effect_scan_page.dart` — 「滤镜扫描」页面
- `lib/services/debug_photo_executor.dart` — `scanEffects` 调试任务

---

## 4. 已知坑与未解项

1. **`Mono` 没有 `3D` 前缀**。按 Apple 命名规律推出来的 `3DMono` 是错的。凡是没采到样本的名字一律不写死，这也是本表坚持「有 IMG 编号证据才收录」的原因。
2. **相机 AAE 与当前配方可能不同**。AAE 是相机拍摄时写入的那份配方，用户在相册改滤镜后，`Adjustments.plist`（当前配方）会变，AAE 未必跟着变。所以「AAE 哈希一致」不能证明「当前滤镜相同」。
3. **ProRAW 上 `contentEditingInput.adjustmentData` 可能为 nil**。判「是否被编辑」用 `PHAsset.hasAdjustments`，不要用 adjustmentData 是否为空。
4. **6 个 `Adjustments.plist` 报「配方解压失败（不是裸 DEFLATE）」**。说明存在另一种配方结构（可能旧 schema 或非滤镜类编辑），assetId 已记录，尚未定位：
   - `6B5C589D-946A-48CB-B9BA-EA717717E6F0`
   - `C52B7CDB-3C5D-4321-BA1F-8B32E005B358`
   - `F3944A68-3DF9-4F67-A8A6-05781D1E5C24`
   - `3081B1AA-1D01-44FD-99C8-A9FC53AA68D6`
   - `13FC6F32-8AD5-4A7C-9E18-5B1F6ED55A23`
   - `7519D72A-9E40-42E6-9B60-F3F655094E64`
5. **扫不全的情况**：某滤镜从未在相册里用过 → 扫不出来；iCloud 原件未下载且网络不可用 → 可能触发 120 秒兜底（结果标记 `timedOut`，只含已读到的部分）。
6. **`adjustmentTimestamp` 在公开 API 下不可控**。文件时间、资源 import date、request import date、request modification date、`unmanagedAdjustment.adjustmentTimestamp` 五类实验均失败。验收应比「解码后的配方内容」，不比字节。
