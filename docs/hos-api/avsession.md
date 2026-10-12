# AVSession Kit（音视频播控服务）实现速查

> 本文是从本地已下载的 OpenHarmony 官方 markdown 文档中**逐字摘录 + 归纳**得到的唯一参考文件，用于实现 ArkTS 音乐播放器接入系统播控中心。
> 文档基线：AVSession 首批接口 API 9，`AVSession` Interface 首批 API 10；桌面歌词/音频模板等为 API 23+。
>
> **⚠️ 来源约束（务必先读）**
> 1. 本文档只覆盖本地 `_docs` 中的 OpenHarmony 文档。本环境中**没有** `@ohos.multimedia.avsession` 的 `js-apis-avsession*.md` 页面，本地全部文档一律只使用 **`@kit.AVSessionKit`** 方式导入。**⚠️ 本文不提供 `@ohos.multimedia.avsession` 旧式导入，因为本地文档中没有该用法的记录，不能凭空发明。**
> 2. 本地也**没有** `arkts-apis-avsession-f.md`（模块/AVSessionManager 函数页）。因此 `createAVSession`、`isDesktopLyricSupported`、`createAVMusicTemplate`、`createAVMusicTemplateController` 只有「指南页表格」和「示例代码」两处证据，它们的完整参数表以示例为准。
> 3. **⚠️ `avSession.AVSessionType` 在本地文档中是字符串字面量联合类型，不是枚举**：`type AVSessionType = 'audio' | 'video' | 'voice_call' | 'video_call' | 'photo'`。因此**不存在** `avSession.AVSessionType.AUDIO` 这个常量；音乐必须写成 `'audio'`（或先声明 `let type: avSession.AVSessionType = 'audio'`）。任何形如 `AVSessionType.AUDIO` 的写法在本地文档中**无任何证据支持**，会被本文标记为 ⚠️ 不可用。
> 4. 本地文档中**完全没有** `MediaControlExtensionAbility`、`module.json5` 中 AVSession 专用声明、以及「灵动岛」相关内容（全库检索 0 命中，见 §11）。凡涉及这些的表述都标记 ⚠️。

---

## 1. 导入与符号来源

```ts
// 【唯一被本地文档记录的导入方式】avsession-*.md 所有 "导入模块" 章节均为这一行
import { avSession } from '@kit.AVSessionKit';
import { avMusicTemplate } from '@kit.AVSessionKit'; // 音频模板（API 23+，仅 Car 设备，见 §8）
```

实践中官方示例统一使用别名 `AVSessionManager`，本文沿用：

```ts
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';          // mediaImage / avQueueImage 用 PixelMap 时
import { wantAgent } from '@kit.AbilityKit';    // setLaunchAbility 用
import { KeyEvent } from '@kit.InputKit';       // handleKeyEvent 回调参数类型
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'; // 长时任务
```

### 1.1 命名空间归属（全部挂在 `avSession` 下）

| 符号 | 形态 | 说明 |
|---|---|---|
| `avSession.createAVSession` | 函数（AVSessionManager） | 创建会话，返回 `AVSession` |
| `avSession.AVSession` | 接口/类 | 会话对象（提供方使用） |
| `avSession.AVSessionController` | 接口/类 | 控制器（控制方使用，`session.getController()` 也可拿到） |
| `avSession.AVSessionType` | **类型别名（字符串联合）** | `'audio' \| 'video' \| 'voice_call' \| 'video_call' \| 'photo'` |
| `avSession.AVMetadata` | 接口 | 媒体元数据 |
| `avSession.AVPlaybackState` | 接口 | 播放状态 |
| `avSession.PlaybackPosition` | 接口 | 播放位置 |
| `avSession.PlaybackState` | **枚举**（这里是真枚举） | 播放状态枚举 |
| `avSession.LoopMode` | 枚举 | 循环模式 |
| `avSession.AVQueueItem` / `avSession.AVMediaDescription` | 接口 | 播放列表 |
| `avSession.OutputDeviceInfo` / `avSession.DeviceInfo` / `avSession.ConnectionState` | 接口/枚举 | 输出设备 |
| `avSession.AVControlCommand` / `avSession.AVControlCommandType` / `avSession.AVCastControlCommandType` | 接口/类型 | 控制命令 |
| `avSession.CommandInfo` | 接口（22+） | 命令来源信息 |
| `avSession.DesktopLyricState` | 接口（23+） | 桌面歌词状态 |
| `avSession.DisplayTag` / `avSession.SkipIntervals` / `avSession.ProtocolType` | 枚举 | 金标 / 快进快退间隔 / 协议 |
| `avSession.AVSessionErrorCode` | 枚举 | 错误码（见 §12） |
| `avMusicTemplate.AVMusicTemplate` / `.AVMusicTemplateController` / `.AVMusicTemplateType` / `.EntityType` / `.PlaybackState` / `.Single` / `.MediaEntity` / `.PlayInfo` / `.PageMediaEntity` / `.AVMusicTemplateErrorCode` | 类/枚举/接口 | 音频模板（见 §8） |

**⚠️ 注意命名冲突**：`avSession.PlaybackState`（播控枚举）与 `avMusicTemplate.PlaybackState`（模板枚举）是**两个不同的枚举**，值也不同（模板：PREPARE=0/PLAY=1/PAUSE=2/STOP=3/COMPLETED=4/ERROR=5/BUFFERING=6）。不要混用。

---

## 2. 创建会话与生命周期

### 2.1 createAVSession（10+）

指南页接口表的原文：

```
createAVSession(context: Context, tag: string, type: AVSessionType, callback: AsyncCallback<AVSession>): void   // 10+
```

> 创建媒体会话。**一个 UIAbility 只能存在一个媒体会话，重复创建会失败。**

本地文档中该函数的两个重载形态（证据来源：接口表 + 示例代码）：

```ts
// callback 形式（接口表原文）
AVSessionManager.createAVSession(context, tag, 'audio', (data: avSession.AVSession) => { /* ... */ });

// Promise 形式（指南示例统一使用 await 形式；⚠️ f.md 页缺失，未逐字给出签名）
const session: avSession.AVSession = await AVSessionManager.createAVSession(context, 'SESSION_NAME', type);
```

参数：

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| context | `Context` | 是 | 示例取法固定为：`this.getUIContext().getHostContext() as Context` |
| tag | `string` | 是 | 会话自定义标签（示例用 `'SESSION_NAME'` / `'createNewSession'`） |
| type | `AVSessionType` | 是 | 音乐用 **`'audio'`**（⚠️ 不是 `AVSessionType.AUDIO`） |

### 2.2 `AVSession` 属性

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| `sessionId` (10+) | string | 是 | 否 | AVSession 对象唯一的会话标识 |
| `sessionType` (10+) | `AVSessionType` | 是 | 否 | 会话类型 |
| `sessionTag` (22+) | string | 是 | 否 | 会话自定义标签 |

### 2.3 生命周期

| 方法 | 签名 | 说明 |
|---|---|---|
| activate (10+) | `activate(): Promise<void>` / `activate(callback: AsyncCallback<void>): void` | 激活会话，激活后可正常使用会话 |
| deactivate (10+) | `deactivate(): Promise<void>` / `deactivate(callback): void` | 禁用当前会话的功能，可通过 activate 恢复 |
| destroy (10+) | `destroy(): Promise<void>` / `destroy(callback): void` | 销毁当前会话，使当前会话完全失效 |

错误码（三者相同）：`6600101` 会话服务端异常、`6600102` 会话不存在。

**关键顺序与约束（来自 access-scene「创建不同类型的会话」注释原文）：**

