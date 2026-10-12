# Folia 播放架构 —— HarmonyOS (ArkTS) 移植参考

> 来源仓库：`_upstream/folia-major-main`（Electron + React 19 + TypeScript，Vite 6）。
> 本文只描述**播放链路**。所有标识符、文件路径、常量值均直接取自源码；凡属推断一律标注 `[推断]`。
> 阅读顺序建议：§1 → §3 → §4 → §9，其余按需查。

---

## 0. 总览与不变量

分层（源码里的实际分层，不是设想）：

| 层 | 位置 | 说明 |
| --- | --- | --- |
| 状态 | `src/stores/usePlaybackStore.ts`、`src/stores/useAudioSettingsStore.ts`、`src/stores/useAutomixSettingsStore.ts` | zustand，**不含每帧值** |
| 每帧信号 | `src/stores/motionSignals.ts` | framer-motion `MotionValue`，永进 store 会导致按帧重渲染 |
| 控制器 | `src/hooks/usePlaybackQueueController.ts`(60KB)、`usePlaybackTransportController.ts`、`useLibraryPlaybackController.ts`(77KB)、`useStagePlaybackController.ts`(57KB)、`usePlaybackAudioBridge.ts`、`usePlaybackInteractionBridge.ts`、`usePlaybackVisualizerBridge.ts`、`useSessionRestoreController.ts` | React hook 形态 |
| 装配 | `src/App.tsx` | 渲染**两个** `<audio>` deck、引擎 ref、事件转发 |
| 服务 | `src/services/*` | `playbackGraph.ts`、`audioEqualizerGraph.ts`、`playbackFade.ts`、`audioEffects/*`、`automix/*`、`playbackRecovery/*`、`repositories/*`、`db.ts` |

源码中明确写下的架构不变量（移植时不可省的约束）：

1. **raw / display 双层**：`usePlaybackStore` 上注释原文——"`raw` — what the machine is doing right now. `display` — what the listener perceives." 过渡期间 raw 已经指向**到达曲**，而听众还在听**出场曲**。display 只以 selector 暴露（`selectDisplaySong` / `selectDisplayLyrics` / `selectDisplayCoverUrl` / `selectDisplayDuration` / `selectDisplayPlayerState`），**绝不落成第二个 stored 字段**。
2. **没有 `index.ts` barrel**：`src/services/automix/README.md` §9 明确"不设 `index.ts`"，因为 `prefetchService` 调 `profileService`、`useAutomixDecks` 回头读 `prefetchService`，收进 barrel 会形成真实循环导入。目录本身就是边界。
3. **音频路径不许走 React**：`audioEqualizerGraph.ts` / `effectChain.ts` 顶部注释——"without routing audio through React" / "without introducing React updates into the audio path"。
4. **每帧值必须是 MotionValue**：`motionSignals.ts` 注释——"They must never become reactive store state — writing `currentTime.get()` into a store would re-render the tree at frame rate."
5. **音量节点在效果链之后**（`playbackGraph.ts:60-79`）：vinyl noise / bit crush / punch 三个效果是"绝对"的，推子放在上游会改变它们"做什么"而非"多响"。实测数据写在文件里：噪声在推子上游时 -51.9 dBFS 恒定、下游为 -51.8/-57.9/-64.0 dBFS；bit crush 的 SNR 在 volume 1.00 为 38.2 dB、0.25 降到 25.8 dB，下游后恒为 38.2 dB。

---

## 1. 播放状态模型（精确类型）

### 1.1 曲目：`SongResult`（`src/types.ts:1220`）

```ts
export interface SongResult {
  id: MediaId;                                   // MediaId = string | number (types/onlineMusic.ts:5)
  name: string;
  artists: Artist[];                             // { id: MediaId; name: string; entityId?: string; catalogRef?: ProviderCatalogRef }
  album: Album;                                  // { id: MediaId; name: string; coverUrl?: string; entityId?: string; catalogRef?: ProviderCatalogRef }
  durationMs: number;
  isPureMusic?: boolean;
  aliases?: string[];
  translatedNames?: string[];
  t?: 0 | 1 | 2;
  sourceType?: 'netease' | 'cloud';
  sourceRef?: PlaybackSourceRef;
  /** Identity of the concrete bytes selected for playback; used to reject stale derived media. */
  playbackSourceRevision?: string;
  fee?: number;
  noCopyrightRcmd?: NoCopyrightRecommendation | null;
  resourceState?: boolean;
  privilege?: SongPrivilege;                     // { id?, fee?, payed?, st?, pl?, dl?, flag?, cs? }
  onlineLyricsState?: OnlineLyricsState;
  matchedLyricsSource?: LyricProviderSource;     // 'netease' | 'qq' | 'kugou' | 'amll'
  matchedLyricsProviderPlatform?: AmllDbPlatform; // 'ncm' | 'qq'
  replayGain?: ReplayGainInfo;
  qqMid?: string;
  kgHash?: string;
  amllDbPlatform?: AmllDbPlatform;
}
```

`OnlineLyricsState`（`types.ts:1247`）：`lyricsSource: 'online' | 'imported'`、`importedLyrics?: LyricData | null`、`importedLyricsName?: string | null`、`hasOnlineOverride?: boolean`、`onlineOverrideLyrics?: LyricData | null`、`matchedSongId?: MediaId`、`matchedIsPureMusic?: boolean`、`matchedLyricsSource?`、`matchedLyricsProviderPlatform?`。

`ReplayGainInfo`（`types.ts:1211`）：`trackGain?` / `albumGain?`（dB）、`trackPeak?` / `albumPeak?`（正线性比）。

**源引用 `PlaybackSourceRef`（`src/types/onlineMusic.ts:19`）——队列身份的基础：**

```ts
export type PlaybackSourceRef =
    | { kind: 'online'; providerId: OnlineProviderId; mediaId: string;
        variant?: string; providerData?: Record<string, JsonValue>; }
    | { kind: 'local'; mediaId: string }
    | { kind: 'navidrome'; mediaId: string }
    | { kind: 'stage'; mediaId: string };
```

**队列去重键 `getPlaybackSongKey`（`src/utils/appPlaybackGuards.ts:90`）：**
`online:<providerId>:<mediaId>`，本地/Navidrome/Stage 为 `<kind>:<mediaId>`。

`UnifiedSong extends SongResult`（`types.ts:1401`）额外带 `sourceRef: PlaybackSourceRef`（必填）、`isLocal?`、`localRef?: LocalSongReference`、`isNavidrome?`、`navidromeData?: any`。

### 1.2 本地曲目：`LocalSong`（`src/types.ts:1275`

关键字段：`id: string`(UUID)、`fileName`、`filePath`、`fileHandle?: FileSystemFileHandle`（**不持久化**）、`duration`(ms)、`fileSize`、`fileLastModified?`、`fileSignature?`、`mimeType`、`bitrate?`、`addedAt`、`title`、`titleOrigin`、`importedMetadata`、`onlineMetadata?`、`trackNumber?`、`discNumber?`、`embeddedMetadataVersion?`、`localCoverAssetId?`、`localCoverSource?`、`localCoverNeedsAssetMigration?`、`replayGain?`/`replayGainTrackGain?`/`replayGainTrackPeak?`/`replayGainAlbumGain?`/`replayGainAlbumPeak?`、`matchedLyrics?: LyricData`、`matchedIsPureMusic?`、`matchedLyricsSongId?`、`hasManualLyricSelection?`、`markedPureMusic?`、`folderName?`、`noAutoMatch?`、`matchedLyricsSource?`、`matchedLyricsProviderPlatform?`、`lyricsSource?: 'local'|'embedded'|'online'`、`useOnlineCover?`、`hasLocalLyrics?`、`localLyricsContent?`、`localLyricsFormat?: 'vtt'|'ttml'|'yrc'|'qrc'|'krc'`、`localLyricsOrigin?`、`hasLocalTranslationLyrics?`、`localTranslationLyricsContent?`、`localTranslationLyricsOrigin?`、`hasEmbeddedLyrics?`、`embeddedLyricsContent?`、`hasEmbeddedTranslationLyrics?`、`embeddedTranslationLyricsContent?`。

### 1.3 传输状态：`PlayerState`（`types.ts:1130`，**枚举不是字符串联合**）

```ts
export enum PlayerState { IDLE = 'IDLE', PLAYING = 'PLAYING', PAUSED = 'PAUSED' }
```

`PlaybackContext = 'main' | 'stage'`（`types.ts:128`）。
`ReplayGainMode = 'off' | 'track' | 'album'`（`types.ts:1409`）。
`StageLoopMode = 'off' | 'all' | 'one'`（`types.ts:130`）——**这就是 RepeatMode**，主播放器复用同名联合类型。
`QueueAddBehavior = 'append' | 'next'`（`types.ts:131`）。

### 1.4 播放 store：`PlaybackStoreState`（`src/stores/usePlaybackStore.ts:35`，逐字段）

| 字段 | 类型 | 初值 |
| --- | --- | --- |
| `currentSong` | `SongResult \| null` | `null` |
| `audioSrc` | `string \| null` | `null` |
| `lyrics` | `LyricData \| null` | `null` |
| `activeLocalLyricsSource` | `ActiveLocalLyricsSource \| null`（`'local'\|'embedded'\|'online'`） | `null` |
| `cachedCoverUrl` | `string \| null` | `null` |
| `duration` | `number` | `0` |
| `playerState` | `PlayerState` | `PlayerState.IDLE` |
| `currentLineIndex` | `number` | `-1` |
| `playQueue` | `SongResult[]` | `[]` |
| `activePlaybackContext` | `PlaybackContext` | `'main'` |
| `isFmMode` | `boolean` | `false` |
| `replayGainMode` | `ReplayGainMode` | `readStoredReplayGainMode()` ← localStorage `local_replaygain_mode` |
| `lyricTimelineOffsetMs` | `number` | `0` |
| `transitionDisplay` | `TransitionDisplay \| null` | `null` |

每个字段对应一个 `setX`（`React.Dispatch<React.SetStateAction<T>>`，支持函数式更新），并在模块级导出同名 setter（`setCurrentSong` / `setAudioSrc` / …），理由见文件注释："The controller hooks used to be handed these as parameters (59 of them across nine hooks)."

`TransitionDisplay`（`usePlaybackStore.ts:7`）：`{ song: SongResult | null; lyrics: LyricData | null; coverUrl: string | null; duration: number }`——"The now-playing picture, frozen for as long as a transition is running."

**注意**：这个 store **没有** `isShuffle`、没有 `history`、没有 `volume`、没有 `loopMode`。音量/静音/循环模式在 `useAudioSettingsStore`，见 §2。

### 1.5 音频设置 store：`AudioSettingsState`（`src/stores/useAudioSettingsStore.ts:133`）

`audioQuality: 'standard'|'high'|'lossless'|'hires'`、`enableMediaCache: boolean`、`mediaCacheLimitGb: number`（0 = 无上限，默认 `DEFAULT_MEDIA_CACHE_LIMIT_GB = 5`）、`queueAddBehavior: QueueAddBehavior`、`autoPlayOnLaunch: boolean`、`enableTranscodeFallback: boolean`、`neteaseScrobbleEnabled: boolean`、`playbackFadeEnabled: boolean`（默认 **true**）、`audioOutputDeviceId: string`、`audioEqualizerSettings: AudioEqualizerSettings`、`isAudioEqualizerOpen: boolean`、`volume: number`（默认 1）、`isMuted: boolean`、`loopMode: 'off' | 'all' | 'one'`。

localStorage 键（全部在本文件）：`default_audio_quality`、`folia_enable_media_cache`（legacy `enable_media_cache` 会读回并提升）、`folia_media_cache_limit_gb`、`queue_add_behavior`、`folia_auto_play_on_launch`、`folia_enable_transcode_fallback`、`folia_netease_scrobble`、`folia_playback_fade_enabled`、`audio_output_device_id`、`player_volume`、`player_is_muted`、`player_loop_mode`、`local_replaygain_mode`、`audio_equalizer_settings`。

### 1.6 歌词类型（`types.ts:5-87`）

`Line { words: Word[]; startTime: number; endTime: number; fullText: string; translation?; id?; agentId?; songPart?; blockIndex?; romanization?; alternateTexts?: LyricAlternateText[]; backgroundVocal?: LyricBackgroundVocal; backgroundVocals?: LyricBackgroundVocal[]; renderHints?: LineRenderHints; isChorus?; chorusEffect?: 'bars'|'circles'|'beams'; wordSegments?: string[] }`

`Word { text; startTime; endTime; syllables?: LyricSyllable[] }`；
`LyricSyllable { text; startTime; endTime; endsWithSpace?; ruby?: LyricRuby[]; obscene?; emptyBeat? }`；
`LyricData { lines: Line[]; title?; artist?; isWordByWord?; ttml?: { timingMode?: 'Word'|'Line'; agents?: Record<string, LyricAgent> } }`。
时间单位一律**秒**（`types.ts` 各处注释 `// Seconds`）。

### 1.7 播放快照（handoff / Stage 用）：`PlaybackSnapshot`（`src/types/appPlayback.ts:53`）

