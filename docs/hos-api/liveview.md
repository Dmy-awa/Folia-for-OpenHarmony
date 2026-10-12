# HarmonyOS 实况窗 / LiveViewKit 与第三方音乐应用 调研报告

> **目标读者**：为 HarmonyOS NEXT API 14 / API 15 编写 ArkTS 音乐播放器的实现者。
> **回答的问题**：三方音乐 App 能否、以及如何把播放信息送进系统「实况窗 / 灵动岛」与「播控中心」。
> **版本口径**：文中的版本号一律照抄官方文档的 `X.Y.Z(API)` 记法。API 14 = `5.0.2(14)`，API 15 = `5.0.3(15)`。凡是起始版本高于 15 的接口，本报告用 ⚠️ 标出并判为 **API 14/15 不可用**。
>
> **⚠️ 来源与核查方法（务必先读，本主题幻觉风险极高）**
> 1. `developer.huawei.com` 的文档站是 **JS 前端渲染**，`web_fetch` 只能拿到空壳（正文为「文档中心 / Document」）。本报告对华为官方文档的正文，是通过 **GitHub 上对华为官方文档的完整镜像仓库** `ActonZhuang/HarmonyOS_Docs`（commit `6a7bf0f2`，快照日期 **2025-07-24**，即 HarmonyOS 5.1 时代）逐文件取回原文后**逐字引用**的。镜像内的文件路径与官方文档一一对应，因此下面引用官方 URL 时，正文内容取自镜像对应文件。
> 2. 该镜像快照 **没有覆盖** HarmonyOS 6.x / 7.x 新增内容。凡涉及更新的口径，本报告改用**华为官方消费者支持页**（`consumer.huawei.com/cn/support/`，服务端渲染，可直接抓取）与发布日期明确的公开报道交叉验证。
> 3. 社区文章（51CTO / CSDN）**只作为「存在性线索」**，不作为签名证据；本报告明确标出了其中**与官方 API 参考冲突、不可照抄**的代码。
> 4. 每条结论标 **信心等级（高 / 中 / 低）**；无法确证的写 **未确认**。

---

## 0. 结论速览（TL;DR）

| # | 问题 | 结论 | 信心 |
|---|---|---|---|
| 1 | 三方有 LiveView / 实况窗 API 吗 | **有**。`@kit.LiveViewKit` → `liveViewManager.startLiveView / updateLiveView / stopLiveView / isLiveViewEnabled / getActiveLiveView`，起始版本 `4.1.0(11)` | **高** |
| 2 | 音乐 App 能申请到吗 | **不能**。可申请场景表**没有音乐**；`event` 枚举**没有音乐取值**；`ohos.permission.LIVE_VIEW` **不存在/不需要**，准入门槛是 AGC「实况窗权益」 | **高**（场景表）/ **中**（permission 不存在） |
| 3 | AVSession 与实况窗的关系 | 音乐类实况窗由**系统「播控」服务**基于 AVSession 数据渲染，**不是** App 调 `liveViewManager`；与机型（Mate / 挖孔）无关，官方称与硬件完全解耦 | **中** |
| 4 | 有「音乐模板」吗 | LiveViewKit **没有**音乐模板（5 种扩展区模板 / 3 种胶囊，均无媒体类）；系统播控的锁屏沉浸态会显示**专辑封面 + 进度 + 播控**，但 App 不可自定义 | **高**（无模板）/ **高**（系统侧存在音乐实况窗） |
| 5 | `module.json5` 要写什么 | LiveViewKit 本体：**无需任何权限**。锁屏沉浸需 `extensionAbilities` 的 `"type": "liveViewLockScreen"` | **高** |
| 6 | 我们该做什么 | **只做 AVSession + 长时任务 + 元数据（含 `lyric`）**；**不要**接 LiveViewKit | **高** |
| 7 | 若 LiveView 不可用 | 对三方音乐 App **不可用**。最接近的等价物就是 AVSession 驱动的系统播控实况窗（胶囊 + 锁屏卡片/沉浸态） | **高** |

**一句话**：三方音乐 App 拿不到「实况窗」的自绘权限，但**根本不需要**——只要正确接入 `avSession`，系统会替你渲染状态栏实况胶囊与锁屏播控（含专辑封面与进度）。LiveViewKit 对音乐 App 是死路。

---

## 1. LiveViewKit / 实况窗 是否为三方提供 API

### 1.1 结论：**是**。信心：**高**

Live View Kit（实况窗服务）是 Huawei 官方 Kit，三方 App 可直接调用 ArkTS 接口创建 / 更新 / 结束实况窗。

- Kit / 模块名：**Live View Kit（实况窗服务）**，模块 **`liveViewManager`**
- 系统能力：**`SystemCapability.LiveView.LiveViewService`**
- 模型约束：**仅 Stage 模型**
- 起始版本：**`4.1.0(11)`** → **API 14 / 15 上存在且可用**（接口层面）