- 「**激活接口要在元数据、控制命令注册完成之后再执行**」→ 顺序必须是：`createAVSession` → `setAVMetadata` → `setAVPlaybackState` → `on(...)` 注册命令 → **最后** `activate()`。
- 「创建 AVSession 后，请先注册应用支持的控制命令，再激活 Session。」（access-scene「注册控制命令」）
- 应用退出、且不需要继续播放时：先 `off(...)` 取消监听，再 `destroy()`。
- 「需要确保 AVSession 对象实例在应用后台播放业务活动期间一直存在，避免被系统回收、释放，导致后台发声时被系统管控」→ **不要把 session 放在局部变量里**，要用成员/单例持有。

### 2.4 其它会话级方法（接口表 10+）

| 接口 | 说明 |
|---|---|
| `setAVMetadata` / `setAVPlaybackState` | 见 §3 / §4 |
| `setLaunchAbility(ability: WantAgent)` | 设置拉起 UIAbility（点播控中心卡片时拉起），用 `wantAgent.getWantAgent(...)` 构造 |
| `getController()` | 获取当前会话自身控制器 `AVSessionController` |
| `getOutputDevice()` / `getOutputDeviceSync(): OutputDeviceInfo` | 获取播放设备信息 |
| `setAVQueueItems` / `setAVQueueTitle` | 见 §5 |
| `dispatchSessionEvent(event: string, args: {[key: string]: Object})` | 即时应答型自定义事件；⚠️**不会**保存在会话对象或 AVSession 服务中 |
| `setExtras(extras: {[key: string]: Object})` | 键值对自定义数据包；**会**存在 AVSession 服务中，生命周期与会话一致，Controller 可 `getExtras` 取回 |
| `sendCustomData` (20+)、`on/off('customDataChange')` (20+) | 自定义数据收发（DSTB/DLNA 等场景） |
| `stopCasting()` / `getAllCastDisplays()` | 投播相关 |

---

## 3. 设置元数据 `setAVMetadata`

```
setAVMetadata(data: AVMetadata): Promise<void>                        // 10+
setAVMetadata(data: AVMetadata, callback: AsyncCallback<void>): void  // 10+
```

错误码：`401` 参数校验失败、`6600101` 会话服务端异常、`6600102` 会话不存在。

### 3.1 `avSession.AVMetadata` 全字段（10+，逐字抄录）

| 名称 | 类型 | 只读 | 可选 | 说明（原文摘要） |
|---|---|---|---|---|
| **assetId** | string | 否 | **否（必填）** | 媒体 ID，媒体信息的唯一标识，由应用自定义。<br>• 该属性发生变化则其他元数据属性都将被刷新。<br>• 若该属性维持不变，且不设置相应的媒体元数据信息，那么将不会更新对应的媒体元数据信息。<br>• **当该属性设为空值时，调用 setAVMetadata 将失败，返回错误码 6600101。** |
| title | string | 否 | 是 | 标题 |
| artist | string | 否 | 是 | 艺术家 |
| author | string | 否 | 是 | 专辑作者 |
| avQueueName (12+) | string | 否 | 是 | 歌单（歌曲列表）名称 |
| avQueueId (11+) | string | 否 | 是 | 歌单（歌曲列表）唯一标识 Id |
| avQueueImage (11+) | `image.PixelMap \| string` | 否 | 是 | 歌单封面图。PixelMap 或图片路径（本地/网络） |
| album | string | 否 | 是 | 专辑名称 |
| writer | string | 否 | 是 | 词作者 |
| composer | string | 否 | 是 | 作曲者 |
| duration | number | 否 | 是 | 媒体时长，单位 **毫秒（ms）** |
| mediaImage | `image.PixelMap \| string` | 否 | 是 | 图片像素数据或图片路径地址（本地/网络）。PixelMap 进则 PixelMap 出；url 进则 url 出 |
| bundleIcon (18+) | `image.PixelMap` | **是** | 是 | 应用图标像素数据。**只读，不从应用侧设置** |
| publishDate | Date | 否 | 是 | 发行日期 |
| subtitle | string | 否 | 是 | 子标题 |
| description | string | 否 | 是 | 媒体描述 |
| **lyric** | string | 否 | 是 | 媒体歌词内容。应用需将歌词内容拼接为一个字符串传入。**字符串长度需小于 40960 字节**。<br>系统支持**简单版 LRC 格式（Simple LRC format）**。歌词不规范（如重复时间戳）将导致解析失败并在系统中显示异常。 |
| singleLyricText (17+) | string | 否 | 是 | 单条媒体歌词内容（**不包含时间戳**），长度 < 40960 字节 |
| previousAssetId | string | 否 | 是 | 上一首媒体 ID |
| nextAssetId | string | 否 | 是 | 下一首媒体 ID |
| filter (11+) | number | 否 | 是 | 当前 session 支持的协议，默认 `TYPE_CAST_PLUS_STREAM`，取值参考 `ProtocolType` |
| drmSchemes (12+) | `Array<string>` | 否 | 是 | 当前 session 支持的 DRM 方案（uuid） |
| skipIntervals (11+) | `SkipIntervals` | 否 | 是 | 快进快退支持的时间间隔。默认 `SECONDS_15`（15 秒） |
| displayTags (11+) | number | 否 | 是 | 媒体资源金标类型，取值参考 `DisplayTag`（目前只有 `TAG_AUDIO_VIVID = 1`） |
| rewindSkipIntervals | `SkipIntervals` | 否 | 是 | 快退间隔，默认 SECONDS_15；系统使用此值而非 skipIntervals。**起始版本 26.0.0**，仅 Stage 模型 ⚠️（本工程 API 14/15 不可用） |
| fastForwardSkipIntervals | `SkipIntervals` | 否 | 是 | 快进间隔，同上，起始版本 26.0.0 ⚠️ |

**要点：**
- 除 `assetId` 外**全部可选**；本地文档中没有「必填 title/artist/mediaImage」的接口级约束，但 §10 的后台播放接入规范**要求**至少设置「标题、副标题/歌手、封面图」。
- `assetId` 变化会整体刷新；`assetId` 不变时，**未传的字段不会被清空/更新**。切歌必须换 `assetId`。
- 进度条要显示，必须同时给 `metadata.duration` + `AVPlaybackState.position/speed/state`（见 §4.3）。
- 歌词接入：设置 `lyric`（LRC，含时间标签）后，播控中心会解析并按播放进度同步刷新；`singleLyricText` 用于单条无时间戳歌词。

### 3.2 官方示例（逐字，含注释）

```ts
let metadata: avSession.AVMetadata = {
  assetId: "121278",
  title: "lose yourself",
  artist: "Eminem",
  author: "ST",
  album: "Slim shady",
  writer: "ST",
  composer: "ST",
  duration: 2222,
  mediaImage: "https://www.example.com/example.jpg",
  subtitle: "8 Mile",
  description: "Rap",
  // LRC中有两类元素：一种是时间标签+歌词，一种是ID标签。
  // 例如：[00:25.44]xxx\r\n[00:26.44]xxx\r\n
  lyric: "lrc格式歌词内容",
  // singleLyricText字段存储单条歌词文本，不包含时间戳。
  singleLyricText: "单条歌词内容",
  previousAssetId: "121277",
  nextAssetId: "121279"
};
currentAVSession.setAVMetadata(metadata).then(() => {
  console.info('Succeeded in setting AVMetadata.');
});
```

---

## 4. 设置播放状态 `setAVPlaybackState`

```
setAVPlaybackState(state: AVPlaybackState): Promise<void>                        // 10+
setAVPlaybackState(state: AVPlaybackState, callback: AsyncCallback<void>): void  // 10+
```

错误码：`401`、`6600101`、`6600102`。

