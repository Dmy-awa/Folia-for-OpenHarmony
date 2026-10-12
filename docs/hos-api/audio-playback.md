# HarmonyOS NEXT 音频播放 / 音频焦点 / 后台运行 实现参考

> 目标读者：编写 ArkTS 音乐播放器（`AudioEngine`）的实现者。
> 本文是**唯一**实现参考，所有签名均直接摘自 OpenHarmony 官方文档（master 分支 zh-cn 文档）。
> **版本口径**：目标平台 HarmonyOS NEXT API 14 / API 15。文档中凡是标注 `API 17+` / `API 18+` / `API 20+` / `API 21+` / `API 23+` 的能力，**在 API 14/15 上不可用**，本文用 ⚠️ 标出。

## 0. 单位速查（经典 bug 源，先看这里）

| 接口 / 回调 | 单位 |
| --- | --- |
| `AVPlayer.currentTime`（属性，只读） | **毫秒 ms** |
| `AVPlayer.duration`（属性，只读） | **毫秒 ms** |
| `on('timeUpdate', (time: number) => …)` | **毫秒 ms**（默认 100ms 上报一次） |
| `on('durationUpdate', (duration: number) => …)` | **毫秒 ms** |
| `on('seekDone', (seekDoneTime: number) => …)` | **毫秒 ms**（回的是"请求值"，非实际落点） |
| `AVPlayer.seek(timeMs, mode?)` 入参 | **毫秒 ms** |
| `on('bufferingUpdate')` 的 `CACHED_DURATION` 值 | **毫秒 ms** |
| `on('bufferingUpdate')` 的 `BUFFERING_PERCENT` 值 | **百分比 %**（0–100 语义） |
| `PlaybackStrategy.preferredBufferDuration` | **秒 s**，取值 `[1, 20]` |
| `AVPlayer.getPlaybackPosition()`（API 18+） | **毫秒 ms** |
| `AVPlayer.getCurrentPresentationTimestamp()`（API 23+） | **微秒 μs** ← 全 AVPlayer 唯一一处微秒 |
| `backgroundTaskManager` 的所有时间参数 | 无（只有 `DelaySuspendInfo` 用 ms） |

> ⚠️ 结论：音乐播放器主链路**全部用毫秒**。唯一出现微秒的是 API 23+ 的 `getCurrentPresentationTimestamp()`，API 14/15 上根本拿不到，**不要**在进度条逻辑里乘/除 1000。

---

## 1. AVPlayer 播放音频

### 1.1 导入与创建

```ts
import { media } from '@kit.MediaKit';

// Promise 形式（推荐）
let avPlayer: media.AVPlayer = await media.createAVPlayer();

// 回调形式
media.createAVPlayer((err: BusinessError, player: media.AVPlayer) => { /* … */ });
```

| 接口 | 签名 | 起始版本 |
| --- | --- | --- |
| `media.createAVPlayer` | `createAVPlayer(callback: AsyncCallback<AVPlayer>): void` | API 9 |
| `media.createAVPlayer` | `createAVPlayer(): Promise<AVPlayer>` | API 9 |

- 创建后 `state === 'idle'`，所有属性为默认值。
- 系统能力：`SystemCapability.Multimedia.Media.AVPlayer`。
- **必须**在 `idle` 状态、**设置播放资源之前**注册 `on('stateChange')` 与 `on('error')`，否则可能收不到资源设置过程中上报的事件。

### 1.2 状态机 `AVPlayer.state`

```ts
type AVPlayerState = 'idle' | 'initialized' | 'prepared' | 'playing'
                    | 'paused' | 'completed' | 'stopped' | 'released' | 'error';
```

`AVPlayer.state` 是**只读**属性，全状态有效。状态切换规则：

| 目标状态 | 触发方式 | 限定前置状态 |
| --- | --- | --- |
| `idle` | `createAVPlayer()` 或 `reset()` | — |
| `initialized` | 设置 `url` / `fdSrc` / `dataSrc` | 仅 `idle` |
| `prepared` | `prepare()` | 仅 `initialized` |
| `playing` | `play()` | `prepared` / `paused` / `completed` |
| `paused` | `pause()` | 仅 `playing` |
| `completed` | 播放到结尾且未设 `loop=true` | 自动 |
| `stopped` | `stop()` | `prepared` / `playing` / `paused` / `completed` |
| `released` | `release()` | 除 `released` 外均可 |
| `idle` | `reset()` | `initialized` / `prepared` / `playing` / `paused` / `completed` / `stopped` / `error` |
| `error` | 播放引擎发生**不可逆错误** | 自动 |

要点：
- `prepared` / `playing` / `paused` / `completed` 状态下播放引擎占用大量内存；暂不使用时应 `reset()` 或 `release()`。
- `reset()` 会重置 `url` / `fdSrc` / `dataSrc` 与 `loop`，**其他用户设置的属性保留**。
- `completed` 状态下 `play()` = 重新播放（进入 `playing`）；`stop()` = 进入 `stopped`。
- `error` 状态时播放服务不可播控，要求 `reset()` 或 `release()` 重建。
- 注意区分 **error 状态** 与 **`on('error')` 事件**：收到 `on('error')` 但未进入 `error` 状态时，多为"未按状态机调用 API / 参数错误"（客户端 bug）或"码流短暂异常"（无需容错）。

### 1.3 资源设置：`url` / `fdSrc` / `dataSrc` / `setMediaSource`

三个属性**都只允许在 `idle` 状态下设置**，设置成功即上报 `initialized`。

| 名称 | 类型 | 起始版本 | 用途 / 约束 |
| --- | --- | --- | --- |
| `url` | `string` | API 9 | 支持 `fd://xx`、`http://xx`、`https://xx`（含 HLS）。音频格式：m4a / aac / mp3 / ogg / wav / flac / amr / ape。网络路径需 `ohos.permission.INTERNET`。**AVPlayer 会独占此 fd**。 |
| `fdSrc` | `AVFileDescriptor` | API 9 | 资源连续存放在同一个文件中、需按偏移量播放时使用。 |
| `dataSrc` | `AVDataSrcDescriptor` | API 10 | 边下边播（应用自填数据）。 |
| `setMediaSource` | `(src: MediaSource, strategy?: PlaybackStrategy) => Promise<void>` | API 12 | 流媒体预下载 / 自定义 HTTP 头。**只能在 `idle` 调用**。 |

`AVFileDescriptor`：

```ts
interface AVFileDescriptor {
  fd: number;       // 必填，resourceManager.getRawFd() 或 fileIo.open() 获得
  offset?: number;  // 默认 0
  length?: number;  // 默认"从 offset 到文件末尾"
}
```

`AVDataSrcDescriptor`（API 10+）：

```ts
interface AVDataSrcDescriptor {
  fileSize: number;  // 字节。-1 表示大小未知，此时行为类似直播：不能 seek、不能 setSpeed、不能设 loop，因而不能重播
  callback: (buffer: ArrayBuffer, length: number, pos?: number) => number;
  // 返回实际填充长度；-1 表示到达流末尾；-2 表示不可恢复错误。fileSize = -1 时禁止使用 pos 参数。
}
```

常用写法：