来源：[liveViewManager（ArkTS API 参考）](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-liveviewmanager)、[Live View Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-introduction)、[构建本地实况窗](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-create-locally)

### 1.2 精确导入语句（逐字引用）

```ts
import { liveViewManager } from '@kit.LiveViewKit';
import { LiveViewLockScreenExtensionAbility } from '@kit.LiveViewKit';      // 5.0.0(12)
import { LiveViewLockScreenExtensionContext } from '@kit.LiveViewKit';       // 5.0.0(12)
```

### 1.3 精确函数签名（逐字引用官方 API 参考）

```
isLiveViewEnabled(): Promise<boolean>
startLiveView(liveView: LiveView): Promise<LiveViewResult>
updateLiveView(liveView: LiveView): Promise<LiveViewResult>
stopLiveView(liveView: LiveView): Promise<LiveViewResult>
getActiveLiveView(id: number): Promise<LiveView>
```

（全部：`仅可在 Stage 模型下使用`、`SystemCapability.LiveView.LiveViewService`、`起始版本：4.1.0(11)`）

⚠️ **未确认**：错误码表中存在 `1003500012 订阅次数超出限制(2000)`、`1003500013 Invalid event type`、`1003500014 Time exceeds valid period`、`1003500015 Subscribe failed`、`1003500016 Request subscribe liveView exceed`，**暗示存在一套「实况窗订阅」接口**，但该 API 参考页面上**没有给出任何订阅函数的签名**。不要在 API 14/15 上依赖订阅能力。

来源：[ArkTS API 错误码](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-error-code)

### 1.4 数据结构类型（逐字引用）

**`LiveView`**（`起始版本：4.1.0(11)`）

| 名称 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | `number` | 是 | 实况窗唯一标识，取值 `[-2147483648, 2147483647]`，**由开发者自行生成** |
| `event` | `string` | 是 | 实况窗的应用场景（取值见 §2.2） |
| `sequence` | `number` | 否 | 保序版本号，`[0, 2147483647]` |
| `isMute` | `boolean` | 否 | **不传则始终默认静默提醒** |
| `timer` | `LiveViewTimer` | 否 | 计时器，`起始版本：5.0.0(12)`；占位符 `${placeholder.timer}` |
| `liveViewData` | `LiveViewData` | 是 | 实况窗详细信息 |

**`LiveViewData`**

| 名称 | 类型 | 必填 |
|---|---|---|
| `primary` | `PrimaryData` | 是（卡片形态） |
| `capsule` | `TextCapsule \| TimerCapsule \| ProgressCapsule` | 否（胶囊形态） |
| `external` | `ExternalData` | 否（小折叠外屏形态） |

**`PrimaryData`**（节选）：`title: string`、`content: Array<RichText>`、`keepTime?: number`（默认 0 不保留，范围 `[0,3600]` 秒）、`clickAction?: WantAgent`、`extensionData?: ExtensionData`、`layoutData?: ProgressLayout | PickupLayout | FlightLayout | ScoreLayout | NavigationLayout`、`liveViewLockScreenPicture?: string | image.PixelMap`

**`RichText`**：`{ text: string; textColor?: string }`（**同一数组中所有 `textColor` 必须同色**）
**`LiveViewResult`**：`{ resultCode: number; message: String }`（0 成功；1 固定区失败；2 辅助区；3 扩展区；4 胶囊；5 外屏）

### 1.5 模板与枚举（官方全集，逐字引用）

**扩展区模板 `LayoutType`**（就这 5 种 + 不显示）：

| 名称 | 值 | 说明 |
|---|---|---|
| `LAYOUT_TYPE_DEFAULT` | -1 | 不显示扩展区 |
| `LAYOUT_TYPE_PROGRESS` | 3 | 进度可视化类型 |
| `LAYOUT_TYPE_PICKUP` | 4 | 强调文本类型 |
| `LAYOUT_TYPE_FLIGHT` | 5 | 左右文本类型 |
| `LAYOUT_TYPE_SCORE` | 7 | 赛事类型 |
| `LAYOUT_TYPE_NAVIGATION` | 8 | 导航类型（`5.0.0(12)`） |

> 官方原话：「实况窗根据扩展区不同共有 **5 种样式模板**：进度可视化模板、强调文本模板、左右文本模板、赛事比分模板和导航模板。」

**胶囊 `CapsuleType`**：`CAPSULE_TYPE_TEXT(1)`、`CAPSULE_TYPE_TIMER(2)`、`CAPSULE_TYPE_PROGRESS(3)`
**其他枚举**：`ExtensionType`(0–4)、`IndicatorType`(0–2)、`LineType`(0–2)、`ExternalType`(0–1, `5.0.0(12)`)、`FlightLayoutStyle`(0–1, `5.0.2(14)`)、`SpaceType`(0–1, `5.0.2(14)`)