```ts
export type PlaybackSnapshot = {
    currentSong: SongResult | null; lyrics: LyricData | null; cachedCoverUrl: string | null;
    audioSrc: string | null; playQueue: SongResult[]; isFmMode: boolean;
    playerState: PlayerState; currentTime: number; duration: number; currentLineIndex: number;
};
```

同文件还有 `PlaybackNavigationOptions { shouldNavigateToPlayer?; unavailableSkipCount?; unifiedQueue?: SongResult[]; isAutomixAdvance? }` 与 `NextTrackOptions extends PlaybackNavigationOptions { allowStopOnMissing?; fromSong?: SongResult }`。

### 1.8 每帧信号（`src/stores/motionSignals.ts`）

`currentTime`、`lyricCurrentTime`、`audioPower`（0..1）、`bass`、`lowMid`、`mid`、`vocal`、`treble`（各自归一化能量）、`spectrum: MotionValue<Uint8Array>`，以及 `audioBands: AudioBandSignals = { bass, lowMid, mid, vocal, treble, spectrum }`。
`AudioBands` 的频段定义写在 `types.ts:1414`：bass 20–150Hz、lowMid 150–400Hz、mid 400–1200Hz、vocal 1000–3500Hz、treble 3500Hz+。

### 1.9 运行期可变底座：`PlaybackRuntimeRefs`（`src/hooks/usePlaybackRuntimeRefs.ts:22`）

`audioRef: HTMLAudioElement|null`（指向**当前被听到的那路 deck**）、`audioContextRef`、`analyserRef`、`gainNodeRef`、`blobUrlRef`、`animationFrameRef`、`shouldAutoPlay: boolean`、`currentSongRef: string|number|null`、`currentSongFullRef`、`playbackAutoSkipCountRef: number`、`volumePreviewFrameRef`、`pendingVolumePreviewRef`、`pendingResumeTimeRef: number|null`、`onlinePlaybackRecoveryRef: Promise<boolean>|null`、`lastAudioRecoverySourceRef: string|null`、`currentOnlineAudioUrlFetchedAtRef: number|null`。
注释原文说明它们为何不是 state："nothing renders off them, and writing one must not schedule a render … a store write is one render too late for that."

---

## 2. 传输 / 队列语义

### 2.1 循环模式（RepeatMode）

- 值域：`'off' | 'all' | 'one'`；字段名 **`loopMode`**（不是 `repeatMode`）；类型别名 `StageLoopMode`。
- 存放：`useAudioSettingsStore.loopMode`，持久化 localStorage `player_loop_mode`（`readStoredLoopMode`，非法值回退 `'off'`）。
- 切换：`handleToggleLoopMode`，顺序 **off → all → one → off**，每次 `setStatusMessage` 提示 `player.loopOff` / `player.loopOne` / `player.loopAll`。
- `'one'` 的实现**不在 JS 里**：由 `<audio loop={effectiveLoopMode === 'one' && automix.activeDeck === deck}>`（`App.tsx:2425`）交给媒体元素原生循环，`onEnded` 里明确注释 "If single loop is active, native loop handles it."
- `'one'` 抑制 automix：`useAutomixDecks.ts:569` `if (loopMode === 'one') return report('loop-one', 'single-track loop, nothing to blend into');`
- `'all'` 的作用点在索引回绕：`handleNextTrack`（`currentIndex` 到末尾 → `nextIndex = 0`）、`handlePrevTrack`（`currentIndex === 0` → `playQueue.length - 1`）、`getNextPlayableQueueSong`（回绕只扫 `index < currentIndex` 的部分）、以及 Stage 快照的 `canGoNext`/`canGoPrevious`。

### 2.2 洗牌（Shuffle）

**没有 shuffle 状态位、没有持久化。** `shuffleQueue`（`usePlaybackQueueController.ts:1293`）是一次性队列重排：

1. `playQueue.length <= 1` 直接返回；
2. 取出当前曲 `firstSong`，其余进 `songsToShuffle`；
3. 对 `songsToShuffle` 做**反向 Fisher–Yates**（`for (let index = len-1; index > 0; index--) { randomIndex = floor(random()*(index+1)); swap }`）；
4. `nextQueue = firstSong ? [firstSong, ...songsToShuffle] : songsToShuffle` —— **当前曲固定在第 0 位**；
5. `setPlayQueue(nextQueue)` + 提示 `status.queueShuffled`；
6. 若 `currentSong && nextQueue.length > 1`，调 `invalidateAndRefetch(currentSong, nextQueue, audioQuality, userId)` 让预热缓存跟上新顺序。

结论：ARKTS 端"随机播放"只需重排数组，不需要独立的遍历顺序模型。`[推断]` 这也是原版"再次点洗牌会重新洗"的原因。

### 2.3 下一首 / 上一首

`handleNextTrack(options?: NextTrackOptions)`（同文件:874）：

1. `isNowPlayingStageActive` 直接 return（Stage 抢占时主传输无效）。
2. `stopAtQueueEnd()`：`audioRef.current.pause()` + `setPlayerState(PlayerState.IDLE)`。
3. 空队列/无当前曲：仅当 `options.allowStopOnMissing` 时停止——注释解释"An emptied queue still has to stop playback at the end of the current track; returning early here left the audio element `ended` while playerState stayed PLAYING."
4. **步进起点**：`heldSong = options?.fromSong ? null : getDisplaySong?.() ?? null`。过渡（blend）期间 `currentSong` 已经是**到达曲**，所以：
   - 有 `heldSong`（即 display 层与 raw 不同）→ 先 `endHeldTransition?.()` 取消进行中的过渡，然后从 `heldSong` 起算索引；
   - 只有 blend 自己的 advance 和"失败跳曲"才传 `fromSong` 走内部曲目。
   注释原话："stepping from the internal one is off by a song: 'next' jumps over the track being blended in."
5. **FM 续源**：`isFmMode && currentIndex >= playQueue.length - 2` → `await omni.getPersonalFm()`，追加 `nextQueue = [...playQueue, ...fmSongs]`，直接 `playSong(nextQueue[currentIndex+1], nextQueue, true, {...})` 返回。
6. **普通推进**：`currentIndex` 在 `[0, len-2)` → `+1`；`currentIndex < 0 && len > 0` → `0`；`loopMode === 'all'` 且已到末尾 → `0`；否则 `nextIndex = -1`，只在 `allowStopOnMissing` 时停止。
7. `playSong(playQueue[nextIndex], playQueue, isFmMode, { shouldNavigateToPlayer, unavailableSkipCount, isAutomixAdvance })`。

`handlePrevTrack()`（同文件:947）：同样的 `heldSong` 处理；`currentIndex > 0 → -1`；否则 `loopMode === 'all'` → `playQueue.length - 1`；否则不动作。**没有"播放超过 3 秒则回到开头"这种行为**。

**失败自动跳曲**（`skipAfterPlaybackFailure`，:973）：
`MAX_UNAVAILABLE_AUTO_SKIP_COUNT = 2`、`UNAVAILABLE_SKIP_CONFIRM_TIMEOUT_MS = 5000`、`UNAVAILABLE_SKIP_CONFIRM_INTERVAL_MS = 1000`（后两者在 `showTimedSkipPrompt` 里做 5 秒倒计时，期间界面每秒刷新）。无可跳曲或已跳 2 次 → `setPlayerState(PlayerState.IDLE)`。

`getNextPlayableQueueSong(queue, song)`（:300）：从 `currentIndex+1` 起找第一个 `isQueueSongPlayable` 的；`loopMode === 'all' && queue.length > 1` 时再扫 `[0, currentIndex)`。`isQueueSongPlayable` = 本地/Navidrome 恒真，否则 `!isSongUnavailable(song) && omni.canPlaySong(song)`。

### 2.4 "插入下一首" vs "加入队列"

设置项 `queueAddBehavior: 'append' | 'next'`（localStorage `queue_add_behavior`，默认 `'append'`）。核心算法 `applyQueueAddBehavior`（`src/utils/queueAddBehavior.ts:14`），**对两种行为都先去重再重插**：

```
1. 过滤输入 songs：跳过与 currentSong 同 key 的、以及批内重复的 → targetSongs
2. targetSongs 为空则原样返回 { changed: false }
3. queueWithoutTargets = queue 中剔除所有 targetSongs 的 key
4. behavior === 'append'  → nextQueue = [...queueWithoutTargets, ...targetSongs]
5. behavior === 'next'    → anchorIndex = queueWithoutTargets 中当前曲的下标
     - anchorIndex === -1 → nextQueue = [...targetSongs, ...queueWithoutTargets]
     - 否则               → nextQueue = [...前 anchorIndex+1 项, ...targetSongs, ...其余]
```

因此**把一首已在队列里的歌"加入队列"会把它的位置移到末尾 / 移到当前曲之后**，而不是产生重复项。`changed` 用于决定是否提示与落库。

调用链：`appendOnlineSongsToMainQueue`（`usePlaybackQueueController.ts:203`）→ `setPlayQueue` + `persistLastPlaybackCache` + toast（`status.added_to_next_play` / `status.added_to_play_queue`，`durationMs: 1200`）。Stage 抢占时写入 `mainPlaybackSnapshotRef.current.playQueue` 而不是主 store。

队列删除/移动：`src/components/app/player-panel/createQueueMutations.ts`（同样每次调用 `persistLastPlaybackCache`）。

清空：`clearQueue`（:1323）→ `setPlayQueue([])` + `persistLastPlaybackCache(currentSong, [])` + 提示 `status.queueCleared`。

### 2.5 历史

**没有播放历史栈。** "上一首"纯粹是 `currentIndex - 1`。仓库里出现的 `ProviderHistoryEntry`（`types/onlineMusic.ts:150`）是**服务商侧**的听歌历史（推荐用），不参与本地队列。也**没有**"最近播放"本地表：`last_song` / `last_queue` 只保存**最后一次**会话（§6）。

播放上报是另一条独立链路，与队列无关：`src/hooks/useNeteaseScrobbleReporter.ts`、`src/hooks/useNavidromeScrobbleReporter.ts`，由 `neteaseScrobbleEnabled` 开关控制（默认 false，"it writes to the listener's music account, so it is never a default"）。

### 2.6 启动恢复

`useSessionRestoreController`（`src/hooks/useSessionRestoreController.ts:72-182`）：

```
getFromCache<SongResult>('last_song')
getFromCache<SongResult[]>('last_queue')
  ↓ normalizePlaybackSongSource(...) 逐个补 sourceRef
  ↓ isStagePlaybackSong(lastSong) 或队列里含 stage → clearPersistedStagePlaybackCache() 后放弃
  ↓ lastSong 为空 → 放弃
  ↓ sourceRef.kind === 'online' && !omni.canPlaySong(lastSong) → 保留缓存、放弃（留给注册了该 provider 的构建）
  ↓ lastQueue 过滤掉 omni 不支持的 online 曲
  ↓ 若任一含本地快照（isLocal / localRef.songId / localData.id）：
        getLocalSongs() + getLocalLibraryCatalogSnapshot()
        按 songId 从库里重建（buildLocalQueue），删掉查不到的；确保 lastSong 在队列里
        重建成功后回写 persistLastPlaybackCache
  ↓ online 曲时对齐 activeProviderId
  ↓ setCurrentSong(lastSong); setPlayQueue(lastQueue?.length ? lastQueue : [lastSong])
  ↓ autoPlayOnLaunch（localStorage folia_auto_play_on_launch）为真 → shouldAutoPlayRef.current = true
      （必须在 source 落地前赋值，"setting it after would miss that run"）
  ↓ await restorePlaybackSourceForSong(lastSong, {...})
      失败 → shouldAutoPlayRef.current = false（否则意图会烧在下一首上）
  ↓ prefetchNearbySongs(lastSong, lastQueue, audioQuality, userId)
```

**默认恢复后暂停**：只有 `autoPlayOnLaunch` 为真才自动播。`canRestoreSession` 由调用方传入（Stage 存在时为 false）。

`restorePlaybackSourceForSong`（`src/components/app/playback/restorePlaybackSource.ts:66`）三分支：

- **Navidrome**：`navidromeApi.getSong(config, id)` 刷新 → `getStreamUrl` → `setAudioSrc` → 歌词（在线匹配或 `hydrateNavidromeLyricPayload`）→ **重算 `playbackSourceRevision = buildNavidromeSourceRevision(carrier, streamUrl)`**（注释：不重算则 representation 查不到，会重复转码）。
- **本地**：`getLocalSongs()` 按 id 找，找不到则按 `(title||fileName) 相同 && |duration - durationMs| < 1000` 兜底；`getAudioFromLocalSong` 拿 blob URL；`ensureLocalSongCoverAsset` + `applyLocalLibraryEntityDisplay` 重建 `UnifiedSong`；`resolveLocalSongLyrics` 决定 `activeLocalLyricsSource`。
- **在线**：`loadOnlineLyricsState` → `omni.canPlaySong` 检查 → `loadOnlineSongAudioSource` → `applyOnlineAudioSourceMetadata` 合并 replayGain → 缓存歌词优先（`getSongCacheWithLegacyMigration<LyricData>('lyric', ...)`）→ 否则 `omni.getLyrics`。