### 4.1 `avSession.AVPlaybackState` 全字段（10+，逐字抄录）

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| state | `PlaybackState` | 否 | 是 | 播放状态 |
| speed | number | 否 | 是 | 播放倍速 |
| position | `PlaybackPosition` | 否 | 是 | 播放位置 |
| bufferedTime | number | 否 | 是 | 缓冲时间 |
| loopMode | `LoopMode` | 否 | 是 | 循环模式 |
| isFavorite | boolean | 否 | 是 | 是否收藏。true 收藏，false 不收藏 |
| activeItemId | number | 否 | 是 | 正在播放的媒体 Id |
| volume | number | 否 | 是 | 正在播放的媒体音量 |
| maxVolume (11+) | number | 否 | 是 | 最大音量 |
| muted (11+) | boolean | 否 | 是 | 当前是否是静音状态 |
| duration (11+) | number | 否 | 是 | 当前媒体资源的时长 |
| videoWidth (11+) | number | 否 | 是 | 视频宽度（px） |
| videoHeight (11+) | number | 否 | 是 | 视频高度（px） |
| extras | `{[key: string]: Object;}` | 否 | 是 | 自定义媒体数据 |

**全部字段都是可选的**（含 `state`）。

### 4.2 `avSession.PlaybackPosition`（10+，两个字段都是必填）

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| elapsedTime | number | 否 | 否 | 已用时间，单位毫秒（ms） |
| updateTime | number | 否 | 否 | 更新时间，单位毫秒（ms） |

### 4.3 进度条模型（access-scene 原文要点）

- 播控中心**自行按上报信息推算进度**，应用**不需要实时刷新 position**；但 **`state` / `position` / `speed` 任何一个变化时必须重新上报**，否则系统会计算错误。
- 播放真正开始后再上报起始 position；若处于缓冲，可先上报 `PLAYBACK_STATE_BUFFERING` 通知系统不刷新进度。
- 官方示例：

```ts
let playbackState: avSession.AVPlaybackState = {
  state: avSession.PlaybackState.PLAYBACK_STATE_PLAY, // 播放状态
  position: {
    elapsedTime: 1000,                // 已经播放的位置，以ms为单位
    updateTime: new Date().getTime(), // 应用更新当前位置时的时间戳，以ms为单位
  },
  speed: 1.0,        // 可选，默认1.0，按应用内支持的speed设置，系统不做校验
  bufferedTime: 14000, // 可选，资源缓存的时间，以ms为单位
};
```
- 不支持试听的歌曲：把 `duration` 设为 **-1**，通知系统不显示实际时长。
- 试听片段：只设试听时长时，收到的 seek 是「试听片段内的相对时间戳」，应用需自行换算绝对时间。

### 4.4 `avSession.PlaybackState` 枚举（10+，逐一列出，含值）

| 名称 | 值 | 说明 |
|---|---|---|
| PLAYBACK_STATE_INITIAL | 0 | 初始状态 |
| PLAYBACK_STATE_PREPARE | 1 | 播放准备状态 |
| PLAYBACK_STATE_PLAY | 2 | 正在播放 |
| PLAYBACK_STATE_PAUSE | 3 | 暂停 |
| PLAYBACK_STATE_FAST_FORWARD | 4 | 快进 |
| PLAYBACK_STATE_REWIND | 5 | 快退 |
| PLAYBACK_STATE_STOP | 6 | 停止 |
| PLAYBACK_STATE_COMPLETED | 7 | 播放完成 |
| PLAYBACK_STATE_RELEASED | 8 | 释放 |
| PLAYBACK_STATE_ERROR | 9 | 错误 |
| PLAYBACK_STATE_IDLE (11+) | 10 | 空闲 |
| PLAYBACK_STATE_BUFFERING (11+) | 11 | 缓冲 |

### 4.5 `avSession.LoopMode` 枚举（10+）

| 名称 | 值 | 说明 |
|---|---|---|
| LOOP_MODE_SEQUENCE | 0 | 顺序播放 |
| LOOP_MODE_SINGLE | 1 | 单曲循环 |
| LOOP_MODE_LIST | 2 | 表单循环 |
| LOOP_MODE_SHUFFLE | 3 | 随机播放 |
| LOOP_MODE_CUSTOM (11+) | 4 | 自定义播放 |

### 4.6 其它相关枚举（按需）

- `avSession.SkipIntervals`（11+，Core 能力）：`SECONDS_10 = 10` / `SECONDS_15 = 15` / `SECONDS_30 = 30`。
- `avSession.DisplayTag`（11+）：`TAG_AUDIO_VIVID = 1`。
- `avSession.ConnectionState`（10+）：`STATE_CONNECTING = 0` / `STATE_CONNECTED = 1` / `STATE_DISCONNECTED = 6`。
- `avSession.ProtocolType`（11+，AVCast 能力）：`TYPE_LOCAL = 0` / `TYPE_CAST_PLUS_STREAM = 2` / `TYPE_DLNA = 4`(12+) / `TYPE_CAST_PLUS_AUDIO = 8`(20+)。
- `avSession.DeviceType`：`DEVICE_TYPE_LOCAL = 0` / `DEVICE_TYPE_BLUETOOTH = 10` / `DEVICE_TYPE_TV = 2` / `DEVICE_TYPE_SMART_SPEAKER = 3`。
- `avSession.BackgroundPlayMode`（**24+**，⚠️ 本工程 API 14/15 不可用）：`ENABLE_BACKGROUND_PLAY = 0` / `DISABLE_BACKGROUND_PLAY = 1`。

---

## 5. 播放列表：`setAVQueueItems` / `setAVQueueTitle`

```
setAVQueueItems(items: Array<AVQueueItem>): Promise<void>
setAVQueueItems(items: Array<AVQueueItem>, callback: AsyncCallback<void>): void
setAVQueueTitle(title: string): Promise<void>
setAVQueueTitle(title: string, callback: AsyncCallback<void>): void
```

错误码：`401`、`6600101`、`6600102`。

### 5.1 `avSession.AVQueueItem`（10+）

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| itemId | number | 否 | **否（必填）** | 播放列表中单项的 ID |
| description | `AVMediaDescription` | 否 | 是 | 播放列表中单项的媒体元数据 |

### 5.2 `avSession.AVMediaDescription`（10+，全字段）

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| **assetId** | string | 否 | **否（必填）** | 播放列表媒体 ID，由应用自定义 |
| title | string | 否 | 是 | 播放列表媒体标题 |
| subtitle | string | 否 | 是 | 子标题。cast+ 协议的音频投播场景不支持 |
| description | string | 否 | 是 | 媒体描述文本 |
| mediaImage | `image.PixelMap \| string` | 否 | 是 | 封面。string 时**只支持网络 URI，不支持本地 URI**；与 albumCoverUri 等价且优先级更高。API 23 起支持 PixelMap |
| extras | `{[key: string]: Object;}` | 否 | 是 | 额外字段（DLNA 场景支持 ExtraKey 键值对，值须为 XML 字符串） |
| mediaUri | string | 否 | 是 | 媒体 URI |
| mediaType | string | 否 | 是 | 媒体类型 |
| mediaSize | number | 否 | 是 | 媒体大小 |
| albumTitle | string | 否 | 是 | 专辑标题 |
| albumCoverUri | string | 否 | 是 | 专辑封面 URI |
| lyricContent | string | 否 | 是 | 歌词内容，长度需小于 40960 字节 |
| lyricUri | string | 否 | 是 | 歌词 URI |
| artist | string | 否 | 是 | 专辑作者 |
| fdSrc | `media.AVFileDescriptor` | 否 | 是 | 本地文件句柄 |
| dataSrc (12+) | `media.AVDataSrcDescriptor` | 否 | 是 | 数据源描述 |
| pcmSrc (20+) | boolean | 否 | 是 | 是否使用 PCM 数据源 |
| drmScheme (12+) | string | 否 | 是 | 支持的 DRM 方案（uuid） |
| duration | number | 否 | 是 | 播放时长 |
| startPosition | number | 否 | 是 | 起始播放位置（投播时应置空或 0） |
| creditsPosition | number | 否 | 是 | 片尾播放位置 |
| appName | string | 否 | 是 | 提供播放列表的应用名 |
| displayTags (11+) | number | 否 | 是 | 金标类型；cast+ 音频投播不支持 |
| launchClientData (20+) | string | 否 | 是 | 投播时发送给接收方的自定义数据 |