```ts
// 1) 网络 / HLS
avPlayer.url = 'https://xxx.xxx.xxx/xxx.mp3';

// 2) 应用沙箱文件（fd://）
let file = await fileIo.open(`${ctx.filesDir}/test.mp3`);
avPlayer.url = `fd://${file.fd}`;

// 3) HAP rawfile（按 offset/length）
let rfd = await ctx.resourceManager.getRawFd('test.mp3');
avPlayer.fdSrc = { fd: rfd.fd, offset: rfd.offset, length: rfd.length } as media.AVFileDescriptor;

// 4) 自定义 HTTP 头 / 播放策略
let src = media.createMediaSourceWithUrl(url, { 'User-Agent': 'x', 'Cookie': 'y' });
let strategy: media.PlaybackStrategy = { preferredBufferDuration: 3 };
await avPlayer.setMediaSource(src, strategy);
```

> ⚠️ 同一 fd 不得同时交给多个 AVPlayer / AVMetadataExtractor / AVImageGenerator / AVTranscoder；传给 AVPlayer 后不要再用该句柄做其它读写。

### 1.4 事件回调（精确签名 + 单位）

| 事件 | 回调签名 | 单位 / 语义 | 起始 |
| --- | --- | --- | --- |
| `on('stateChange')` | `OnAVPlayerStateChangeHandle = (state: AVPlayerState, reason: StateChangeReason) => void` | `reason`: `USER = 1`（用户/客户端主动调用）、`BACKGROUND = 2`（后台系统行为，如未注册播控中心权限被强制暂停） | API 9（`reason` 参数自 API 12 起为类型化） |
| `on('error')` | `(error: BusinessError) => void` | `error.code` / `error.message`。仅错误提示，**不需要**用户停止播控；若同时进入 `error` 状态需 `reset()`/`release()` | API 9 |
| `on('durationUpdate')` | `(duration: number) => void` | **ms**。默认只在 `prepared` 上报一次；特殊码流可多次上报。直播不上报 | API 9 |
| `on('timeUpdate')` | `(time: number) => void` | **ms**。默认 **100ms** 间隔；seek 引起的跳变会立刻上报；直播不上报；`paused` 下缓冲结束时也会上报一次 | API 9 |
| `on('seekDone')` | `(seekDoneTime: number) => void` | **ms**。上报的是**用户请求的 time**，不是实际落点；精确位置需读 `currentTime`。除 `SEEK_CONTINUOUS` 外，每次 `seek()` 后都会回调 | API 9 |
| `on('speedDone')` | `(speed: number) => void` | 智能追帧开启时会回调特定值 `100` | API 9 |
| `on('volumeChange')` | `(vol: number) => void` | 生效的媒体音量 | API 9 |
| `on('bufferingUpdate')` | `OnBufferingUpdateHandler = (infoType: BufferingInfoType, value: number) => void` | `BufferingInfoType`: `BUFFERING_START = 1`（系统暂停播放）、`BUFFERING_END = 2`（系统恢复播放）、`BUFFERING_PERCENT = 3`（百分比）、`CACHED_DURATION = 4`（**ms**，变化量 > 500ms 才上报一次）。**仅网络播放支持** | API 9 |
| `on('endOfStream')` | `() => void` | 播放到结尾时上报。若 `loop = true` 会跳回开头重播；否则会另经 `stateChange` 上报 `completed` | API 9 |
| `on('audioInterrupt')` | `(info: audio.InterruptEvent) => void` | 音频焦点变化，详见第 2 节 | API 9 |
| `on('audioOutputDeviceChangeWithInfo')` | `(data: audio.AudioStreamDeviceChangeInfo) => void` | 输出设备变化及原因，详见第 5 节 | API 11 |
| `on('startRenderFrame')` | `() => void` | 视频首帧送显，纯音频无关 | API 9 |

每个事件都有配对的 `off(type, callback?)`；`callback` 不传则取消该事件的**所有**回调。

`completed` / `endOfStream` 的驱动逻辑：

```ts
avPlayer.on('endOfStream', () => {
  // 到达结尾：loop=false 时随后会收到 stateChange('completed')，在此处执行"下一首"
});
avPlayer.on('stateChange', (state: string, reason: media.StateChangeReason) => {
  switch (state) {
    case 'prepared':  /* 此时 duration 有效，可刷新进度条长度 */ break;
    case 'playing':   /* 起播（或 resume）*/ break;
    case 'paused':    /* 系统/用户暂停 */ break;
    case 'completed': /* 播放结束，切下一首 */ break;
    case 'error':     /* 不可逆错误，reset() 或 release() */ break;
  }
});
```

### 1.5 方法清单（精确签名 / 限定状态 / 版本）

| 方法 | 签名 | 可调用状态 | 起始 |
| --- | --- | --- | --- |
| `prepare` | `prepare(callback: AsyncCallback<void>): void` / `prepare(): Promise<void>` | 仅 `initialized` | API 9 |
| `play` | `play(callback: AsyncCallback<void>): void` / `play(): Promise<void>` | `prepared` / `paused` / `completed` | API 9 |
| `pause` | `pause(callback: AsyncCallback<void>): void` / `pause(): Promise<void>` | 仅 `playing` | API 9 |
| `stop` | `stop(callback: AsyncCallback<void>): void` / `stop(): Promise<void>` | `prepared` / `playing` / `paused` / `completed` | API 9 |
| `reset` | `reset(callback: AsyncCallback<void>): void` / `reset(): Promise<void>` | `initialized` / `prepared` / `playing` / `paused` / `completed` / `stopped` / `error` | API 9 |
| `release` | `release(callback: AsyncCallback<void>): void` / `release(): Promise<void>` | 除 `released` 外均可 | API 9 |
| `seek` | `seek(timeMs: number, mode?: SeekMode): void` | `prepared` / `playing` / `paused` / `completed` | API 9 |
| `setVolume` | `setVolume(volume: number): void` | `prepared` / `playing` / `paused` / `completed` | API 9 |
| `setSpeed` | `setSpeed(speed: PlaybackSpeed): void` | `prepared` / `playing` / `paused` / `completed` | API 9 |
| `setMediaMuted` | `setMediaMuted(mediaType: MediaType, muted: boolean): Promise<void>` | `prepared` / `playing` / `paused` / `completed` | API 12 |
| `setPlaybackStrategy` | `setPlaybackStrategy(strategy: PlaybackStrategy): Promise<void>` | **仅 `initialized`** | API 12 |
| `setMediaSource` | `setMediaSource(src: MediaSource, strategy?: PlaybackStrategy): Promise<void>` | **仅 `idle`** | API 12 |
| `setPlaybackRange` | `setPlaybackRange(startTimeMs: number, endTimeMs: number, mode?: SeekMode): Promise<void>` | `initialized`/`prepared`/`paused`/`stopped`/`completed` | API 18 ⚠️ |
| `getPlaybackPosition` | `getPlaybackPosition(): number`（**ms**） | `prepared` / `playing` / `paused` / `completed` | API 18 ⚠️ |
| `getCurrentPresentationTimestamp` | `getCurrentPresentationTimestamp(): number`（**μs**） | `playing` / `paused` / `completed` | API 23 ⚠️ |
| `setPlaybackRate` | `setPlaybackRate(rate: number): Promise<void>` | — | API 20 ⚠️ |
| `getPlaybackInfo` | `getPlaybackInfo(): Promise<PlaybackInfo>` | `prepared`/`playing`/`paused` | API 12 |
| `selectTrack` / `deselectTrack` | — | — | API 12 |

**注意：`setLoop` 与 `setAudioRendererInfo` 在 ArkTS API 中并不存在为方法**，它们是 AVPlayer 的**属性**：

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `loop` | `boolean` | 循环播放，默认 `false`，动态属性。只允许在 `prepared`/`playing`/`paused`/`completed` 设置。**直播场景不支持** |
| `audioRendererInfo` | `audio.AudioRendererInfo` | 音频渲染信息。**只允许在 `initialized` 状态、第一次 `prepare()` 之前**设置 |
| `audioInterruptMode` | `audio.InterruptMode` | 焦点模式，默认 `SHARE_MODE`，动态属性。只允许在 `prepared`/`playing`/`paused`/`completed` 设置，且应在第一次 `play()` 之前设置 |
| `audioEffectMode` | `audio.AudioEffectMode` | 默认 `EFFECT_DEFAULT`；`audioRendererInfo.usage` 变动时恢复默认 |
| `currentTime` | `number`（只读，**ms**） | `prepared`/`playing`/`paused`/`completed` 有效；无效返回 `-1`；直播默认 `-1` |
| `duration` | `number`（只读，**ms**） | 同上 |

> ⚠️ 如果代码里写了 `avPlayer.setLoop(true)` / `avPlayer.setAudioRendererInfo(info)`，那是不存在的 API，改为 `avPlayer.loop = true` / `avPlayer.audioRendererInfo = info`。
> （C/C++ 侧才存在 `OH_AVPlayer_SetAudioRendererInfo` / `OH_AVPlayer_SetAudioInterruptMode`。）

`seek` 细节：

```ts
avPlayer.seek(1000, media.SeekMode.SEEK_PREV_SYNC); // 单位 ms，默认 mode 即 SEEK_PREV_SYNC
```

`SeekMode`：`SEEK_NEXT_SYNC = 0`、`SEEK_PREV_SYNC = 1`、`SEEK_CLOSEST = 2`（API 12+）、`SEEK_CONTINUOUS = 3`（API 18+ ⚠️，该模式**不触发** `seekDone`，结束需 `seek(-1, SEEK_CONTINUOUS)`）。

> 官方示例明确：**必须等 `seekDone` 之后才能用 `timeUpdate` 更新进度条**，否则拖动会被回弹。

### 1.6 `PlaybackStrategy`（API 12+，`setPlaybackStrategy` / `setMediaSource` 的第二参）

| 字段 | 类型 | 单位 / 取值 | 起始 |
| --- | --- | --- | --- |
| `preferredWidth` | `number` | px，>0 整数 | API 12 |
| `preferredHeight` | `number` | px，>0 整数 | API 12 |
| `preferredBufferDuration` | `number` | **秒**，`[1, 20]` | API 12 |
| `preferredHdr` | `boolean` | 默认 `false` | API 12 |
| `mutedMediaType` | `media.MediaType` | 关闭输出的媒体类型。API 12–19 仅支持 `MEDIA_TYPE_AUD`；API 20+ 增加 `MEDIA_TYPE_VID` | API 12 |
| `preferredAudioLanguage` | `string` | 仅 dash 场景 | API 13 |
| `preferredSubtitleLanguage` | `string` | 仅 dash 场景 | API 13 |
| `showFirstFrameOnPrepare` | `boolean` | 默认不显示首帧 | API 17 ⚠️ 不可用 |
| `preferredBufferDurationForPlaying` | `number` | **秒**，`[0, 20]` | API 18 ⚠️ |
| `thresholdForAutoQuickPlay` | `number` | **秒**，≥2 且 > 起播缓冲水线，默认 5 | API 18 ⚠️ |
| `enableSuperResolution` | `boolean` | 默认 `false` | API 18 ⚠️ |
| `keepDecodingOnMute` | `boolean` | 默认 `false`；**仅视频** | API 20 ⚠️ |

> ⚠️ **`keepDecodedFrameOnPause` 这个字段在官方文档中不存在**（已全量检索 zh-cn 文档）。API 20 有一个语义相近但**仅用于视频**的 `keepDecodingOnMute`。API 14/15 上二者都不可用，音乐播放器不需要。
> ⚠️ 同理 `showFirstFrameOnPrepare` 是 API 17+，**API 14/15 编译不过**。

音乐播放器实际可用的最小策略：

```ts
let strategy: media.PlaybackStrategy = {
  preferredBufferDuration: 5   // 秒，[1,20]；网络音源抗卡顿
};
await avPlayer.setPlaybackStrategy(strategy);   // 必须在 initialized 状态调用
```

---

## 2. 音频焦点 / 打断

### 2.1 系统自动申请与释放

- **开始播放时系统自动为该音频流申请焦点**；申请失败则音频流无法起播，应用会收到 `InterruptEvent`。
- **结束播放（pause / stop / release）时系统自动释放焦点**；释放后受影响的其它音频流会触发恢复。
- 播放过程中若有其它音频流申请焦点，系统按"音频焦点策略"（由 `StreamUsage` + 启动先后顺序决定）自动执行暂停 / 继续 / 降音 / 恢复，并**通过 `InterruptEvent` 通知应用**。
- 系统默认**优先采用强制打断**（`INTERRUPT_FORCE`），应用无法更改；只有系统无法强制执行的操作（如 `INTERRUPT_HINT_RESUME`）才用 `INTERRUPT_SHARE`。

### 2.2 AVPlayer 上的焦点回调与响应

```ts
import { audio } from '@kit.AudioKit';