**播放位置不恢复**：`restorePlaybackSourceForSong` 全程不写 `pendingResumeTimeRef`，恢复后从 0 开始。`[推断]` 上游刻意如此（`pendingResumeTime` 只用于"在线 URL 过期重取后回到原位置"，见 `createOnlineRecoveryController`）。

---

## 3. 播放管线（音频如何真的响）

**使用 HTMLMediaElement + Web Audio，不用纯 WebAudio 播流。** 两个 `<audio>` 元素（deck A / deck B）由 `src/services/automix/useAutomixDecks.ts` 持有，`App.tsx:2418-2425` 渲染：

```tsx
<audio key={deck} ref={register} src={automix.deckSrc(deck)}
       preload="auto" crossOrigin="anonymous"
       loop={effectiveLoopMode === 'one' && automix.activeDeck === deck} />
```

### 3.1 图结构

`src/services/playbackGraph.ts:37-97` 是唯一的接线函数（注释说明它从 hook 里搬出来就是为了"the order can be asserted"）：

```
deckA(HTMLAudioElement) → MediaElementAudioSourceNode → [deck chain A] ┐
deckB(HTMLAudioElement) → MediaElementAudioSourceNode → [deck chain B] ┴→ mixNode (GainNode)
   → 10 段 EQ (BiquadFilter × 10) → equalizerOutput (GainNode)
   → effectChain(input=equalizerOutput, output=gainNode)
   → gainNode   ← 播放音量，仅 syncOutputGain 可写
   → fadeNode   ← 播放/暂停淡入淡出，仅 services/playbackFade 可写
   → analyser   （fftSize = 2048, smoothingTimeConstant = 0.6）
   → context.destination
```

代码里有一行自检日志，文字即规范：
`'[AudioContext] graph: decks -> mix -> equaliser -> effects -> volume -> fade -> analyser -> out'`

### 3.2 单路 deck 链（`src/services/automix/crossfadeGraph.ts:34` `AutomixDeckChain`）

```
source: MediaElementAudioSourceNode
  → replayGain: GainNode   // 本曲 ReplayGain，由 usePlaybackAudioBridge 拥有（每路独立）
  → trim: GainNode         // 过渡期间的平衡修正（BALANCE_STEP_DB = 0.75 / BALANCE_RAMP_SEC = 0.4）
  → tone: { low: BiquadFilterNode（low shelf）, mid: BiquadFilterNode（bell, MID_BELL_Q = 0.8）, high: BiquadFilterNode（high shelf） }
  → fade: GainNode         // 0..1 交叉淡化包络，唯一被端到端自动化的节点
  → throw: { send: GainNode, delay: DelayNode, feedback: GainNode }   // 回声抛掷，静默除非计划要求
  → (deckAnalyser)         // 测量用，取在 fade 之前
  → output                 // = mixNode
```

`throw` 常量：`DEFAULT_THROW_DELAY_SEC = 0.25`（有 BPM 时按网格推导）、`THROW_FEEDBACK = 0.45`、`THROW_SEND = 0.6`、`THROW_OPEN_SEC = 0.15`。
其他：`TONE_RESET_SEC = 0.12`、`CURVE_TAIL_GUARD_SEC = 0.006`（两个 48k 渲染量子）、`softLimit(x)`（0.95 以下直线、之上单调奇对称无拐角，用于 stem 总线求和）。

### 3.3 源解析阶梯（在线曲）

`loadOnlineSongAudioSource`（`src/services/onlinePlayback.ts:19`），**顺序即优先级**：

1. `getCachedSongAudioBlob(song)` 命中 → `createSafeObjectUrl(blob)` → `{ kind:'ok', audioSrc: blobUrl, blobUrl, replayGain }`；ReplayGain 从 `song.replayGain ?? prefetched?.replayGain ?? getCachedSongReplayGain(song)`（注释：这条路上永远不会再问 provider）。
2. `prefetched?.audioUrl && !== 'CACHED_IN_DB' && isUrlValid(prefetched.audioUrlFetchedAt)` → 用预热 URL。`URL_TTL_MS = 1200 * 1000`（`prefetchService.ts:39`，20 分钟）。
3. `omni.getAudioSource(song, audioQuality)` → `toSafePlaybackUrl(source?.url)`；空则 `{ kind:'unavailable' }`；异常 `OnlineProviderError` 带 `reason: ProviderErrorCode`。
4. 成功则 `updatePrefetchedAudioUrl(song, url, audioQuality, replayGain)` 回写预热缓存。

不可用原因分流（`usePlaybackQueueController.ts:577-606`）：`'preview-only' | 'auth-required' | 'region-restricted'` → 直接报错停止（不自动跳）；其他 → `getNextPlayableQueueSong` + `showTimedSkipPrompt('status.songUnavailablePrompt', ...)`（最多 2 次）。

### 3.4 本地 / Navidrome 源

- 本地：`getAudioFromLocalSong(localSong)`（`src/services/localMusicService.ts`）返回 `blob:` URL；`blobUrlRef` 持有，`retireBlobUrl`（而非立即 `revokeObjectURL`）交出旧 URL——注释："a blend is still playing the song this replaces on the other deck, and a revoked URL is a deck that can no longer be seeked."
- Navidrome：`navidromeApi.getStreamUrl(config, id)` 直连 HTTP URL。

### 3.5 自动播放意图（autoplay intent）

单标志 `shouldAutoPlayRef: boolean`，由 `usePlaybackAudioBridge.ts:245-329` 的 effect 消费。effect 的三道 bail-out（都**不消耗**意图）：`audioRef.current.getAttribute('src') !== audioSrc`、`audioRef.current.error` 存在、`isAutoplayHeld` 为真（automix 已装好下一首但未到淡化时刻，此时把状态压回 `PLAYING`）。消耗后：
- `suppressAutoplayRef` 为真 → 消耗、置 `PAUSED`、返回（"the listener presses pause and the next song starts anyway" 的修复）；
- `syncOutputGain(target, 0)` → `play()` → 成功 `setPlayerState(PLAYING)` + `setupAudioAnalyzer()`；
- 失败：若元素其实在播则记 PLAYING；`AbortError` → 把意图放回（`shouldAutoPlayRef.current = true`）；`NotAllowedError` → 提示 `status.clickToPlay` + `PAUSED`。

### 3.6 ReplayGain

`applyReplayGain`（`usePlaybackAudioBridge.ts:80`）：本地曲从 `LocalSong.replayGainTrackGain/…` 组装；Navidrome 从 `carrier.navidromeData.replayGain`；在线曲从 `song.replayGain`。计算 `calculateReplayGain(info, mode)`（`src/utils/replayGain.ts`）→ `rampGain(ctx, activeChain.replayGain, calculation.linearGain, 0.1)`。
**写到 deck 而不是共享输出**——注释："loudness compensation is a per-track value, so during a blend the two decks legitimately need different ones."

### 3.7 播放/暂停淡入淡出（`src/services/playbackFade.ts`）

独立 `fadeNode`（不是音量节点、不是 deck 增益）。

- `PLAYBACK_FADE_SECONDS = 0.2`
- `TIMER_GRACE_MS = 15`（定时器比音频线程多等一点）
- `PAUSE_DRAIN_MS = 150`（pause 后节点保持静音的时间，"the pop heard at the very end of a fade-out"）
- `RESTORE_RAMP_SECONDS = 0.03`
- API：`fadeOutThen(action) -> boolean`、`isFadingOut()`、`cancelPendingPause()`、`prepareFadeIn() -> token|null`、`runFadeIn(token)`、`abortFadeIn(token)`、`cancel()`、`flush()`。
- 每次排定的 pause 带 generation token；resume / 二次 pause / 换曲都会 bump generation 使旧 pause 失效。
- 暂停流程（`usePlaybackTransportController.ts:189`）：先算 `isSounding` → 若可淡出则 `playbackFade.fadeOutThen(settleDeferredPause)` 并立即 `setPlayerState(PAUSED)`（元素约 200ms 后才真停）；否则直接 `settlePause()`。
- 恢复流程（同文件:80）：`transportRevision` 递增 + `wantsPlayback = true`；若正在淡出且元素没在放 → `cancelPendingPause()` 直接转 PLAYING（不按 play）。`AudioContext.state === 'suspended'` 时先 `resume()`。`prepareFadeIn()` 在 `play()` **之前**调用，`runFadeIn(token)` 在成功之后。

### 3.8 分析器 → 可视化

`usePlaybackVisualizerBridge.ts`：`analyserRef.current.getByteFrequencyData(dataArray)`（`frequencyBinCount = fftSize/2 = 1024`），写入 `motionSignals` 的 `bass/lowMid/mid/vocal/treble/spectrum/audioPower`。有信号判定：`Boolean(audioElement && !audioElement.paused && !audioElement.ended)`。

### 3.9 媒体缓存（播完整首后写缓存）

`cacheSongAssets` → `cachePlayedTrackAssets(song, src, coverUrl)`（`src/services/playedTrackCache.ts`），由 `enableMediaCache` 开关门控，只在 `onEnded` 且源不是 `blob:` 时触发（`App.tsx:2559`）。容量上限 `mediaCacheLimitGb`。

---

## 4. 音频效果（完整参数表）

### 4.1 参数模型（`src/utils/audioEffects.ts`）

```ts
export type AudioEffectId =
    | 'highpass' | 'lowpass' | 'drive' | 'crush' | 'wow' | 'noise' | 'width' | 'space' | 'punch';
export type AudioEffectSettings = Record<AudioEffectId, number>;
```

控件表 `AUDIO_EFFECT_CONTROLS`（**这就是完整默认值/范围表**，`utils/audioEffects.ts:41`）：

| id | min | max | step | neutral(默认) | scale | unit | addsNoise |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `highpass` | 20 | 2000 | 1 | 20 | log | hz | |
| `lowpass` | 500 | 20000 | 1 | 20000 | log | hz | |
| `drive` | 0 | 1 | 0.01 | 0 | linear | ratio | |
| `crush` | 0 | 1 | 0.01 | 0 | linear | ratio | ✓ |
| `wow` | 0 | 1 | 0.01 | 0 | linear | ratio | |
| `noise` | 0 | 1 | 0.01 | 0 | linear | ratio | ✓ |
| `width` | 0 | 2 | 0.01 | 1 | linear | ratio | |
| `space` | 0 | 1 | 0.01 | 0 | linear | ratio | |
| `punch` | 0 | 1 | 0.01 | 0 | linear | ratio | |

`normalizeAudioEffects(value)` 逐项 `clamp(min, max)`，缺失取 neutral。滑块域为 0..1000（`audioEffectToSliderPosition` / `sliderPositionToAudioEffect`，log 域用对数映射）。

### 4.2 均衡器（10 段，`src/utils/audioEqualizer.ts` + `src/services/audioEqualizerGraph.ts`）

- 存储键 `audio_equalizer_settings`；增益范围 `AUDIO_EQUALIZER_MIN_GAIN_DB = -12` … `AUDIO_EQUALIZER_MAX_GAIN_DB = 12`。
- `AUDIO_EQUALIZER_BANDS` = 31 / 62 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 16000 Hz。
- 第 0 段 `'lowshelf'`、末段 `'highshelf'`、其余 `'peaking'`；`filter.Q.value = 1.4`；频率再夹到 `Math.min(freq, sampleRate * 0.475)`。
- 应用：`filter.gain.setTargetAtTime(nextGain, ctx.currentTime, 0.015)`；`settings.enabled === false` 时全部为 0。
- 设置结构 `AudioEqualizerSettings { enabled: boolean; gains: number[]; preset: AudioEqualizerModeId; effects: AudioEffectSettings; customSlots: AudioEqualizerCustomSlot[] }`；`customSlots` 固定两个（`['custom1','custom2']`），各含 `{ gains, effects }`。

### 4.3 效果链节点与连接顺序（`src/services/audioEffects/effectNodes.ts:91`）

```
input
 → highpass  (BiquadFilter, type='highpass', Q=0.7, frequency=20)
 → lowpass   (BiquadFilter, type='lowpass',  Q=0.7, frequency=min(20000, sr*0.475))
 → drive     (WaveShaper, oversample='4x', curve=createSaturationCurve(drive))
 → crush     (WaveShaper, curve=createBitCrushCurve(crush))
 → wowDelay  (DelayNode, maxDelayTime=0.2, delayTime 基准 WOW_BASE_DELAY_SECONDS = 0.012)
 → stereoInput (GainNode, channelCount=2, channelCountMode='explicit', channelInterpretation='speakers')
 → splitter(2) → 宽度矩阵 → merger(2)
 → compressor (DynamicsCompressor, attack=0.008, release=0.18)
 → makeup     (GainNode)
 → dry  ──────────────┐
 → wetSend → convolver → wet ─┴→ output
 noiseGain ────────────────────→ output
```