### 5.3 官方示例（逐字）

```ts
let queueItemDescription_1: avSession.AVMediaDescription = {
  assetId: '001',
  title: 'music_name',
  subtitle: 'music_sub_name',
  description: 'music_description',
  mediaImage: imagePixel,          // image.PixelMap（示例由 resourceManager + image.createImageSource 生成）
  extras: { extras: 'any' }
};
let queueItem_1: avSession.AVQueueItem = {
  itemId: 1,
  description: queueItemDescription_1
};
let queueItemsArray: avSession.AVQueueItem[] = [queueItem_1, queueItem_2];
currentAVSession.setAVQueueItems(queueItemsArray).then(() => {
  console.info('Succeeded in setting AVQueueItems.');
});
// 设置媒体播放列表名称。
currentAVSession.setAVQueueTitle('QUEUE_TITLE').then(() => {
  console.info('Succeeded in setting AVQueueTitle.');
});
```

---

## 6. 事件监听（`session.on(...)` / `session.off(...)`）

> 通用规则（文档原文）：**每个指令支持注册多个回调**，如需只执行最新监听，需先 `off` 旧监听，否则新旧监听都会触发。
> **注册某个固定播控命令 = 向系统声明「应用支持该指令」**：媒体会话控制方的 `getValidCommands()` 会体现该命令有效；**不支持的命令请勿注册或及时 `off`**，注册后播控中心对应按钮会置灰（access-scene「不支持命令的处理」）。文档明确警告：**「请勿进行无逻辑的空实现监听」**。

### 6.1 固定播控命令（必须实现才有对应播控能力）

| 事件名 | 回调签名（逐字） | 说明 / 是否必须 |
|---|---|---|
| `'play'` | `(callback: () => void)` | 播放。**必须**（§10 接入规范要求注册「播放/暂停」） |
| `'pause'` | `(callback: () => void)` | 暂停。**必须** |
| `'stop'` | `(callback: () => void)` | 停止 |
| `'playNext'` | `(callback: () => void)` | 下一首。audio 类型播控中心会显示该按钮 |
| `'playPrevious'` | `(callback: () => void)` | 上一首。audio 类型播控中心会显示该按钮 |
| `'fastForward'` | `(callback: (time?: number) => void)` | 快进。**参数 time 单位是「秒」**（注意与 seek 的毫秒不同） |
| `'rewind'` | `(callback: (time?: number) => void)` | 快退。**参数 time 单位是「秒」** |
| `'seek'` | `(callback: (time: number) => void)` | 跳转。**参数 time 单位是「毫秒」** |
| `'setSpeed'` | `(callback: (speed: number) => void)` | 设置播放倍速 |
| `'setLoopMode'` | `(callback: (mode: LoopMode) => void)` | 设置循环模式。处理完毕后须用 `setAVPlaybackState` 上报切换后的 `loopMode` |
| `'setTargetLoopMode'` (18+) | `(callback: Callback<LoopMode>)` | 设置**目标**循环模式（用户偏好），推荐参数用 `LoopMode` |
| `'toggleFavorite'` | `(callback: (assetId: string) => void)` | 收藏切换。处理完毕后须上报 `isFavorite` |
| `'playWithAssetId'` (20+) | `(callback: Callback<string>)` | 播放指定 assetId 的资源 |
| `'playFromAssetId'` (**deprecated**) | — | 已废弃，用上面的替代 |

**通话类**（音乐 App 不需要）：`'answer'`（11+）、`'hangUp'`（11+）、`'toggleCallMute'`（11+），回调均为 `() => void`。

### 6.2 高级播控事件

| 事件名 | 回调签名（逐字） | 说明 |
|---|---|---|
| `'skipToQueueItem'` | `(callback: (itemId: number) => void)` | 播放列表某项被选中，session 端可播放该项 |
| `'handleKeyEvent'` | `(callback: (event: KeyEvent) => void)` | 蓝牙/有线外设按键事件，**含播放、暂停、上下一首、快进、快退**；`KeyEvent` 来自 `@kit.InputKit` |
| `'outputDeviceChange'` | `(callback: (state: ConnectionState, device: OutputDeviceInfo) => void)` | 播放设备变化（需接入 avCastPicker 投播组件时才有切换回调） |
| `'commonCommand'` | `(callback: (command: string, args: {[key: string]: Object}) => void)` | 自定义控制命令（由控制方 `sendCommonCommand` 下发，args 与之完全一致） |
| `'castDisplayChange'` (12+) | 见 AVSession.md | 扩展屏投播显示设备变化（AVCast 能力） |
| `'customDataChange'` (20+) | 见 AVSession.md | 自定义数据变化 |
| `'playWithAssetId'` (20+) | 见上表 | — |

### 6.3 API 22+ 的新式监听（可选，等价能力）

`onPlay(callback: Callback<CommandInfo>): void`、`onPlayNext`、`onPlayPrevious`、`onFastForward(callback: TwoParamCallback<number, CommandInfo>)`、`onRewind(...)` 等。其中 `CommandInfo`（22+）字段：`callerBundleName` / `callerModuleName` / `callerDeviceId` / `callerType`（`CallerType`：`TYPE_CAST="cast"` / `TYPE_BLUETOOTH="bluetooth"` / `TYPE_APP="app"` / `TYPE_NEARLINK="nearlink"`）。
⚠️ 22+ 接口在 API 14/15 工程中**不可用**，仅作了解。

### 6.4 官方的注册/注销示例（逐字）

```ts
session.on('play', () => {
  console.info(`on play , do play task`);
  // 如暂不支持该指令，请勿注册；或在注册后但暂不使用时，通过session.off('play')取消监听。
  // 处理完毕后，请使用SetAVPlaybackState上报播放状态。
});
session.on('seek', (time) => {
  console.info(`on seek , the seek time is ${time}`);
});
session.on('setSpeed', (speed) => {
  console.info(`on setSpeed , the speed is ${speed}`);
});
session.on('setLoopMode', (mode) => {
  console.info(`on setLoopMode , the loop mode is ${mode}`);
});
session.on('toggleFavorite', (assetId) => {
  console.info(`on toggleFavorite , the target asset Id is ${assetId}`);
});
session.on('skipToQueueItem', (itemId) => { /* ... */ });
session.on('handleKeyEvent', (event) => { /* event: KeyEvent */ });
session.on('outputDeviceChange', (device) => { /* ... */ });
session.on('commonCommand', (commandString, args) => { /* ... */ });
```

注销（`off` 也可传 callback 只取消对应监听，不传则取消该事件全部监听）：

```ts
session.off('play'); session.off('pause'); session.off('stop');
session.off('playNext'); session.off('playPrevious');
session.off('skipToQueueItem'); session.off('handleKeyEvent');
session.off('outputDeviceChange'); session.off('commonCommand');
```

### 6.5 音乐播放器**必须处理**的事件清单（结论）

- **强必须（否则播控中心基本不可用）**：`'play'`、`'pause'`。
- **音乐 App 必需**：`'playNext'`、`'playPrevious'`、`'seek'`、`'setLoopMode'`、`'toggleFavorite'`、`'skipToQueueItem'`。
- **强烈建议**：`'stop'`、`'setSpeed'`、`'handleKeyEvent'`（等键控与耳机佩戴检测）、`'outputDeviceChange'`。
- **可选**：`'commonCommand'`、`'fastForward'`/`'rewind'`（audio 类型下**快进/快退按钮不会显示**，见 §7）。

---

## 7. 播控中心 / 锁屏 / 通知的自动接入，与激活要求

### 7.1 零 UI 代码自动呈现（access-scene「适配媒体通知」原文）

