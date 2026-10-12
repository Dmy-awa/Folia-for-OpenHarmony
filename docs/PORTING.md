# Folia 鸿蒙移植说明（Upstream → HarmonyOS）

本文记录 **上游 Electron/React 工程** 到 **本工程 ArkTS/ArkUI** 的模块级映射、
单位/语义对齐规则，以及**有意舍弃**的部分。目标是让后续维护者能一眼看出
「这个鸿蒙模块对应上游哪个文件」，而不是重新逆向一遍。

- 上游仓库：`chthollyphile/folia-major`（AGPL-3.0）
- 本工程：`folia-harmonyos`，HarmonyOS NEXT API 14，ArkTS / ArkUI，状态管理 V2
- 上游源码规模：`src/` 约 27.9 万行 TS/TSX（含 i18n 文案与 3D 可视化）

---

## 一、为什么不能「编译成鸿蒙」，只能重写

| 上游技术 | 鸿蒙是否有对等能力 | 处理方式 |
| --- | --- | --- |
| React 19 + zustand + framer-motion | ❌ 无 | 用 ArkUI 声明式 UI + `@ObservedV2/@Trace` 状态管理 V2 重写 |
| Tailwind CSS | ❌ 无 | 改用 ArkUI 属性 + 资源限定词 |
| Web Audio API（播放图、EQ、9 个效果、双 deck 交叉淡入） | ❌ **无对等节点** | 本期不移植，见第五节 |
| `<audio>` 元素 | ✅ 有（AVPlayer） | 重新实现，状态机与回调完全不同 |
| Dexie / IndexedDB | ✅ 有（preferences / relationalStore / 文件） | 重新实现持久化层 |
| Node.js 主进程（crypto、npm provider 包、ffmpeg、ONNX） | ❌ 无 | 用 `@kit.NetworkKit` / `@kit.CryptoArchitectureKit` / `@kit.zlib` 重写，或改为服务端 |
| `music-metadata` npm 包 | ❌ 无 | **自行实现**容器与标签解析（本工程已实现 6 种容器） |
| `DOMParser`（TTML） | ⚠️ `@ohos.xml` 能力不同 | 本期 TTML 退回增强 LRC 解析 |
| `Intl.Segmenter`（CJK 分词） | ❌ 无 | 退化为按字素切分（上游本身也有该 fallback 路径） |
| Electron 壁纸 / 遥控窗 / OBS / Discord RPC | ❌ 平台专属 | 舍弃 |

---

## 二、模块映射表

### 2.1 播放（核心）

| 上游 | 本工程 | 说明 |
| --- | --- | --- |
| `services/playbackGraph.ts` | `services/player/AudioEngine.ets` | 上游是 Web Audio 图；这里退化为单 AVPlayer + 音量/速率控制。**效果链未移植** |
| `stores/usePlaybackStore.ts` | `services/player/PlaybackController.ets` | 合并为一个 `@ObservedV2` 控制器，含 `@Trace` 状态 |
| `utils/queueAddBehavior.ts` | `services/player/PlaybackQueue.ets` | `append` / `next` 两种插入行为，**都先去重再重插** |
| `hooks/usePlaybackQueueController.ts` | `PlaybackQueue` + `PlaybackController` | 队列变更、随机重排、循环模式 |
| `hooks/usePlaybackTransportController.ts` | `PlaybackController` 的 play/pause/seek/next/prev | — |
| `stores/usePlaybackStore.ts` 的 `loopMode` | `core/Types.ets` 的 `RepeatMode` | 见下方「语义对齐」 |
| `hooks/usePlaybackRuntimeRefs.ts` | 无 | ArkTS 不需要 ref 规避重渲染，由 V2 状态管理承担 |
| Electron `useElectronPlaybackBridge` | `services/media/MediaSessionService.ets` | 上游与 Electron 主进程通信以更新系统托盘/媒体键；鸿蒙改为 AVSession |
| `hooks/useElectronDisplaySleepBlocker` | `utils/WindowAdapter.ets` 的 `setKeepScreenOn` | ⚠️ 官方明确「纯音频播放不要用屏幕常亮」，本工程只在需要时调用并复位 |

### 2.2 歌词