宽度矩阵（`ChannelSplitter` 2 路 → 4 个 Gain → `ChannelMerger` 2 路）：
`leftDirect: splitter[0]→merger[0]`、`rightCross: splitter[1]→merger[0]`、`leftCross: splitter[0]→merger[1]`、`rightDirect: splitter[1]→merger[1]`。

### 4.4 参数映射公式（`src/services/audioEffects/effectChain.ts:48-80`）

```ts
const active = nextEnabled ? normalizeAudioEffects(nextEffects) : DEFAULT_AUDIO_EFFECT_SETTINGS;

rampParam(ctx, nodes.highpass.frequency, active.highpass);                       // 原值 Hz
rampParam(ctx, nodes.lowpass.frequency, Math.min(active.lowpass, ctx.sampleRate * 0.475));

// drive / crush 只在值变化时重建曲线（lastDrive / lastCrush 记忆）
curve.drive = createSaturationCurve(active.drive);
curve.crush = createBitCrushCurve(active.crush);

wow.set(active.wow); noise.set(active.noise); reverb.set(active.space);

const direct = (1 + active.width) / 2;
const cross  = (1 - active.width) / 2;
leftDirect.gain = rightDirect.gain = direct;
leftCross.gain  = rightCross.gain  = cross;

compressor.threshold = -6 - active.punch * 26;   // dB,   punch 0→-6, 1→-32
compressor.ratio     =  1 + active.punch * 7;    //       punch 0→1,  1→8
compressor.knee      = 30 - active.punch * 18;   // dB,   punch 0→30, 1→12
makeup.gain          = dbToLinear(active.punch * 3);   // punch 1 → +3 dB 补偿
```

`rampParam`（`effectParams.ts:6`）：`param.cancelScheduledValues(ctx.currentTime); param.setTargetAtTime(value, ctx.currentTime, ramp)`，默认 `EFFECT_RAMP_SECONDS = 0.03`。`dbToLinear(db) = 10 ** (db/20)`。

### 4.5 三个可选分支（各自不同的 ramp 时间）

**reverb（`reverbBranch.ts`）** —— 并联卷积：
- 懒创建 `ConvolverNode`，`normalize = true`，IR = `createReverbImpulse(ctx)`，默认 `seconds = 2.2`、`decay = 2.8`，2 声道，样本 `(random*2-1) * (1-progress)**decay`。
- `wetSend → convolver → wet`。
- `space > 0`：`wet.gain = space * 0.75`、`dry.gain = 1 - space * 0.2`，ramp 0.08s。
- `space == 0`：`wet → 0`、`dry → 1`，ramp 0.08s，并 `release.schedule(teardown)`。
- 干湿互相补偿，总电平基本恒定。

**noise（`noiseBranch.ts`）** —— 黑胶噪声底，直接混到链输出：
- 缓冲 `createVinylNoiseBuffer(ctx)`：长度 `max(1, floor(sr*3))` 秒、2 声道；每样本 `(random*2-1)*0.12 + crackle*0.9`；爆音触发概率 `0.0007`，衰减系数 `0.88`。
- 走 `bandpass`：`frequency = 2600` Hz、`Q = 0.5`；`source.loop = true`。
- 增益 `noiseGain.gain = amount ** 1.4 * 0.55`，ramp 0.12s；关闭时 0 / 0.12s。

**wow / flutter（`wowBranch.ts`）** —— 延迟线调制：
- 两个 `OscillatorNode` 经各自 `GainNode` 接 `wowDelay.delayTime`：
  - wow：`frequency = 0.7` Hz，depth = `amount * 0.0045`（秒）
  - flutter：`frequency = 6.8` Hz，depth = `amount * 0.0006`（秒）
- 开启时 `wowDelay.delayTime` ramp 到 `WOW_BASE_DELAY_SECONDS = 0.012`（0.08s）；关闭时回 0。

**延迟释放（`effectBranchRelease.ts`）**：`RELEASE_DELAY_MS = 800`；`createReleaseTimer()` 的 `schedule` 只接受第一次，`cancel` 在分支重新打开时取消——避免"刚关又开"时节点被拆掉。

`createSaturationCurve(amount)`（`effectSources.ts:25`）：`amount <= 0 → null`；`shape = 1 + amount*4`；`scale = tanh(shape)`；对 1024 点曲线 `curve[i] = (tanh(shape*x) / scale) * compensation`，`x = i/(N-1)*2-1`；`compensation` 用 `measureSaturationCompensation` 对 0.5 幅度参考正弦做响度对齐（"more drive means more harmonics, not more level"，顶端约 20% THD，常用预设约 5%）。

`createBitCrushCurve(amount)`：`amount <= 0 → null`；`bits = 16 - sqrt(amount) * 12`（开方是为了让 8–10 bit 可听区落在滑块中段）；`steps = max(2, 2**(bits-1))`；8192 点曲线 `clamp(round(x*steps)/steps, -1, 1)`。

### 4.6 效果持久化

整包 `AudioEqualizerSettings` 序列化进 localStorage `audio_equalizer_settings`（`writeStoredAudioEqualizerSettings`）。`resolveAudioEqualizerSettings` 做完整迁移：`RETIRED_PRESET_IDS = ['tape','vinyl']` 折进 `custom1`；旧的单 `customGains/customEffects` 折进 `custom2`；**旧数据保持 neutral 效果链**（注释解释：把 `Lo-Fi` 这个名字补上噪声会被用户当成故障）。预设在 `src/utils/audioPresets.ts`（`AUDIO_SOUND_PRESETS`）。

---

## 5. Automix（智能过渡）

权威文档：`src/services/automix/README.md`（571 行，本节的骨架即取自它；模型细节另见 `src/services/automix/MODELS.md`）。**先读 README 再读代码**是仓库自己的要求（`docs/technical.md` 代码速查表）。

### 5.1 它是什么

不是交叉淡化器——是"上一首快放完了，下一首该怎么接进来"的完整决策系统。四层（README §1）：

| 层 | 职责 | 输入 | 输出 |
| --- | --- | --- | --- |
| 证据 | 测量音频的客观事实 | PCM | `TrackProfile`、`BeatGrid`、`TrackStems` |
| 决策 | 用乐理规则把事实变成方案 | 两首歌的证据 | `TransitionPlan`（纯数据） |
| 执行 | 把方案变成音频节点事件 | `TransitionPlan` | 增益曲线、滤波器、缓冲源 |
| 绑定 | React / DOM 外壳 | — | 两个 `<audio>` |

除 `useAutomixDecks.ts` 外，本目录**不依赖 React 或 DOM**，故单测不需要音频设备。

### 5.2 两种模式 = 两个规划器（`transitionStrategy.ts`）

```ts
export type TransitionMode = 'crossfade' | 'automix';
export interface TransitionSettings { mode: TransitionMode; crossfadeMaxSec: number; performance: boolean; }
export const DEFAULT_TRANSITION_SETTINGS = { mode: 'automix', crossfadeMaxSec: CROSSFADE_DEFAULT_SEC /* 5 */, performance: false };
```

`planForMode(settings, from, to, bpm = null, at = 0)`：
- `mode === 'crossfade'` → `planCrossfade(from, to, clampCrossfadeSeconds(crossfadeMaxSec), at)`；
- `hasEvidence(from, to, bpm)` 为真 → `planTransition(...)`，若 `settings.performance` 再补 `expansion: chooseExpansionIntensity({ tailDb, headDb, startsHot })`；
- 否则 → `planCrossfade(from, to, CROSSFADE_DEFAULT_SEC, at)` 并把 `reason` 改成 `` `automix has no evidence here, ${plan.reason} instead` ``。

`hasEvidence` = `from.profile || to.profile || (bpm 有限且 > 0) || from.lines?.length`——**三者任一**（注释解释：只看 profile 会把 21.3s 的音乐化混合退化成 5s 交叉淡化）。
`modeNeedsBeatGrid(mode)` = `mode === 'automix'`（crossfade 不读网格，因此不该付拍点模型的钱）。
`canAnalyseTracks()` = 存在 `window.OfflineAudioContext`。

### 5.3 曲目档案 `TrackProfile`（`trackProfile.ts:132`，`TRACK_PROFILE_VERSION = 9`）

采样率 `PROFILE_SAMPLE_RATE = 22050`。字段逐条：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `version` | `number` | 档案版本 |
| `partial` | `boolean` | 只分析了文件开头（Range 请求限制），所有"结尾"字段为 null 而非错值 |
| `gridless?` | `boolean` | 拍点模型**从未跑过**（区别于"跑过但没结果"） |
| `duration` | `number` | 实际分析秒数，非曲长 |
| `leadIn` | `number` | 开头数字静音秒数 |
| `vocalStart` | `number \| null` | 第一个持续中置人声时刻（单声道或纯器乐为 null） |
| `sectionStart` | `number \| null` | 第一个结构边界（Foote novelty） |
| `sections` | `number[]` | 全部边界秒数 |
| `leadOut` | `number \| null` | 结束后数字静音 |
| `bodyOut` | `number \| null` | 从停止保持电平到文件末尾的距离（衰减尾 + 静音），≥ `leadOut`；**从末端量起** |
| `startsHot` | `boolean` | 开头即满电平 |
| `endsHot` | `boolean \| null` | 结束仍满电平 |
| `introSlope` | `number` | 开头 EDGE_WINDOW_SEC 内 dB/秒 |
| `outroSlope` | `number \| null` | 末尾 EDGE_WINDOW_SEC 内 dB/秒 |
| `loudness` | `number` | 有声段 RMS（dBFS） |
| `headDb` | `number` | 开头窗 K 计权电平（LUFS） |
| `tailDb` | `number \| null` | 结尾窗同上 |
| `introTone` | `number[]` | 开头窗三段能量占比 `[<250Hz, 250Hz–4kHz, >4kHz]`，和为 1 |
| `outroTone` | `number[] \| null` | 同上，结尾窗 |
| `bpm` | `number \| null` | 全曲 BPM |
| `outroBpm` | `number \| null` | 末 `OUTRO_TEMPO_SEC` 的 BPM |
| `beatOffset` | `number` | 到网格第一拍的秒数 |
| `downbeatOffset` | `number \| null` | 到第一个小节线（**锚在末拍回推**） |
| `headDownbeatOffset` | `number \| null` | 同一小节线，但**从曲首量**（进场侧唯一可用的） |
| `beatsPerBar` | `number` | 恒 4（显式写出） |
| `key` | `number` | 主音 pitch class，0 = C，-1 = 无 |
| `major` | `boolean` | 大调/小调 |
| `keyConfidence` | `number` | 0..1 |
| `introKey` | `KeyEstimate` | 开头窗调性 |
| `outroKey` | `KeyEstimate \| null` | 结尾窗调性 |

`KeyEstimate { key: number; major: boolean; confidence: number }`。
调性用 **Krumhansl-Schmuckler** 模板相关：`MAJOR_PROFILE = [6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88]`、`MINOR_PROFILE = [6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17]`（12 个旋转取最大相关）。
结构分析常量：`NOVELTY_BIN_SEC = 1`、`NOVELTY_HALF_KERNEL = 4`、`NOVELTY_MIN_KERNEL = 2`、`NOVELTY_MIN_SEC = 2`、`NOVELTY_SIGMAS = 1`。

### 5.4 过渡方案 `TransitionPlan`（`transitionPlanner.ts:57`）

```ts
export type TransitionKind = 'hardCut' | 'fade';

export interface TransitionPlan {
    kind: TransitionKind;
    style: TransitionStyle;      // beatCut | bassSwap | tailRide | plainBlend
    relation: KeyRelation;       // compatible | adjacent | neutral | clashing | unknown
    tempo: TempoRelation;        // locked | near | stretchable | drifting | far | unknown
    stretch: number;             // 出场曲 playbackRate，1 = 不变速
    tiltDb: [number, number];    // 进场曲中/高频修正 dB
    echoThrow: boolean;
    outStart: number;            // 出场曲第几秒开始过渡
    inStart: number;             // 进场曲从第几秒起播
    overlap: number;             // 占用出场曲尾部多少秒
    minOverlap: number;
    reason: string;
    expansion?: number | null;   // 0.25 / 0.5 / 0.75 / 1
}
```

`TransitionTrack { duration: number; lines: Line[] | null; profile?: TrackProfile | null; vocalEnd?: number | null; separated?: { from: number; to: number } | null }`。

关键常量（`transitionPlanner.ts`）：
`AUTOMIX_MAX_OVERLAP_SEC = 25`、`AUTOMIX_MIN_OVERLAP_SEC = 0.8`、`AUTOMIX_DEFAULT_OVERLAP_SEC = 5`、`AUTOMIX_MIN_CUT_ROOM_SEC = 0.15`、`AUTOMIX_DEFAULT_OVERLAP_BEATS = BEATS_PER_PHRASE * 2`、`GRID_SNAP_BEATS = 1`、`SECTION_SNAP_SEC = 2`、`MAX_TRIMMED_TAIL_SEC = 10`、`ENTRY_MARGIN_SEC = 0.1`。