- 「当前系统**不直接向应用提供主动发送媒体控制通知的接口**，那么当应用**正确接入媒体播控中心并进入播放状态时，系统会自动发送通知**，同时在**通知和锁屏界面**进行展示。」
- 「**通知中心、锁屏下的播控卡片的展示，由系统进行发送，并控制相应的生命周期。**」
- 因此：**只要 AVSession 创建、激活、上报元数据+播放状态、注册控制命令，通知栏/锁屏播控卡片无需任何额外 UI 代码。**
- **⚠️ 灵动岛 / 实况窗**：本地全部文档中检索 `灵动岛`、`实况窗`、`LiveView` 均**没有**与 AVSession 播控卡片相关的描述（`实况窗` 仅在长时任务/通知模块出现，用于 DATA_TRANSFER 进度通知）。**本地文档不支持「AVSession 自动上灵动岛」的结论**，请勿据此实现。

### 7.2 激活要求（汇总）

1. 必须**先** `setAVMetadata` + `setAVPlaybackState` + 注册控制命令，**再** `activate()`。文档原文：「激活接口要在元数据、控制命令注册完成之后再执行。」
2. 会话必须 `activate()` 且实例在后台**持续存活**；未接入 AVSession、或接入但**无有效 AVSession 实例**时，应用退到后台将被**强制暂停音频播放**。
3. 必须有**有效音频流类型** + 长时任务（§10），否则退后台会被静音并冻结。
4. 元数据最低要求（后台播放接入规范原文）：「元数据：标题、副标题/歌手、封面图」「注册控制命令：播放/暂停」。
5. 播放状态必须随播放器状态变化及时更新（至少 state/position/speed 变化时）。

### 7.3 audio 类型在播控中心的控制样式（access-scene 原文）

- **audio 类型**：收藏、上一首、播放/暂停、下一首、循环模式。
- **video 类型**：快退、上一首、播放/暂停、下一首、快进。

**快进/快退与上/下一首的显示差异（audio 场景原文表格）：**

| 应用注册的事件组合 | 播放中心显示按钮 | 按钮是否可用 |
|---|---|---|
| 未注册任何事件 | 「上一首」、「下一首」 | 所有按钮置灰，无法点击 |
| 注册上一首/下一首事件 | 「上一首」、「下一首」 | 注册上一首 →「上一首」可用；注册下一首 →「下一首」可用；未注册的不可用 |
| 注册快进/快退事件 | 「上一首」、「下一首」 | **所有按钮置灰，无法点击** |
| 注册上一首/下一首及快进/快退事件 | 「上一首」、「下一首」 | 同第 2 行（快进/快退在 audio 下不出现） |

结论：**音乐（audio）会话注册 `fastForward`/`rewind` 不会带来任何按钮**，不要指望用它代替上一首/下一首。

### 7.4 蓝牙/有线耳机按键（access-scene「适配蓝牙按键与有线按键事件」）

- 「方式一（推荐使用）：正确接入媒体播控中心，注册需要的控制指令并实现对应的功能。**AVSession 会监听多模按键事件，将其转换为 AVSession 的控制指令发送回应用**，应用无须区分不同的按键事件。」
- 「按照此方式接入播放暂停，也等同于**适配了蓝牙耳机的佩戴检测**，在双耳佩戴与摘下时也会收到播放暂停控制指令。」
- 目前支持转换的指令：`play`、`pause`、`stop`、`playNext`、`playPrevious`、`fastForward`、`rewind`。
- ⚠️ 另一种「直接监听多模按键」的方式，文档明说「当前系统不直接向应用提供监听多模按键事件的接口」——即不可用。

### 7.5 控制方（Controller）侧补充

```ts
let controller = await session.getController();                 // 获取会话自身控制器
let avCommand: AVSessionManager.AVControlCommand = { command: 'play' };
controller.sendControlCommand(avCommand);                       // 下发控制命令
controller.on('playbackStateChange', 'all', (state) => { });    // 状态变更监听
controller.getValidCommands();                                  // 反映已注册的固定播控命令
```
> `sendControlCommand` 前需确保对应媒体会话已注册监听。控制器全量 API 见 `arkts-apis-avsession-AVSessionController.md`（含 `getValidCommandsSync()`）。

---

## 8. `AVMusicTemplate`（音频模板）

### 8.1 是什么 / 与普通 AVSession 的区别（原文）

- 「从 **API version 23** 开始，支持媒体应用通过**音频模板**接入播控中心（系统应用），实现音视频在播控中心进行统一的界面显示和播控管理，减少应用侧开发工作量。」
- 「音频模板同时支持音频和视频内容，且两者的接入方式相同。」
- 差异：普通 AVSession 只上报「当前这一首 + 播放状态」，界面由系统播控中心模板渲染；音频模板是**整套 UI 数据契约**（主 Tab、Tab 内容、合集、专辑、排行榜、搜索、热词、登录、会员购买、下载、设置页、问题反馈、自定义元素……），由媒体应用通过**回调 + 同步接口**喂数据给 Car 机上的播控界面。
- **⚠️ 硬性限制（原文逐字）**：「本功能仅支持在 **API version 23 及以上版本的 Car 设备工程**中使用。创建工程时，请在 Device type 中选择『Car』。」参考页每节均标注「**本模块仅适用于 API version 23 及以上版本的 Car 设备**」。
- **系统能力 / 权限**：`SystemCapability.Multimedia.AVSession.AVMusicTemplate`。**⚠️ 本地文档中没有列出任何 `ohos.permission.*` 权限、也没有声明它是系统应用专有 API**；但因为它被限定为 Car 设备 + 独立的系统能力，**普通第三方手机（Phone/Tablet）应用在 API 14/15 上无法使用，API 23+ 的非 Car 设备同样不可用**。因此本工程（API 14/15 音乐 App）**不应采用音频模板**。

### 8.2 是否在播控中心渲染歌词？

**⚠️ 否（按本地文档）**：`AVMusicTemplate` / `AVMusicTemplateController` / `AVMusicTemplate` 的 `i`、`t`、`e` 文档全文中**检索 `歌词/lyric/Lyric` 为 0 命中**。音频模板的数据结构里**没有任何歌词或逐字歌词（word-by-word lyric）类型**。
播控中心/Car 界面的歌词来自普通 AVSession 的 **`AVMetadata.lyric`（Simple LRC）** 与 `singleLyricText`（§3），以及桌面歌词（§9）。**⚠️ 本地文档中不存在逐字歌词（逐词）API。**

### 8.3 创建与生命周期 API

```ts
// 创建（指南示例逐字；⚠️ f.md 页缺失，promise/callback 细节未逐字给出）
this.template = avMusicTemplate.createAVMusicTemplate(avMusicTemplate.AVMusicTemplateType.DEFAULT);
// AVMusicTemplateType.DEFAULT 的值是字符串 'smartCar'
```

| 成员 | 签名 | 说明 |
|---|---|---|
| `sessionId` | string | 音频模板唯一的标识 |
| `sessionTag` | string | 音频模板标签 |
| `startTemplate` | `startTemplate(): Promise<OperResult>` | 启动音频模板界面。错误码 `801 capability not supported` |
| `destroy` | `destroy(): Promise<void>` | 销毁音频模板实例。错误码 `801` |
| `setExtensionAbility` | `setExtensionAbility(want: WantAgent): Promise<void>` | 向音频模板控制方同步「用于被拉起的 Ability」（媒体应用需拉起自定义界面时调用）。错误码 `801` / `35000005` / `35000011` |

**属性表（AVMusicTemplate）：** `sessionId: string`（否/否）、`sessionTag: string`（否/否）；模型约束：仅 Stage；系统能力：`SystemCapability.Multimedia.AVSession.AVMusicTemplate`。

### 8.4 数据同步接口（`AVMusicTemplate`，全部 `Promise<void>`，仅 Stage 模型）

