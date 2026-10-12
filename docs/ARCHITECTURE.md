# 架构与鸿蒙适配说明

本文说明本工程的关键实现决策与鸿蒙平台适配细节。
模块级的「上游文件 → ArkTS 模块」映射表见 [`PORTING.md`](PORTING.md)；
API 的逐字段核实结果见 [`hos-api/`](hos-api/)。

---

## 1. 全局横屏与四形态适配

三层保障：

### 1.1 静态声明（`module.json5`）

```json5
"deviceTypes": ["phone", "tablet", "2in1", "default"],
"orientation": "landscape",
"preferMultiWindowOrientation": "landscape",
"minWindowWidth": 600, "minWindowHeight": 360,
"maxWindowRatio": 4.5, "minWindowRatio": 0.8,
"supportWindowMode": ["fullscreen", "split", "floating"]
```

`2in1` 就是鸿蒙电脑 / PC 的官方设备类型值（**不存在 `pc` 这个值**）。

### 1.2 运行时锁定（`utils/WindowAdapter.ets`）

```ts
windowStage.getMainWindowSync().setPreferredOrientation(window.Orientation.LANDSCAPE)
window.setWindowLayoutFullScreen(true)
window.setWindowSystemBarEnable([])
```

> ⚠️ **PC / 2in1 上方向锁不生效**——自由窗口模型下官方明确「调用不生效不报错」。
> 因此代码在 `deviceType === '2in1'` 时主动跳过方向锁，并要求布局能接受任意宽高比。

### 1.3 断点驱动布局（`utils/Breakpoints.ets`）

阈值与官方 `GridRow` / `Navigation` 的默认约定一致：
`xs [0,320)` · `sm [320,600)` · `md [600,840)` · `lg [840,+∞)`

| 断点 | 典型设备 | 布局策略 |
| --- | --- | --- |
| `md` | 手机横屏 / 小平板 | 导航栏收窄为纯图标，播放页纯歌词沉浸，曲库单列 |
| `lg` | 平板 / 鸿蒙电脑 / 2in1 | 导航栏展开带文字，播放页右侧队列面板，曲库双栏 |

窗口尺寸通过 `window.on('windowSizeChange')` 监听（回调单位是 **px**，内部换算为 vp），
安全区通过 `getWindowAvoidArea` 读取，**PC 自由窗口下返回空值属于预期**，代码已容忍。

---

## 2. 媒体播控（AVSession）

`services/media/MediaSessionService.ets` 是这一能力的核心。官方有一条**硬性顺序约束**：

```
createAVSession → setAVMetadata → setAVPlaybackState → 注册控制命令 → activate()
```

文档原文：「激活接口要在元数据、控制命令注册完成之后再执行。」

已注册的播控命令（注册即代表应用支持该指令，未注册的系统按钮会置灰）：

| 命令 | 说明 |
| --- | --- |
| `play` / `pause` | **强必须**，否则播控中心基本不可用 |
| `playNext` / `playPrevious` | audio 类型播控中心会显示对应按钮 |
| `seek` | ⚠️ 参数单位是**毫秒** |
| `setLoopMode` | 处理后必须回传 `loopMode` |
| `toggleFavorite` | 处理后必须回传 `isFavorite` |
| `skipToQueueItem` | 队列跳转 |
| `handleKeyEvent` | 蓝牙 / 有线耳机多模按键 |
| `fastForward` / `rewind` | ⚠️ 参数单位是**秒**（与 `seek` 不同，极易出错） |

两个容易踩的坑，本工程已处理：

- **`assetId` 必填且不能为空**，否则 `setAVMetadata` 直接返回 `6600101`。切歌必须更换 `assetId`。
- **不要逐帧上报 position**。系统会按 `elapsedTime + updateTime` 自行推算进度；
  但 `state` / `position` / `speed` 任一变化时必须重新上报，否则进度会算错。

---