**`LiveViewLockScreenExtensionAbility`**（锁屏沉浸实况窗扩展 Ability，继承 `UIExtensionAbility`，`起始版本：5.0.0(12)`）：
- 独立子进程，**不能跨进程拉起其他 Ability**
- **不允许**调用通知 API、窗口 API、卡片 API、后台任务 API、联系人 API、分布式数据管理 API、相机 API、NFC API、上传下载 API、蜂窝通信 API

来源：[LiveViewLockScreenExtensionAbility](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-lock-screen-ability)

---

## 2. 准入 / 权益 / 权限要求

### 2.1 `ohos.permission.LIVE_VIEW` —— **不需要，且官方文档中不存在**。信心：**中**

核查过程与证据：

1. 我把华为官方**全部 5 类权限列表**文档取回全文检索（[应用权限列表](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/permissions-for-all)：开放权限(系统授权)、开放权限(用户授权)、受限开放权限、企业类应用可用权限、MDM 应用可用权限）——**`ohos.permission.LIVE_VIEW` 0 命中**。
2. 官方 LiveViewKit 样例 `live-view-kit_-sample-code_-clientdemo_-arkts` 的 `entry/src/main/module.json5` **只声明 `ohos.permission.INTERNET`**，没有任何实况窗权限。
3. 官方锁屏实况窗样例 `HarmonyOS_Samples/LiveViewLockScreen` 的 `module.json5` 只声明 `ohos.permission.KEEP_BACKGROUND_RUNNING`（用于后台定位），无实况窗权限。
4. 官方 LiveViewKit 文档中**从未出现**权限声明章节；准入靠 **AppGallery Connect 权益**，不是靠 permission。

> **结论**：请**不要**在 `module.json5` 里写 `ohos.permission.LIVE_VIEW`（会编译/校验失败）。准入 = AGC 权益 + 重新生成并打包 Profile 文件。
> **未确认**：我**无法证明**该权限字符串在任何华为内部版本中存在或曾存在；在当前官方文档体系中它是**无据可查**的。