| 方法 | 签名 | 说明 |
|---|---|---|
| `setUserInfo` | `setUserInfo(userInfo: UserInfo): Promise<void>` | 用户信息变化（登录后）通知界面刷新 |
| `setDialogCommand` | `setDialogCommand(...)` | 对话框指令同步 |
| `setCurrentSingle` | `setCurrentSingle(single: Single): Promise<void>` | 同步**当前单曲** |
| `setMediaEntities` | `setMediaEntities(entities: MediaEntity[]): Promise<void>` | 同步媒体资源变更 |
| `setTabContent` | `setTabContent(...)` | 同步 Tab 内容 |
| `setPlaylist` | `setPlaylist(playlist: PageMediaEntity): Promise<void>` | 同步**播放列表**（分页） |
| `setDownloadMediaEntityStatus` | `setDownloadMediaEntityStatus(single: MediaEntity): Promise<void>` | 同步单曲下载状态 |
| `setCustomElements` | `setCustomElements(...)` | 自定义元素 |
| `setSettings` | `setSettings(...)` | 设置页数据 |
| `reportExecuteAction` | `reportExecuteAction(actionType: string, params: string): Promise<void>` | 上报执行动作结果 |

上述接口的通用错误码：`801`、`35000005 AVMusicTemplate does not exist.`、`35000011 The data write error, data is invalid.`

### 8.5 事件注册（`on*` / `off*` 成对，回调为 `QueryXxxEvent` 类型，定义在 `avMusicTemplate-t.md`）

`onQueryMainTabs` / `offQueryMainTabs`、`onQueryMediaTabContent` / `offQueryMediaTabContent`、`onQueryMediaEntity`、`onQueryCompilation`、`onQueryPlaylist`、`onQueryCurrentSingle`、`onQueryCompilationByKeyword`、`onQueryMediaEntityByKeyword`、`onQueryRecommendMediaEntityList`、`onQueryHotWords`、`onQuerySearchHistory`、`onClearSearchHistory`、`onLogin`、`onRequestDialogInfo`、`onHandleMemberPurchase`、`onQueryMemberPurchase`、`onQueryCustomContent`、`onDownloadMediaEntity`、`onSettingsChange`、`onProblemAndAdvice`、`onPlayForSearch`、`onExecuteAction`、`onPlayMediaEntity`、`onFavoriteMediaEntity`。

**主界面必须同时注册这两个（原文）：**
- `onQueryMainTabs`（`QueryMainTabsEvent`）：提供主界面展示的 TAB 数据集合，并**规定「我的主页」的 tabId 为 `"minePage"`**。
- `onQueryMediaTabContent`（`QueryMediaTabContentEvent`）：根据 tabId 提供页面展示内容数据。

示例（逐字）：

```ts
private queryMainTabsEvent: avMusicTemplate.QueryMainTabsEvent = async () => {
  return new Promise<avMusicTemplate.MediaTab[]>(async (resolve, reject) => {
    let tabs: avMusicTemplate.MediaTab[] = await this.getMainTabs();
    resolve(tabs);
  });
};
private queryMediaTabContentEvent: avMusicTemplate.QueryMediaTabContentEvent = async (tabId: string) => { /* ... */ };
this.template?.onQueryMainTabs(this.queryMainTabsEvent);
this.template?.onQueryMediaTabContent(this.queryMediaTabContentEvent);
```

### 8.6 关键数据结构

- `MediaTab`：`tabId`、`tabName`（示例写法）。
- `MediaTabContent`：`errorCode: 0`、`tabId`、`compilations: Compilation[]`。
- `Compilation`：`errorCode`、`id`、`title`、`hasMoreData`、`totalSize`、`memberMediaType: EntityType`、`topElements: MediaEntity[]`。
- `MediaEntity`：`mediaId`、`mediaType: EntityType`、`parentId`、`parentMediaType: EntityType`、`title`、`imageUrl`、`playState: PlaybackState`（示例还用到 `desc`）。
- `Single`（继承 `MediaEntity`）：`isVip: boolean`（必填）、`singer: string`（必填）、`playInfo: PlayInfo`（必填）、`favSubscribeData: FavoriteData`（必填）、`tags?: string[]`、`settings?: SettingItem[]`、`downloadStatus?`、`downloadProgress?`。
- `PlayInfo`（**全部字段均为「否/否」，即必填**）：`playCounts: string`、`isSupportNext`、`isSupportPrev`、`isSupportQuickForward`、`isSupportQuickBackward`、`quickForwardStep: number`、`quickBackwardStep: number`、`isSupportSkipHead`、`isSupportSkipTail`、`isSupportPlayMode`、`isSupportPlayRate`、`supportedPlayRate: string[]`、`currentPlayRate: string`、`isSupportSoundQuality`、`isSupportSoundEffect`、`totalDuration: number`、`currentPlayDuration: number`、`isSupportProgress: boolean`（默认 true）。
- `FavoriteData`：`isSupportFav`、`isFavorite`、`favCounts: string`。
- `PageMediaEntity`：`errorCode`、`errorMsg`、`pageIndex`、`pageSize`、`hasMoreData`、`totalSize`、`memberMediaType: EntityType`、`elements: MediaEntity[]`。
- `EntityType` 枚举：`UNKNOWN=0`、`SINGLE=1`、`SINGER=2`、`ALBUM=3`、`RANKING=4`、`BANNER=5`、`RADIO_STATION=6`。
- `UserInfo`：`userInfoId`、`nickName`、`profilePicUrl`、`tips`、`isLogin`、`isVip`（示例写法）。
- 其它接口：`OperResult`、`Banner`、`Album`、`Ranking`、`QueryMediaEntityParam`、`EpisodeRange`、`SettingItem`、`SettingContent`、`QrCodeInfo`、`DialogActionInfo`、`DialogInfo`、`DialogButtonInfo`、`MemberPurchaseInfo`、`CustomElement`、`SearchPlayInfo`、`SearchPlayMusicInfo`、`SearchPlayMusicItem`、`SearchPlayVideoInfo`。

### 8.7 `AVMusicTemplateController`（控制方，Car 播控界面对接用）

- 导入同样是 `import { avMusicTemplate } from '@kit.AVSessionKit';`；系统能力 `SystemCapability.Multimedia.AVSession.AVMusicTemplate`；仅 Stage；仅 API 23+ Car。
- 属性：`sessionId: string`（唯一标识）、`isDestroy: boolean`（是否已销毁）。
- 查询方向（`template -> controller` 的拉取接口，均为 `Promise`）：`queryMainTabs()`、`queryMediaTabContent`、`queryMediaEntity`、`queryCompilation`、`queryPlaylist`、`queryCurrentSingle`、`queryCompilationByKeyword`、`queryMediaEntityByKeyword`、`queryRecommendMediaEntityList`、`queryHotWords`、`querySearchHistory`、`clearSearchHistory`、`login`、`requestDialogInfo`、`handleMemberPurchase`、`queryMemberPurchase`、`queryCustomContent`、`downloadMediaEntity`、`playForSearch`、`executeAction`、`playMediaEntity`、`favoriteMediaEntity`、`updateSettings`、`reportProblemAndAdvice`。
- 变更监听：`onUserInfoChange`、`onDialogCommandChange`、`onCurrentSingleChange`、`onMediaEntitiesChange`、`onTabContentChange`、`onPlaylistChange`、`onDownloadMediaEntityStatusChange`、`onCustomElementsChange`、`onSettingsChange`、`onReportExecuteAction`、`onExtensionAbilityChange`（均成对 `off*`）；`destroy()`。
- **⚠️ 创建控制器（`createAVMusicTemplateController`）只在链接中出现，其参数表所在 `arkts-apis-avMusicTemplate-f.md` 不在本地文档集中，本文不给出签名。** 仅可确认错误码 `35000002`「音频模板控制器创建失败」、`35000006`「模板控制器不存在」、`35000007`「模板控制器已经存在」。

### 8.8 音频模板错误码（`avMusicTemplate.AVMusicTemplateErrorCode`）