avPlayer.on('audioInterrupt', (info: audio.InterruptEvent) => {
  if (info.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
    switch (info.hintType) {
      case audio.InterruptHint.INTERRUPT_HINT_PAUSE:
        // 系统已暂停本流（临时失焦）。应用只需同步状态/UI。
        // 焦点恢复时会收到 INTERRUPT_HINT_RESUME。
        break;
      case audio.InterruptHint.INTERRUPT_HINT_STOP:
        // 系统已停止本流（永久失焦），后续不会再收到任何焦点事件；
        // 需用户主动触发才能恢复。同步状态/UI。
        break;
      case audio.InterruptHint.INTERRUPT_HINT_DUCK:
        // 系统已把音量降到正常音量的 20%。应用侧保持播放即可。
        break;
      case audio.InterruptHint.INTERRUPT_HINT_UNDUCK:
        // 系统已恢复正常音量。
        break;
    }
  } else if (info.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
    switch (info.hintType) {
      case audio.InterruptHint.INTERRUPT_HINT_RESUME:
        // 建议应用恢复播放（主动调用 play()）。不想恢复可忽略。
        break;
      default:
        break;
    }
  }
});
```

典型场景适配（官方表格）：

| 先播 | 推荐 StreamUsage | 后播 | 推荐 StreamUsage | 推荐体验 | 适配方案 |
| --- | --- | --- | --- | --- | --- |
| 音乐 | `STREAM_USAGE_MUSIC` | 音乐 | `STREAM_USAGE_MUSIC` | 后播正常播放，先播停止 | 收 `INTERRUPT_HINT_STOP` → 停止播放并更新 UI |
| 音乐 | `STREAM_USAGE_MUSIC` | 导航 | `STREAM_USAGE_NAVIGATION` | 音乐降音量，导航结束后恢复 | 收 `INTERRUPT_HINT_DUCK` / `_UNDUCK` |
| 视频 | `STREAM_USAGE_MOVIE` | 闹铃 | `STREAM_USAGE_ALARM` | 视频暂停，闹铃结束后继续 | 收 `_PAUSE` 暂停，收 `_RESUME` 重启播放 |
| 音乐 | `STREAM_USAGE_MUSIC` | 来电铃声 | `STREAM_USAGE_RINGTONE` | 音乐暂停，挂断后恢复 | 同上 |
| 音乐 | `STREAM_USAGE_MUSIC` | VoIP | `STREAM_USAGE_VOICE_COMMUNICATION` | 通话接通音乐暂停，挂断恢复 | 同上 |

`InterruptEvent` 结构：

```ts
interface InterruptEvent {
  eventType: InterruptType;        // 必填
  forceType: InterruptForceType;   // 必填
  hintType: InterruptHint;         // 必填
}
```

枚举（audio kit）：

| 枚举 | 成员 = 值 | 含义 |
| --- | --- | --- |
| `InterruptType` | `INTERRUPT_TYPE_BEGIN = 1` / `INTERRUPT_TYPE_END = 2` | 中断开始 / 结束 |
| `InterruptForceType`（API 9+） | `INTERRUPT_FORCE = 0` | 具体操作**已由系统强制执行**，应用只需更新状态/UI |
| | `INTERRUPT_SHARE = 1` | 系统不执行，仅**建议**应用操作，应用可自行决策或忽略 |
| `InterruptHint` | `INTERRUPT_HINT_NONE = 0` | 无提示 |
| | `INTERRUPT_HINT_RESUME = 1` | 可恢复播放。**必为 `INTERRUPT_SHARE`** |
| | `INTERRUPT_HINT_PAUSE = 2` | 暂停，临时失去焦点；焦点可用时会再收到 RESUME |
| | `INTERRUPT_HINT_STOP = 3` | 停止，彻底失去焦点，不会再收到焦点事件 |
| | `INTERRUPT_HINT_DUCK = 4` | 降低音量播放（默认降到 20%） |
| | `INTERRUPT_HINT_UNDUCK = 5` | 恢复正常音量 |
| | `INTERRUPT_HINT_MUTE = 6` / `INTERRUPT_HINT_UNMUTE = 7` | API 20+ ⚠️ |

### 2.3 焦点模式 `InterruptMode` 与"在哪声明"

| 名称 | 值 | 含义 |
| --- | --- | --- |
| `audio.InterruptMode.SHARE_MODE` | 0 | 共享焦点模式（**默认**）。同一应用的多个音频流共享一个焦点，流间并发规则由应用自定，焦点策略只在**跨应用**时介入 |
| `audio.InterruptMode.INDEPENDENT_MODE` | 1 | 独立焦点模式。每条流独立持有焦点，多流同时播放会触发焦点策略管理 |

设置方式（**唯一的正确方式**）：

```ts
avPlayer.audioInterruptMode = audio.InterruptMode.SHARE_MODE;    // 或 INDEPENDENT_MODE
// 限定在 prepared/playing/paused/completed 状态；应在第一次 play() 之前设置
```

> ⚠️ **`interruptMode` 不在 `module.json5` 里声明**。它不是 `requestPermissions` 项，也不是 ability 的 `metadata`。已全量检索 zh-cn 文档：`InterruptMode` 只出现在 AVPlayer 属性、AudioRenderer 的 `setInterruptMode()`、以及 OHAudio 的 `OH_AVPlayer_SetAudioInterruptMode` / `OH_AudioStreamBuilder_SetRendererInterruptMode` 中。请按上面的属性赋值实现。

### 2.4 `audio.AudioSessionManager`（自定义焦点策略，API 12+）

**获取方式（`getInstance` 不存在 ⚠️）：**

```ts
import { audio } from '@kit.AudioKit';