| 上游 | 本工程 | 说明 |
| --- | --- | --- |
| `types.ts` 的 `LyricData` / `Line` / `Word` | `core/Types.ets` 的 `LyricDocument` / `LyricLine` / `LyricWord` | **时间单位保持秒（float）** |
| `utils/lyrics/parserCore.ts` | `services/lyrics/LyricCore.ets` + `LyricParsers.ets` | 公共内核与各格式解析器拆成两个文件 |
| `utils/lyrics/formatDetection.ts` | `LyricParsers.detectFormat` | 判定顺序与阈值逐字对齐 |
| `utils/lyrics/krcDecrypt.ts` | `services/lyrics/KrcDecoder.ets` | XOR 表逐字节照抄 |
| `utils/lyrics/qrcDecrypt.ts` | `services/lyrics/QrcDecoder.ets` | **自定义 S-box 的 3DES**，不能用系统 DES192 |
| `utils/lyrics/timelineSplitter.ts` | ⏳ 未移植 | 合并时间轴拆轨，属于增强匹配能力 |
| `utils/lyrics/wordSegmentation.ts` | ⚠️ 简化 | 上游依赖 `Intl.Segmenter`；ArkTS 无此能力，退化为按字素切分 |
| `utils/lyrics/matchScore.ts` / `autoMatchBestLyric.ts` | ⏳ 未移植 | 权重与流程已完整记录在 `docs/porting/lyrics-spec.md` §7 |
| `appPlaybackHelpers.findLatestActiveLineIndex` | `services/lyrics/LyricTimeline.ets` | 额外提供二分版本供长歌词使用 |
| 歌词动画主题（10+ 套） | `components/lyrics/LyricTheme.ets` | 已移植 3 套（浮名/流光/心象），新增只需加定义 |

### 2.3 本地音乐库