| 名称 | 值 | 说明 |
|---|---|---|
| ERR_CODE_CREATE_AV_MUSIC_TEMPLATE_FAILED | 35000001 | 音频模板创建失败 |
| ERR_CODE_CREATE_AV_MUSIC_TEMPLATE_CONTROLLER_FAILED | 35000002 | 音频模板控制器创建失败 |
| ERR_CODE_TEMPLATE_LISTENER_NO_EXIT | 35000003 | 模板监听未注册 |
| ERR_CODE_CONTROLLER_CALLBACK_NO_EXIT | 35000004 | 未注册模板控制器回调 |
| ERR_CODE_AV_MUSIC_TEMPLATE_NOT_EXIST | 35000005 | 音频模板不存在 |
| ERR_CODE_CONTROLLER_NOT_EXIST | 35000006 | 模板控制器不存在 |
| ERR_CODE_CONTROLLER_IS_EXIST | 35000007 | 模板控制器已经存在 |
| ERR_CODE_SERVICE_NOT_EXIST | 35000008 | 音频模板管理服务不存在 |
| ERR_CODE_SERVICE_EXCEPTION | 35000009 | 音频模板管理服务异常 |
| ERR_CODE_EXCEED_MAX_DATA_SIZE | 35000010 | 数据超过了允许的最大传输容量 |
| ERR_CODE_WRITE_RESULT_EXCEPTION | 35000011 | 写数据失败，数据不可用 |
| ERR_CODE_AV_MUSIC_TEMPLATE_ERROR | 35000012 | 音频模板错误 |

---

## 9. 桌面歌词（`avsession-desktop-lyrics.md`，**API 23+**）

> 原文：「从 **API version 23** 开始，支持应用接入桌面歌词功能，将歌词以悬浮窗形式展示在系统桌面……适用于音乐播放器或有歌词展示需求的音频类应用。」
> ⚠️ 本工程目标为 API 14/15，**桌面歌词整套 API 不可用**；以下记录以备将来升级。

**流程（原文）：**
1. 创建 AVSession 实例，并通过 `setAVMetadata` 填入**符合 LRC 格式**的歌词内容；系统播控中心将解析该内容，实现歌词内容的同步展示。「歌词内容必须包含时间标签及对应歌词文本。」
   - 「设置元数据时，**必须包含 `lyric` 字段**，否则桌面歌词功能无法生效。」
2. 调用以下接口控制使能与显示：
   - `isDesktopLyricSupported`（⚠️ 位于 `arkts-apis-avsession-f.md`，**本地文档无参数表**）：判断应用是否支持桌面歌词。
   - `enableDesktopLyric(enable: boolean): Promise<void>`：启用/不启用桌面歌词。错误码 `6600101`、`6600102`、`6600111`。
   - `setDesktopLyricVisible(visible: boolean): Promise<void>`：显示/隐藏歌词窗口。错误码 `6600101`、`6600102`、`6600110`、`6600111`。
   - `isDesktopLyricVisible(): Promise<boolean>`：查询显示状态。错误码同上。
   - `setDesktopLyricState(state: DesktopLyricState): Promise<void>`：设置窗口锁定状态，限制拖动或关闭。
   - `getDesktopLyricState(): Promise<DesktopLyricState>`：查询锁定状态。
   - 监听：`onDesktopLyricVisibilityChanged(callback: Callback<boolean>)` / `offDesktopLyricVisibilityChanged(callback?)`；`onDesktopLyricStateChanged(callback: Callback<DesktopLyricState>)` / `offDesktopLyricStateChanged(callback?)`。
3. **必须响应**控制器侧 `onDesktopLyricEnabled(callback: Callback<boolean>)` 与 `offDesktopLyricEnabled(...)` 回调（`AVSessionController`，API 23+，错误码 `6600101`、`6600103`），**根据回调值更新 UI**，确保应用内 UI 与系统实际状态一致。
4. 应用退出时必须主动 `destroy()` 会话；销毁会导致关联的桌面歌词组件自动跟随退出，再次启动需重新初始化 AVSession。「确保 AVSession 对象在后台播放期间不被系统回收，否则会导致歌词中断。」

**`avSession.DesktopLyricState`（23+，仅 Stage，Core）**

| 名称 | 类型 | 只读 | 可选 | 说明 |
|---|---|---|---|---|
| isLocked | boolean | 否 | 否 | 桌面歌词位置是否锁定。锁定后固定当前位置，不可被拖拽 |

**相关错误码**（见 §12）：`6600110` 应用桌面歌词功能未开启；`6600111` 当前设备不支持桌面歌词。

---

## 10. 后台场景（`avsession-background-scene.md`）与「后台卡片/长时任务」

**核心约束（原文）：**
- 当应用需要在后台播放流类型为 `STREAM_USAGE_MUSIC`、`STREAM_USAGE_MOVIE`、`STREAM_USAGE_AUDIOBOOK`（以及游戏类 `STREAM_USAGE_GAME`）时，**必须接入 AVSession 并且申请长时任务**。
- 「如果应用不满足上述接入规范，退至后台播放时会被**系统静音并冻结**，无法在后台正常播放。直到应用重新切回前台时，才会被解除静音并恢复播放。」
- 需要申请 **`AUDIO_PLAYBACK` BackgroundMode** 的长时任务（`@ohos.resourceschedule.backgroundTaskManager`）。
- 创建/释放时机：「建议在应用启动或开始播放业务之前进行创建，并在应用进程结束或完全退出播放业务且不再播放时予以释放，以避免频繁创建和释放 AVSession」；「**不要使用局部变量保存 AVSession 对象**」。
- 接入后**要求**：设置元数据「标题、副标题/歌手、封面图」，注册控制命令「播放/暂停」。
- 长时任务与播放状态联动：暂停/停止时主动取消长时任务；再次播放时重新申请；收到播控指令、音频设备变更导致暂停/播放时也要同步取消/申请；投播开始申请、断开取消（投播中音频暂停无须处理长时任务）。
- 若不打算做后台播放，可在 `onBackground` 中主动停止播放，`onForeground` 恢复。
- 从 API 20 起，申请 `AUDIO_PLAYBACK` 长时任务**但不接入 AVSession** 时会在通知栏显示通知；**接入 AVSession 后由 AVSession 发送通知**，后台任务模块不再发送（API 19 及之前不显示通知）。→ 这也印证 §7.1：**通知/锁屏卡片由 AVSession 侧自动产生**。

**⚠️ 关于「实况窗 / 灵动岛 / 后台卡片」**：本地 AVSession 全部文档**没有**任何「后台卡片」「Live View/实况窗」「灵动岛」的专用 API 描述。可确认的只有：**正确接入并进入播放状态后，系统会自动在通知中心和锁屏展示播控卡片**（§7.1）；其余形态在本地文档中**无支撑**。

---

## 11. `module.json5` 声明（⚠️ 重要缺口）

**⚠️ 本地文档事实：**
- 在全部 `_docs` 中检索 `MediaControlExtensionAbility`（及中文「媒体控制扩展/多媒体控制扩展」）→ **0 命中**。**本地文档不支持「必须声明 MediaControlExtensionAbility」这一说法**，无法给出其配置示例，请勿凭空编造。
- 本地 AVSession 相关文档中**没有**任何 `module.json5` 片段、没有 AVSession 专用权限、也没有 AVSession 专用 `metadata` 条目。检索 `ohos.permission.*` / `requestPermissions` 在 AVSession 文档中 → **0 命中**。

**可以确定的（来自长时任务文档 `continuous-task.md`，是 AVSession 后台播放的硬性前置）：**
1. 需要申请 **`ohos.permission.KEEP_BACKGROUND_RUNNING`** 权限。
2. 在 `module.json5` 的 `abilities` 下用 `backgroundModes` 声明长时任务类型（`AUDIO_PLAYBACK` 对应配置项字符串为 **`audioPlayback`**）。

```json5
// module.json5 —— 逐字引自 continuous-task.md（Stage 模型）
"module": {
    "abilities": [
        {
           "backgroundModes": [
           // 长时任务类型的配置项
           "audioRecording",
           "bluetoothInteraction",
           "audioPlayback"   // 音视频播放，音乐 App 需要这一项
           ]
        }
    ],
    // ...
}
```