let audioManager = audio.getAudioManager();
let audioSessionManager: audio.AudioSessionManager = audioManager.getSessionManager();  // API 12+
```

| 成员 | 精确签名 | 起始 |
| --- | --- | --- |
| `activateAudioSession` | `activateAudioSession(strategy: AudioSessionStrategy): Promise<void>` | API 12 |
| `deactivateAudioSession` | `deactivateAudioSession(): Promise<void>` | API 12 |
| `isAudioSessionActivated` | `isAudioSessionActivated(): boolean` | API 12 |
| `on('audioSessionDeactivated')` | `on(type: 'audioSessionDeactivated', callback: Callback<AudioSessionDeactivatedEvent>): void` | API 12 |
| `off('audioSessionDeactivated')` | `off(type: 'audioSessionDeactivated', callback?: Callback<AudioSessionDeactivatedEvent>): void` | API 12 |
| `setAudioSessionScene` | `setAudioSessionScene(scene: AudioSessionScene): void` | **API 20** ⚠️ |
| `on('audioSessionStateChanged')` | `on(type: 'audioSessionStateChanged', callback: Callback<AudioSessionStateChangedEvent>): void` | **API 20** ⚠️ |
| `setDefaultOutputDevice` / `getDefaultOutputDevice` / `on('currentOutputDeviceChanged')` | — | API 20 ⚠️ |

> ⚠️ **`AudioSessionManager` 上没有 `on('audioInterrupt')`**。`audioInterrupt` 是 **AVPlayer / AudioRenderer** 的事件。`AudioSessionManager` 的事件名是 `'audioSessionDeactivated'`（12+）与 `'audioSessionStateChanged'`（20+）——注意是 `StateChanged` 不是 `StateChange`。
> ⚠️ **`setAudioSessionScene` 与 `AudioSessionScene` 是 API 20+，API 14/15 上不可用。** API 14/15 只能用 `activateAudioSession(strategy)` 改焦点策略。

相关类型：

```ts
interface AudioSessionStrategy { concurrencyMode: AudioConcurrencyMode; }   // API 12+
```

| `AudioConcurrencyMode` | 值 | 含义 |
| --- | --- | --- |
| `CONCURRENCY_DEFAULT` | 0 | 用系统默认焦点策略 |
| `CONCURRENCY_MIX_WITH_OTHERS` | 1 | 与其它音频混音 |
| `CONCURRENCY_DUCK_OTHERS` | 2 | 压低其它音频音量 |
| `CONCURRENCY_PAUSE_OTHERS` | 3 | 暂停其它音频 |

```ts
// API 12+ 可用（API 14/15 推荐用法）
let strategy: audio.AudioSessionStrategy = {
  concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT
};
audioSessionManager.activateAudioSession(strategy).then(() => { /* ok */ });