落点公式（README §9）：`min(soundingEnd − overlap, max(bodyEnd, lastSungMoment))`。
长度：`一个乐句（BEATS_PER_PHRASE = 16 拍） × 各系数 → 按乐句/小节/拍取整`，天花板 25s；超天花板时**退整数个小节**而不是把上限当答案。

### 5.5 接法选择（`transitionChooser.ts`）

`TransitionStyle` 四种：`beatCut` / `bassSwap`（默认重叠接法）/ `tailRide` / `plainBlend`（兜底）。
常量：`MIN_KEY_CONFIDENCE = 0.25`、`FADE_OUT_SLOPE_DB_PER_SEC = -1.5`、`INTRO_SILENCE_SEC = 0.3`、`BEAT_CUT_SEC = 0.04`、`CUT_LEAD_SEC = 1.5`、`HEAD_BUDGET_SEC = 0.05`。

长度系数（**相乘**，README §9 明确写出会相乘，且有 **0.25 地板**）：

```ts
const LENGTH_SCALE: Record<KeyRelation, number> =
  { compatible: 1, adjacent: 0.85, neutral: 0.7, clashing: 0.4, unknown: 1 };
const STYLE_SCALE: Record<TransitionStyle, number> =
  { beatCut: 1, bassSwap: 1, tailRide: 1.4, plainBlend: 1 };
const ENERGY_STEP_CEILING_DB = 12;   const ENERGY_STEP_SCALE = 0.4;
const HOT_START_SCALE = 0.6;
```

### 5.6 Crossfade 规划器（`crossfadePlanner.ts`）——**可移植性最高的一块**

`CROSSFADE_MIN_SEC = 1`、`CROSSFADE_MAX_SEC = AUTOMIX_MAX_OVERLAP_SEC = 25`、`CROSSFADE_DEFAULT_SEC = 5`、`clampCrossfadeSeconds` 取整并夹紧。

`planCrossfade(from, to, seconds, at = 0)` 的三道天花板（全是**事实**不是判断）：

```
end     = endsOf(from).sounding             // 去掉尾部数字静音
inStart = max(0, (to.profile?.leadIn ?? 0) - ENTRY_MARGIN_SEC)
incoming= to.duration 有限 ? max(0, to.duration - inStart) : Infinity
room    = min( max(0, end - at), incoming, end / 4 )
overlap = min(clampCrossfadeSeconds(seconds), room)
overlap < AUTOMIX_MIN_OVERLAP_SEC → hardCut(`no room to crossfade - ${room}s available`)
```

输出固定：`style:'plainBlend'`、`relation:'unknown'`、`tempo:'unknown'`、`stretch:1`、`tiltDb:[0,0]`、`echoThrow:false`、`outStart: round(end - overlap)`、`minOverlap: AUTOMIX_MIN_OVERLAP_SEC`。文件注释："These fields state the crossfade as the absence of automix's four moves."

### 5.7 执行（`automixSession.ts` + `crossfadeGraph.ts` + `useAutomixDecks.ts`）

状态机：`AutomixPhase = 'idle' | 'armed' | 'fading'`，deck `AutomixDeckId = 'A' | 'B'`。
关键常量：`AUTOMIX_ARM_LEAD_SEC = 1`、`RELEASE_MARGIN_SEC = 0.25`、`FADE_CLEANUP_MARGIN_MS = 150`、`CUT_SECONDS = 0.05`、`BALANCE_INTERVAL_MS = 100`、`BALANCE_RAMP_SEC = 0.4`、`BALANCE_STEP_DB = 0.75`、`MAX_ALIGN_HOLD_SEC = 1`。

流程（README §3 的图，逐字转述）：
1. **预取阶段**（播放前数分钟）：`ensureTrackProfile(song)` → `fetch(Range)` → `decodeAudioData` → `analyseBeatGrid`（→ utilityProcess → ONNX）→ `analyseTrack(pcm)`；
2. **准备阶段**：`ensureStems({song, role})` → utilityProcess → htdemucs，首/尾各 30 秒（`STEM_WINDOW_SEC`）；
3. **排程阶段**：`checkTransitionPoint()` → `planForMode(...)` → `phase='armed'`，`onAutoplayHoldChange(true)`（进场 deck 加载缓冲但不出声），`advanceTrack()` 队列提前推进；
4. **执行阶段**：`phase='fading'` → `applyTempoBend(element, stretch)` → 有 stem 则 `planVocalExit()` + `planStemHandover()` + `connectStemBus()` + `connectStemDeck()×2` + `scheduleStemWindow()`；无 stem 则 `scheduleCrossfade()` + `scheduleBandBlend()` → 可选 `scheduleEchoThrow()` → `settle()`（**所有结局的必经之路**）。

时钟与变速（README §6.6）：
- `deckClock.ts` 把 `currentTime` 的阶梯读数拟合成直线（斜率即 `playbackRate`），精度到毫秒以下，从而**不需要 AudioBufferSourceNode / 整曲解码 / 重写进度条**；
- **变速只弯出场曲**；
- `tempoBend.ts` 只剩两个属性赋值：`playbackRate` + `preservesPitch`（**每次显式写入**，且 README 明确警告：元素自带时间伸缩器，不要再写 WSOLA）；
- `STRETCH_LIMIT = 0.12`（变速上限）、`DRIFT_LIMIT = 0.25`（重叠上限），中间地带叫 `drifting`。

### 5.8 是否"重 DSP"

按 README §7 的能力分级，Automix 可切成两半：

| 子能力 | 桌面 | 浏览器 | 依赖 |
| --- | --- | --- | --- |
| htdemucs 分离 | ✅ | ❌ | `onnxruntime-node` + `models/*.onnx`，`electron/analysis/*` |
| build-up 表现模式 | ✅ | ❌ | 由 htdemucs 派生 |
| Beat This! 拍点 | ✅ | ❌ | ONNX（前处理常数是契约：22050Hz / n_fft 1024 / hop 441 / Slaney mel 30–11000 / `log1p(1000x)` / 1500 帧分块 / 6 帧边界） |
| 曲目分析 | ✅ | ✅ | `OfflineAudioContext` + `fetch(Range)` |
| 变速对齐 | ✅ | ✅ | `playbackRate` + `preservesPitch` |
| 软限幅 | ✅ | ✅ | `WaveShaper` |
| 全套规划与选择 | ✅ | ✅ | 纯算术 |

**结论**：真正需要重 DSP 的只有 `beatThis.ts`（梅尔谱 + FFT + ONNX）和 `stems.ts`（htdemucs 推理）；`signalAnalysis.ts`/`trackProfile.ts` 的其余部分（K 计权、自相关测速 est、novelty、chroma）是纯 TS 数学，可逐行移植，代价是 **CPU 时间**而非算法复杂度（预算：扫描按毫秒让出主线程，预算 **8 ms**）。规划层（`transitionChooser` / `transitionPlanner` / `crossfadePlanner` / `musicalTime` / `stemGesture` 的算式部分）是**零 DSP 的纯函数**，是最高价值、最低风险的移植目标。

排序与门控：`modelsPresent()`（`modelAvailability.ts`）→ `TransitionCapabilities { beatGrid, stems, full, desktop }`；`shouldRemindAboutModels()` 在 `!present.beat_this || !present.htdemucs` 时提示（但浏览器构建直接返回 false，因为"a prompt there is an errand that does not exist"）。

---

## 6. 播放恢复 / 持久化

### 6.1 存储后端

**IndexedDB / Dexie**，库名 `APP_DATABASE_NAME = 'KineticPlayerDB'`（`src/services/appDatabase.ts:10`），class `AppDatabase extends Dexie`。表与索引（`this.version(...).stores({...})`）：

| 版本 | 变化 |
| --- | --- |
| `0.6` | `session: ''`、`api_cache: 'key'`、`user_cache: 'key'`、`media_cache: 'key'`、`metadata_cache: 'key'`、`local_music: 'id'`、`theme_registry: 'fingerprint'` |
| `0.7` | 新增 `local_library_entities: 'id, kind, *normalizedAliases, mergedInto, needsReview, createdAt'`、`local_library_assignments: 'songId, *artistEntityIds, albumEntityId, artistOrigin, albumOrigin'` |
| `0.8` | 同 schema + `upgrade()`：把 `local_music` 全表读出来跑 `migrateLegacyLocalSongRecords`，重建 entities / assignments |
| `0.9` | `local_music: 'id, localCoverAssetId'`，新增 `local_cover_assets: 'id'` |

`this.on('versionchange')` → `close()` + 派发 `APP_DATABASE_VERSION_CHANGE_EVENT`（`'folia-database-version-change'`）+ `window.location.reload()`。
标记键：`LOCAL_LIBRARY_BOOTSTRAP_MARKER_KEY = 'local_library_entities_bootstrap_v1'`、`LOCAL_LIBRARY_ARTIST_SPLIT_MARKER_KEY = 'local_library_artist_split_v1'`。

缓存路由 `getCacheTableName(key)`（`repositories/cacheRepository.ts:29`）——**这就是缓存键到表的映射规范**：

```
USER_CACHE_KEYS = { user_profile, user_playlists, user_liked_songs, user_cloud_playlist }
  或 key 匹配 online_provider_*_user_*                     → user_cache
key ∈ { last_song, last_queue, last_theme }                → api_cache
key 前缀 audio_ 或 cover_                                  → media_cache
key 前缀 automix_profile_ | lyric_ | theme_ | replayGain_
   | playlist_tracks_ | playlist_detail_                   → metadata_cache
其余                                                        → api_cache
```

`playbackRecovery` 的播放位置不在此列；`SessionData`（`dbTypes.ts:6`）是**旧的单文件会话**：`audioFile?: File|Blob`、`fileName?`、`lyricId?`、`lyrics?: LyricData`、`theme?: Theme`、`cachedAiBg?`、`coverUrl?`、`timestamp?`，由 `sessionRepository` 用 Dexie 显式主键表 `appDatabase.session.put(value, key)` 存 7 个 out-of-line 键（`SESSION_KEYS`）。

### 6.2 播放到底持久化了什么

`persistPlaybackCache`（`src/components/app/playback/persistPlaybackCache.ts:16`）**只有两个键**：

```
saveToCache('last_song',  sanitizePlaybackSong(song))
saveToCache('last_queue', queue.filter(!isStagePlaybackSong).map(sanitizePlaybackSong))
```

`sanitizePlaybackSong`：把本地曲压缩成 `{ ...snapshot, isLocal: true, localRef: { songId } }` 并**剥掉 `localData`**（"Persists local playback as a lightweight songId reference"）。
Stage 曲目一律**不持久化**。

**没有被持久化的播放状态**：`playerState`、播放位置、`isFmMode`、`volume`（另有键）、`loopMode`（另有键）、`activePlaybackContext`。
`[推断]` 因此恢复后一律从 0:00、暂停态开始，除非 `autoPlayOnLaunch`。

写入时机（`void persistLastPlaybackCache(...)`，**无节流、无 debounce**）：
`playSong` 换曲（:646）、`appendOnlineSongsToMainQueue`（:240）、公开/私有队列增删（`createQueueMutations.ts`）、`shuffleQueue`（通过 `invalidateAndRefetch` 之后的队列）、`clearQueue`（写空队列）、`handleStagePlayerQueueRequest`（:1262）、`restorePlaybackSourceForSong` 三条分支（:128/:204/:244）、`createOnlineRecoveryController`（:151）、歌词状态变更（`useLibraryPlaybackController` 内 10+ 处）。**写入以"每次队列/曲目变更"为粒度，不是定时器。**

### 6.3 其它播放相关持久化键

| 键前缀 | 表 | 内容 |
| --- | --- | --- |
| `audio_*` | media_cache | 在线曲音频 Blob |
| `cover_*` / `cover_local_*` | media_cache | 封面 |
| `replayGain_*` | metadata_cache（分类时随 media 清除） | ReplayGain |
| `lyric_*` | metadata_cache | 歌词 |
| `automix_profile_*` | metadata_cache | `TrackProfile`（独立 `analysis` 缓存分类，清音频时**不**清它） |
| `theme_*` / `last_theme` | metadata_cache / api_cache | 主题 |
| `local_dir_handles` | api_cache | `FileSystemDirectoryHandle` 映射 |
| `local_snapshot_<root>` | api_cache | 本地库快照 |

localStorage：全部设置项（§1.5）+ `local_replaygain_mode`。

### 6.4 恢复算法（启动到出声）

见 §2.6 的逐步流程。补充要点：

- 缓存读取入口 `getFromCache<T>(key)`（`services/db.ts:88`）→ `readCacheEntry` → 按 `getCacheTableName` 找表，miss 时对 `movedOutOfApiCache(key)`（`USER_CACHE_KEYS` 或 `automix_profile_` 前缀）做**惰性迁移**（找到旧行 → 事务内搬到新表 + 删旧行 → 返回）；`tableName === 'api_cache'` 时不做这次回退（"a miss is the ordinary case for covers and lyrics"）。
- `getFromCacheWithMigration<T>(key, migrate)` 用于歌词结构升级（`migrateLyricDataRenderHints`）。
- Stage 会话恢复是另一条路：`useStagePlaybackController.restoreStagePlaybackHandoff(handoff)` + `clearPersistedStagePlaybackCache()`。