来源（样例）：[Gitee: live-view-kit sample](https://gitee.com/harmonyos_samples/live-view-kit_-sample-code_-clientdemo_-arkts)、[GitCode: LiveViewLockScreen module.json5](https://raw.gitcode.com/HarmonyOS_Samples/LiveViewLockScreen/raw/master/entry/src/main/module.json5)

### 2.2 可申请场景清单 —— **没有音乐**。信心：**高**

官方 `event` 字段取值（镜像快照，11 个）：**`TAXI`（出行打车）、`DELIVERY`（即时配送）、`FLIGHT`（航班）、`TRAIN`（高铁/火车）、`QUEUE`（排队）、`PICK_UP`（取餐）、`SCORE`（赛事比分）、`RENT`（共享租赁）、`TIMER`（计时）、`WORKOUT`（运动锻炼）、`NAVIGATION`（导航）**。

官方原文：「使用对应场景需要申请权益，详情请参见实况窗权益说明。」

AGC 申请侧的一致性证据：「**单次最多申请 3 个场景，同个应用最多申请 11 个场景**」——与 11 个 `event` 一一对应。设计规范文档的场景节点章节同样只有：即时配送 / 打车出行 / 取餐 / 排队 / 计时 / 航班高铁 / 共享租赁 / 运动锻炼 / 导航，**无音乐**。

⚠️ 新增场景（仅社区来源，**中**信心）：一篇 2026-09 的技术文章列出的场景表扩到 16 个，新增 `CHECK_IN`（打卡）、`EXPRESS`（快递）、`PROGRESS`（进度）、`TRADE`（金融交易）、`SUBSCRIBE_TIMER`（订阅计时）——**依然没有音乐**。来源：[鸿蒙系统实况窗功能详解与开发适配指南（CSDN）](https://harmonyosdev.csdn.net/6a97c5303bda720d4b38e12e.html)

### 2.3 准入原则与申请流程（官方原文归纳）

**场景准入原则**：① 用户非常关注、需反复查看或快捷操作；② 有明确开始/结束、**总时长 ≤ 8 小时**；③ 用户有明确预期、通常用户主动触发；④ 内容有价值，**不可用于营销、广告**。

**其他硬约束**：
- 实况窗支持 **HarmonyOS NEXT 及以上**、**仅 Phone / Tablet**（镜像快照说「暂不支持模拟器」；较新文档说要支持模拟器但与真机有差异）、**仅中国境内**（不含港澳台）
- 单实况窗生命周期 **≤ 8 小时**；**> 2 小时未更新**隐藏状态栏/锁屏胶囊；**> 4 小时未更新**判定结束并清除
- 流控：系统级创建 15/s、更新 30/s；应用级创建 10/s、更新 20/s
- 通过 Push Kit 创建/更新有更严格的场景与频次限制（快照期仅 `FLIGHT`/`TAXI`/`TRAIN`）

**申请流程**（[申请实况窗正式权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-formal-authority)）：
1. 先设计（[实况窗设计规范](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-design-formula)）
2. AGC →「项目设置 > 开放能力管理 > 实况窗服务 > 申请」，填场景类型 / 场景描述 / 附件，**5 个工作日**回复
3. **正式权限**：要求应用**已上架且月活 ≥ 1000**；单次最多 3 个场景、总共 ≤ 11 个场景；需方案评审 + 测试验收，**全流程约 15 个工作日**
4. **调测权限**：要求月活 < 1000，有效期 **60 天**（可延期 60 天）
5. **白名单设备调测**：按 Push Token 添加，**每应用上限 100 台**，24 小时内生效；白名单设备**不做本地构建实况窗权限校验**
6. 权限通过后需**重新生成 Profile 文件**并在发布时**打包进应用包**

**结果**：一个正常的第三方**音乐播放器不属于任何可申请场景**，在 AGC「实况窗服务」申请页里**找不到可选场景**。官方文档还说明：若开发者的应用有符合要求的场景但在 AGC 未找到申请入口，可发邮件至 `hwpush@huawei.com`——但这只是给「表外但合格场景」的兜底通道，音乐播放不在场景准入原则内（它没有明确的开始/结束与 ≤8 小时时长，且与系统播控功能重叠）。

来源：[实况窗权益说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-rights)

### 2.4 官方样例覆盖的场景（旁证）

官方样例 README 明确列出其实现的场景：即时配送、打车出行、高铁旅行、排队叫号、赛事比分、导航、航旅出行、计时、共享租赁、取餐、运动锻炼。**无音乐、无媒体类**；样例还附了一份《实况窗各场景参数与模板映射关系指导.xlsx》，同样不做音乐。

---

## 3. AVSession 与「实况窗 / 灵动岛」的关系

### 3.1 官方开发者文档的**否定性证据**（重要）

我把 AVSession Kit 的官方开发者文档全文（简介、本地媒体会话概述、应用接入 AVSession 场景介绍、媒体会话提供方、后台播放、播控推荐服务、投播等）以及 `@ohos.multimedia.avsession` 的 ArkTS API 参考全部取回检索：

> **`实况窗` 0 命中，`胶囊` 0 命中，`灵动岛` 0 命中。** AVSession 官方文档只出现「**播控中心**」「锁屏」「通知栏」「语音助手」。

也就是说：**截至该文档快照，华为官方开发者文档从未把 AVSession 与实况窗写在一起。** 任何「AVSession 自动产生实况窗」的说法，在官方开发者文档里**找不到明文**。

### 3.2 官方**消费者**支持页的正面证据（信心：高，「音乐实况窗存在」这一事实）

华为官方消费者支持页《实况窗支持的应用和场景有哪些？》的场景表中，明确存在一行：

| 场景 | 子场景 | 应用 |
|---|---|---|
| **音视频播放** | **音乐** | **华为音乐、酷狗音乐、QQ音乐、酷我音乐、汽水音乐、网易云音乐** |

同一页还列：

> 「**支持实况窗的系统服务有**：通话、畅连、闹钟、钱包刷卡、打印、录音机、录屏、计时器、**播控**、听歌识曲、连接华为耳机、充电、多设备协同（…）等场景支持实况窗。」

其中酷狗 / QQ音乐 / 酷我 / 汽水 / 网易云 **都是第三方 App**，说明三方音乐 App 的实况窗**确实存在**。

来源：[实况窗支持的应用和场景有哪些？（华为官网）](https://consumer.huawei.com/cn/support/content/zh-cn16019387/)

### 3.3 时间线交叉验证

IT之家 2025-07-28 报道：HarmonyOS 5.1 推送时，华为官网更新实况窗支持应用/场景，「**含即时配送、音视频播放等**」，音乐子场景列出：华为音乐、酷狗音乐、QQ音乐、酷我音乐、汽水音乐（当时**尚无网易云**）。后续报道称 HarmonyOS 5/6 实况窗新增「淘宝闪购、**网易云音乐**」等。

来源：[IT之家 871315](https://m.ithome.com/html/871315.htm)

### 3.4 综合推断（信心：**中**）

把 §3.1 与 §3.2 / §3.3 拼起来，唯一自洽的解释是：

> **音乐类应用的实况窗（状态栏实况胶囊、锁屏播控卡片/沉浸态）是由系统的「播控」服务基于 AVSession 上报的数据渲染的，不是由 App 调用 `liveViewManager` 创建的。**

依据链：
- 官方面向**开发者**的 LiveViewKit 没有音乐 `event`、没有音乐模板 → App 侧**造不出来**音乐实况窗（§2.2 / §4）；
- 官方面向**消费者**的页面把「播控」列为**支持实况窗的系统服务**，并把音乐 App 列进实况窗场景表 → 音乐实况窗**确实存在**；
- 两者相减 ⇒ 渲染方只能是**系统播控**，数据源只能是 **AVSession**。

⚠️ **未确认（必须诚实标注）**：我**没有找到**任何**官方开发者文档**明文写「注册 audio 类型 AVSession 后系统会自动出现实况胶囊」。触发条件（是否要求 `session.activate()`、是否需要长时任务、是否要求元数据完整、限哪些系统版本/机型）**均未在官方文档中确证**。因此我方实现策略应当是：**把 AVSession 接得尽可能完整、规范**，让系统在任何触发条件下都能渲染。

### 3.5 是否只有某些机型（Mate / 挖孔）才有「灵动岛」

**不是。** 官方口径（信心：高）：

> 「**面向 HarmonyOS NEXT 及以上的全量 Phone、Tablet 设备**：实况窗特性与设备硬件**完全解耦**，开发者接入后，可以覆盖到所有 HarmonyOS NEXT 及以上的全量 Phone、Tablet 设备。」

胶囊的**位置**才与挖孔有关（居中挖孔居中展示，侧边挖孔或无孔则居左），但**能力本身全量机型可用**。官方材料从不使用「灵动岛」一词——这是媒体/民间对 HarmonyOS「**实况窗 / 实况胶囊**」的类比叫法。

### 3.6 ⚠️ 不可信的社区说法（明确排除）

1. **「`event: 'PLAYBACK'`」——错误，不可照抄。** 社区文章《HarmonyOS 7 实况窗 + AVSession：锁屏视频播控实现》演示了 `liveViewManager.startLiveView({ id, event: 'PLAYBACK', … })`。官方 `event` 枚举中**没有 `PLAYBACK`**。照抄会命中错误码 `1003500013 Invalid event type` 或 `1003500005 The right of liveView is not enabled`。来源：[51CTO 57894](https://ost.51cto.com/posts/57894)
2. **「AVSession `setBackgroundPlayMode(BackgroundPlayMode.…)` 决定实况胶囊存亡（API 24 新增）」——未确认。** 一篇社区文章称 HarmonyOS 6.1.1（API 24）的 `avSession` 新增 `BackgroundPlayMode` 枚举与 `setBackgroundPlayMode()`，并称系统状态栏「实况胶囊」完全听命于此。我在**官方 AVSession API 参考全文检索中未找到 `setBackgroundPlayMode`**，且该 API 属 API 24，**API 14/15 本就无关**。该文章的示例代码还把 `createAVSession` 的 `context` 取错（用 `getUIContext().getHostContext()` 的页面上下文，官方规范是用 `UIAbilityContext`）。**不作为依据。** 来源：[51CTO 40843](https://ost.51cto.com/posts/40843)

---

## 4. 实况窗的「音乐模板 / 媒体模板」

### 4.1 LiveViewKit 侧：**没有音乐模板**。信心：**高**

- 扩展区模板只有 5 种（进度可视化 / 强调文本 / 左右文本 / 赛事比分 / 导航），**没有媒体/音乐类**（§1.5）
- 胶囊只有 3 种（文本 / 计时器 / 进度），**没有「封面 + 播放键」类**
- `event` 枚举**没有音乐**（§2.2）

⇒ 一个三方音乐 App **无法**用 `liveViewManager` 拼出一个「显示歌名/歌手/封面/进度的音乐实况窗」。最接近的拼法是拿 `LAYOUT_TYPE_PROGRESS` + `CAPSULE_TYPE_PROGRESS` 硬凑，但：① 拿不到音乐场景权益（`event` 无合法取值）；② 违反设计规范（不符合场景的方案不予开通正式权限，上线后违规会被处置）。

### 4.2 系统侧：**有**，但 App 不可自定义。信心：**高**

华为官方消费者支持页《实况窗显示任务实时信息》原文：

> 「**实况窗沉浸态**：在锁屏状态下点亮屏幕，点击下方的锁屏实况窗胶囊，可展开实况窗沉浸态。…如：**锁屏状态下，播放音乐时可查看当前音乐的专辑封面，调整播放进度**；运动时可查看跑步轨迹和里程信息；导航时可查看导航详情。」

⇒ 系统提供了一套**音乐专用的锁屏沉浸实况窗**（专辑封面 + 播放进度 + 播控交互）。**它由系统播控渲染，三方 App 只能通过 AVSession 提供数据，不能控制其 UI。**

来源：[实况窗显示任务实时信息（华为官网）](https://consumer.huawei.com/cn/support/content/zh-cn16115636/)

---

## 5. `module.json5` 需要的精确声明

### 5.1 LiveViewKit 本体：**无需任何权限**。信心：**高**

官方样例证实：创建/更新/结束实况窗**不声明任何实况窗相关权限**。准入走 AGC 权益 + Profile，不走 permission。

### 5.2 锁屏沉浸实况窗：需要 `extensionAbilities`。信心：**高**

来自官方样例 `HarmonyOS_Samples/LiveViewLockScreen` 的 `entry/src/main/module.json5`（**逐字摘录**，含官方注释）：

```json5
{
  "module": {
    // … abilities 等 …
    // [Start addLiveViewLockScreenExtensionAbilityName]
    "extensionAbilities": [
      {
        // Keep it consistent with LiveViewLockScreenExtensionAbility name in live view instance
        "name": "LiveViewExtAbility",
        "type": "liveViewLockScreen",
        // LiveViewLockScreenExtensionAbility location
        "srcEntry": "./ets/liveview/LiveViewExtAbility.ets",
        "exported": false
      }
    ],
    // [End addLiveViewLockScreenExtensionAbilityName]
    "requestPermissions": [
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",   // 该样例用于后台定位，不是实况窗所需
        "reason": "$string:reason_background",
        "usedScene": { "abilities": ["EntryAbility"], "when": "always" }
      }
    ]
  }
}
```

关键点：`"type": "liveViewLockScreen"`，`"exported": false`，`name` 与实况窗实例中引用的 ExtensionAbility 名保持一致。

来源：[LiveViewLockScreen module.json5（官方样例原件）](https://raw.gitcode.com/HarmonyOS_Samples/LiveViewLockScreen/raw/master/entry/src/main/module.json5)

### 5.3 音乐播放器**实际需要**的声明（AVSession 路线）

```json5
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",
        "reason": "$string:reason_background",
        "usedScene": { "abilities": ["EntryAbility"], "when": "always" }
      }
    ],
    "abilities": [
      {
        "name": "EntryAbility",
        // …
        "backgroundModes": ["audioPlayback"]   // 长时任务类型 AUDIO_PLAYBACK
      }
    ]
  }
}
```

- `ohos.permission.KEEP_BACKGROUND_RUNNING`：申请长时任务所需（官方后台播放文档）。
- `backgroundModes` 取 `audioPlayback`：官方文档写「当后台播音的任务类型为 **`AUDIO_PLAYBACK`** 时…可申请类型为 `AUDIO_PLAYBACK` 的长时任务」。⚠️ **信心：中**——`BackgroundMode` 枚举名 `AUDIO_PLAYBACK` 有官方文档明文，但 `module.json5` 里的**字符串字面量拼写**（`audioPlayback`）我在本次取回的文档中**未逐字确认**，实现时请以 DevEco 的 `module.json5` schema 补全为准。
- **声明 `avSession` 不需要任何 permission**（官方 AVSession 文档中无相关权限声明章节）。

来源：[AVSession Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-overview)、[长时任务](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/continuous-task)

---

## 6. 给 Folia（三方 ArkTS 音乐播放器）的具体建议

**优先级从高到低。每一项都标注在 API 14 / 15 上对普通应用是否可用。**

### ① AVSession（`@kit.AVSessionKit`）+ 元数据 + 播放状态 —— **必做，API 14/15 可用 ✅**

这是**唯一**能满足「在控制栏/灵动岛可以快捷操作以及显示歌曲信息」的正路。

```ts
import { avSession as AVSessionManager } from '@kit.AVSessionKit';

let type: AVSessionManager.AVSessionType = 'audio';   // ⚠️ 字符串字面量联合类型，不是枚举
const session = await AVSessionManager.createAVSession(context, 'FOLIA_PLAYER', type);
await session.activate();                              // 激活后系统播控才接管
```

必做清单：
- `setAVMetadata(metadata)` —— **标题、副标题/歌手、封面图是官方明列的「必须设置」项**
- `setAVPlaybackState(state)` —— 播放/暂停/进度/循环模式
- 注册控制命令：至少 **`play` / `pause`**（官方明列的「必须注册」项），建议补齐 `playNext` / `playPrevious` / `stop` / `seek` / `setLoopMode` / `toggleFavorite`
- 生命周期：`session.destroy()` 在 App 退出播放业务时调用（防「尸体会话」）
- **官方硬规定**：「所有需要进行后台播放的音视频应用，都需要同时接入 AVSession 和后台任务管理，**未接入的应用在退到后台时，将会被强制暂停音频播放**」

来源：[AVSession Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-overview)、[应用接入 AVSession 场景介绍](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-access-scene)

### ② 长时任务 `AUDIO_PLAYBACK` —— **必做，API 14/15 可用 ✅**

`backgroundTaskManager` 申请 `AUDIO_PLAYBACK` 长时任务 + `ohos.permission.KEEP_BACKGROUND_RUNNING`。
官方规范：暂停/停止时**主动取消**长时任务，恢复播放时**重新申请**；被焦点打断后系统会冻结/取消，重启播放需再申请。

来源：[后台播放](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-background-playback)（对应官方指南「本地媒体会话 - 后台播放」）、[长时任务](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/continuous-task)

### ③ `AVMetadata.lyric`（LRC 歌词）→ 播控中心/锁屏歌词 —— **推荐，API 14/15 可用 ✅**

```ts
let metadata: AVSessionManager.AVMetadata = {
  assetId: '0',
  title: 'TITLE',
  mediaImage: 'IMAGE',
  artist: 'ARTIST',
  // LRC 有两类元素：时间标签+歌词，ID 标签
  // 例如：[00:25.44]xxx\r\n[00:26.44]xxx\r\n
  lyric: 'lrc格式歌词内容',
};
```

- `lyric`：**起始 API 10** → **API 14/15 可用 ✅**。官方说明：「系统支持**简单版 LRC 格式（Simple LRC format）**」，长度 < 40960 字节，**不规范（如重复时间戳）会解析失败并显示异常**。
- ⚠️ `singleLyricText`（不含时间戳的单条歌词）：**起始 API 17** → **API 14/15 不可用 ❌**。做单行歌词显示时要自己从 LRC 切分。
- 另有 `dispatchSessionEvent('dynamic_lyric', { lyric })` 的动态歌词用法（官方 API 参考示例）。

### ④ 元数据补全（歌单/前后曲）→ 播控中心体验 —— **推荐，API 14/15 可用 ✅**

`assetId`、`previousAssetId`、`nextAssetId`、`album`、`author`、`writer`、`composer`、`duration`、`subtitle`、`description`、`mediaImage`；歌单 `avQueueName` / `avQueueId` / `avQueueImage`（**11+**）、`setAVQueueItems` / `setAVQueueTitle`。
官方要求：「若应用接入歌单功能，则确保在 `AVMetadata` 中一直携带歌单数据」。

### ⑤ LiveViewKit 实况窗（`liveViewManager`）—— **不要做，API 14/15 不可用 ❌**

理由（任一即否决）：
1. AGC 可申请场景表**无音乐**，拿不到 `event` 的合法取值 → 必然 `1003500005 The right of liveView is not enabled.`
2. 就算硬传字符串，也会 `1003500013 Invalid event type.`
3. 无音乐模板，拼出的样式不符合《实况窗设计规范》→ 不予开通正式权限，上线后按违规处置。
4. 被系统播控的实况窗**功能重叠**：你在状态栏再多插一个胶囊只会和系统播控胶囊打架。

### ⑥ 锁屏沉浸实况窗（`"type": "liveViewLockScreen"`）—— **不要做，API 14/15 不可用 ❌**

接口本身 `5.0.0(12)` 起可用，**但依赖 LiveViewKit 权益**，与 ⑤ 同因被否决。

### ⑦ 「灵动岛式自绘实况窗」—— **不可得 ❌**（见 §7）

---

## 7. LiveView 对三方音乐 App 是否可用 —— **不可用，明确结论**

### 7.1 明确结论

> **LiveViewKit 的 `liveViewManager` 不能被第三方音乐 App 用来展示音乐实况窗。** 不是「还没有找到用法」，而是**产品规则上就不开放**：可申请场景表没有音乐、`event` 无音乐取值、没有音乐模板。信心：**高**。

### 7.2 但需求**已经能被满足** —— 最接近的等价物就是系统播控实况窗

「在控制栏/灵动岛可以快捷操作以及显示歌曲信息」这个需求，**不需要 LiveViewKit**：

| 触达点 | 由谁渲染 | 三方 App 要做什么 |
|---|---|---|
| 系统**播控中心**卡片（播放/暂停/上下曲/进度/歌名/歌手/封面） | 系统 | 接入 AVSession + 元数据 + 播放状态 + 注册控制命令 |
| **状态栏实况胶囊**（「播控」系统服务） | 系统 | 同上（可能还需长时任务，触发条件未确证） |
| **锁屏播控卡片 / 沉浸态**（专辑封面 + 进度 + 播控） | 系统 | 同上 |
| 播控中心**歌词** | 系统 | `AVMetadata.lyric` |
| 自绘「灵动岛」实况窗（自定义 UI） | —— | **做不到，也不该做** |

**实现成本对比**：LiveViewKit 路线（若可行）需要 AGC 权益审批（15 工作日 + 评审/验收 + Profile 重签）且要自己画 UI；AVSession 路线是**纯代码、零审批、零 UI**，系统全帮你画。

### 7.3 一句话给决策者

> 别碰 LiveViewKit。把 `avSession` 接完整（含 `lyric`），把长时任务申请对，**用户想要的一切（控制栏快捷操作 + 歌曲信息 + 锁屏封面进度）都会自动到位**。

---

## 8. 信心等级汇总

| 结论 | 信心 | 依据强度 |
|---|---|---|
| LiveViewKit 存在，`liveViewManager` 5 个 API、数据结构、模板枚举如 §1 | **高** | 官方 API 参考逐字引用 |
| `event` 无音乐、AGC 场景表无音乐、无音乐模板 | **高** | 官方 API 参考 + 权益/设计规范 + 官方样例 README 三处一致 |
| `ohos.permission.LIVE_VIEW` 不存在/不需要 | **中** | 5 类官方权限列表 + 2 个官方样例 module.json5 全查无；属否定性证据，无法穷尽证明 |
| 锁屏沉浸扩展 `"type": "liveViewLockScreen"` | **高** | 官方样例 `module.json5` 原件 |
| 三方音乐 App 的实况窗来自**系统「播控」服务**（AVSession 驱动） | **中** | 官方消费者页（场景表含音乐 + 播控列为实况窗系统服务）+ 官方开发者文档的否定性证据；**因果链无官方开发者文档明文** |
| 「注册 AVSession 即自动出现实况胶囊」 | **未确认** | 无官方明文；触发条件（activate/长时任务/元数据/版本机型）均未知 |
| 实况窗与硬件解耦、全量 Phone/Tablet，非 Mate 专属 | **高** | 官方简介原文 |
| 音乐锁屏沉浸态显示「专辑封面 + 进度 + 播控」 | **高** | 官方消费者页原文 |
| `AVMetadata.lyric` 起始 API 10、Simple LRC、<40960 字节 | **高** | 官方 API 参考逐字引用 |
| `singleLyricText` 起始 API 17 → API 14/15 不可用 | **高** | 官方 API 参考逐字引用 |
| `setBackgroundPlayMode` / `BackgroundPlayMode`（API 24） | **未确认** | 官方 AVSession API 参考全文检索无命中；仅社区文章 |
| 实况窗订阅类接口（错误码 1003500012–16） | **未确认** | 仅有错误码，无函数签名 |
| `module.json5` 的 `backgroundModes: ["audioPlayback"]` 字符串拼写 | **中** | 文档给的是枚举名 `AUDIO_PLAYBACK`；字面量拼写未逐字确认 |

---

## 9. 来源清单

**华为官方文档（正文经 GitHub 镜像 `ActonZhuang/HarmonyOS_Docs@6a7bf0f2` 快照 2025-07-24 取回）**

- [liveViewManager（ArkTS API 参考）](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-liveviewmanager)
- [LiveViewLockScreenExtensionAbility](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-lock-screen-ability)
- [ArkTS API 错误码（Live View Kit）](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/liveview-error-code)
- [Live View Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-introduction)
- [实况窗权益说明](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-rights)
- [申请实况窗正式权限](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-formal-authority)
- [构建本地实况窗](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-create-locally)
- [实况窗设计规范](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/liveview-design-formula)
- [AVSession Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-overview)
- [应用接入 AVSession 场景介绍](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-access-scene)
- [长时任务](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/continuous-task)
- [应用权限列表（5 类）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/permissions-for-all)

**华为官方消费者支持页（服务端渲染，直接抓取）**

- [实况窗支持的应用和场景有哪些？](https://consumer.huawei.com/cn/support/content/zh-cn16019387/) —— 音乐场景表 + 「播控」系统服务
- [实况窗显示任务实时信息](https://consumer.huawei.com/cn/support/content/zh-cn16115636/) —— 锁屏沉浸态音乐封面/进度

**官方样例源码**

- [Gitee: LiveViewKit_SampleCode_Clientdemo_ArkTS](https://gitee.com/harmonyos_samples/live-view-kit_-sample-code_-clientdemo_-arkts)（`entry/src/main/module.json5` 仅 `ohos.permission.INTERNET`）
- [GitCode: LiveViewLockScreen 官方样例 module.json5](https://raw.gitcode.com/HarmonyOS_Samples/LiveViewLockScreen/raw/master/entry/src/main/module.json5)

**公开报道（用于时间线交叉验证）**

- [IT之家：HarmonyOS 5 系统实况窗支持应用/场景公布，含即时配送、音视频播放等](https://m.ithome.com/html/871315.htm)（2025-07-28）

**社区来源（仅作线索，已标注冲突项）**

- [51CTO 40843：AVSession 后台播放与实况胶囊联动](https://ost.51cto.com/posts/40843) —— ⚠️ `setBackgroundPlayMode` 未在官方文档中确证
- [51CTO 57894：HarmonyOS 7 实况窗 + AVSession](https://ost.51cto.com/posts/57894) —— ⚠️ `event: 'PLAYBACK'` 与官方枚举冲突，**不可照抄**
- [CSDN：鸿蒙系统实况窗功能详解与开发适配指南](https://harmonyosdev.csdn.net/6a97c5303bda720d4b38e12e.html) —— 更新版 16 场景表（仍无音乐）

**否定性检索记录（用于证明「没有」）**

- `github.com/openharmony/docs` 全库文件树检索 `liveview` / `实况`：**0 命中** → LiveViewKit 是 **HarmonyOS 专有**，OpenHarmony 无此能力（与 AVSession 不同，后者 OpenHarmony 有）。
- 本次取回的**全部**华为官方文档中检索 `ohos.permission.LIVE_VIEW`：**0 命中**。
- 本次取回的**全部** AVSession 官方文档中检索 `实况` / `胶囊` / `灵动岛`：**0 命中**。