// 会话被非主动停用时
audioSessionManager.on('audioSessionDeactivated', (e: audio.AudioSessionDeactivatedEvent) => {
  // e.reason: DEACTIVATED_LOWER_PRIORITY（焦点被抢占）| DEACTIVATED_TIMEOUT（无流运行超时）
});
```

`AudioSessionScene`（**API 20+，API 14/15 不可用 ⚠️**）：`AUDIO_SESSION_SCENE_MEDIA = 0`（媒体）、`AUDIO_SESSION_SCENE_GAME = 1`（游戏）、`AUDIO_SESSION_SCENE_VOICE_COMMUNICATION = 2`（VoIP）。

两种用法（官方模型）：
1. **修改焦点策略**：激活会话 → 新起的流按新策略起流。**AudioSession 不持有焦点**，焦点仍由各音频流持有。需要在**音频流启动前**激活，否则不生效。
2. **用 AudioSession 申请焦点**（API 20+ 的 scene 机制）：焦点由 AudioSession 持有，后续播放流不再申请焦点；结束须主动 `deactivateAudioSession()` 释放。

并发策略优先级：`STOP > PAUSE > DUCK > PLAYBOTH`；当指定的会话策略优先级高于默认策略时，指定策略不会生效。

---

## 3. 后台播放（长时任务）

### 3.1 官方接入规范（必须满足）

- 后台播放**媒体类**流（`STREAM_USAGE_MUSIC` / `STREAM_USAGE_MOVIE` / `STREAM_USAGE_AUDIOBOOK`）或**游戏类**（`STREAM_USAGE_GAME`）时：**必须接入 AVSession 并申请 `AUDIO_PLAYBACK` 类型长时任务**。
- 其它用户可感知的播放任务：只需申请 `AUDIO_PLAYBACK` 长时任务，无需接入 AVSession。
- **不满足规范**：退后台播放会被系统**静音并冻结**，切回前台才解除静音并恢复。
- 申请 `AUDIO_PLAYBACK` 但不接入 AVSession：API 20 起长时任务申请成功后通知栏会显示通知；接入 AVSession 后由 AVSession 发通知（API 19 及之前后台任务模块不发通知）。
- 申请了 `AUDIO_PLAYBACK`，退后台时**若没有有效音频播放**，应用可能被系统冻结。

### 3.2 权限与 `module.json5`

必需权限：**`ohos.permission.KEEP_BACKGROUND_RUNNING`**（`startBackgroundRunning` / `stopBackgroundRunning` / `on('continuousTaskCancel')` 均标注此权限）。

Stage 模型：**长时任务仅支持 UIAbility 申请**（FA 模型才用 ServiceAbility）。**必须**在 `module.json5` 的 `abilities[].backgroundModes` 里声明类型配置项，`audioPlayback` 对应 `AUDIO_PLAYBACK`。

### 3.3 申请 / 取消接口（精确签名）

| 接口 | 签名 | 起始 |
| --- | --- | --- |
| 申请（单类型，Promise） | `startBackgroundRunning(context: Context, bgMode: BackgroundMode, wantAgent: WantAgent): Promise<void>` | API 9 |
| 申请（单类型，callback） | `startBackgroundRunning(context: Context, bgMode: BackgroundMode, wantAgent: WantAgent, callback: AsyncCallback<void>): void` | API 9 |
| 申请（多类型，**推荐**） | `startBackgroundRunning(context: Context, bgModes: string[], wantAgent: WantAgent): Promise<ContinuousTaskNotification>` | API 12 |
| 取消 | `stopBackgroundRunning(context: Context): Promise<void>` / `stopBackgroundRunning(context: Context, callback: AsyncCallback<void>): void` | API 9 |
| 监听取消 | `on(type: 'continuousTaskCancel', callback: Callback<ContinuousTaskCancelInfo>): void` | API 15 |
| 监听暂停 | `on(type: 'continuousTaskSuspend', callback: Callback<ContinuousTaskSuspendInfo>): void` | API 20 ⚠️ |

**`BackgroundMode` 枚举（API 14/15 使用这个）：**

```ts
backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK   // = 2，音视频播放
backgroundTaskManager.BackgroundMode.DATA_TRANSFER    // = 1
backgroundTaskManager.BackgroundMode.AUDIO_RECORDING  // = 3
backgroundTaskManager.BackgroundMode.LOCATION         // = 4
backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION // = 5
backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION // = 6
backgroundTaskManager.BackgroundMode.VOIP             // = 8 (API 13+)
backgroundTaskManager.BackgroundMode.TASK_KEEPING     // = 9
```

> ⚠️ **`BackgroundTaskMode` 是 API 21+ 才引入的新枚举**（成员为 `MODE_AUDIO_PLAYBACK = 2` 等），**API 14/15 上不存在**。API 14/15 的常量名是 `backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK`；多类型接口则传字符串数组 `['audioPlayback']`（取值来自长时任务类型表的"配置项"列）。

调用样例（API 14/15 可用，`@kit.BackgroundTasksKit`）：

```ts
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const wantAgentInfo: wantAgent.WantAgentInfo = {
  wants: [{ bundleName: 'com.example.music', abilityName: 'EntryAbility' }],
  actionType: wantAgent.OperationType.START_ABILITY,
  requestCode: 0,
  actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
};
const wantAgentObj: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);

// 方式一：单类型枚举
await backgroundTaskManager.startBackgroundRunning(ctx,
  backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wantAgentObj);

// 方式二：多类型字符串数组（API 12+，返回 ContinuousTaskNotification）
const res: backgroundTaskManager.ContinuousTaskNotification =
  await backgroundTaskManager.startBackgroundRunning(ctx, ['audioPlayback'], wantAgentObj);

// 取消
await backgroundTaskManager.stopBackgroundRunning(ctx);
```

### 3.4 取消原因监听（API 15+）

```ts
function onCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo) {
  // info.id     : number  被取消的长时任务 Id
  // info.reason : ContinuousTaskCancelReason
}