### 6.5 源失效 / 恢复阶梯

**(a) 流 URL 过期刷新**（`createOnlineRecoveryController.ts`）：
- `shouldRefreshCurrentOnlineAudioSource()`：非本地/非 Navidrome/非 Stage，`audioSrc` 存在且非 `blob:`，且 `Date.now() - fetchedAt >= onlineAudioUrlTtlMs - onlineAudioUrlRefreshBufferMs`。
- `recoverOnlinePlaybackSource({ failedSrc, resumeAt, autoplay, shouldAutoplay })`：
  1. **幂等键** `getOnlineRecoveryKey(src)` = `origin + pathname`（`[推断]` 目的注释已写明：QQ 每次给新 `vkey`/`guid`，比全 URL 会无限循环）；若 `lastAudioRecoverySourceRef.current === key` → **直接返回 false**（同一媒体已刷过一次还失败，不再循环）；
  2. 并发合并：`onlinePlaybackRecoveryRef.current` 非空则复用同一 Promise；
  3. `loadOnlineSongAudioSource(song, audioQuality, null)` 重取；
  4. 校验 `currentSongRef.current === getPlaybackSongKey(song)`，否则丢弃；
  5. 换 blob 时 revoke 旧 `blobUrlRef`；
  6. `applyOnlineAudioSourceMetadata` 合并新 replayGain → `setCurrentSong` + `setPlayQueue(replacePlaybackSongInQueue(...))` + `persistLastPlaybackCache`；
  7. `pendingResumeTimeRef.current = max(0, resumeAt ?? element.currentTime)` —— **恢复位置靠这个 ref**；`shouldAutoPlayRef.current = autoplay && (shouldAutoplay?.() ?? true)`（注释：解析新源不能撤销在途的暂停）；
  8. `currentOnlineAudioUrlFetchedAtRef.current = audioSrc.startsWith('blob:') ? null : Date.now()`；`setAudioSrc(...)`。

**(b) 元素解码失败 → 转码兜底（桌面专属）**：
`classifyMediaElementFailure(error, source)`（`mediaFailureClassifier.ts:16`）→ `MediaFailureKind = 'aborted' | 'network' | 'decode' | 'unsupported' | 'unknown'`；`eligibleForTranscode` 仅在 `MEDIA_ERR_DECODE(3)` 与 `MEDIA_ERR_SRC_NOT_SUPPORTED(4)`（且源不是 `folia-transcode:` 开头，避免二次转码）为真。
`startPlayableTranscode(song, failedSource, localSongs, priority)` → `window.electron.requestTranscodeFallback(request)`；错误码 `NOT_ELECTRON` / `SOURCE_UNAVAILABLE` / `CANCELLED`。请求体 `TranscodeFallbackRequest { requestId, priority, source, limitBytes: mediaCacheLimitGb * 1024**3 }`；`TranscodeFallbackSource` 有 `kind: 'local'|'navidrome'`、`songKey`、`sourceRevision`、`fileName`、`data` 或 `url`。

**(c) 表现缓存 `representationRegistry`**：`Map<songKey, PlaybackRepresentation>`；`getPlaybackRepresentation(song)` 先比 `song.playbackSourceRevision`，不一致则**删条目并返回 null**；`getPlaybackAnalysisKey(song)` = `` `${songKey}@${representationId}` ``。修订号生成 `buildLocalSourceRevision(song, file)` = `` `${id}:${size}:${lastModified}` ``；`buildNavidromeSourceRevision(song, url)` = `` `[id, path, suffix, durationMs, safeUrlIdentity(url)]` ``（`safeUrlIdentity` 只保留 `origin + pathname + format&maxBitRate`，**刻意剔除 token**）。

---

## 7. 移植特性清单

复杂度：L = 纯逻辑/数据、M = 需平台 API 或中等算法、H = 重算法/重平台能力/需重新设计。
"可行"列针对 ArkTS + HarmonyOS（`@ohos.multimedia.media` AVPlayer / `@ohos.multimedia.audio` AudioRenderer）。

| # | 特性 | 源码 | 复杂度 | ArkTS 可行性 |
| --- | --- | --- | --- | --- |
| 1 | 曲目模型 `SongResult` / `PlaybackSourceRef` / `getPlaybackSongKey` | `types.ts:1220`、`types/onlineMusic.ts:19`、`utils/appPlaybackGuards.ts:90` | L | ✅ 直接翻译（interface → interface） |
| 2 | 播放 store（15 字段 + setter） | `stores/usePlaybackStore.ts` | L | ✅ `@Observed`/`AppStorage` + 类 |
| 3 | raw/display 双层与 5 个 selector | `stores/usePlaybackStore.ts:142-176` | L | ✅ 纯函数；**必须保留** |
| 4 | 每帧信号（currentTime / 歌词钟 / 频段） | `stores/motionSignals.ts` | M | ⚠️ `MotionValue` 无对应物；用无订阅的可变单例 + 手动 dirty 通知 |
| 5 | 循环模式 off/all/one | `stores/useAudioSettingsStore.ts:114-121,287` | L | ✅ `'one'` 用 AVPlayer `loop` |
| 6 | 洗牌（Fisher–Yates 保当前曲） | `usePlaybackQueueController.ts:1293` | L | ✅ |
| 7 | 插入下一首 vs 加入队列 | `utils/queueAddBehavior.ts` | L | ✅ 纯函数，逐行可搬 |
| 8 | 下一首/上一首（含 display-song 步进） | `usePlaybackQueueController.ts:874,947` | M | ✅ 逻辑纯；`getDisplaySong`/`endHeldTransition` 依赖过渡，见 #20 |
| 9 | 不可用自动跳曲（倒计时 5s，最多 2 次） | `usePlaybackQueueController.ts:973` + `showTimedSkipPrompt` | L | ✅ |
| 10 | 在线源解析阶梯（缓存 → 预热 → provider） | `services/onlinePlayback.ts:19` | M | ✅ 换成 `@ohos.net.http` / `request` + 文件 Blob |
| 11 | 流 URL TTL 刷新 + 幂等键 | `createOnlineRecoveryController.ts` | M | ✅ 逻辑可搬 |
| 12 | 媒体缓存（整曲播完写） | `services/playedTrackCache.ts`、`services/audioCache.ts` | M | ⚠️ 用 RDB/file 目录替代 Dexie media_cache |
| 13 | 预热（next 2 / prev 1，LRU 200，TTL 20min） | `services/prefetchService.ts:37-40` | M | ✅ 逻辑可搬；`PREFETCH_COUNT_NEXT=2`、`PREFETCH_COUNT_PREV=1`、`MAX_PREFETCH_CACHE_SIZE=200` |
| 14 | ReplayGain（track/album/off + peak 限制） | `utils/replayGain.ts`、`usePlaybackAudioBridge.ts:80` | L | ✅ 纯数学 |
| 15 | 播放/暂停 0.2s 淡入淡出 | `services/playbackFade.ts` | M | ⚠️ 需自建增益斜坡（AudioRenderer 可变速/可 setVolume，但无 GainNode） |
| 16 | 10 段 EQ（±12dB，shelf/peaking） | `utils/audioEqualizer.ts`、`services/audioEqualizerGraph.ts` | M | ⚠️ 用 `audio.AudioEqualizer`/`AudioEffect` 或自写 biquad DSP |
| 17 | 9 个效果参数模型 + 预设/自定义槽 | `utils/audioEffects.ts`、`utils/audioEqualizer.ts` | L | ✅ 数据模型可原样搬 |
| 18 | 效果链（HP/LP/drive/crush/wow/stereo/comp/reverb/noise） | `services/audioEffects/*` | H | ⚠️ **ArkTS 无 Web Audio**；9 个效果中 reverb(Convolver)/noise(BufferSource)/wow(LFO→delayTime) 无对等节点，需 NAPI/C++ DSP 或用 AudioEffect 库近似 |
| 19 | 双 deck 音频图 + 交叉淡化/分频接缝/回声/软限幅 | `playbackGraph.ts`、`automix/crossfadeGraph.ts` | H | ⚠️ 需用两个 AudioRenderer/AVPlayer + 自建混音与增益自动化 |
| 20 | Automix 会话状态机 idle→armed→fading | `automix/automixSession.ts`（73KB） | H | ✅ 逻辑可搬，但 #19 是前置 |
| 21 | Crossfade 规划器（纯函数） | `automix/crossfadePlanner.ts` | L | ✅ **最高性价比，建议第一批移植** |
| 22 | Automix 规划器 + 接法选择 + 音乐时间 | `transitionPlanner.ts`、`transitionChooser.ts`、`musicalTime.ts` | M | ✅ 纯算术，仅依赖 `Line[]` 与 `TrackProfile` |
| 23 | 曲目档案 `TrackProfile`（非模型部分） | `automix/trackProfile.ts`、`signalAnalysis.ts` | H | ⚠️ 纯 TS 数学可移，但需要 FFT + 大块 PCM 解码 + 8ms 让出预算；CPU 与内存是主要风险 |
| 24 | Beat This! 拍点（ONNX） | `automix/beatThis.ts` + `electron/analysis/*` | H | ❌ 需 ONNX Runtime for HarmonyOS / MindSpore Lite；**建议第一期直接用 `estimateTempo` / `estimateDownbeat` 回退**（README 说这是浏览器构建的既有退路） |
| 25 | htdemucs 音轨分离 | `automix/stems.ts`、`stemGesture.ts`、`expansionGesture.ts` | H | ❌ 同上；无分离即无 stem 手势与 build-up |
| 26 | 变速对齐 tempoBend | `automix/tempoBend.ts` | L | ✅ AVPlayer `setSpeed()`；**需验证保音高行为** `[推断]` |
| 27 | 曲目过渡时钟拟合 deckClock | `automix/deckClock.ts` | M | ✅ 纯数学，喂 AVPlayer 的 `currentTime` |
| 28 | 队列/会话持久化（last_song / last_queue） | `persistPlaybackCache.ts`、`services/db.ts`、`repositories/*` | M | ⚠️ Dexie → `@ohos.data.relationalStore`；schema 可照搬 §6.1 |
| 29 | 启动恢复 | `useSessionRestoreController.ts` | M | ✅ 逻辑可搬 |
| 30 | Session（旧单文件会话）表 | `repositories/sessionRepository.ts` | L | ⚠️ 只服务于旧版本，`[推断]` 可直接丢弃 |
| 31 | 本地库（扫描/实体/封面/匹配） | `services/localMusicService.ts`、`localLibrary*` | H | ❌ 依赖 `FileSystemDirectoryHandle`；HarmonyOS 需改用媒体库 / picker / 沙箱目录 |
| 32 | 歌词解析 6+ 格式 | `utils/lyrics/parserCore.ts` | M | ✅ 纯 TS，逐行可搬（见 §7.1） |
| 33 | 歌词时钟 + `lyricTimelineOffsetMs` | `stores/motionSignals.ts`、`usePlayback...` | L | ✅ |
| 34 | 分析器频段 → 可视化 | `usePlaybackVisualizerBridge.ts` | M | ⚠️ 需在 AudioRenderer 侧接 FFT 或复用 #23 的 FFT |
| 35 | 个人 FM 续队列 | `usePlaybackQueueController.ts:908` + `omni.getPersonalFm` | L | ✅ 走 HTTP provider |
| 36 | 睡眠定时器 | `stores/useSleepTimerStore.ts` | L | ✅ |
| 37 | 播放上报（网易云/Navidrome scrobble） | `useNeteaseScrobbleReporter.ts`、`useNavidromeScrobbleReporter.ts` | L | ✅ `[推断]` 仅在对应 provider 接入后需要 |
| 38 | 音频输出设备选择 | `useAudioOutputDevice.ts`、`audio_output_device_id` | M | ⚠️ `setAudioRendererInfo` / 设备枚举 API 需核对 |
| 39 | 扩展钩子 `beforePlay` | `services/hostExtensionHooks.ts` | L | ⚠️ mods 系统一般不进移植（§8） |

### 7.1 歌词解析导出面（`src/utils/lyrics/parserCore.ts`）

```
export type LyricParseFormat = TimedLyricFormat | 'yrc' | 'qrc' | 'krc' | 'awlrc';
export interface TimedTextEntry { ... }                       // :11
export const INTERLUDE_FULL_TEXT = '......';                  // :56
export const isInterludeLine = (line: Pick<Line,'fullText'>) => line.fullText === INTERLUDE_FULL_TEXT;  // :119
export const attachInterludes = (lines: Line[]): Line[];      // :121
export const finalizeParsedLyricLines = (...);                // :165
export const findTranslationsForSortedStartTimes = (...);     // :211
export const parseLRC = (...);                                // :428
export const parseYRC = (...);                                // :489
export const parseQRC = (...);                                // :570
export const parseVTT = (...);                                // :780
export const parseTTML = (...);                               // :818
export const parseEnhancedLRC = (...);                        // :838
export const parseKRC = (...);                                // :953
export const parseAwlrc = (...);                              // :1154
export const parseLyricsByFormat = (...);                     // :1234
```