## 3. 播控中心歌词

`services/media/ControlCenterLyric.ets` 把解析后的歌词**重新序列化**为 Simple LRC：

- 剥掉逐字尖括号（系统不识别，会当正文显示）；
- 跳过间奏行（`......`）与元信息行；
- 反向补偿运行时时间轴偏移，避免播控中心歌词与音频不同步；
- 按 **UTF-8 字节数**截断到 40000 字节（系统上限 40960），
  避免中文按字符数低估导致超限。

> ⚠️ `AVMetadata.singleLyricText` 是 API 17+ 的字段，本工程目标 API 14 **不可用**，因此没有使用。

---

## 4. 后台播放

```json5
// module.json5
"requestPermissions": [{ "name": "ohos.permission.KEEP_BACKGROUND_RUNNING", ... }],
"abilities": [{ "backgroundModes": ["audioPlayback"], ... }]
```

```ts
await backgroundTaskManager.startBackgroundRunning(
  context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wantAgent);
```

三条必须遵守的规则（本工程已实现）：

- **单个 UIAbility 同时只能有一个长时任务**——暂停时必须 `stopBackgroundRunning`，恢复时重新申请；
- **音频还在播就取消长时任务会被系统强制终止进程**，因此取消与暂停必须成对；
- `STREAM_USAGE_MUSIC` 场景**必须同时接入 AVSession**，否则后台播放会被静音冻结。

> ⚠️ `BackgroundTaskMode.MODE_AUDIO_PLAYBACK` 是 API 21+ 的枚举，API 14 不存在；
> API 14/15 必须用 `BackgroundMode.AUDIO_PLAYBACK`。

---

## 5. 音频焦点与设备变化

- 中断事件从 **AVPlayer** 上收：`avPlayer.on('audioInterrupt', …)`。
  `forceType = INTERRUPT_FORCE` 表示系统已代为执行（如已暂停），应用只需同步 UI；
  `INTERRUPT_SHARE` 表示由应用决定。`RESUME` 恒为 SHARE，
  且只在「用户本意就是要播」时才自动恢复。
- 拔出耳机：`on('audioOutputDeviceChangeWithInfo')`，`changeReason === 2`
  （原设备不可用）时按官方建议**暂停播放并取消长时任务**。
- ⚠️ 不存在 `AudioSessionManager.getInstance()`（应为 `audio.getAudioManager().getSessionManager()`），
  它也没有 `on('audioInterrupt')`；`setAudioSessionScene` 是 API 20+，本工程未使用。

---

## 6. 歌词内核

移植自上游 `src/utils/lyrics/parserCore.ts`。**时间轴统一使用秒（float）**，
与上游完全一致，只有格式边界（YRC/QRC/KRC 的原始标签）做 `/1000`。
播放器位置是毫秒，全应用仅在 `LyricTimeline.toLyricTime` 一处换算——
这个约定是刻意的，因为上游 `buildTimedWords` 里的常量（0.05s 最小时长、
0.9 时长分配）、间奏阈值（3s）、翻译配对窗口（1.0s）全是秒制，
改成毫秒反而会引入大量容易漏掉的换算点。

已实现的格式与关键点：

| 格式 | 关键点 |
| --- | --- |
| LRC | 末行时长恒为 5s；中段行按 `min(duration, 阅读时间 + 2s)` 压缩；`[ti:]/[ar:]` 之外的行内标签**整行丢弃**（上游真实行为，未「顺手支持」） |
| 增强 LRC | 三分支固定顺序：`<mm:ss.xx>` 尖括号 → 同行多 `[...]` → 普通整行 |
| VTT | 按空行分块 + cue 时间行；无逐字但有假时轴 |
| YRC | 词标签是**绝对毫秒** |
| QRC | 词标签与文本相对位置不固定，用「切段 + 前瞻/后置偏好」消歧；解密需**自定义 S-box 的 3DES**，不能用系统 DES192 替代 |
| KRC | 词 offset **相对行首**（与 YRC 相反，最易错）；`[language:BASE64]` 内嵌翻译/罗马音轨必须解析，否则酷狗翻译全丢 |
| AWLRC | 小数部分是**毫秒**而非十进制小数（`[02:43.97]` = 163s + 97ms） |