backgroundTaskManager.on('continuousTaskCancel', onCancel);
// backgroundTaskManager.off('continuousTaskCancel', onCancel);
```

`ContinuousTaskCancelInfo`（API 15+）：`{ reason: ContinuousTaskCancelReason; id: number; detailedReason?: ContinuousTaskDetailedCancelReason /* API 26+ */ }`。

`ContinuousTaskCancelReason`（API 15+）：

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `USER_CANCEL` | 1 | 用户取消 |
| `SYSTEM_CANCEL` | 2 | 系统取消 |
| `USER_CANCEL_REMOVE_NOTIFICATION` | 3 | 用户移除通知（预留，暂未启用） |
| `SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED` | 4 | 数据传输速率低（预留） |
| `SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION` | 5 | 申请 AUDIO_PLAYBACK 但未接入 AVSession（预留） |
| `SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING` | 6 | 申请 AUDIO_PLAYBACK 但未播放音视频（预留） |
| `SYSTEM_CANCEL_AUDIO_RECORDING_NOT_RUNNING` | 7 | 申请 AUDIO_RECORDING 但未录制（预留） |
| `SYSTEM_CANCEL_NOT_USE_LOCATION` | 8 | 申请 LOCATION 但未用定位（预留） |
| `SYSTEM_CANCEL_NOT_USE_BLUETOOTH` | 9 | 蓝牙未使用（预留） |
| `SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE` | 10 | 多设备互联未使用（预留） |
| `SYSTEM_CANCEL_USE_ILLEGALLY` | 11 | 使用非法类型（预留） |

> 收到 `USER_CANCEL` / `SYSTEM_CANCEL` 后应停止播放并同步 UI；长时任务已不存在，恢复播放需重新申请。

### 3.5 规则 / 限制 / 生命周期

**数量限制**
- API 20 及之前：一个 UIAbility（FA 为 ServiceAbility）**同一时刻仅支持一个长时任务**，结束后才能申请下一个。要同时申请多个需创建多个 UIAbility。
- API 21+ 支持一个 UIAbility 同时申请多个，最多 10 个。

**运行限制（违规 → 挂起或终止）**
- 申请了长时任务但**未执行相应业务**（如申请 AUDIO_PLAYBACK 却没在放音乐）→ 退后台被挂起。
- 业务类型与申请类型**不一致**（只申请 AUDIO_PLAYBACK 却同时在录音）→ 退后台被挂起或终止。
- **未申请**长时任务却在后台有播放行为 → 退后台被**查杀**。
- 业务已执行完 → 退后台被挂起。
- 后台负载持续高于该类型典型负载 → 被挂起或终止。

**必须及时取消 / 重新申请（关键时序）**
- 用户点击暂停 → **及时主动取消长时任务**；再次播放 → **重新申请**。
- 音频在后台播放时被[打断]（焦点打断），**系统会自行检测并停止长时任务**；音频重启播放时需再次申请。
- 收到 AVSession 播控指令、输出设备变更等导致暂停时 → 暂停时取消、播放时重新申请。
- **停止长时任务的同时，必须暂停或停止音频流，否则应用会被系统强制终止。**
- 建议监听 AVSession 的 `on('pause')`，收到后若无需继续播放则取消已申请的长时任务。
- 建议把申请推迟到 UIAbility 的 `onBackground`，避免前台出现长时任务通知。

**通知**
- 申请成功后通知栏会出现与长时任务绑定的通知；**用户删除该通知时系统会自动停止长时任务**。
- 通知弹窗生命周期与申请周期绑定，任务取消通知即撤销。

**没有"固定时长上限"**：AUDIO_PLAYBACK 无绝对超时；只有 DATA_TRANSFER 有"首次进度更新超过 10 分钟未更新则取消"的规则（音乐播放器不适用）。`TASK_KEEPING`（计算任务）在 API 20 及之前仅对 PC/2in1 开放。

### 3.6 是否需要 `MediaControlExtensionAbility`？

> ⚠️ **官方 zh-cn 文档（含 `module-configuration-file.md` 的 ExtensionAbility `type` 取值表、AVSession Kit 全套文档、背景任务文档）中不存在 `MediaControlExtensionAbility`。**
> `extensionAbilities[].type` 的合法取值里没有任何 media 相关的类型。

文档明确要求的**替代方案**是：
1. **接入 AVSession**（`@kit.AVSessionKit`）：创建/激活 AVSession，`setAVMetadata`（标题、副标题/歌手、封面图），注册控制命令（至少 播放/暂停），并在整个后台播放期间**保持 AVSession 对象实例存活**（不要用局部变量保存，避免被回收）。
2. **申请 `AUDIO_PLAYBACK` 长时任务**。
3. 二者同时满足后，系统播控中心会自动展示并发送通知与控制事件；AVSession 会对后台媒体播放形成约束，未创建 AVSession 就做上述播放业务时，系统检测到退后台会**停止播放**。

`module.json5` 中与 AVSession 相关的额外配置，在本文档范围内**没有**任何必需项（AVSession 是运行时接口，不是配置文件声明项）。

---

## 4. `StreamUsage` / `SourceType` / `AudioRendererInfo`

### 4.1 音乐播放器推荐值

```ts
import { audio } from '@kit.AudioKit';

avPlayer.audioRendererInfo = {
  usage: audio.StreamUsage.STREAM_USAGE_MUSIC,  // 音乐
  rendererFlags: 0
} as audio.AudioRendererInfo;   // 必须在 initialized 状态、第一次 prepare() 之前
```

- `AudioRendererInfo` 结构：`{ content?: ContentType /* 已废弃 */; usage: StreamUsage; rendererFlags: number; volumeMode?: AudioVolumeMode /* API 19+ */ }`。`rendererFlags` 设为 `0`。
- **默认值**：媒体源含视频 → `usage` 默认 `STREAM_USAGE_MOVIE`；否则默认 `STREAM_USAGE_MUSIC`；`rendererFlags` 默认 `0`。
- 纯音频音乐播放器不设也能工作，但**建议显式设置**，以保证音量类型 / 焦点策略 / 输出设备选择符合预期。

`StreamUsage` 相关取值（audio kit）：

| 名称 | 值 | 场景 |
| --- | --- | --- |
| `STREAM_USAGE_MUSIC` | 1 | 音乐（**音乐播放器选这个**）。音量类型 = 媒体音量 MEDIA；默认输出设备 = 扬声器；可触发低功耗渲染器 |
| `STREAM_USAGE_MOVIE` | 10 | 短视频 / 电影 / 电视剧 |
| `STREAM_USAGE_AUDIOBOOK` | 12 | 有声读物、听书、新闻、播客。同样可触发低功耗渲染器 |
| `STREAM_USAGE_GAME` | 11 | 游戏配乐；与 Music 可混音 |
| `STREAM_USAGE_NAVIGATION` | 13 | 导航播报（会让 Music 降音量） |
| `STREAM_USAGE_VOICE_COMMUNICATION` | 2 | VoIP（会暂停 Music） |
| `STREAM_USAGE_VOICE_MESSAGE` | 5 | 语音短消息 |
| `STREAM_USAGE_ALARM` | 4 | 闹铃 |
| `STREAM_USAGE_RINGTONE` | 6 | 铃声 |
| `STREAM_USAGE_NOTIFICATION` | 7 | 通知音 |

低功耗播放提示：`STREAM_USAGE_MUSIC` / `STREAM_USAGE_AUDIOBOOK` 时系统默认使用低功耗渲染器（API 11+ 支持），熄屏缓存最大 10000ms，亮屏最大 1000ms；熄屏数据写满后主处理器休眠、应用进入挂起，因此**必须**配合后台播放规范（AVSession + 长时任务）。

`SourceType`（**录制**流类型，音乐播放器用不到，列出以免误用）：`SOURCE_TYPE_MIC`、`SOURCE_TYPE_VOICE_RECOGNITION`、`SOURCE_TYPE_VOICE_COMMUNICATION`、`SOURCE_TYPE_VOICE_MESSAGE`、`SOURCE_TYPE_CAMCORDER`（13+）、`SOURCE_TYPE_UNPROCESSED`（14+）、`SOURCE_TYPE_LIVE`（20+）。

### 4.2 音量

- 播放流的 `StreamUsage` 决定其所属**音量类型**：MUSIC/MOVIE/AUDIOBOOK/GAME → 媒体音量（MEDIA）。
- `AVPlayer.setVolume(volume: number)` 调节的是**播放器相对音量** `[0.00, 1.00]`，与系统媒体音量相互独立、相乘生效。

---

## 5. 音频输出设备变化（拔出耳机等）

### 5.1 AVPlayer 侧事件（API 11+，API 14/15 可用）

```ts
import { audio } from '@kit.AudioKit';