`parserCore.ts` 是 CODEMAP 里的枢纽模块（被 32+ 模块依赖）。移植时**只需这一份文件 + `renderHints.ts` + `graphemeTiming.ts`**，无平台依赖。

---

## 8. 应放弃的桌面专属能力

按"能不能省"分级，附文件。**P0 = 直接删，无播放影响；P1 = 功能级删除，需在设置里隐藏；P2 = 需要替代方案。**

| 级别 | 能力 | 文件 |
| --- | --- | --- |
| **P0** | 壁纸模式（window-to-layer / 桌面层） | `electron/macWallpaperController.cjs`、`electron/windowsWallpaperController.cjs`、`electron/windowsWallpaperMouse.cjs`、`electron/windowsWallpaperTarget.cjs`、`electron/wallpaperWatchdog.cjs`、`electron/wallpaperEntryRequest.cjs`、`build/windowtolayer`、`docs/wallpaper-mode.md`、`src/stores/useWallHandoffStore.ts`、`src/components/wall/*`、脚本 `npm run build:windowtolayer` / `dev:electron:wallpaper` / `build:wallpaper-helper` |
| **P0** | 外部遥控窗（Remote Control） | `electron/remoteControlWindowSettings.cjs`、`src/types/remoteControl.ts`、`src/components/remote/*`、`src/utils/playbackSyncBridge.ts`、`src/hooks/usePlayerChromeAutoHide.ts`、`useElectronPlaybackBridge.ts` 中 `publishRemoteControlSnapshot` / `onRemoteControlCommand` 分支 |
| **P0** | Discord Rich Presence | `electron/discordPresence.cjs`、`useElectronPlaybackBridge.ts` 中 `publishDiscordPresenceSnapshot`（:344, :521） |
| **P0** | OBS 浏览器源 | `src/services/obs/*`（`currentObsUrl.ts`、`obsCustomCss.ts`、`visualSettingsConfig.ts`、`webObsTarget.ts`）、`src/utils/obsBrowserSource.ts`、`src/utils/obsUrl.ts`、`src/types/obsBrowserSource.ts`、`src/hooks/useObsBrowserSourcePublisher.ts`、`src/components/obs/*` |
| **P0** | Windows 任务栏控制 / 缩略图按钮 | `useElectronPlaybackBridge.ts` 的 `onTaskbarControl` / `updateTaskbarControls`（:391, :419） |
| **P0** | 语音输入自动暂停 | `electron/voiceInputPause.cjs`、`onVoiceInputStateChanged`（:435） |
| **P0** | 视频导出（ffmpeg） | `src/services/electronVideoExport.ts`、`src/hooks/useElectronVideoExportController.ts`、`electron/modSystem/ffmpeg.cjs` |
| **P0** | 窗口间播放移交（main ↔ 遥控窗） | `electron/windowPlaybackHandoff.cjs`、`src/hooks/useElectronWindowPlaybackHandoff.ts`、`src/types/appPlayback.ts` 中 `WindowPlaybackHandoff*` |
| **P0** | mods / Folium 扩展系统 | `src/mods/*`、`electron/modSystem/*`、`src/services/hostExtensionHooks.ts`（`beforePlay` / `lyrics.transform` 钩子） |
| **P0** | 歌词语义接口（127.0.0.1:32109） | `electron/lyricApi.cjs`、`docs/lyric-api.md` |
| **P1** | Stage API / NowPlaying / PlayerCap 三路外部播放源 | `electron/stageApi.cjs`、`src/hooks/useStagePlaybackController.ts`（57KB）、`src/services/nowPlayingProvider.ts`、`src/services/playerCapProvider.ts`、`src/types/playerCap.ts`、`src/utils/playerCapSession.ts`、`stage-client.html` |
| **P1** | 转码兜底（ffmpeg 子进程） | `electron/transcode/{cache,protocol,runner,service}.cjs`、`src/services/playbackRecovery/playableSourceService.ts`、`src/hooks/useTranscodeFallback.ts`、`src/types/playbackRecovery.ts` |
| **P1** | onnx / htdemucs 推理（含 `utilityProcess` 隔离、模型下载与 sha256 校验） | `electron/analysis/{host,worker,sidecar,modelPaths,modelStore}.cjs`、`electron/analysis/htdemucs_runner.py`、`src/services/automix/{beatThis,stems,stemGesture,expansionGesture,modelAvailability}.ts`、`build/fetchModels.mjs`、`docs/automix-memory-optimization.md` |
| **P1** | 显示休眠阻止 / 更新通道 / 崩溃日志 / 内存监控 | `electron/displaySleepBlocker.cjs`、`electron/updateChannels.cjs`、`electron/debug/*` |
| **P1** | 局域网同步（sync-server / src/services/sync） | `sync-server/*`、`src/services/sync/*` |
| **P1** | Ponder 教学浮层 | `src/services/ponder/*`、`src/components/ponder/*`（唯一被播放层引用的是 `usePlaybackStore.ts` 的边界违规注释，非功能依赖） |
| **P1** | 主题 AI / Gemini 调色 | `src/services/gemini.ts`、`themeCache.ts` 中 AI 分支 |
| **P2** | Electron 主进程内嵌的网易云 / 酷狗 / QQ Node 服务 | `electron/neteaseApiStartup.cjs`、`electron/neteaseBackend.cjs`、`electron/kugouApiBridge.cjs`、`electron/qqApiStartup.cjs`、`electron/qqBackend.cjs`、`electron/qqAuthSessionRepository.cjs` → HarmonyOS 端改为直连远端 HTTP API（Web 构建本来就这么做） |
| **P2** | 本地音乐库（File System Access） | `src/services/localMusicService.ts`、`localLibrary*`(12 个)、`localCover*`、`electron/localCoverAssets.cjs`、`electron/modSystem/fileGrants.cjs` |
| **P2** | 音频输出设备切换 | `src/hooks/useAudioOutputDevice.ts` |
| **P2** | `FileSystemDirectoryHandle` 持久化 | `saveDirHandles` / `getDirHandles`（`services/db.ts:265`） |

**丢弃原则**：P0 全删；P1 保留数据模型与"被引用点"的空实现（避免调用方大面积改签名），但 UI 开关隐藏；P2 必须**替换**而非删除。

---

## 9. 推荐的 ArkTS 模块分解

命名约定：包根 `entry/src/main/ets/playback/`。每个模块给出**职责 → 源文件来源**。

### 9.1 核心（必须，第一批）

| 模块 | 职责 | 派生自 |
| --- | --- | --- |
| `playback/model/` | 全部纯数据类型：`SongResult`、`Artist`、`Album`、`PlaybackSourceRef`、`MediaId`、`PlayerState`、`LoopMode`、`QueueAddBehavior`、`ReplayGainMode`、`PlaybackSnapshot`、`Line`/`Word`/`LyricData`。**零逻辑、零平台** | `src/types.ts`、`src/types/onlineMusic.ts`、`src/types/appPlayback.ts` |
| `playback/model/PlaybackGuards.ets` | `getPlaybackSongKey` / `isLocalPlaybackSong` / `isNavidromePlaybackSong` / `replacePlaybackSongInQueue` / `normalizePlaybackSongSource` / `isOnlinePlaybackSong` | `src/utils/appPlaybackGuards.ts` |
| `playback/store/PlaybackStore.ets` | raw 层 15 字段 + 模块级 setter；**display 层 5 个 selector 作纯函数** | `src/stores/usePlaybackStore.ts` |
| `playback/store/AudioSettingsStore.ets` | 音量、静音、loopMode、audioQuality、缓存开关/上限、queueAddBehavior、playbackFadeEnabled、ReplayGain 模式 | `src/stores/useAudioSettingsStore.ts` |
| `playback/store/AutomixSettingsStore.ets` | automixEnabled / transitionMode / crossfadeMaxSec / transitionPerformance / 两个动画开关 | `src/stores/useAutomixSettingsStore.ts` |
| `playback/store/Signals.ets` | 每帧值：`currentTime`、`lyricCurrentTime`、`audioPower`、五频段、`spectrum`。**无订阅可变单例 + 显式 `markDirty()`** | `src/stores/motionSignals.ts` |
| `playback/queue/QueueAddBehavior.ets` | `applyQueueAddBehavior`（append / next + 去重重插） | `src/utils/queueAddBehavior.ts` |
| `playback/queue/QueueController.ets` | `playSong`、`handleNextTrack`、`handlePrevTrack`、`shuffleQueue`、`clearQueue`、`getNextPlayableQueueSong`、不可用自动跳曲（倒计时常量一并搬） | `src/hooks/usePlaybackQueueController.ts`（丢弃 Stage/FM 之外的部分按 §8 决定） |
| `playback/queue/FmQueue.ets` | 个人 FM 续队列（`getPersonalFm` 追加 + 提前 2 首触发） | 同上 :908 |
| `playback/transport/TransportController.ets` | `resume` / `pause`、`transportRevision`、`wantsPlayback`、autoplay intent（`shouldAutoPlay`/`suppressAutoplay`/`isAutoplayHeld` 三道 bail-out） | `src/hooks/usePlaybackTransportController.ts`、`src/hooks/usePlaybackAudioBridge.ts:245-329` |
| `playback/transport/PlaybackFade.ets` | 0.2s 淡入淡出 + generation token + 150ms drain + 0.03s 回单位增益 | `src/services/playbackFade.ts` |
| `playback/replaygain/ReplayGain.ets` | `calculateReplayGain(info, mode)` + `dbToLinear` | `src/utils/replayGain.ts`、`audioEffects/effectParams.ts` |

### 9.2 音频引擎（风险最高，需先做技术验证）

| 模块 | 职责 | 派生自 |
| --- | --- | --- |
| `playback/engine/AudioDeck.ets` | 单路播放器封装（AVPlayer/AVPlayer+AudioRenderer）：`src` 装配、`play/pause/seek`、`currentTime` 读取、`playbackRate`+保音高、`loop`、`error/ended/timeupdate/loadedmetadata` 事件 | `src/services/automix/useAutomixDecks.ts`、`App.tsx:2418-2600` 的事件表 |
| `playback/engine/DeckPair.ets` | A/B 双 deck 管理：active deck、`isActiveDeck`、`isTransitionAudible`、`resolveDeckSrc`、`handleActiveDeckPlaying`、`handleTailEnded`、stall 重试（`STALL_GRACE_MS = 2500`、`STALL_RETRY_MS = 1000`、`STALL_ATTEMPTS = 10`） | `useAutomixDecks.ts` |
| `playback/engine/AudioGraph.ets` | 汇合点 + 节点顺序的**唯一权威**：decks → mix → EQ → effects → volume → fade → analyser → out。把顺序写成可断言的数据/函数，移植 `buildPlaybackGraph` 的注释与自检日志 | `src/services/playbackGraph.ts` |
| `playback/engine/DeckChain.ets` | 每路 deck 的 replayGain → trim → tone(low/mid/high) → fade → throw。常量 `MID_BELL_Q=0.8`、`TONE_RESET_SEC=0.12`、`CURVE_TAIL_GUARD_SEC=0.006`、`THROW_*`、软限幅 `softLimit` | `src/services/automix/crossfadeGraph.ts` |
| `playback/engine/GainRamp.ets` | `rampGain` / `rampGainDb` / `resetTone` / `resetThrow` / `cancelAndHoldAtTime` 语义（README §9 执行条） | `crossfadeGraph.ts:167-212` |
| `playback/engine/Analyser.ets` | FFT（可复用 #9.3 的实现）→ 五频段 + spectrum，供可视化 | `src/hooks/usePlaybackVisualizerBridge.ts` |

### 9.3 DSP / 效果

| 模块 | 职责 | 派生自 |
| --- | --- | --- |
| `playback/dsp/Biquad.ets` | 通用 biquad（peaking / lowshelf / highshelf / highpass / lowpass / bandpass），参数与 Q 值照搬 | `audioEqualizerGraph.ts`、`effectNodes.ts` |
| `playback/dsp/FFT.ets` | 定长 FFT（2048）+ 窗函数；供分析器与 `signalAnalysis.fft` 共用 | `automix/signalAnalysis.ts` |
| `playback/effects/EffectModel.ets` | `AudioEffectId`、`AudioEffectControl`、`AUDIO_EFFECT_CONTROLS`（完整 min/max/step/neutral/scale/unit/addsNoise）、`normalizeAudioEffects`、滑块域换算、`AudioEqualizerSettings` + 两个自定义槽 | `src/utils/audioEffects.ts`、`src/utils/audioEqualizer.ts` |
| `playback/effects/EffectChain.ets` | 串联链 + 三个可选分支的参数映射公式（§4.4/4.5 全是纯算术） | `audioEffects/effectChain.ts`、`reverbBranch.ts`、`noiseBranch.ts`、`wowBranch.ts` |
| `playback/effects/curves.ets` | `createSaturationCurve`（含 `measureSaturationCompensation`）、`createBitCrushCurve`、`createVinylNoiseBuffer`、`createReverbImpulse` | `audioEffects/effectSources.ts` |
| `playback/effects/EffectRelease.ets` | 分支延迟释放（`RELEASE_DELAY_MS = 800`） | `audioEffects/effectBranchRelease.ts` |