其他移植要点：

- `buildTimedWords`：CJK 逐码元、标点权重 0、拉丁词权重 `1 + len*0.15`、
  只用 90% 时长、单字最小 0.05s、尾部越界等比回缩；
- 翻译配对是 **±1.0s 窗口内的贪心最近配对**，每条线 / 每条目最多用一次——
  不能退回最近邻（上游修过的 bug）；
- 间奏行：首行晚于 3s 时补 `<0.5, first-0.5>`，相邻行间隔 >3s 时补
  `<curEnd+0.05, nextStart-0.05>`，恒为 6 个等分点；
- `findLatestActiveLineIndex` **从后往前扫**，取第一个
  `startTime <= t <= renderEndTime` 的行——因为 `renderEndTime` 可能越过下一行
  `startTime`，倒序保证取「最后一行」；
- **只有 YRC / QRC / KRC / 增强 LRC 的 `words` 是真实逐字时间**，
  LRC 与 VTT 的 `words` 是假时轴，UI 必须以 `hasWordTiming` 判断而不是 `words.length > 0`。

### 6.1 关于 inflate

HarmonyOS 的 `@ohos.zlib` **没有同步的 ArrayBuffer 解压接口**
（只有文件级接口与异步的 `Zip.uncompress`），因此本工程把 zlib 的 `puff.c`
INFLATE 移植成了纯 ArkTS，保证 KRC/QRC 的解密路径是同步的。

---

## 7. 本地音乐库

**设计取舍**：系统文件选择器给的 URI 只授予临时权限，重启后失效。
本实现选择**复制进应用沙箱**（`filesDir/music/<hash>.<ext>`），
路径稳定、无额外权限、外部文件删除后曲库仍可用；代价是双份存储。
若后续要支持「引用外部目录」，只需把 `importFiles` 换成持久化 URI 权限
（`fileShare.persistPermission`），其余逻辑无需改动。

索引以 JSON 存放在 `filesDir/folia/library.json`——
比 `preferences` 没有单值大小限制，比关系型数据库实现更轻。

标签解析自行实现（上游用的 `music-metadata` 是 Node 包，鸿蒙不可用）：
ID3v2.2/2.3/2.4 + ID3v1、FLAC Vorbis Comment + PICTURE、Ogg Vorbis/Opus、
MP4/M4A atom（含 64 位 atom 大小）、WAV、ADTS。所有解析步骤均做边界检查，
**面对损坏文件绝不抛异常**，最多返回空字段。

歌词解析顺序：同目录同名侧车文件（`.lrc → .vtt → .ttml → .qrc → .yrc → .krc`），
其次内嵌歌词（导入时落地成侧车文件，统一读取路径），最后尝试在线匹配。

---

## 8. 在线音乐

三层结构（与上游一致，不可省略）：

```
HttpTransport（HTTP / 签名） → *Provider（归一化） → OmniRouter（门面）
```

UI 与 ViewModel **只允许调用 `OmniRouter`**，绝不直接触碰 provider。