3. 权限声明（`requestPermissions`）写法需参考 `../security/AccessToken/declare-permissions.md`（⚠️ 该文件不在本地文档集中，未逐字核对）。
4. **不需要任何 AVSession 专用权限**：本地文档中所有 AVSession API 的「系统能力」均为 `SystemCapability.Multimedia.AVSession.Core`（非受限系统能力），示例代码中也没有 `requestPermissionsFromUser`。**⚠️ 音频模板**的「系统能力」为 `SystemCapability.Multimedia.AVSession.AVMusicTemplate` 且仅限 Car 设备（§8.1）。

---

## 12. 需要处理的错误码（`avSession.AVSessionErrorCode`，10+）

| 名称 | 值 | 说明 | 处理建议 |
|---|---|---|---|
| ERR_CODE_SERVICE_EXCEPTION | 6600101 | 会话服务端异常 | 需重试/重建会话；`assetId` 为空时 `setAVMetadata` 也返回此码 |
| ERR_CODE_SESSION_NOT_EXIST | 6600102 | 会话不存在 | 会话已销毁/被回收，需重建 |
| ERR_CODE_CONTROLLER_NOT_EXIST | 6600103 | 会话控制器不存在 | 控制器侧 |
| ERR_CODE_REMOTE_CONNECTION_ERR | 6600104 | 远端会话连接失败 | 投播/分布式 |
| ERR_CODE_COMMAND_INVALID | 6600105 | 无效会话命令 | 检查命令参数 |
| ERR_CODE_SESSION_INACTIVE | 6600106 | 会话未激活 | **必须先 `activate()`**（激活顺序见 §2.3） |
| ERR_CODE_MESSAGE_OVERLOAD | 6600107 | 命令&消息过载 | 降低上报频率（勿逐帧上报 position） |
| ERR_CODE_DEVICE_CONNECTION_FAILED | 6600108 | 设备连接失败 | 投播 |
| ERR_CODE_REMOTE_CONNECTION_NOT_EXIST | 6600109 | 远端会话不存在 | 投播 |
| ERR_CODE_DESKTOP_LYRIC_NOT_ENABLED (23+) | 6600110 | 应用程序的桌面歌词功能未开启 | 先 `enableDesktopLyric(true)` |
| ERR_CODE_DESKTOP_LYRIC_NOT_SUPPORTED (23+) | 6600111 | 当前设备不支持桌面歌词功能 | 降级处理 |

**通用错误码**：`401` = parameter check failed（1.必填参数未指定 2.参数校验失败）。
**AVCast 投播错误码**（13+，AVCast 能力，音乐 App 通常不涉及）：`6611000`~`6611108`、`6612000`~`6612107`、`6613000`~`6613004`、`6614000`~`6614005`、`6615000`~`6615002`、`6616000`~`6616008`、`6616100`（未指定的投播错误 / 远端播放器错误 / 超时 / DRM / 解码 / 音频渲染器等），详见 `arkts-apis-avsession-e.md`。

---

## 13. 最小可用示例（AVPlayer 状态 → AVSession）

> 说明：仅演示 AVSession 侧接线（播放器具体播放逻辑用注释代替）。**顺序遵循文档要求：创建 → 元数据/状态 → 注册命令 → activate**。约 60 行。

```ts
import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';

// 注意：session 必须是长生命周期成员，不能是局部变量（否则后台播放会被系统管控）。
let gSession: AVSessionManager.AVSession | undefined = undefined;

export async function setupAVSession(context: Context) {
  // 1. 创建会话：音乐类型用字符串 'audio'（不是 AVSessionType.AUDIO）
  const type: AVSessionManager.AVSessionType = 'audio';
  gSession = await AVSessionManager.createAVSession(context, 'FOLIA_MUSIC', type);

  // 2. 设置元数据：assetId 为必填；进度条需要 duration
  const metadata: AVSessionManager.AVMetadata = {
    assetId: 'song_0001',            // 必填，切歌必须换新值，否则其他字段不会刷新
    title: '歌曲标题',
    artist: '歌手',
    album: '专辑',
    duration: 23000,                 // 毫秒；不支持试听可设 -1
    mediaImage: 'https://example.com/cover.jpg',
    lyric: '[00:25.44]第一句\r\n[00:26.44]第二句\r\n', // Simple LRC，桌面歌词同源
  };
  await gSession.setAVMetadata(metadata);

  // 3. 注册控制命令（先注册，再 activate）
  gSession.on('play', () => { /* 播放器 play()；完成后上报状态 */ });
  gSession.on('pause', () => { /* 播放器 pause()；完成后上报状态 */ });
  gSession.on('stop', () => { /* 停止播放 */ });
  gSession.on('playNext', () => { /* 下一首 */ });
  gSession.on('playPrevious', () => { /* 上一首 */ });
  gSession.on('seek', (time: number) => { /* 毫秒 */ });
  gSession.on('setLoopMode', (mode: AVSessionManager.LoopMode) => { /* 切换并上报 loopMode */ });
  gSession.on('toggleFavorite', (assetId: string) => { /* 收藏并上报 isFavorite */ });
  gSession.on('skipToQueueItem', (itemId: number) => { /* 播放列表选中项 */ });

  // 4. 上报播放状态（state/position/speed 变化时必须重新上报）
  const state: AVSessionManager.AVPlaybackState = {
    state: AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY,
    position: { elapsedTime: 0, updateTime: new Date().getTime() },
    speed: 1.0,
    loopMode: AVSessionManager.LoopMode.LOOP_MODE_SEQUENCE,
    isFavorite: false,
  };
  await gSession.setAVPlaybackState(state);

  // 5. 设置播放列表（可选）与拉起用 Ability（可选）
  await gSession.setAVQueueTitle('默认歌单');
  await gSession.setAVQueueItems([
    { itemId: 1, description: { assetId: 'song_0001', title: '歌曲标题', artist: '歌手' } }
  ]);

  // 6. 最后激活：激活后系统播控中心 / 通知 / 锁屏自动展示，无需额外 UI 代码
  await gSession.activate();
}

// 退出且不再播放时：先取消监听，再销毁
export async function teardownAVSession() {
  if (!gSession) { return; }
  gSession.off('play'); gSession.off('pause'); gSession.off('stop');
  gSession.off('playNext'); gSession.off('playPrevious'); gSession.off('seek');
  gSession.off('setLoopMode'); gSession.off('toggleFavorite'); gSession.off('skipToQueueItem');
  await gSession.destroy();
  gSession = undefined;
}
```

---

## 附：本文的证据来源文件

| 主题 | 来源 |
|---|---|
| Kit 简介、约束、后台管控 | `avsession-overview.md` |
| 提供方接口表与全流程示例（创建/元数据/状态/队列/extras/dispatchSessionEvent/监听/off/destroy） | `using-avsession-developer.md` |
| 接入场景（会话类型样式、元数据、歌词、金标、进度条、控制命令、快进快退显示规则、媒体通知、蓝牙按键） | `avsession-access-scene.md` |
| 后台播放与长时任务 | `avsession-background-scene.md`、`continuous-task.md` |
| 桌面歌词 | `avsession-desktop-lyrics.md`、`arkts-apis-avsession-AVSession.md#enabledesktoplyric23` 等 |
| AVSession 接口逐条签名/错误码/示例 | `arkts-apis-avsession-AVSession.md` |
| 接口结构体（AVMetadata/AVPlaybackState/AVQueueItem/AVMediaDescription/DesktopLyricState/CommandInfo…） | `arkts-apis-avsession-i.md` |
| 类型与枚举 | `arkts-apis-avsession-t.md`、`arkts-apis-avsession-e.md` |
| 控制器 | `arkts-apis-avsession-AVSessionController.md` |
| 音频模板 | `using-avsession-AVMusicTemplate.md`、`arkts-apis-avMusicTemplate-*.md` |