> **移植风险标注 `[推断]`**：HarmonyOS **没有 Web Audio API**。`ConvolverNode`（卷积混响）、`AudioBufferSourceNode`（噪声底）、`OscillatorNode → AudioParam`（wow/flutter 的 LFO 调制）没有对等节点。可行路线有三：① 用 `@ohos.multimedia.audio` 的 `AudioEffect`/`AudioEqualizer` 覆盖 EQ + 部分效果，其余用 NAPI/C++ 自写；② 用 AudioRenderer 回调自建整条 DSP 链（完全掌控，但要自己做重采样与缓冲）；③ 首版只交付 EQ + drive + crush + punch（可用 AudioRenderer 侧波形整形近似），把 reverb/noise/wow 标为"暂不可用"。**建议在动工前先做一次 spike。**

### 9.4 源 / 恢复 / 持久化

| 模块 | 职责 | 派生自 |
| --- | --- | --- |
| `playback/source/SourceResolver.ets` | 在线源阶梯：缓存 Blob → 预热 URL → provider；`unavailable` 原因分流 | `src/services/onlinePlayback.ts:19`、`src/services/prefetchService.ts` |
| `playback/source/Prefetch.ets` | next 2 / prev 1、LRU 200、TTL 1200s、`refreshPrefetchAfterQueueEdit` | `prefetchService.ts` |
| `playback/source/MediaCache.ets` | 整曲播完写音频+封面；容量上限 `mediaCacheLimitGb`；分类统计（playlist/lyrics/cover/media/analysis） | `playedTrackCache.ts`、`services/audioCache.ts`、`repositories/cacheRepository.ts` |
| `playback/recovery/OnlineRecovery.ets` | TTL 判定 + `getOnlineRecoveryKey`（origin+pathname）幂等 + 并发合并 + `pendingResumeTime` 复位 | `createOnlineRecoveryController.ts` |
| `playback/recovery/SourceRevision.ets` | `buildLocalSourceRevision` / `buildNavidromeSourceRevision` / `safeUrlIdentity` / `representationRegistry` | `playbackRecovery/sourceRevision.ts`、`representationRegistry.ts` |
| `playback/recovery/MediaFailure.ets` | `classifyMediaElementFailure` 五分类 + 错误码常量 | `mediaFailureClassifier.ts` |
| `playback/persistence/Database.ets` | RDB schema 与版本迁移（照搬 §6.1 的表与索引设计，版本号可重排为 1..N） | `services/appDatabase.ts`、`repositories/cacheRepository.ts` |
| `playback/persistence/CacheKeys.ets` | **键前缀 → 存储类别**的路由表（`audio_`/`cover_`/`lyric_`/`automix_profile_`/`replayGain_`/`theme_`/`local_snapshot_`） | `cacheRepository.getCacheTableName` |
| `playback/persistence/PlaybackCache.ets` | `persistPlaybackCache` / `restorePlaybackSession`（sessionRepository 除外） | `persistPlaybackCache.ts`、`useSessionRestoreController.ts` |
| `playback/persistence/RestoreSource.ets` | `restorePlaybackSourceForSong` 三分支 | `components/app/playback/restorePlaybackSource.ts` |

### 9.5 Automix（按可行性分三批）

| 批次 | 模块 | 职责 | 派生自 |
| --- | --- | --- | --- |
| 1 | `playback/automix/Crossover.ets` | **纯规划层**：`planForMode` / `planCrossfade` / `planTransition` / `chooseTransitionStyle` / `musicalTime`（拍/小节/乐句、`STRETCH_LIMIT`、`DRIFT_LIMIT`）/ `LENGTH_SCALE`+`STYLE_SCALE`+0.25 地板 | `transitionStrategy.ts`、`crossfadePlanner.ts`、`transitionPlanner.ts`、`transitionChooser.ts`、`musicalTime.ts` |
| 1 | `playback/automix/TempoBend.ets` | `playbackRate` + `preservesPitch`（只弯出场曲） | `tempoBend.ts` |
| 1 | `playback/automix/DeckClock.ets` | `currentTime` 阶梯 → 直线拟合、毫秒级相位 | `deckClock.ts` |
| 1 | `playback/automix/Session.ets` | 状态机 idle→armed→fading、`AUTOMIX_ARM_LEAD_SEC=1`、autoplay hold、`settle()` 单一收口 | `automixSession.ts` |
| 1 | `playback/automix/DeckAnalyser.ets` | 播放中的实时 K 计权电平、下一拍时刻 | `deckAnalyser.ts` |
| 2 | `playback/automix/Profile.ets` | `TrackProfile`（§5.3 全字段）+ K 计权 + 自相关测速 + `estimateDownbeat` + Foote novelty + chroma/K-S 调性 + 交叉/分频曲线 + `toneTilt` | `trackProfile.ts`、`signalAnalysis.ts` |
| 2 | `playback/automix/ProfileService.ets` | 字节来源（`fetch(Range)` → decode）、何时允许下载、结果存储、运行期缓存；主线程让出预算 **8 ms** | `profileService.ts` |
| 3（暂缓） | `playback/automix/BeatGrid.ets` | Beat This! 前处理契约（22050/1024/441/Slaney 30–11000/`log1p(1000x)`/1500 帧/6 帧边界），推理后端待定 | `beatThis.ts` |
| 3（暂缓） | `playback/automix/Stems.ets` / `StemGesture.ets` / `Expansion.ets` | 30 秒窗口管理、四 stem 交接、build-up 渲染 | `stems.ts`、`stemGesture.ts`、`expansionGesture.ts` |

### 9.6 歌词 / UI 支撑

| 模块 | 职责 | 派生自 |
| --- | --- | --- |
| `playback/lyrics/ParserCore.ets` | 16 个导出符号（§7.1），LRC/YRC/QRC/VTT/TTML/KRC/AWLRC + `attachInterludes` + `finalizeParsedLyricLines` | `utils/lyrics/parserCore.ts` |
| `playback/lyrics/LyricClock.ets` | 歌词钟 + `lyricTimelineOffsetMs` + `currentLineIndex` 守卫（只在行变化时写） | `motionSignals.ts` + 各 controller |
| `playback/lyrics/LyricsPipeline.ets` | 本地/内嵌/在线三源解析与优先级、`lyrics.transform` 钩子位置（若保留 mods 则接，否则留空实现） | `utils/lyrics/localSongLyrics.ts`、`utils/onlineLyricsState.ts`、`useLibraryPlaybackController` 歌词段 |
| `playback/ui/ProgressModel.ets` | 进度条模型 + `isShowingTail` 时读 tail deck 的规则（`App.tsx:2495-2524` 的 isActive/isShowingTail 二分） | `App.tsx` 事件处理 |

### 9.7 建议的落地顺序

1. **Spike**：ArkTS 里两个 AVPlayer 能否同时播放并各自编程控音量/速率；AudioRenderer 能否拿到 PCM 做 FFT；AudioEffect 能否覆盖 10 段 EQ。**这一步的结果会决定 §9.3 走①②③哪条路。**
2. `model` + `store` + `PlaybackGuards` + `QueueAddBehavior`（纯逻辑，零风险，可先写单测）。
3. `AudioDeck` + `AudioGraph` + `TransportController` + `PlaybackFade` + `ReplayGain`（能放歌、能暂停、能调音量）。
4. `SourceResolver` + `Prefetch` + `QueueController` + `FmQueue`（能放列表、能切歌）。
5. `persistence/*`（能记住上次会话）。
6. `Crossover`（**只有 crossfade 模式**，纯规划层 + `DeckChain` 的 `scheduleCrossfade`）。
7. `Profile` + `ProfileService` + `DeckClock` + `Session`（automix 模式）。
8. `effects/*`（按 spike 结论决定覆盖面）。
9. 暂缓：`BeatGrid`、`Stems`、`Expansion`（§8 的 P1）。

---

## 附录 A：播放相关文件索引（按改动风险排序）

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `src/hooks/useLibraryPlaybackController.ts` | 77 KB | 本地/Navidrome 播放、歌词匹配、元数据回写。**最大，但大部分是歌词/匹配而非传输** |
| `src/services/automix/automixSession.ts` | 73 KB | 过渡状态机 |
| `src/hooks/usePlaybackQueueController.ts` | 60 KB | 队列 + 在线加载 + Stage 请求 |
| `src/hooks/useStagePlaybackController.ts` | 57 KB | Stage/NowPlaying（P1 丢弃） |
| `src/services/automix/trackProfile.ts` | 52 KB | 曲目档案 |
| `src/services/automix/useAutomixDecks.ts` | 46 KB | 双 deck |
| `src/services/automix/transitionPlanner.ts` | 45 KB | 规划器 |
| `src/services/automix/signalAnalysis.ts` | 42 KB | 共享 DSP 数学 |
| `src/services/automix/stemGesture.ts` | 42 KB | stem 交接（P1） |
| `src/services/automix/stems.ts` | 38 KB | 分离（P1） |
| `src/services/automix/README.md` | 37 KB | **必读设计文档** |
| `src/services/automix/crossfadeGraph.ts` | 31 KB | deck 链与调度 |
| `src/services/automix/profileService.ts` | 26 KB | 档案 I/O |
| `src/services/automix/beatThis.ts` | 21 KB | 拍点前处理（P1） |
| `src/hooks/useElectronPlaybackBridge.ts` | 33 KB | 桌面桥（P0/P1 丢弃） |
| `src/hooks/usePlaybackAudioBridge.ts` | 17 KB | 音频图装配 + autoplay + ReplayGain |
| `src/hooks/usePlaybackInteractionBridge.ts` | 17 KB | 交互（seek / 睡眠 / 错误恢复触发） |
| `src/services/playbackGraph.ts` | 109 行 | **接线顺序的唯一权威** |
| `src/services/audioEqualizerGraph.ts` | 58 行 | 10 段 EQ |
| `src/services/playbackFade.ts` | 278 行 | 传输淡入淡出 |
| `src/services/audioEffects/*` | 8 文件 / ~19 KB | 效果链 |
| `src/stores/usePlaybackStore.ts` | 176 行 | 播放状态 |
| `src/utils/queueAddBehavior.ts` | 83 行 | append/next |

## 附录 B：可直接照搬的常量总表

```
PlayerState            IDLE | PLAYING | PAUSED
loopMode               'off' | 'all' | 'one'          (localStorage: player_loop_mode)
queueAddBehavior       'append' | 'next'              (localStorage: queue_add_behavior)
replayGainMode         'off' | 'track' | 'album'      (localStorage: local_replaygain_mode)
audioQuality           'standard' | 'high' | 'lossless' | 'hires'

PLAYBACK_FADE_SECONDS  0.2      TIMER_GRACE_MS        15
PAUSE_DRAIN_MS         150      RESTORE_RAMP_SECONDS  0.03
EFFECT_RAMP_SECONDS    0.03     RELEASE_DELAY_MS      800
WOW_BASE_DELAY_SECONDS 0.012    (wow 0.7Hz / flutter 6.8Hz)

AUTOMIX_MAX_OVERLAP_SEC    25    AUTOMIX_MIN_OVERLAP_SEC  0.8
AUTOMIX_DEFAULT_OVERLAP_SEC 5    AUTOMIX_MIN_CUT_ROOM_SEC 0.15
AUTOMIX_ARM_LEAD_SEC        1    CROSSFADE_MIN_SEC        1
CROSSFADE_DEFAULT_SEC       5    CROSSFADE_MAX_SEC        25
BEAT_CUT_SEC              0.04   CUT_LEAD_SEC             1.5
HEAD_BUDGET_SEC           0.05   ENTRY_MARGIN_SEC         0.1
MAX_TRIMMED_TAIL_SEC        10   STRETCH_LIMIT            0.12
DRIFT_LIMIT               0.25   MIN_KEY_CONFIDENCE       0.25
FADE_OUT_SLOPE_DB_PER_SEC -1.5   INTRO_SILENCE_SEC        0.3
HOT_START_SCALE            0.6   ENERGY_STEP_CEILING_DB   12
ENERGY_STEP_SCALE          0.4   BEATS_PER_PHRASE         16
TRACK_PROFILE_VERSION        9   PROFILE_SAMPLE_RATE      22050

PREFETCH_COUNT_NEXT          2   PREFETCH_COUNT_PREV      1
URL_TTL_MS             1200000   MAX_PREFETCH_CACHE_SIZE  200
MAX_UNAVAILABLE_AUTO_SKIP_COUNT 2
UNAVAILABLE_SKIP_CONFIRM_TIMEOUT_MS 5000
UNAVAILABLE_SKIP_CONFIRM_INTERVAL_MS 1000
CACHE  DEFAULT_MEDIA_CACHE_LIMIT_GB 5   ANALYSIS_ROUTING 见 §6.1
```