avPlayer.on('audioOutputDeviceChangeWithInfo', (data: audio.AudioStreamDeviceChangeInfo) => {
  switch (data.changeReason) {
    case audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE:
      // 旧设备不可用（耳机拔出、蓝牙断开、分布式设备下线）
      // 官方建议：报告此原因时应考虑暂停音频播放
      break;
    case audio.AudioStreamDeviceChangeReason.REASON_NEW_DEVICE_AVAILABLE:
      // 新设备可用（耳机插入、蓝牙连接/佩戴、分布式设备上线）→ 继续播放
      break;
    case audio.AudioStreamDeviceChangeReason.REASON_OVERRODE:
      // 用户强制选择设备
      break;
    case audio.AudioStreamDeviceChangeReason.REASON_UNKNOWN:
      break;
    case audio.AudioStreamDeviceChangeReason.REASON_SESSION_ACTIVATED:      // 4，API 20+ ⚠️
    case audio.AudioStreamDeviceChangeReason.REASON_STREAM_PRIORITY_CHANGED: // 5，API 20+ ⚠️
      break;
  }
});
```

`AudioStreamDeviceChangeInfo`（API 11+）：`{ devices: AudioDeviceDescriptors; changeReason: AudioStreamDeviceChangeReason }`。`devices` 为数组，一般只含一个设备。

### 5.2 推荐行为（官方"响应输出设备变更时合理暂停"）

| `changeReason` | 触发场景 | 推荐处理 |
| --- | --- | --- |
| `REASON_OLD_DEVICE_UNAVAILABLE = 2` | 蓝牙断开、佩戴检测摘下、3.5mm/Type-C/USB 耳机拔出、分布式设备下线 | **音乐场景：暂停播放**并更新 UX 界面（听书/视频同样暂停；游戏场景不暂停） |
| `REASON_NEW_DEVICE_AVAILABLE = 1` | 蓝牙连接/佩戴、有线耳机插入、分布式设备上线 | 继续播放（按业务判断） |
| `REASON_OVERRODE = 3` | 用户从界面强选设备、外设接听来电 | 按业务处理 |
| `REASON_UNKNOWN = 0` | 未知 | 按业务处理 |

- 暂停时要**同时取消长时任务**；恢复播放时**重新申请**。
- API 20+ 另有 `OutputDeviceChangeRecommendedAction`（`DEVICE_CHANGE_RECOMMEND_TO_CONTINUE = 0` / `DEVICE_CHANGE_RECOMMEND_TO_STOP = 1`）以及 `AudioSessionManager.on('currentOutputDeviceChanged')`；**API 14/15 只能用上面的 AVPlayer 事件**。
- AudioRenderer 侧对应事件为 `on('outputDeviceChangeWithInfo')`（API 11+），音乐播放器用 AVPlayer 事件即可。

---

## 6. `module.json5` 完整片段

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "deviceTypes": ["phone", "tablet"],
    // …
    "requestPermissions": [
      // 在线音源（http/https/HLS）必需
      { "name": "ohos.permission.INTERNET" },
      // 后台/熄屏播放必需（长时任务）
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",
        "reason": "$string:reason_keep_background_running",
        "usedScene": {
          "abilities": ["EntryAbility"],
          "when": "always"           // 后台播放属于 always；前台短时间内播放可用 inuse
        }
      }
      // 可选：读取用户媒体（音乐文件）时才需要；纯媒体库/文件选择器方案下通常由 picker 授权，无需声明
      // { "name": "ohos.permission.READ_MEDIA" },
      // 可选：仅当需要读取图片/视频的地理位置信息（EXIF 定位）时才有意义，音乐播放器一般不需要
      // { "name": "ohos.permission.MEDIA_LOCATION" },
      // 若在线播放需要判断 Wi-Fi 状态（示例工程附带）
      // { "name": "ohos.permission.GET_WIFI_INFO" }
    ],
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "launchType": "singleton",
        "exported": true,
        // 长时任务类型配置项：audioPlayback 对应 BackgroundMode.AUDIO_PLAYBACK
        "backgroundModes": [
          "audioPlayback"
        ],
        // 注意：interruptMode（SHARE_MODE / INDEPENDENT_MODE）不在这里声明，
        // 而是在代码中通过 avPlayer.audioInterruptMode 属性设置（见 2.3 节）。
        "metadata": [],
        "skills": [
          {
            "actions": ["ohos.want.action.home"],
            "entities": ["entity.system.home"]
          }
        ]
      }
    ]
  }
}
```

权限说明汇总：

| 权限 | 是否必需 | 用途 |
| --- | --- | --- |
| `ohos.permission.INTERNET` | 在线播放时必需 | 网络媒体资源 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 后台/熄屏播放必需 | 长时任务（`startBackgroundRunning` 等接口的权限要求） |
| `ohos.permission.READ_MEDIA` | 视方案而定 | 读取用户媒体文件（相册/媒体库方式） |
| `ohos.permission.MEDIA_LOCATION` | 通常不需要 | 读取媒体的地理位置信息，与音频播放无关 |
| `ohos.permission.GET_WIFI_INFO` | 可选 | 判断 Wi-Fi 状态（示例工程使用） |

> ⚠️ 任何**音频焦点相关**的配置项都**不在** `module.json5` 中。

---

## 7. `AudioEngine` 骨架（ArkTS，约 150 行）

> 说明：本骨架覆盖"纯播放引擎"职责（AVPlayer 状态机 / 事件 / 打扰 / 后台任务）。
> ⚠️ 若 `StreamUsage` 为 `STREAM_USAGE_MUSIC/MOVIE/AUDIOBOOK/GAME` 且需要后台播放，官方规范**还要求接入 AVSession**（`@kit.AVSessionKit`：创建会话 → 设置元数据 → 注册 play/pause 控制命令 → 保持实例存活）。本骨架未包含 AVSession，请在 `play()` 成功后补齐；否则退后台会被静音冻结。