| Provider | 可行性 | 说明 |
| --- | --- | --- |
| **Navidrome** | ✅ 纯客户端 | 只需 MD5。`token = md5(password + salt)`，salt 为 8 字节随机数的 16 位小写十六进制；参数 `u/t/s/v=1.16.1/c=Folia/f=json`；URL 为 `<server>/rest/<endpoint>`（**无 `.view` 后缀**）；直链不失效、无需额外请求头 |
| **酷狗（匿名）** | ✅ 纯客户端 | 只需 MD5。签名：`mid = md5(String(Date.now()))`，参数键排序后以 `k=v` **无分隔符**拼接，`signature = md5(SALT + src + SALT)`，`SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"`。歌词接口需 `decode=true`，且**只读 `decodeContent` 字段**（KRC 解密在服务端完成）。⚠️ 上游规范用的是 **http 明文**地址，HarmonyOS 对明文流量有限制，本工程**默认改走同 host 同路径的 https**（签名与请求头不受影响），明文地址保留为 `KUGOU_SEARCH_URL_PLAINTEXT` 备切换 |
| **网易云** | ⚠️ 需自建服务 | 上游的加密全在 npm 包 `@neteasecloudmusicapienhanced/api` 里，**仓库源码中不含任何 AES 密钥 / RSA 模数**，无法照搬。本工程实现为可配置基址的 HTTP 客户端，请自行部署 NeteaseCloudMusicApi 后填写地址。注意：该 API **忽略 HTTP 状态码，只看响应体的 `code` 字段**，且 cookie 是作为 **URL 查询参数 `cookie=`** 传递而非请求头 |

各 provider 的完整端点表、请求/响应示例与「需要抓包确认」清单，
见 [`porting/online-providers.md`](porting/online-providers.md)。

---

## 9. 有意舍弃的桌面能力

上游 `porting/playback-architecture.md` 第 8 节列出了完整清单，摘要：

| 能力 | 舍弃原因 |
| --- | --- |
| 壁纸模式（window-to-layer） | 桌面窗口层级技巧，鸿蒙无对应概念 |
| 外部遥控窗 + Discord RPC + 任务栏控制 | 平台专属；鸿蒙的等价物是 AVSession（已实现） |
| OBS 浏览器源 | 直播推流场景，移动端无意义 |
| 转码兜底 + Folium 模组系统 + 视频导出 | 依赖 ffmpeg 与 JS 沙箱，成本远高于收益 |
| ONNX 拍点检测 + htdemucs 分轨 | 需要原生推理运行时；可用上游的 `estimateTempo` 回退 |
| Web Audio 音效链 | **HarmonyOS 没有 Web Audio**，见下节 |

---

## 10. 为什么音效链没做

上游用 Web Audio 构建了完整链路：

```
双 deck（HTMLAudioElement）
  → 每路 deck chain（replayGain → trim → tone{low/mid/high} → fade → throw）
  → mixNode
  → 10 段 EQ（31Hz~16kHz，lowshelf + 8×peaking + highshelf，Q=1.4，±12dB）
  → effectChain（highpass/lowpass/drive/crush/wow/noise/width/space/punch）
  → 音量 → 播放淡入淡出 → Analyser(fft 2048) → destination
```

其中「音量的位置」是硬约束：**必须在效果链之后**，否则 vinyl noise / bit crush / punch
的行为会被推子改变（上游文件内附有实测 dB 数据）。

**HarmonyOS 没有 Web Audio**，`ConvolverNode`、`AudioBufferSourceNode`、
`Oscillator → AudioParam` 都没有对等节点。可行路线：

1. 用 `AudioRenderer`（`@kit.AudioKit`）+ **NAPI 自写 DSP**——能力最全，工作量最大；
2. 用系统的 AudioEffect 预设能力——只能做固定预设，无法复刻上游参数；
3. 只做 EQ + drive + crush + punch 这 4 个纯 Biquad / 波形整形效果——性价比最高。

上游的**全部参数、取值范围、默认值与映射公式**都已记录在
[`porting/playback-architecture.md`](porting/playback-architecture.md) 第 4 节，可直接照搬。

同理，Automix 的**规划层**（transitionChooser / transitionPlanner / crossfadePlanner /
musicalTime）是**零 DSP 的纯函数**，与 Web Audio 无关，是移植性价比最高的部分；
只有拍点检测与分轨需要重 DSP。