| 上游 | 本工程 | 说明 |
| --- | --- | --- |
| `services/localMusicService.ts` | `services/library/LocalLibraryService.ets` | 导入、索引、侧车歌词 |
| `music-metadata`（npm） | `services/library/MetadataReader.ets` + `Mp3/Flac/Mp4/Vorbis/Wav Parser.ets` | 全部自行实现 |
| `FileSystemDirectoryHandle`（浏览器目录句柄） | `picker.DocumentViewPicker` + 沙箱复制 | 见 [`ARCHITECTURE.md` 第 7 节](ARCHITECTURE.md#7-本地音乐库) 的取舍说明 |
| `dexie` 的 `local_songs` 表 | `filesDir/folia/library.json` | 见 README「已知限制」第 6 条 |
| `utils/lyrics/localLyricFormatOrder.ts` | `LocalLibraryService.findSidecarLyric` | 优先级 `.lrc → .vtt → .ttml → .qrc → .yrc → .krc` |

### 2.4 在线音乐

| 上游 | 本工程 | 说明 |
| --- | --- | --- |
| `services/onlineMusic/omni.ts`（713 行 / 73 个方法） | `services/online/OmniRouter.ets` | 保留「transport → provider → omni」三层与代次计数 |
| `*Transport.ts` | `services/online/HttpTransport.ets` | `fetch` → `@kit.NetworkKit` |
| `*Provider.ts` | `services/online/{Netease,Kugou,Navidrome}Provider.ets` | 归一化逻辑保留 |
| `electron/preload.cjs` 的 `fetchLyricProxy` | **删除** | 那是绕 CORS 用的；`@ohos.net.http` 没有 CORS 限制 |
| `electron/neteaseBackend.cjs`（内嵌 Node 服务） | `NeteaseProvider` + 可配置基址 | 加密在 npm 包里，客户端无法照搬 |
| `electron/kugouApiBridge.cjs` | `KugouProvider`（匿名能力端侧实现） | 签名算法已在源码中确认并照抄 |
| `blueimp-md5` | `services/online/crypto/CryptoUtil.ets` | `cryptoFramework.createMd('MD5')` |
| `localStorage` 存 provider 配置 | `OnlineSettings` + `preferences` | — |

### 2.5 UI

| 上游 | 本工程 |
| --- | --- |
| `App.tsx`（13.8 万行，巨型入口） | `app/AppBootstrap.ets` + `views/shell/AppShell.ets`（刻意拆薄） |
| `components/UnifiedPanel.tsx`（5.4 万行） | `views/LibraryView.ets` + `views/SearchView.ets` + `views/SettingsView.ets` |
| `components/FloatingPlayerControls.tsx` | `components/player/TransportBar.ets` + `ProgressBar.ets` |
| `components/app/lattice/*`（歌词舞台） | `components/lyrics/LyricStage.ets` + `LyricTheme.ets` |
| `components/modal/SettingsModal.tsx`（12.7 万行） | `views/SettingsView.ets`（仅保留鸿蒙端有意义的项） |
| `i18n/locales/*`（3 个 35 万行文案文件） | 中文文案硬编码；接入 `@ohos.intl` 即可多语言化 |

---

## 三、需要严格遵守的语义对齐

### 3.1 歌词时间单位

上游 `src/types.ts` 的歌词时间轴**全部是秒（float）**，毫秒只出现在格式边界
（YRC/QRC/KRC 的原始标签）并由解析器 `/1000`。

本工程**完全保持这一约定**，刻意不改成毫秒，因为：

- 转换点越多越容易漏；
- `buildTimedWords` 里的常量（0.05s 最小时长、0.9 时长分配）是秒制；
- 间奏判定阈值（3s）、翻译配对窗口（1.0s）都是秒制。

播放器位置是毫秒（AVPlayer / AVSession 都是毫秒），因此全应用**只有一处**换算：

```ts
// services/lyrics/LyricTimeline.ets
export function toLyricTime(positionMs: number, offsetMs: number): number {
  const clamped = Math.max(-2000, Math.min(2000, offsetMs));
  return (positionMs - clamped) / 1000;
}
```

UI 必须先 `/1000` 再调用时间轴函数；`LyricStage` 内部承担这一换算。

### 3.2 循环模式

上游把 shuffle 与 repeat 分开：`loopMode: 'off' | 'all' | 'one'`，
shuffle 只是一次性重排、不持久化。

本工程合并为单一枚举：

```ts
export enum RepeatMode { OFF = 'off', ALL = 'all', ONE = 'one', SHUFFLE = 'shuffle' }
```

**原因**：鸿蒙 `AVSession` 只暴露一个 `loopMode` 字段
（`LOOP_MODE_SEQUENCE / SINGLE / LIST / SHUFFLE`），合并后与系统一 一对应，
避免"应用内是随机、播控中心显示顺序"的不一致。`PlaybackQueue.shuffle()`
仍然保持上游的「当前曲固定首位 + 反向 Fisher–Yates」语义。

### 3.3 队列去重

上游 `applyQueueAddBehavior` 的规则是**两种插入行为都先去重再重插**，
所以对已在队列中的歌曲执行「下一首播放」是**移动**而不是新增重复项。

`PlaybackQueue.add()` 完整复刻了这一点，并且当被去重的条目恰好是**当前播放曲**时
不移除它（否则会导致播放中断），而是把新条目插到其后。

### 3.4 真实逐字 vs 假时轴

LRC 与 VTT 也会产出 `words`，但那是由 `buildTimedWords` 生成的**等分假时轴**。

因此 UI 判断「是否可以做逐字扫光」**必须**看 `LyricDocument.hasWordTiming`，
不能看 `line.words.length > 0`。本工程：

- `LyricParsers.buildDocument` 显式传入 `hasWordTiming`；
- 增强 LRC 取 `drafts.some(d => d.words.length > 0)`（混合文件也算逐字）；
- `LyricTheme.canHighlightWords()` 额外要求 `theme.wordHighlight`。

---

## 四、上游被**有意舍弃**的能力

上游 `docs/porting/playback-architecture.md` 第 8 节列出了完整的舍弃清单，摘要：

| # | 能力 | 上游文件 | 舍弃原因 |
| --- | --- | --- | --- |
| 1 | 壁纸模式（window-to-layer） | `electron/{mac,windows}WallpaperController.cjs`、`src/components/wall/*` | 桌面窗口层级技巧，鸿蒙无对应概念 |
| 2 | 外部遥控窗 + Discord RPC + Windows 任务栏控制 | `electron/discordPresence.cjs`、`src/components/remote/*` | 平台专属；鸿蒙的等价物是 AVSession（已实现） |
| 3 | OBS 浏览器源 | `src/services/obs/*` | 直播推流场景，移动端无意义 |
| 4 | 转码兜底 + Folium 模组系统 + 视频导出 | `electron/transcode/*`、`src/mods/*` | 依赖 ffmpeg 与 JS 沙箱，成本远高于收益 |
| 5 | ONNX 拍点检测 + htdemucs 分轨 | `electron/analysis/*`、`src/services/automix/{beatThis,stems}*` | 需要原生推理运行时；可用上游的 `estimateTempo` 回退 |

另有**必须替换而非删除**的部分：Electron 主进程内嵌的在线音乐 Node 服务
（已改为 `HttpTransport` + 各 provider）；本地库的目录句柄（已改为 picker + 沙箱复制）；
Stage API / NowPlaying / PlayerCap 三路外部播放源（属于 P1，本期未实现）。

---

## 五、关于音效链：为什么本期没做

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
`Oscillator → AudioParam` 都没有对等节点。可行路线有三条：

1. 用 `AudioRenderer`（`@kit.AudioKit`）+ **NAPI 自写 DSP**——能力最全，工作量最大；
2. 用系统的 AudioEffect 预设能力——只能做固定预设，无法复刻上游参数；
3. 只做 EQ + drive + crush + punch 这 4 个纯 Biquad/波形整形效果——性价比最高。

上游的**全部参数、取值范围、默认值与映射公式**都已记录在
[`docs/porting/playback-architecture.md`](porting/playback-architecture.md) 第 4 节，
可直接照搬，无需再逆向。

同理，Automix 的**规划层**（transitionChooser / transitionPlanner / crossfadePlanner /
musicalTime）是**零 DSP 的纯函数**，与 Web Audio 无关，是移植性价比最高的部分；
只有拍点检测与分轨需要重 DSP。

---

## 六、鸿蒙侧的「必须遵守」清单（踩坑记录）

这些是移植过程中核对官方文档后确认的硬约束，已在代码中落实：

### AVSession

1. 激活顺序：`createAVSession → setAVMetadata → setAVPlaybackState → 注册命令 → activate()`。顺序错了播控中心可能拿不到数据。
2. `AVMetadata.assetId` **必填且不能为空**，否则 `setAVMetadata` 返回 `6600101`；切歌必须换 `assetId`。
3. **不要逐帧上报 position**，系统按 `elapsedTime + updateTime` 自行推算；但 `state/position/speed` 变化必须重报。
4. `seek` 回调参数单位是**毫秒**，`fastForward`/`rewind` 是**秒**。
5. 注册即代表「应用支持该指令」，未注册的按钮置灰；文档明确要求**不要做无逻辑空实现**。
6. `AVSessionType` 是字符串字面量联合类型，音乐写 `'audio'`，**没有** `AVSessionType.AUDIO` 常量。
7. `AVMusicTemplate` 仅 API 23+ Car 设备可用且**不渲染歌词**，本工程不使用。

### AVPlayer

8. 必须**先在 idle 注册 `stateChange` 与 `error`，再设置播放源**，否则会漏事件。
9. `url`/`fdSrc`/`dataSrc` 只能在 `idle` 设置；`audioRendererInfo`/`setPlaybackStrategy` 只能在 `initialized` 设置；`audioInterruptMode` 在 `prepared` 之后。
10. `timeUpdate`/`durationUpdate`/`seekDone`/`seek()`/`currentTime`/`duration` **全是毫秒**；唯一例外是 `PlaybackStrategy.preferredBufferDuration`（秒）。
11. 拖动进度条后，在 `seekDone` 之前**不要用 `timeUpdate` 覆盖 UI**，否则进度条回跳。
12. `setLoop`/`setAudioRendererInfo` 是**属性**不是方法；`PlaybackStrategy.keepDecodedFrameOnPause` **不存在**；`showFirstFrameOnPrepare` 是 API 17+。
13. 中断事件在 **AVPlayer** 上收（`on('audioInterrupt')`），不在 AudioSessionManager 上；后者也没有 `getInstance()`（应为 `audio.getAudioManager().getSessionManager()`）。

### 后台与窗口

14. 长时任务：API 14/15 用 `backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK`；`BackgroundTaskMode.MODE_AUDIO_PLAYBACK` 是 API 21+。
15. 权限 `KEEP_BACKGROUND_RUNNING` 与 `abilities[].backgroundModes: ["audioPlayback"]` **两者缺一不可**。
16. 一个 UIAbility 同时只能有一个长时任务：暂停必须取消，恢复必须重新申请；音频在播时取消会被**强制终止进程**。
17. `STREAM_USAGE_MUSIC` 场景必须同时接入 AVSession，否则后台播放被静音冻结。
18. 横屏：`setPreferredOrientation(window.Orientation.LANDSCAPE)`。**PC / 2in1 上不生效**（自由窗口），代码需主动跳过。
19. `deviceTypes` 里鸿蒙电脑是 `2in1`，**没有 `pc` 这个值**。
20. `getWindowAvoidArea` 在 PC / 2in1 自由窗口下返回**空避让区**，代码必须容忍空值。
21. `window.on('windowSizeChange')` 回调单位是 **px**，布局用 vp，必须除以 `display.getDefaultDisplaySync().densityPixels`。

### 实况窗

22. `LiveViewKit` 的 `event` 枚举**没有音乐场景**，`LayoutType` 也没有媒体模板，接入还需 AGC 权益申请。
    → 三方音乐 App **不能**用 `liveViewManager`。音乐的控制栏/锁屏/实况胶囊由**系统播控服务基于 AVSession 渲染**。
    详见 [`docs/hos-api/liveview.md`](hos-api/liveview.md)。

---

## 七、自检工具

工程内的 `tools/` 提供了三个脚本，用于在**没有 DevEco Studio** 的环境下做机械校验：

```bash
# 0. 指向你自己的 HarmonyOS SDK 声明目录（verify_hos_api.py 需要）
export HOS_API_DIR="/path/to/sdk/ets/api"      # Windows: $env:HOS_API_DIR = "..."

# 1. 鸿蒙 API 符号核对：对 15 个 SDK 声明文件、185 个 API 符号逐一比对
python tools/verify_hos_api.py

# 2. 修正写错的相对导入路径（只在唯一候选可解析时才改写）
python tools/fix_imports.py

# 3. 静态检查：相对导入可解析性、ArkTS 禁用构造、导出符号存在性、
#    类字段初始化、build() 唯一根容器、必需配置文件与资源引用
python tools/validate_arkts.py
```

`validate_arkts.py` 会检查的 ArkTS 禁用构造包括：
`require()`、`any`、`Object.assign`、对象展开、`console.*`、DOM 全局、
`localStorage`、`ESObject`，以及混用状态管理 V1 装饰器（`@State/@Prop/@Link/@ObjectLink`）。

> ⚠️ 这三个脚本**不能替代编译器**。它们只能抓住机械性错误；
> 类型兼容性、ArkUI 组件属性合法性、API 版本可用性仍需在 DevEco Studio 中验证。

本轮交付前这三项检查均为**通过**状态：API 符号 185/185 存在，
50 个 `.ets` 文件 0 错误 0 警告，导入路径全部可解析。

---

## 八、后续维护建议

1. **首次在 DevEco 打开后**，先跑一次 `Build → Clean Project` 再编译，排除缓存干扰。
2. **优先修编译错误而非告警**；ArkTS 的部分告警（如未使用导入）不影响构建。
3. 若要接 TTML，建议引入 `@ohos.xml`（`xml.XmlPullParser`）重写 `parseTTML`，
   上游的 `ttmlConversion.ts` 逻辑可以照搬，只是把 DOM 遍历换成 Pull 解析。
4. 若要接网易云，建议保持「自建服务 + HTTP 客户端」的形态，
   不要去客户端复刻 weapi/eapi——上游仓库里本来就没有这些密钥。
5. 新增歌词主题时，只需在 `components/lyrics/LyricTheme.ets` 的 `LYRIC_THEMES`
   数组里加一个定义；主题选择 UI 会自动出现（设置页遍历该数组）。