```ts
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

type EngineState = 'idle' | 'initialized' | 'prepared' | 'playing' | 'paused' | 'completed' | 'stopped' | 'released' | 'error';

export class AudioEngine {
  private player: media.AVPlayer | null = null;
  private ctx: common.UIAbilityContext;
  private state: EngineState = 'idle';
  private seeking = false;                 // seek 期间忽略 timeUpdate，避免进度条回弹
  private lastTick = 0;                    // timeUpdate 节流（ms 时间戳）
  private bgTaskOn = false;                // 长时任务是否已申请
  private pausedByInterrupt = false;       // 是否因焦点打断而暂停（用于 RESUME 判断）

  // 对外回调，播放器 UI 层实现
  public onState?: (s: EngineState) => void;
  public onTime?: (positionMs: number, durationMs: number) => void;
  public onError?: (code: number, msg: string) => void;
  public onNext?: () => void;              // 播完自动切下一首
  public onPrev?: () => void;

  constructor(ctx: common.UIAbilityContext) { this.ctx = ctx; }

  // 1) 创建 + 挂事件（必须在设置资源之前）
  async init(): Promise<void> {
    this.player = await media.createAVPlayer();
    const p = this.player;

    p.on('stateChange', (s: string, reason: media.StateChangeReason) => {
      this.state = s as EngineState;
      if (s === 'completed') { this.stopBackgroundTask(); this.onNext?.(); }
      if (s === 'error') { this.onError?.(-1, 'player error state'); void this.reset(); }
      this.onState?.(this.state);
    });

    p.on('error', (e: BusinessError) => { this.onError?.(e.code, e.message); });

    p.on('durationUpdate', (duration: number) => {         // 单位 ms
      this.onTime?.(this.player?.currentTime ?? 0, duration);
    });

    p.on('timeUpdate', (time: number) => {                 // 单位 ms，默认 100ms 上报
      if (this.seeking) return;                            // 官方要求：等 seekDone 后再刷新进度
      const now = Date.now();
      if (now - this.lastTick < 250) return;               // 节流到 250ms，降低 UI 刷新频率
      this.lastTick = now;
      this.onTime?.(time, this.player?.duration ?? 0);
    });

    p.on('seekDone', (t: number) => { this.seeking = false; this.onTime?.(t, this.player?.duration ?? 0); });
    p.on('endOfStream', () => { /* completed 状态随后到达，切歌逻辑在 stateChange 中处理 */ });

    p.on('audioInterrupt', (info: audio.InterruptEvent) => {
      if (info.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        if (info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
            info.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
          // 系统已暂停/停止本流：同步状态与后台任务
          this.pausedByInterrupt = info.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE;
          this.state = 'paused';
          this.stopBackgroundTask();
          this.onState?.(this.state);
        }
        // DUCK / UNDUCK 由系统完成，无需改动播放状态
      } else if (info.forceType === audio.InterruptForceType.INTERRUPT_SHARE &&
                 info.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        if (this.pausedByInterrupt) { this.pausedByInterrupt = false; void this.play(); }
      }
    });

    p.on('audioOutputDeviceChangeWithInfo', (data: audio.AudioStreamDeviceChangeInfo) => {
      if (data.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
        void this.pause();   // 音乐场景：耳机拔出等旧设备不可用 → 暂停
      }
    });

    // 焦点模式：默认 SHARE_MODE。注意这是属性赋值，不是 module.json5 配置。
    // p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;   // 需在 prepared 之后、首次 play() 之前
  }

  // 2) 加载音源（只在 idle 调用）：url / fdSrc / dataSrc 三选一
  async load(url: string): Promise<void> {
    if (!this.player || this.state !== 'idle') await this.reset();
    if (!this.player) return;
    this.player.audioRendererInfo = {          // 只允许在 initialized 状态、首次 prepare 之前
      usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
      rendererFlags: 0
    } as audio.AudioRendererInfo;
    this.player.url = url;                     // 赋值成功 → initialized
    // 等价写法：this.player.setPlaybackStrategy({ preferredBufferDuration: 5 });  // 单位秒
  }

  async prepare(): Promise<void> { await this.player?.prepare(); }   // initialized → prepared

  // 3) 播控
  async play(): Promise<void> {                                       // prepared/paused/completed → playing
    if (!this.player) return;
    await this.player.play();
    await this.startBackgroundTask();                                 // 播放即申请长时任务
  }

  async pause(): Promise<void> {                                      // 仅 playing → paused
    await this.player?.pause();
    await this.stopBackgroundTask();                                  // 暂停必须取消，否则会被挂起
  }

  async stop(): Promise<void> {                                       // prepared/playing/paused/completed → stopped
    await this.player?.stop();
    await this.stopBackgroundTask();
  }

  seek(positionMs: number): void {                                    // 单位 ms；prepared/playing/paused/completed
    if (!this.player) return;
    this.seeking = true;
    this.player.seek(positionMs, media.SeekMode.SEEK_PREV_SYNC);      // 结果以 seekDone 为准
  }

  async reset(): Promise<void> { await this.stopBackgroundTask(); await this.player?.reset(); this.state = 'idle'; }

  async release(): Promise<void> { await this.stopBackgroundTask(); await this.player?.release(); this.player = null; this.state = 'released'; }

  setVolume(v: number): void { this.player?.setVolume(Math.max(0, Math.min(1, v))); }  // [0.00, 1.00]
  setLoop(loop: boolean): void { if (this.player) this.player.loop = loop; }           // 属性，非方法

  // 4) 后台长时任务（API 14/15：BackgroundMode.AUDIO_PLAYBACK + KEEP_BACKGROUND_RUNNING）
  private async startBackgroundTask(): Promise<void> {
    if (this.bgTaskOn) return;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: this.ctx.applicationInfo.name, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const wa: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, wa);
      this.bgTaskOn = true;
    } catch (e) { this.onError?.((e as BusinessError).code, (e as BusinessError).message); }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.bgTaskOn) return;
    try { await backgroundTaskManager.stopBackgroundRunning(this.ctx); } catch (_) { /* ignore */ }
    this.bgTaskOn = false;
  }
}
```

---

## 8. 最小正确调用顺序（照着写）

```
createAVPlayer()                    → state = idle
  ├─ on('stateChange')              ← 必须在设置资源之前
  ├─ on('error')                    ← 必须在设置资源之前
  ├─ on('durationUpdate'/'timeUpdate'/'seekDone'/'bufferingUpdate'/'endOfStream')
  ├─ on('audioInterrupt')
  └─ on('audioOutputDeviceChangeWithInfo')
avPlayer.url = 'https://…'          → state = initialized      （或 fdSrc / dataSrc / setMediaSource）
avPlayer.audioRendererInfo = { usage: STREAM_USAGE_MUSIC, rendererFlags: 0 }   （仅 initialized）
avPlayer.setPlaybackStrategy({ preferredBufferDuration: 5 })                   （仅 initialized）
avPlayer.audioInterruptMode = audio.InterruptMode.SHARE_MODE                   （prepared 后、首次 play 前）
prepare()                           → state = prepared          （此时 duration 有效）
play()                              → state = playing
  └─ startBackgroundRunning(ctx, BackgroundMode.AUDIO_PLAYBACK, wantAgent)     （KEEP_BACKGROUND_RUNNING）
pause()                             → state = paused
  └─ stopBackgroundRunning(ctx)     （暂停必须取消长时任务）
seek(ms)                            → 等 on('seekDone') 再更新进度条
（播放到结尾）                       → on('endOfStream') 且 state = completed → 切下一首
reset()                             → state = idle（可重新设置 url 换歌）
release()                           → state = released（退出播放）
```

## 9. 已知不确定 / 需实测项（⚠️）

1. `PlaybackInfo`、`getTrackDescription` 等次要接口的字段单位未在本文逐条展开；音乐播放器主链路不需要。
2. `bufferingUpdate` 的 `BUFFERING_PERCENT` 官方只写"缓冲百分比"，未明确 0–100 还是 0–1，建议实测或直接用 `CACHED_DURATION`（明确为 ms）。
3. 长时任务通知的具体 UI 形态由系统控制，文档未给出可定制内容（除 API 12+ 返回的 `notificationId` 供上传下载类更新实况窗，音乐场景无需使用）。
4. `ohos.permission.READ_MEDIA` 是否需要，取决于本地音乐文件的获取方式（媒体库 API vs 文件选择器）；本文档未下载 `security/AccessToken` 权限列表，请按最终选型确认。
5. `MediaControlExtensionAbility` 在本次抓取的 OpenHarmony zh-cn 文档中**查无此物**；如 HarmonyOS 商业版另有该能力，需以华为侧文档为准。
