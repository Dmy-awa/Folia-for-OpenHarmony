# 在线音乐 Provider 层 —— HarmonyOS ArkTS 移植规范

> 唯一权威参考。所有常量、端点、参数名均从上游 `folia-major-main` 源码逐字摘录。
> 标注约定：
> - **【源码】** = 直接从源码引用的事实。
> - **【推断】** = 由源码上下文推断，需在实现时验证。
> - **`未在源码中找到，需要抓包确认`** = 该常量/字段不在本仓库内（例如位于 npm 依赖包中），禁止臆造。

上游仓库根：`D:\Personal\Documents\deepseek-harness\default-workspace\_upstream\folia-major-main`

---

## 0. 结论速览（先读这段）

| Provider | 渲染进程是否有 crypto | 依赖 | 可纯端侧实现？ | 难度 |
| --- | --- | --- | --- | --- |
| 网易云 netease | ❌ 无 crypto，只发 HTTP 到内嵌 Node 服务 | `@neteasecloudmusicapienhanced/api@^4.41.1`（`electron/neteaseBackend.cjs`） | ❌ 必须自实现 weapi/eapi/xeapi 全套 crypto，或自建代理 | **高** |
| 酷狗 kugou | ✅ 有 MD5 签名（`LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`） | `kugoumusicapi@v1.6.0`（`electron/kugouApiBridge.cjs`） | ⚠️ 匿名搜索可端侧；登录态全量需要移植整个 KuGouMusicApi | **高** |
| Navidrome | ✅ 只需 MD5 | 无（纯 Subsonic HTTP） | ✅ **可以完全端侧** | **低** |
| 波点 bodian | ❌ | `bodian-music-api@0.1.2`，协议在闭源独立仓库 | ❌ 不建议移植 | 高（不可控） |
| QQ 音乐 | ❌ | 需私有后端 `VITE_QQ_API_BASE` | ❌ | 高 |

**核心结论**：网易云与酷狗在桌面端**都不是端侧协议实现**——它们是「渲染进程 → IPC/HTTP → 主进程内嵌的 Node 服务 → 上游」。HarmonyOS 没有 Node 主进程，因此这两个 provider 的**全部加密与协议必须由 ArkTS 重写**（或保留一个服务端代理）。Navidrome 是唯一无需任何服务端组件的 provider。

---

## 1. Provider 无关接口契约（ArkTS 必须一比一复刻）

来源：【源码】`src/types/onlineMusic.ts`（478 行）。以下为**逐字**摘录。

### 1.1 顶层 provider 接口

```ts
// src/types/onlineMusic.ts:436-456
export interface OnlineMusicProvider {
    id: OnlineProviderId;
    displayName: string;
    shortName?: string;
    getAvailability?(): ProviderAvailability;
    capabilities: ProviderCapabilities;
    normalizeSong(raw: unknown): UnifiedSong;
    normalizeUser?(raw: unknown): ProviderUser;
    normalizeCollection?(raw: unknown, type?: string): ProviderCollection;
    songMetadata?: OnlineSongMetadataProvider;
    getSongPageUrl?(song: SongResult): string | null;
    search?: OnlineSearchProvider;
    playback?: OnlinePlaybackProvider;
    playbackReports?: OnlinePlaybackReportProvider;
    lyrics?: OnlineLyricsProvider;
    auth?: OnlineAuthProvider;
    library?: OnlineLibraryProvider;
    catalog?: OnlineCatalogProvider;
    recommendations?: OnlineRecommendationProvider;
    mutations?: OnlineMutationProvider;
}
```

### 1.2 基础标识与能力类型

```ts
// src/types/onlineMusic.ts:5-14
export type MediaId = string | number;
export type OnlineProviderId = 'netease' | (string & {});
export type AudioQualityPreference = 'standard' | 'high' | 'lossless' | 'hires';
export type ProviderCatalogEntityKind = 'album' | 'artist' | 'playlist';

export interface ProviderCatalogRef {
    providerId: OnlineProviderId;
    kind: ProviderCatalogEntityKind;
    id: MediaId;
}
```

```ts
// src/types/onlineMusic.ts:31-58
export interface ProviderCapabilities {
    search: boolean;
    playback: boolean;
    lyrics: boolean;
    auth: boolean;
    userLibrary: boolean;
    playlists: boolean;
    albums: boolean;
    artists: boolean;
    recommendations: boolean;
    mutations: boolean;
    /** Personal FM can be steered by mode/scene, i.e. `getPersonalFm` honours PersonalFmRequestOptions. */
    personalFmModes?: boolean;
    wordByWordLyrics: boolean;
    userCloud?: boolean;
    historyRecommendations?: boolean;
    playlistSubscription?: boolean;
    playlistTrackMutations?: boolean;
    likes?: boolean;
    userAlbums?: boolean;
    /** The provider accepts a listening report for a track the user actually played. */
    playbackReports?: boolean;
}

export interface ProviderAvailability {
    configured: boolean;
    reason?: 'not-configured' | 'runtime-unavailable';
}
```

### 1.3 分页与播放源

```ts
// src/types/onlineMusic.ts:76-96
export interface ProviderPage<T> {
    items: T[];
    total?: number;
    hasMore: boolean;
    nextOffset: number;
}

export interface ProviderAudioSource {
    url: string;
    fetchedAt: number;
    expiresAt?: number;
    quality: AudioQualityPreference;
    replayGain?: ReplayGainInfo;
}

export type ProviderSongAvailabilityState = 'playable' | 'unavailable' | 'unknown';

export interface ProviderSongAvailability {
    state: ProviderSongAvailabilityState;
    label?: string;
}
```

### 1.4 能力子接口（**ArkTS 必须实现的全部方法签名**）

```ts
// src/types/onlineMusic.ts:249-251
export interface OnlineSearchProvider {
    searchSongs(query: string, limit: number, offset: number): Promise<ProviderPage<UnifiedSong>>;
}

// src/types/onlineMusic.ts:253-258
export interface OnlinePlaybackProvider {
    getSongDetail(id: MediaId): Promise<UnifiedSong | null>;
    getAudioSource(song: SongResult, quality: AudioQualityPreference): Promise<ProviderAudioSource | null>;
    getAvailability?(song: SongResult): ProviderSongAvailability;
    getReplacement?(song: SongResult): Promise<ProviderSongReplacement | null>;
}

// src/types/onlineMusic.ts:268-276
export interface ProviderPlaybackReport {
    playedSeconds: number;
    totalSeconds?: number;
    quality?: AudioQualityPreference;
}

export interface OnlinePlaybackReportProvider {
    reportPlayback(song: SongResult, report: ProviderPlaybackReport): Promise<void>;
}

// src/types/onlineMusic.ts:278-285
export interface OnlineLyricsProvider {
    getLyrics(song: SongResult, context?: { userId?: MediaId | null }): Promise<ProviderLyricsResult>;
    getChorusRanges?(songId: MediaId): Promise<ChorusRange[]>;
}

export interface OnlineSongMetadataProvider {
    getSongMetadata(song: SongResult): ProviderSongMetadata;
}

// src/types/onlineMusic.ts:354-376
export interface OnlineAuthProvider {
    getLoginStatus(): Promise<ProviderUser | null>;
    logout(): Promise<void>;
    getQrLoginMethods?(): QrLoginMethod[];
    resolveQrLoginMethods?(): Promise<QrLoginMethod[]>;
    getQrKey?(methodId?: string): Promise<string>;
    createQr?(key: string): Promise<string>;
    checkQr?(key: string): Promise<QrLoginState>;
    cancelQr?(key: string): Promise<void>;
    getQrTtlMs?(): number;
    getQrLoginDiagnostics?(): Promise<string[]>;
    canRunQrLoginSelfCheck?(): boolean;
    runQrLoginSelfCheck?(): Promise<LoginSelfCheckResult | null>;
}

// src/types/onlineMusic.ts:378-385
export interface OnlineLibraryProvider {
    getUserPlaylists(userId: MediaId, limit: number, offset: number): Promise<ProviderPage<ProviderCollection>>;
    getLikedSongIds?(userId: MediaId): Promise<MediaId[]>;
    /** Full liked-track records, used when a provider needs more than the song id (e.g. KuGou fileId). */
    getLikedSongs?(userId: MediaId): Promise<UnifiedSong[]>;
    getUserAlbums?(userId: MediaId, limit: number, offset: number): Promise<ProviderPage<ProviderCollection>>;
    getCloudCollection?(user?: ProviderUser): Promise<ProviderCollection | null>;
}

// src/types/onlineMusic.ts:387-399
export interface OnlineCatalogProvider {
    canResolveSongCatalogRefs?(song: UnifiedSong): boolean;
    resolveSongCatalogRefs?(song: UnifiedSong): Promise<UnifiedSong>;
    getPlaylistTracks?(id: MediaId, limit: number, offset: number, collection?: ProviderCollection): Promise<ProviderPage<UnifiedSong>>;
    getPlaylistDetail?(id: MediaId, collection?: ProviderCollection): Promise<ProviderCollection | null>;
    getCloudTracks?(limit: number, offset: number, collection?: ProviderCollection): Promise<ProviderPage<UnifiedSong>>;
    getAlbumTracks?(id: MediaId, limit?: number, offset?: number, collection?: ProviderCollection): Promise<ProviderPage<UnifiedSong>>;
    getAlbumDetail?(id: MediaId, collection?: ProviderCollection): Promise<ProviderCollection | null>;
    getArtistSongs?(id: MediaId, limit: number, offset: number): Promise<ProviderPage<UnifiedSong>>;
    getArtistAlbums?(id: MediaId, limit: number, offset: number): Promise<ProviderPage<ProviderCollection>>;
    getArtistDetail?(id: MediaId): Promise<ProviderCollection | null>;
    getSubscriptionStatus?(type: 'playlist' | 'album', id: MediaId, collection?: ProviderCollection): Promise<boolean>;
}

// src/types/onlineMusic.ts:405-418
export interface PersonalFmRequestOptions {
    mode?: string;
    submode?: string | null;
}

export interface OnlineRecommendationProvider {
    getDailySongs?(refresh?: boolean): Promise<UnifiedSong[]>;
    getPersonalFm?(options?: PersonalFmRequestOptions): Promise<UnifiedSong[]>;
    getRecommendedCollections?(limit: number): Promise<ProviderCollection[]>;
    getHistoryEntries?(): Promise<ProviderHistoryEntry[]>;
    getHistoryDates?(): Promise<string[]>;
    getHistorySongs?(entry: ProviderHistoryEntry | string): Promise<UnifiedSong[]>;
    dislikeSong?(id: MediaId): Promise<{ replacement?: UnifiedSong; limitReached?: boolean }>;
}

// src/types/onlineMusic.ts:420-434
export interface OnlineMutationProvider {
    canAddToPlaylist?(playlist: ProviderCollection): boolean;
    likeSong?(
        song: MediaId | SongResult,
        liked: boolean,
        context?: { likedFileId?: MediaId },
    ): Promise<void>;
    updatePlaylistTracks?(
        operation: 'add' | 'del',
        playlist: MediaId | ProviderCollection,
        tracks: Array<MediaId | SongResult>,
    ): Promise<void>;
    subscribePlaylist?(playlist: MediaId | ProviderCollection, subscribed: boolean): Promise<void>;
    subscribeAlbum?(id: MediaId, subscribed: boolean): Promise<void>;
}
```

### 1.5 领域数据模型

```ts
// src/types/onlineMusic.ts:83-176（节选，字段全量）
export interface ProviderLyricsResult {
    lyrics: LyricData | null;
    mainText?: string | null;
    wordByWordText?: string | null;
    translationText?: string | null;
    romanizationText?: string | null;
    isPureMusic: boolean;
    chorusRanges?: ChorusRange[];
}

export interface ChorusRange { startTime: number; endTime: number; }

export interface ProviderUser {
    id: MediaId;
    nickname: string;
    avatarUrl?: string;
    backgroundUrl?: string;
    vipType?: number;
}

export interface ProviderArtistSummary { id: MediaId; name: string; entityId?: string; catalogRef?: ProviderCatalogRef; }
export interface ProviderAlbumSummary {
    id: MediaId; name: string; coverUrl?: string; entityId?: string; catalogRef?: ProviderCatalogRef;
}
export interface ProviderSongMetadata {
    artists: ProviderArtistSummary[];
    album: ProviderAlbumSummary;
    durationMs: number;
    coverUrl?: string;
    aliases: string[];
    translatedNames: string[];
}

export interface ProviderCollection {
    providerId: OnlineProviderId;
    id: MediaId;
    name: string;
    type: 'playlist' | 'album' | 'artist' | 'radio' | 'cloud' | string;
    coverUrl?: string;
    description?: string;
    trackCount?: number;
    albumCount?: number;
    isOwned?: boolean;
    creator?: ProviderUser;
    artists?: ProviderArtistSummary[];
    aliases?: string[];
    publishedAt?: number;
    publisher?: string;
    playCount?: number;
    updatedAt?: number;
    tracksUpdatedAt?: number;
    isLiked?: boolean;
    providerData?: Record<string, JsonValue>;
}

export interface ProviderHistoryEntry { id: string; label: string; providerData?: Record<string, JsonValue>; }
export interface ProviderAccountSummary {
    providerId: OnlineProviderId;
    displayName: string;
    shortName: string;
    availability: ProviderAvailability;
    requiresAccount?: boolean;
    status: 'unknown' | 'authenticated' | 'anonymous' | 'error';
    user: ProviderUser | null;
    collections: ProviderCollection[];
    error?: string;
    hydration?: 'loading' | 'ready';
    freshness?: 'stale' | 'refreshing' | 'fresh' | 'error';
    lastUpdatedAt?: number;
}
```

### 1.6 来源身份（不可退化）

```ts
// src/types/onlineMusic.ts:19-29
export type PlaybackSourceRef =
    | {
        kind: 'online';
        providerId: OnlineProviderId;
        mediaId: string;
        variant?: string;
        providerData?: Record<string, JsonValue>;
      }
    | { kind: 'local'; mediaId: string }
    | { kind: 'navidrome'; mediaId: string }
    | { kind: 'stage'; mediaId: string };
```

**硬性规则（`skills/online-song-omni-routing/SKILL.md:117`）**：在线歌曲身份是三元组 `(kind='online', providerId, mediaId)`，**不是** `song.id`。
`online:netease:123` 与 `online:kugou:123` 是两个不同播放身份。ArkTS 侧必须保留等价结构，禁止用裸数字 ID 去重/比较。

```ts
// src/types.ts:1220-1245 —— SongResult（UnifiedSong 的基础）
export interface SongResult {
  id: MediaId;
  name: string;
  artists: Artist[];
  album: Album;
  durationMs: number;
  isPureMusic?: boolean;
  aliases?: string[];
  translatedNames?: string[];
  t?: 0 | 1 | 2;
  sourceType?: 'netease' | 'cloud';
  sourceRef?: PlaybackSourceRef;
  playbackSourceRevision?: string;
  fee?: number;
  noCopyrightRcmd?: NoCopyrightRecommendation | null;
  resourceState?: boolean;
  privilege?: SongPrivilege;
  onlineLyricsState?: OnlineLyricsState;
  matchedLyricsSource?: LyricProviderSource;
  matchedLyricsProviderPlatform?: AmllDbPlatform;
  replayGain?: ReplayGainInfo;
  qqMid?: string;
  kgHash?: string;          // ← 酷狗 hash 的快捷字段
  amllDbPlatform?: AmllDbPlatform;
}

// src/types.ts:1401-1403
export interface UnifiedSong extends SongResult {
  sourceRef: PlaybackSourceRef;   // ← 必填，比 SongResult 更严
}
```

```ts
// src/types.ts:78-87
export interface LyricData {
  lines: Line[];
  title?: string;
  artist?: string;
  isWordByWord?: boolean;
  ttml?: { timingMode?: 'Word' | 'Line'; agents?: Record<string, LyricAgent>; };
}

// src/types.ts:1211-1218
export interface ReplayGainInfo {
  trackGain?: number;   // dB
  albumGain?: number;   // dB
  trackPeak?: number;   // 正线性比
  albumPeak?: number;
}
```

### 1.7 统一错误

```ts
// src/types/onlineMusic.ts:220-247
export type ProviderErrorCode =
    | 'auth-required' | 'unsupported' | 'not-public' | 'unavailable'
    | 'not-playable' | 'preview-only' | 'region-restricted'
    | 'network' | 'invalid-response';

export class OnlineProviderError extends Error {
    constructor(
        public readonly code: ProviderErrorCode,
        message: string,
        public readonly providerId?: OnlineProviderId,
        public readonly cause?: unknown,
        public readonly httpStatus?: number,
        public readonly retryAfterMs?: number,
    ) {
        super(message);
        this.name = 'OnlineProviderError';
    }
}
```

ArkTS 无 `class extends Error` 的完全等价能力时，用 `Error` + 附加字段的接口对象模拟；语义（`code` 分流、`httpStatus` 与 body 内 `code` 分开）必须保留。

### 1.8 别名层（对外公开名，内部名保持迁移兼容）

```ts
// src/types/onlineMusic.ts:458-478
export type OmniProviderId = OnlineProviderId;
export type OmniProviderCapabilities = ProviderCapabilities;
export type OmniProviderSummary = ProviderAccountSummary;
export type OmniPage<T> = ProviderPage<T>;
export type OmniAudioSource = ProviderAudioSource;
export type OmniLyricsResult = ProviderLyricsResult;
export type OmniPlaybackReport = ProviderPlaybackReport;
export type OmniCollection = ProviderCollection;
export type OmniUser = ProviderUser;
export { OnlineProviderError as OmniError };
```

> **ArkTS 建议**：只保留一套名字（`Omni*` 或去前缀），不要双套别名——ArkTS 的 `export type` 别名支持有限。

---

## 2. Omni 路由层

### 2.1 Omni 是什么（具体是哪些文件）

**【源码】** `src/services/onlineMusic/omni.ts`（713 行）是**唯一公开入口**。
配套文件：

| 文件 | 职责 |
| --- | --- |
| `omni.ts` | facade：按 active provider / song sourceRef / collection.providerId 路由；生成号防晚到响应 |
| `providerRegistry.ts`（84 行） | 注册表：`registerOnlineMusicProvider` / `getOnlineMusicProvider` / `getOnlineMusicProviderForSong` / `providerSupports` |
| `providerAccountCache.ts` | 按 provider 缓存 user/collections/likedSongIds + hydration/freshness |
| `providerStorage.ts`（64 行） | session 持久化边界（localStorage） |
| `neteaseProvider.ts` / `kugouProvider.ts` / `qqProvider.ts` / `bodianProvider.ts` | **adapter**：归一化 |
| `kugouTransport.ts` / `qqTransport.ts` / `bodianTransport.ts` | **transport**：HTTP/IPC/协议 |
| `resourceCache.ts` / `resourceKeys.ts` | 在线资源缓存（kind：`audio`、`lyric`、`cover`、`theme`、`replayGain`） |
| `playbackReportGate.ts` | 听歌上报频控 |

### 2.2 Adapter 与 Transport 的分界（硬约束）

**【源码】** `src/services/onlineMusic/README.md:7-18`

```text
UI / hooks / stores / app services
  -> omni.ts
       -> providerRegistry.ts
            -> neteaseProvider.ts
            -> kugouProvider.ts
                 -> kugouTransport.ts（酷狗请求/IPC 边界）
            -> qqProvider.ts
                 -> qqTransport.ts（QQ 音乐请求边界）
       -> providerAccountCache.ts / providerStorage.ts
  -> src/types/onlineMusic.ts（共享合同）
```

| 层 | 允许 | 禁止 |
| --- | --- | --- |
| 组件/hook/store | `omni` + source-aware 工具 | registry、provider、transport、raw API |
| 普通 app service | `omni` | 具体 provider 调用 |
| 跨 provider 编排 | `omni` 的 provider-explicit 方法 | 丢掉 `providerId` |
| `*Provider.ts` | 自己的 transport 与 adapter helper；归一化成共享类型 | 把 raw 响应形状泄漏给调用方 |
| `*Transport.ts` | HTTP/IPC/provider 协议 | UI 或产品编排 |
| 测试 | 被测层 | 拿 raw provider 数据当公开合同 |

> **移植含义**：ArkTS 里应当保留同样的三层：`Omni`（facade）、`XxxProvider`（归一化）、`XxxTransport`（HTTP/sign）。**不要**把签名逻辑写进 provider。

### 2.3 路由选择规则

**【源码】** `omni.ts:48-66`

```ts
const activeProviderId = (): OmniProviderId => {
    const storedProviderId = useOnlineProviderAccountStore.getState().activeProviderId;
    // A persisted selection can outlive its provider when switching builds or branches.
    return getOnlineMusicProvider(storedProviderId) ? storedProviderId : 'netease';
};
const activeProvider = () => requireOnlineMusicProvider(activeProviderId());
const providerForSong = (song: SongResult) => {
    const provider = getOnlineMusicProviderForSong(song);
    if (!provider) throw new OnlineProviderError('unsupported', 'Song is not owned by an online provider');
    return provider;
};
const providerForCollection = (collection: OmniCollection) => requireOnlineMusicProvider(collection.providerId);
```

- 默认 provider 回落值：**`'netease'`**。
- 歌曲操作按 `song.sourceRef.providerId` 路由；集合操作按 `collection.providerId` 路由。

**【源码】** `providerRegistry.ts:63-66`

```ts
export const getOnlineMusicProviderForSong = (song: SongResult): OnlineMusicProvider | null => {
    const sourceRef = getPlaybackSourceRef(song);
    return sourceRef.kind === 'online' ? getOnlineMusicProvider(sourceRef.providerId) : null;
};
```

### 2.4 注册顺序（决定 UI 中的 provider 列表顺序）

**【源码】** `providerRegistry.ts:81-84`

```ts
registerOnlineMusicProvider(neteaseProvider);
registerOnlineMusicProvider(kugouProvider);
registerOnlineMusicProvider(qqProvider);
registerOnlineMusicProvider(bodianProvider);
```

> 顺序即 `listOnlineMusicProviders()`（`Array.from(providers.values())`）的返回顺序：**网易云 → 酷狗 → QQ → 波点**。

### 2.5 晚到响应防护（ArkTS 必须复刻）

**【源码】** `omni.ts:99-110`

```ts
let activeRequestGeneration = 0;

// Rejects late active-provider responses after an account switch transaction begins.
const withActiveProvider = async <T>(run: (provider: OnlineMusicProvider) => Promise<T>): Promise<T> => {
    const providerId = activeProviderId();
    const generation = activeRequestGeneration;
    const result = await run(requireOnlineMusicProvider(providerId));
    if (generation !== activeRequestGeneration || providerId !== activeProviderId()) {
        throw new DOMException('Active online provider changed', 'AbortError');
    }
    return result;
};
```

**ArkTS 替换**：`DOMException('...', 'AbortError')` 不可用 → 用自有异常类型 + 错误码 `'abort'`；语义（切换后丢弃旧响应）必须一致。

### 2.6 完整 Omni 公共方法表（ArkTS facade 需实现的 73 个方法）

**【源码】** `omni.ts`（行号即源码位置）：

| 行 | 方法 | 说明 |
| --- | --- | --- |
| 113 | `invalidateActiveRequests()` | 生成号 +1 |
| 117 | `getActiveRequestGeneration()` | |
| 122 | `subscribeProviders(listener)` | Folium mod 运行时增删 provider |
| 126 | `getProviderRegistryVersion()` | |
| 130 | `getProviderSummaries(): OmniProviderSummary[]` | |
| 151 | `getActiveProviderSummary()` | |
| 157 | `isSongLiked(song, fallbackLikedSongIds?)` | |
| 174 | `toggleSongLike(song, fallbackLikedSongIds?): Promise<boolean>` | |
| 180 | `getActiveCapabilities()` | |
| 184 | `getProviderCapabilities(providerId)` | |
| 188 | `supportsDailySongs(providerId)` | |
| 192 | `getProviderAvailability(providerId)` | |
| 196 | `getProviderLabel(providerId)` | |
| 201 | `searchSongs(query, page)` | 按 active provider |
| 208 | `searchProviderSongs(providerId, query, page)` | 显式 |
| 214 | `getLoginStatus(providerId)` | |
| 220 | `logout(providerId)` | |
| 227/231 | `getQrLoginMethods` / `resolveQrLoginMethods` | |
| 237 | `createQrLogin(providerId, methodId?)` → `{ key, imageUrl }` | |
| 245 | `checkQrLogin(providerId, key)` | |
| 252 | `cancelQrLogin(providerId, key)` | 必须幂等 |
| 257 | `getQrLoginDiagnostics(providerId)` | |
| 267/271 | `canRunQrLoginSelfCheck` / `runQrLoginSelfCheck` | |
| 276 | `getQrTtlMs(providerId)` | |
| 281/285 | `getUserPlaylists` / `getProviderUserPlaylists` | |
| 292 | `refreshProviderPlaylists(providerId)` | |
| 339 | `getPlaylistsForSong(song)` | |
| 357 | `canAddSongToPlaylist(song)` | |
| 366 | `canLikeSong(song)` | |
| 375 | `canEditCollectionTracks(collection)` | |
| 385 | `canDislikeSong(song)` | |
| 393 | `canSubscribeCollection(collection)` | |
| 406 | `getUserAlbums(userId, page)` | |
| 410/414 | `getLikedSongIds` / `getProviderLikedSongIds` | |
| 418 | `getProviderLikedSongs(providerId, userId)` | 酷狗需要 fileId |
| 424/428 | `getCloudCollection` / `getProviderCloudCollection` | |
| 432/436 | `normalizeCachedUser` / `normalizeCachedCollection` | |
| 440 | `getHomeFeed(limit = 35)` | |
| 456 | `getPersonalFm(options?)` | |
| 460 | `getDailySongs(refresh?)` | |
| 464/468/472 | `getRecommendationHistory` / `...Dates` / `...Songs` | |
| 476 | `getSongDetail(providerId, id)` | |
| 480 | `canPlaySong(song)` | |
| 484 | `getAudioSource(song, quality)` | |
| 497/502 | `canReportPlayback` / `reportPlayback` | 仅网易云声明 `playbackReports` |
| 508 | `getLyrics(song, context?)` | |
| 521 | `getChorusRanges(song)` | |
| 526/530 | `getSongAvailability` / `getSongReplacement` | |
| 534 | `getCollectionTracks(collection, page)` | |
| 545/549 | `getAlbumDetail` / `getCollectionDetail` | |
| 556/560/564 | `getArtistDetail` / `getArtistSongs` / `getArtistAlbums` | |
| 568/573 | `getSubscriptionStatus` / `subscribe` | |
| 586 | `updateCollectionTracks(collection, op, tracks)` | |
| 599 | `addSongToPlaylist(song, playlist)` | |
| 644 | `likeSong(song, liked)` | |
| 687 | `dislikeSong(song)` | |
| 695/702 | `canResolveCatalogRef` / `resolveCatalogRefs` | |
| 708 | `getSongPageUrl(song)` | |

---

## 3. 分 Provider 细节

### 3.1 网易云 netease

#### 3.1.1 架构真相（**移植的第一决定点**）

**【源码】** `src/services/onlineMusic/neteaseProvider.ts` 中**没有任何 AES/RSA/MD5 实现**。
（grep `weapi|eapi|linuxapi|aes|rsa|nonce|presetKey` 在该文件只命中 1 处无关的 `privilege` 字段。）

渲染进程实际只做一件事：向**主进程内嵌的本地 Node HTTP 服务**发普通 GET。

**【源码】** `src/services/netease.ts:73-101`

```ts
const getApiBase = async () => {
  if (isElectronRuntime()) {
    const { port, status } = await waitForNeteasePort(getElectronBridge());
    if (port === null) { /* throw NETEASE_API_UNAVAILABLE */ }
    // 必须是 127.0.0.1 而不是 localhost：本地 API 只监听 IPv4 回环
    return `http://127.0.0.1:${port}`;
  }
  if (API_BASE) return API_BASE;
  const configuredApiBase = getConfiguredApiBase();   // VITE_NETEASE_API_BASE
  if (configuredApiBase) { API_BASE = configuredApiBase; return API_BASE; }
  throw new Error("Failed to access environment variables for API base. Please configure VITE_NETEASE_API_BASE.");
};
```

- **桌面端**：`http://127.0.0.1:<动态端口>`，端口由 `findFreePort()` 决定，通过 `ipcRenderer.invoke('get-netease-port')` 取得（`electron/preload.cjs:133`）。
- **网页端**：`VITE_NETEASE_API_BASE` 配置的远端地址。

#### 3.1.2 base URL / host

| 用途 | 值 | 来源 |
| --- | --- | --- |
| 桌面端本地 API | `http://127.0.0.1:<port>` | `netease.ts:89` |
| 网页端 | `VITE_NETEASE_API_BASE` | `netease.ts:28` |
| 上游自检 host | `interfacepc.music.163.com`（eapi/扫码）、`interface3.music.163.com`（xeapi 公钥、匿名注册）、`interface.music.163.com`（其余） | `electron/neteaseBackend.cjs:42` |

```js
// electron/neteaseBackend.cjs:42
const SELF_CHECK_HOSTS = ['interfacepc.music.163.com', 'interface3.music.163.com', 'interface.music.163.com'];
// electron/neteaseBackend.cjs:40
const LISTEN_HOST = '127.0.0.1';
```

#### 3.1.3 本地 API 端点（网易 adapter 调用的全部路径）

**【源码】** `src/services/netease.ts`。全部为 **GET**，响应 JSON。带 `timestamp` 的是需要防缓存的（`netease.ts:114-123`）：

```ts
const needsTimestamp =
    endpoint.includes('/login') ||
    endpoint.includes('/user') ||
    endpoint.includes('/playlist/detail');
```

| 端点 | 查询参数 | 行 |
| --- | --- | --- |
| `/song/detail` | `ids=<idParam>` | 459 |
| `/song/copyright/rcmd` | `songid=<songId>` | 465 |
| `/logout` | — | 568 |
| `/login/qr/key` | — | 572 |
| `/login/qr/create` | `key=<key>&qrimg=true` | 576 |
| `/login/qr/check` | `key=<key>` | 580 |
| `/login/status` | — | 584 |
| `/user/account` | — | 593 |
| `/like` | `id=<id>&like=<like>` | 603 |
| `/scrobble/v1` | 见下 | 627 |
| `/likelist` | `uid=<uid>` | 631 |
| `/user/playlist` | `uid=<uid>&limit=<l>&offset=<o>` | 635 |
| `/playlist/track/all` | `id=<id>&limit=<l>&offset=<o>` | 647 |
| `/playlist/detail` | `id=<id>` | 653 |
| `/playlist/tracks` | `op=<op>&pid=<pid>&tracks=<trackParam>&timestamp=<t>` | 666 |
| `/album` | `id=<id>` | 670 |
| `/album/sublist` | `limit=<l>&offset=<o>` | 685 |
| `/artist/detail` | `id=<id>` | 697 |
| `/artist/album` | `id=<id>&limit=<l>&offset=<o>` | 706 |
| `/artist/top/song` | `id=<id>` | 739 |
| `/artist/songs` | `id=<id>&limit=<l>&offset=<o>&order=<order>` | 745 |
| **`/song/url/v1`** | `id=<id>&level=<level>&randomCNIP=true&https=true` | 756 |
| **`/lyric/new`** | `id=<id>` | 760 |
| `/song/chorus` | `id=<id>` | 764 |
| `/cloud/lyric/get` | `uid=<uid>&sid=<sid>` | 768 |
| `/user/cloud` | `limit=<l>&offset=<o>` | 772 |
| `/user/cloud/detail` | `id=<idParam>` | 788 |
| **`/cloudsearch`** | `keywords=<urlencoded>&limit=<l>&offset=<o>` | 807 |
| `/personal_fm` | `timestamp=<t>` | 824 |
| `/personal/fm/mode` | 见下 + `timestamp` | 836 |
| `/recommend/songs` | `afresh=<afresh>&timestamp=<t>` | 848 |
| `/recommend/songs/dislike` | `id=<songId>&timestamp=<t>` | 857 |
| `/history/recommend/songs` | `timestamp=<t>` | 865 |
| `/history/recommend/songs/detail` | `date=<urlencoded>&timestamp=<t>` | 878 |
| `/personalized` | `limit=<l>` | 887 |
| `/fm_trash` | `id=<songId>&timestamp=<t>` | 891 |
| `/playlist/subscribe` | `t=<t>&id=<id>&timestamp=<t>` | 896 |
| `/album/sub` | `t=<t>&id=<id>&timestamp=<t>` | 901 |
| `/playlist/detail/dynamic` | `id=<id>` | 905 |
| `/album/detail/dynamic` | `id=<id>` | 909 |
| `/register/anonimous` | `timestamp=<t>` | 142 |

**音频 URL（唯一途径）** —— `netease.ts:751-757`：

```ts
getSongUrl: async (id: number, level: string = 'exhigh') => {
    // Use exhigh (320k) by default to ensure VIP songs have a valid signed URL.
    // 'standard' often returns null or invalid links for VIP content even if logged in.
    // randomCNIP=true added to improve success rate for some restricted tracks
    // https=true ensures URLs are returned with HTTPS protocol to avoid mixed content issues
    return fetchWithCreds(`/song/url/v1?id=${id}&level=${level}&randomCNIP=true&https=true`);
},
```

quality → level 映射（`neteaseProvider.ts:34-38`）：

```ts
const mapQuality = (quality: AudioQualityPreference): string => {
    if (quality === 'standard') return 'standard';
    if (quality === 'high') return 'exhigh';
    return quality;      // 'lossless' | 'hires' 原样传
};
```

听歌上报 quality 映射（`neteaseProvider.ts:44-49`）：

```ts
const mapScrobbleQuality = (quality?: AudioQualityPreference): { level: string; bitrate: number } => {
    if (quality === 'standard') return { level: 'standard', bitrate: 128 };
    if (quality === 'lossless') return { level: 'lossless', bitrate: 999 };
    if (quality === 'hires') return { level: 'hires', bitrate: 1999 };
    return { level: 'exhigh', bitrate: 320 };
};
```

#### 3.1.4 请求头 / cookie 处理（**关键，别漏**）

**【源码】** `netease.ts:103-184`

```ts
const fetchWithCreds = async (endpoint: string, options: RequestInit = {}) => {
  const base = await getApiBase();
  const url = `${base}${endpoint}`;
  const defaultOptions: RequestInit = { ...options, mode: 'cors' };
  // ... timestamp 追加 ...
  const storedCookie = readProviderSessionValue('netease', 'cookie', ['netease_cookie']);
  let cookieToUse = storedCookie;
  if (!cookieToUse) {
    const isLoginOrStatusEndpoint =
      endpoint.startsWith('/login') || endpoint.startsWith('/user/account') || endpoint.startsWith('/logout');
    if (!isLoginOrStatusEndpoint) {
      let anonCookie = readProviderSessionValue('netease', 'anonymous_cookie', ['netease_anonymous_cookie']);
      if (!anonCookie && !endpoint.startsWith('/register/anonimous')) {
        try {
          const anonRes = await fetch(`${base}/register/anonimous?timestamp=${Date.now()}`).then(r => r.json());
          if (anonRes && typeof anonRes.cookie === 'string' && anonRes.cookie) {
            anonCookie = anonRes.cookie;
            writeProviderSessionValue('netease', 'anonymous_cookie', anonRes.cookie);
          }
        } catch (e) { console.warn('Failed to fetch anonymous cookie', e); }
      }
      cookieToUse = anonCookie;
    }
  }
  if (cookieToUse) {
    const sep = finalUrl.includes('?') ? '&' : '?';
    finalUrl = `${finalUrl}${sep}cookie=${encodeURIComponent(cookieToUse)}`;
  }
  // ... fetch(finalUrl, { ...defaultOptions, credentials: 'include' }) ...
  // ... JSON.parse；非 JSON 时抛 `NetEase API ${target} returned HTTP ${res.status} without a JSON body` ...
  if (!storedCookie && cookieToUse && (data?.code === 301 || data?.code === 401 || data?.code === 403)) {
    removeProviderSessionValue('netease', 'anonymous_cookie', ['netease_anonymous_cookie']);
  }
  return data;
};
```

要点：
1. Cookie **通过 URL query 参数 `cookie=` 传递**（不是 `Cookie:` 请求头），值需 `encodeURIComponent`。
2. 无登录态时自动用匿名 cookie，并把匿名 cookie 缓存到 session。
3. **不看 HTTP 状态码**，只看 body 的 `code`（注释 `netease.ts:169-170` 明确说明）。
4. 匿名 cookie 被拒（301/401/403）且当前不是登录态 → 清掉缓存，下次重新注册。

`randomCNIP` 的 IP 策略（`electron/neteaseApiStartup.cjs:209-215`）：

```js
function withoutImplicitClientIp(request) {
  return (uri, data, options = {}) => request(uri, data, options.randomCNIP ? options : { ...options, ip: '' });
}
```

> 只有显式传 `randomCNIP` 的请求才带伪造来源 IP；其余请求不写 `X-Real-IP`/`X-Forwarded-For`，由网易按连接识别。上游默认会把 `127.0.0.1` 写进去，从 `::1` 进来的还会换成随机国内 IP——后者与手机扫码位置对不上，会让扫码确认失败。

#### 3.1.5 加密 / 签名方案 —— **必须自实现的清单**

**`未在源码中找到，需要抓包确认`**

本仓库**不包含** weapi / eapi / linuxapi / xeapi 的任何 crypto 常量。它们全部位于 npm 依赖：

```json
// package.json:209
"@neteasecloudmusicapienhanced/api": "^4.41.1",
```

**【源码】** `electron/neteaseBackend.cjs:36` `const NCM_PACKAGE = '@neteasecloudmusicapienhanced/api';`

被替换/使用的上游模块（`electron/neteaseBackend.cjs:84-109`）：

| 上游模块路径 | 用途 |
| --- | --- |
| `${NCM_PACKAGE}/util/request` | 请求管线（crypto 在这里） |
| `${NCM_PACKAGE}/util/index` | `generateDeviceId()`、`generateRandomChineseIP()`、`cookieToJson()` |
| `${NCM_PACKAGE}/module/login_qr_check` | 扫码轮询（本仓库替换掉，修正上游吞错 bug） |
| `${NCM_PACKAGE}/util/option` | 传给替换后的 `login_qr_check` |
| `${NCM_PACKAGE}/util/xeapiKey` | `getXeapiPublicKey` |
| `${NCM_PACKAGE}/main` | `register_anonimous` |
| `${NCM_PACKAGE}/server` | `serveNcmApi({ port, host })` |

**因此本仓库中可确证的、必须复刻的协议事实只有这些：**

1. **eapi 用于扫码**：`electron/neteaseApiStartup.cjs:221-234`

```js
// 替换上游 module/login_qr_check.js
function createLoginQrCheck(createOption) {
  return async (query, request) => {
    const result = await request(
      '/api/login/qrcode/client/login',
      { key: query.key, type: 3 },
      createOption(query),
    );
    return {
      status: 200,
      body: { ...result.body, cookie: result.cookie.join(';') },
      cookie: result.cookie,
    };
  };
}
```

- 上游未加密路径：`/api/login/qrcode/client/login`，参数 `{ key, type: 3 }`。
- 实测 host：`interfacepc.music.163.com`，路径 `/eapi/login/qrcode/client/login`
  （`test/unit/electron/neteaseLoginDiagnostics.test.ts:118`）。
- 要码的上游未加密路径：`/api/login/qrcode/unikey`（`neteaseApiStartup.cjs:237`）。

```js
// electron/neteaseApiStartup.cjs:237
const QR_RETRY_URIS = new Set(['/api/login/qrcode/unikey', '/api/login/qrcode/client/login']);
const DEFAULT_QR_RETRY_DELAY_MS = 300;
```

2. **xeapi 公钥**：启动时经 `getXeapiPublicKey(currentPublicKey, deviceId)` 获取，响应必须含 `sk` 字符串字段：

```js
// electron/neteaseApiStartup.cjs:46-53
function hasUsableXeapiPublicKey(publicKey) {
  return Boolean(publicKey && typeof publicKey === 'object' && typeof publicKey.sk === 'string' && publicKey.sk.trim());
}
```

  缓存到 `path.resolve(os.tmpdir(), 'xeapi_public_key')`，JSON 序列化（`neteaseBackend.cjs:74,150`）。刷新失败时若缓存 key 可用则回落缓存（`neteaseApiStartup.cjs:146-156`）。

3. **匿名 token**：`register_anonimous` 的响应 cookie 中必须含 **`MUSIC_A`**：

```js
// electron/neteaseApiStartup.cjs:184-189
const cookieObject = cookieToJson(anonymousCookie);
if (typeof cookieObject.MUSIC_A !== 'string' || !cookieObject.MUSIC_A.trim()) {
  throw new Error('anonymous registration response missing MUSIC_A');
}
await persistToken(cookieObject.MUSIC_A);
```
  持久化到 `path.resolve(os.tmpdir(), 'anonymous_token')`（`neteaseBackend.cjs:73`）。
  `util/request` **只在加载时读一次**匿名 token 并缓存到进程结束（`neteaseBackend.cjs:76-78`）。

4. **设备身份**：`global.deviceId = ncmUtil.generateDeviceId()`（`neteaseBackend.cjs:134`）；
   匿名 IP：`global.cnIp = ncmUtil.generateRandomChineseIP()`（`neteaseBackend.cjs:132`）。
   算法在 npm 包内 → **`未在源码中找到，需要抓包确认`**。

5. **上游 axios 请求无 timeout**（`electron/neteaseApiStartup.cjs:14-16`），本仓库用 `withTimeout` 包住，
   默认 `DEFAULT_OPERATION_TIMEOUT_MS = 10000`；重试 `DEFAULT_RETRY_ATTEMPTS = 3`、
   `DEFAULT_RETRY_BASE_DELAY_MS = 250`、`DEFAULT_RETRY_JITTER_MS = 100`。

6. **上游请求失败的形状**：reject 成 `{ status: 502, body: { code: 502, msg } }`（`neteaseApiStartup.cjs:240-246`）。

> **对 ArkTS 的含义**：网易云的 crypto（weapi 的 AES-CBC + RSA、eapi 的 AES-ECB + MD5 digest、linuxapi 的 AES-ECB）
> **必须从 `@neteasecloudmusicapienhanced/api` 的 `util/request.js`/`util/crypto.js` 移植**，本仓库无此常量。
> **禁止臆造** AES key / IV / RSA 模指数。

#### 3.1.6 歌词

**【源码】** `neteaseProvider.ts:240-260`

```ts
const getLyrics = async (song, context?): Promise<ProviderLyricsResult> => {
    if (song.sourceRef?.kind === 'online' && song.sourceRef.variant === 'cloud' && context?.userId != null) {
        const response = await neteaseApi.getCloudLyric(toNeteaseId(context.userId), toNeteaseId(song.id));
        const mainText = extractCloudLyricText(response);
        // ...
    }
    const response = await neteaseApi.getLyric(toNeteaseId(song.id));   // → /lyric/new?id=
    // ...
};
```

- 云盘歌曲专用：`/cloud/lyric/get?uid=&sid=`，文本抽取（`neteaseProvider.ts:155-157`）：
  ```ts
  const extractCloudLyricText = (response: any): string => (
      response?.lrc || response?.data?.lrc || response?.lyric || response?.data?.lyric || ''
  );
  ```
- 普通歌词解析（`src/utils/lyrics/neteaseProcessing.ts:44-62`）——**响应形状逐字**：

```ts
export const extractNeteaseLyricPayload = (source?: RawNeteaseLyric | null): ExtractedNeteaseLyricPayload => {
    const mainLrc  = source?.lrc?.lyric || null;
    const yrcLrc   = source?.yrc?.lyric || source?.lrc?.yrc?.lyric || null;
    const ytlrc    = source?.ytlrc?.lyric || source?.lrc?.ytlrc?.lyric || null;
    const yromalrc = source?.yromalrc?.lyric || source?.lrc?.yromalrc?.lyric || null;
    const tlyric   = source?.tlyric?.lyric || null;
    const romalrc  = source?.romalrc?.lyric || source?.lrc?.romalrc?.lyric || null;
    const transLrc = (yrcLrc && ytlrc) ? ytlrc : tlyric;
    const romanizationLrc = (yrcLrc && yromalrc) ? yromalrc : romalrc;
    const isPureMusic = hasNeteasePureMusicFlag(source) || isPureMusicLyricText(mainLrc);
    return { mainLrc, yrcLrc, transLrc, romanizationLrc, isPureMusic };
};
```

字段：`lrc.lyric`（原文）、`yrc.lyric`（逐字）、`ytlrc.lyric`（逐字翻译）、`yromalrc.lyric`（逐字罗马音）、
`tlyric.lyric`（翻译）、`romalrc.lyric`（罗马音）。**无加密**（网易返回明文 LRC/YRC）。

- 副歌区间：`/song/chorus?id=`，解析（`neteaseProcessing.ts:26-42`）：
  `code === 200`，区间在 `chorusRes.chorus` 或 `chorusRes.data`，字段 `startTime`/`endTime`，**毫秒 → 除以 1000 转秒**。

#### 3.1.7 会话 / 登录态存储

| 值 | 存储 | key |
| --- | --- | --- |
| 登录 cookie | localStorage | `online_provider:netease:cookie`（legacy：`netease_cookie`） |
| 匿名 cookie | localStorage | `online_provider:netease:anonymous_cookie`（legacy：`netease_anonymous_cookie`） |
| 匿名 token `MUSIC_A` | 主进程临时文件 | `%TEMP%\anonymous_token` |
| xeapi 公钥 | 主进程临时文件 | `%TEMP%\xeapi_public_key` |
| deviceId / cnIp | 主进程 `global` | 进程内存 |

**【源码】** `src/services/onlineMusic/providerStorage.ts:10-12`

```ts
export const getProviderSessionKey = (providerId: OnlineProviderId, key: string): string => (
    `online_provider:${providerId}:${key}`
);
export const getProviderCacheKey = (providerId: OnlineProviderId, key: string): string => (
    `online_provider_${providerId}_${key}`
);
```

#### 3.1.8 网易云接口示例（3 个最重要端点）

**（A）搜索 —— GET `{base}/cloudsearch`**

```http
GET /cloudsearch?keywords=%E5%91%A8%E6%9D%B0%E4%BC%A6&limit=30&offset=0&cookie=MUSIC_A%3Dxxx%3B%20__csrf%3Dyyy HTTP/1.1
Host: 127.0.0.1:<port>
```
响应（本地 API 转发的网易原始结构，`netease.ts:806-811` 只处理 `result.songs` / `result.privileges`）：
```json
{
  "result": {
    "songs": [
      { "id": 186016, "name": "晴天", "ar": [{ "id": 6452, "name": "周杰伦" }],
        "al": { "id": 186013, "name": "叶惠美", "picUrl": "http://p1.music.126.net/..." },
        "dt": 269000, "alia": [], "tns": [], "fee": 1, "privilege": { "id": 186016, "fee": 1, "st": 0 } }
    ],
    "songCount": 1234,
    "privileges": [ { "id": 186016, "st": 0, "fee": 1, "pl": 320000, "dl": 320000 } ]
  },
  "code": 200
}
```
净化后的 `UnifiedSong`（`neteaseProvider.ts:213-238`）：
```json
{ "id": 186016, "name": "晴天", "artists": [{ "id": 6452, "name": "周杰伦" }],
  "album": { "id": 186013, "name": "叶惠美", "coverUrl": "http://..." },
  "durationMs": 269000, "aliases": [], "translatedNames": [], "isPureMusic": false,
  "fee": 1, "privilege": {...},
  "sourceRef": { "kind": "online", "providerId": "netease", "mediaId": "186016" } }
```

**（B）歌曲 URL —— GET `{base}/song/url/v1`**

```http
GET /song/url/v1?id=186016&level=exhigh&randomCNIP=true&https=true&cookie=MUSIC_U%3D... HTTP/1.1
```
响应：
```json
{ "data": [ { "id": 186016, "url": "https://m801.music.126.net/.../xxx.mp3",
              "br": 320000, "size": 10776593, "md5": "ab12...", "code": 200,
              "type": "mp3", "level": "exhigh", "encodeType": "mp3",
              "time": 269000, "fee": 1, "freeTrialInfo": null } ], "code": 200 }
```
- `level` 取值：`standard` | `exhigh` | `lossless` | `hires`（由 `mapQuality` 产生）。
- `code: 200` 且 `url != null` 才算成功；VIP 无权限时 `url` 为 `null`。
- **URL 带签名，会过期** → 对应 ArkTS 的 `ProviderAudioSource.expiresAt` 语义【推断】。

**（C）歌词 —— GET `{base}/lyric/new`**

```http
GET /lyric/new?id=186016&cookie=MUSIC_A%3D... HTTP/1.1
```
响应（明文，无加密）：
```json
{ "lrc":    { "version": 1, "lyric": "[00:00.000] 作词 : 徐若瑄\n[00:01.000] 作曲 : 周杰伦\n..." },
  "tlyric": { "version": 1, "lyric": "[00:00.000] Lyrics : Vivian Hsu\n..." },
  "yrc":    { "version": 1, "lyric": "[0,1000](0,500,0)晴(500,500,0)天..." },
  "ytlrc":  { "version": 1, "lyric": "..." },
  "romalrc":{ "version": 1, "lyric": "..." },
  "yromalrc":{ "version": 1, "lyric": "..." },
  "code": 200 }
```

---

### 3.2 酷狗 kugou

#### 3.2.1 架构真相

两条路径（`kugouTransport.ts:355-405`）：

1. **Electron（桌面）**：`window.electron.kugouRequest(operation, params)`
   → `ipcRenderer.invoke('kugou-api-request', operation, params)`（`electron/preload.cjs:144`）
   → `electron/kugouApiBridge.cjs` → `require('kugoumusicapi')` 的模块函数。
   **渲染进程只传 operation + 业务参数，凭据由主进程注入。**
2. **Web**：`VITE_KUGOU_API_BASE` 指向的 Node 服务，`GET {base}{ENDPOINTS[op]}?{params}&cookie=...&timestamp=...`。

**【源码】** `electron/kugouApiBridge.cjs:208`

```js
apiLoader = () => require('kugoumusicapi'),
```

**【源码】** `electron/kugouApiBridge.cjs:232`

```js
process.env.platform = 'lite';
```

> `platform = 'lite'` 是概念版/lite 客户端身份，影响 KuGou 上游返回的音质与权限。

#### 3.2.2 base URL / host

| 用途 | 值 | 来源 |
| --- | --- | --- |
| Web REST base | `VITE_KUGOU_API_BASE` | `kugouTransport.ts:59-68` |
| 匿名搜索 | `http://complexsearch.kugou.com/v2/search/song` | `kugouTransport.ts:225` |
| 匿名搜索 x-router | `complexsearch.kugou.com` | `kugouTransport.ts:239` |
| 旧版播放回落 | `https://m.kugou.com/app/i/getSongInfo.php` | `kugouTransport.ts:267` |
| Electron | IPC（无 URL） | — |

#### 3.2.3 全部 operation 与端点（36 个）

**【源码】** `kugouTransport.ts:7-57`（逐字）

```ts
export const KUGOU_OPERATIONS = [
    'register_dev', 'login_qr_key', 'login_qr_create', 'login_qr_check', 'logout',
    'user_detail', 'user_vip_detail', 'youth_union_vip', 'youth_day_vip', 'youth_day_vip_upgrade',
    'user_playlist', 'user_cloud', 'user_cloud_url', 'search',
    'audio', 'krm_audio', 'song_url', 'song_climax', 'search_lyric', 'lyric', 'playlist_track_all',
    'playlist_detail',
    'album_detail', 'album_songs', 'artist_detail', 'artist_albums', 'artist_audios',
    'everyday_recommend', 'everyday_history', 'personal_fm', 'top_card_youth', 'playlist_add',
    'playlist_del', 'playlist_tracks_add', 'playlist_tracks_del',
] as const;

const ENDPOINTS: Record<KugouOperation, string> = {
    register_dev: '/register/dev',
    login_qr_key: '/login/qr/key',
    login_qr_create: '/login/qr/create',
    login_qr_check: '/login/qr/check',
    logout: '/logout',
    user_detail: '/user/detail',
    user_vip_detail: '/user/vip/detail',
    youth_union_vip: '/youth/union/vip',
    youth_day_vip: '/youth/day/vip',
    youth_day_vip_upgrade: '/youth/day/vip/upgrade',
    user_playlist: '/user/playlist',
    user_cloud: '/user/cloud',
    user_cloud_url: '/user/cloud/url',
    search: '/search',
    audio: '/audio',
    krm_audio: '/krm/audio',
    song_url: '/song/url',
    song_climax: '/song/climax',
    search_lyric: '/search/lyric',
    lyric: '/lyric',
    playlist_track_all: '/playlist/track/all',
    playlist_detail: '/playlist/detail',
    album_detail: '/album/detail',
    album_songs: '/album/songs',
    artist_detail: '/artist/detail',
    artist_albums: '/artist/albums',
    artist_audios: '/artist/audios',
    everyday_recommend: '/everyday/recommend',
    everyday_history: '/everyday/history',
    personal_fm: '/personal/fm',
    top_card_youth: '/top/card/youth',
    playlist_add: '/playlist/add',
    playlist_del: '/playlist/del',
    playlist_tracks_add: '/playlist/tracks/add',
    playlist_tracks_del: '/playlist/tracks/del',
};
```

Electron 侧 operation → KuGouMusicApi 模块名映射（`electron/kugouApiBridge.cjs:9-45`），注意三个一对多：

```js
  playlist_track_all: ['playlist_track_all', 'playlist_track_all_new'],   // 依次尝试
```

其余均为 `[同名]`；`logout: []`（本地清除，不发上游请求，直接返回 `{ code: 200 }`，见 `kugouApiBridge.cjs:317-322`）。

#### 3.2.4 Web 传输的请求形状

**【源码】** `kugouTransport.ts:376-397`

```ts
const execute = async (targetOperation, targetParams): Promise<any> => {
    const query = new URLSearchParams();
    Object.entries(targetParams).forEach(([key, value]) => {
        if (value !== undefined) query.set(key, String(value));
    });
    const cookie = getWebSessionCookie();
    if (cookie) query.set('cookie', cookie);
    query.set('timestamp', String(Date.now()));

    const response = await fetch(`${base}${ENDPOINTS[targetOperation]}?${query}`, { credentials: 'include' });
    // ...
    const responseBody = await response.json();
    persistWebSession(responseBody);
    const body = responseBody?.body ?? responseBody;    // ← 去 envelope
    return body;
};
```

- 方法：**GET**（文档 `ku-go-api-docs.md:214` 说明同时支持 GET/POST，POST 必须加时间戳）。
- `cookie` 与 `timestamp` 都是 query 参数。
- 响应 envelope 是 `{ status, body, cookie }`，本层取 `body`。
- **设备校验重试**（`kugouTransport.ts:399-405`）：若 body 的 `errcode`/`error_code === 20028` 或消息含 `本次请求需要验证`，则清 `dfid`、重跑 `register_dev`、重发原请求。

#### 3.2.5 签名方案（**这是本仓库中唯一可确证的真实签名常量**）

**【源码】** `kugouTransport.ts:192-241` —— 匿名 Android 搜索签名（`platform: 'AndroidFilter'`，`appid: '3116'`）：

```ts
// Reproduces KuGou's anonymous Android search signature used before account-backed provider search.
export const requestKugouAnonymousSearch = async (keyword, page, pagesize): Promise<any> => {
    const clientTimeMs = Date.now();
    const clientTimeSec = Math.floor(clientTimeMs / 1000);
    const mid = md5(String(clientTimeMs));
    const params: Record<string, string | number> = {
        sorttype: '0',
        keyword,
        pagesize,
        page,
        userid: '0',
        appid: '3116',
        token: '',
        clienttime: clientTimeSec,
        iscorrection: '1',
        uuid: '-',
        mid,
        dfid: '-',
        clientver: '11070',
        platform: 'AndroidFilter',
    };
    const signatureSource = Object.keys(params)
        .sort()
        .map(key => `${key}=${params[key]}`)
        .join('');
    params.signature = md5(
        `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA${signatureSource}LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`,
    );

    const targetUrl = new URL('http://complexsearch.kugou.com/v2/search/song');
    Object.entries(params).forEach(([key, value]) => targetUrl.searchParams.set(key, String(value)));
    // ...
    const response = await fetch(requestUrl, {
        method: 'GET',
        credentials: 'omit',
        headers: {
            'User-Agent': 'Android14-1070-11070-201-0-SearchSong-wifi',
            'KG-Rec': '1',
            'KG-RC': '1',
            'KG-CLIENTTIMEMS': String(clientTimeMs),
            mid,
            'x-router': 'complexsearch.kugou.com',
        },
    });
    // ...
};
```

**签名算法（精确）**：
1. `mid = MD5(String(Date.now()))`（十进制毫秒时间戳的 MD5 十六进制小写）。
2. 把参数字典的 key **字典序排序**，拼成 `k1=v1k2=v2...`（**无分隔符**）。
3. `signature = MD5( SALT + signatureSource + SALT )`，其中

   **`SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"`**（32 字符，出现两次，前后包裹）。
4. `signature` 作为一个**普通查询参数**加入（注意：`signatureSource` 在算签名时**不含** `signature` 自身，因为它在之后才被赋值）。

**请求头**（逐字）：`User-Agent: Android14-1070-11070-201-0-SearchSong-wifi`、`KG-Rec: 1`、`KG-RC: 1`、
`KG-CLIENTTIMEMS: <clientTimeMs>`、`mid: <mid>`、`x-router: complexsearch.kugou.com`。

> ⚠️ **重要区分**：这是**匿名 Android 搜索**的签名路径（`requestKugouAnonymousSearch`），
> **只在没有登录态时**用于 `searchSongs`（`kugouProvider.ts:984-998`）。
> 登录态下的 `/search` 走 KuGouMusicApi 服务，签名由 `kugoumusicapi` npm 包内部完成。

**登录态下的签名/lite-header 方案** → **`未在源码中找到，需要抓包确认`**（在 `kugoumusicapi` 包内）。
仅能确证主进程设置 `process.env.platform = 'lite'`（`kugouApiBridge.cjs:232`）。

#### 3.2.6 lite 客户端设备 cookie（**ArkTS 必做，否则 `本次请求需要验证`**）

**【源码】** `electron/kugouApiBridge.cjs:128-141`

```js
// Builds the stable lite-client identity expected by KuGouMusicApi without starting its HTTP server.
function createDeviceCookies() {
  const guid = crypto.randomUUID().replace(/-/g, '').toUpperCase();
  const digest = crypto.createHash('md5').update(guid).digest('hex');
  const mac = Array.from(crypto.randomBytes(6)).map(value => value.toString(16).padStart(2, '0')).join(':').toUpperCase();
  return {
    KUGOU_API_PLATFORM: 'lite',
    KUGOU_API_GUID: guid,                                  // 32 位大写 hex
    KUGOU_API_MID: BigInt(`0x${digest}`).toString(10),      // md5(guid) 当大整数转十进制
    KUGOU_API_DEV: randomUpperHex(5),                       // 10 位大写 hex
    KUGOU_API_MAC: mac,                                     // AA:BB:CC:DD:EE:FF 大写
    KUGOU_API_WEBGL: BigInt(`0x${randomUpperHex(8)}`).toString(10),
  };
}
```

`randomUpperHex(bytes) = crypto.randomBytes(bytes).toString('hex').toUpperCase()`（`kugouApiBridge.cjs:47`）。

> ArkTS：`crypto.randomUUID()` → `@ohos.util` 的 `util.generateRandomUUID()`；`randomBytes` → `@ohos.security.cryptoFramework` 的随机数或 `util` 等效；`BigInt(0x<hex>).toString(10)` 需要手写 hex→十进制字符串转换（ArkTS 的 `BigInt` 支持需实测）。

#### 3.2.7 凭据存储与注入

**【源码】** `electron/kugouApiBridge.cjs:5-8`

```js
const LEGACY_SESSION_KEY = 'KUGOU_API_SESSION_V1';
const SESSION_KEY = 'KUGOU_API_SESSION_V2';
const SESSION_ENVELOPE_VERSION = 2;
const AUTH_COOKIE_KEYS = new Set(['token', 'userid', 'user_id', 'dfid']);
```

- 存储格式：`safeStorage.encryptString(JSON.stringify({ version: 2, cookies })).toString('base64')`（`kugouApiBridge.cjs:111-124`）。
- 拒绝 Linux `basic_text` 后端（`kugouApiBridge.cjs:55-68`）——明文不上盘。
- 注入：`invokeModule` 把 `{ userid, uid, token, cookie: {...sessionCookies} }` 合并进 params（`kugouApiBridge.cjs:283-290`）。
- 响应合并回 session：`mergeResponseSession` 读 `result.cookie[]` 数组的每个 `k=v`，以及 `body.data.token` / `userid` / `dfid`（`kugouApiBridge.cjs:241-255`）。
- 渲染进程侧（**Electron 模式**）只留非敏感 `userid`：
  - 读：`readProviderSessionValue('kugou', 'userid')` → `online_provider:kugou:userid`
  - IPC 边界过滤掉 `token`/`dfid`/`cookie`（`kugouTransport.ts:359-361`）
  - `login_qr_check`/`register_dev` 的响应体在主进程被剥离 `token`/`dfid`/`cookie`（`kugouApiBridge.cjs:260-272`）
- 渲染进程侧（**Web 模式**）在 localStorage 存 `cookie` / `token` / `userid` / `dfid`（`kugouTransport.ts:318-330`），
  cookie 串拼装见 `getWebSessionCookie()`（`kugouTransport.ts:162-178`）。

#### 3.2.8 播放 URL

**【源码】** `kugouProvider.ts:1016-1132`。请求变体（按顺序降级）：

```ts
const qualities = sourceRef?.variant === 'cloud' ? [quality] : qualityFallbacks(quality);
// 非 cloud：
//   1) song_url { hash, quality, album_id, album_audio_id }
//   2) song_url { hash, quality, album_id: '', album_audio_id: '' }   ← 仅当有 album 元数据时才加
// cloud：
//   user_cloud_url { hash, id: providerData.fileId }
```

**quality 映射（逐字，`kugouProvider.ts:662-673`）**：

```ts
const qualityValue = (quality: AudioQualityPreference): string => ({
    standard: '128', high: '320', lossless: 'flac', hires: 'high',
})[quality];

const QUALITY_FALLBACKS: Record<AudioQualityPreference, AudioQualityPreference[]> = {
    standard: ['standard'],
    high: ['high', 'standard'],
    lossless: ['lossless', 'high', 'standard'],
    hires: ['hires', 'lossless', 'high', 'standard'],
};
const qualityFallbacks = (quality: AudioQualityPreference): AudioQualityPreference[] => QUALITY_FALLBACKS[quality];
```

> 注意反直觉点：Folia 的 `hires` → KuGou 参数 **`high`**；Folia 的 `lossless` → KuGou 参数 **`flac`**。

URL 抽取（`kugouProvider.ts:1050-1053`）：

```ts
const url = audioUrlOf(
    valueOf(payload, 'play_url', 'playUrl', 'url')
    ?? valueOf(data?.[0], 'url', 'play_url'),
);
```

ReplayGain 来自同一 payload：`volume`（dB trackGain）、`volume_peak`（经 `decibelsToLinearPeak` 转线性 trackPeak）
（`kugouProvider.ts:1055-1062`）。

**最后兜底**（仅非 cloud，`kugouProvider.ts:1100-1128`）：
`GET https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=<hash>`，
取 `url` 或 `backup_url`，成功则 `quality: 'standard'`。User-Agent 为
`Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36`（`kugouTransport.ts:293`）。

**音频 URL 是否需要额外头 / 是否过期** → **`未在源码中找到，需要抓包确认`**（Folia 未对返回 CDN URL 附加任何请求头，
交由播放器直接加载）。

#### 3.2.9 歌词

两步（`kugouProvider.ts:711-760`）：

**第 1 步** `GET /search/lyric`：
```ts
const response = await requestKugou('search_lyric', {
    hash: String(song.kgHash ?? song.id).toUpperCase(),
    duration: song.durationMs,
    man: 'no',
    ...(albumAudioId !== undefined ? { album_audio_id: String(albumAudioId) } : {}),
});
const candidates = (response as any)?.candidates;
return Array.isArray(candidates) ? candidates[0] ?? null : null;
```
`albumAudioId` 取自 `sourceRef.providerData.albumAudioId ?? .mixSongId ?? .catalogLookupId`。

**第 2 步** `GET /lyric`：
```ts
const response = await requestKugou('lyric', {
    id: String(candidate.id),
    accesskey: String(candidate.accesskey),
    fmt: 'krc',
    decode: true,
});
const lyricText = typeof (response as any)?.decodeContent === 'string' ? (response as any).decodeContent : '';
```
- 用 **`fmt=krc` + `decode=true`**，**服务端**返回已解码的 `decodeContent`。
- 因此 **ArkTS 不需要实现 KRC 解密**，只要服务端还提供这组参数。若走纯端侧，则
  KRC 的 DES/加密解码 → **`未在源码中找到，需要抓包确认`**（Folia 从未在客户端解密）。
- 解析：`parseLyricsByFormat('krc', lyricText, '')`，随后 `parsed.isWordByWord = true`。
- 纯音乐判定：`isPureMusicLyricText(lyricText)`。
- 副歌：`GET /song/climax?hash=<hash>`（`kugouProvider.ts:701`）。

#### 3.2.10 认证失败的判定（ArkTS 必须复刻）

**【源码】** `kugouTransport.ts:77-82`

```ts
const KUGOU_AUTH_FAILURE_STATUSES: ReadonlySet<number> = new Set([401, 403]);
const KUGOU_AUTH_FAILURE_ERROR_CODES: ReadonlySet<number> = new Set([152]);
```

`152` 的来源注释：**认证请求缺少有效 cookie 凭据**（`kugouTransport.ts:79-81`）。
`20028` = 需要设备验证（`kugouTransport.ts:70-74`）。

#### 3.2.11 扫码登录

**【源码】** `kugouProvider.ts:1189-1199`

```ts
const response = await requestKugou('login_qr_key');
// → GET /login/qr/key
const response = await requestKugou('login_qr_create', { key, qrimg: true });
// → GET /login/qr/create?key=<key>&qrimg=true
const response = await requestKugou('login_qr_check', { key, qrcode: key });
// → GET /login/qr/check?key=<key>&qrcode=<key>
```

文档说明（`ku-go-api-docs.md:305-315`）：轮询返回码 `0` 过期、`1` 等待扫码、`2` 待确认、`4` 授权成功（返回 token）。

#### 3.2.12 酷狗接口示例（3 个最重要端点）

**（A）搜索 —— 登录态 `GET {base}/search`**
```http
GET /search?keywords=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&keyword=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&type=song&page=1&pagesize=30&cookie=token%3Dxxx%3Buserid%3D123%3Bdfid%3Dyyy&timestamp=1691256061923 HTTP/1.1
```
（`kugouProvider.ts:999` 同时传 `keywords` 与 `keyword` 两个参数名。）

文档示例（`ku-go-api-docs.md:764`）：
```text
/search?keywords=周杰伦&cookie=token=xxxx;userid=xxxx;dfid=xxxx
```
⚠️ 文档明确：不带认证信息会返回 `error_code: 152`。

**（A'）搜索 —— 匿名端侧（不经服务端）**
```http
GET http://complexsearch.kugou.com/v2/search/song?sorttype=0&keyword=%E6%B5%B7%E9%98%94%E5%A4%A9%E7%A9%BA&pagesize=30&page=1&userid=0&appid=3116&token=&clienttime=1691256061&iscorrection=1&uuid=-&mid=<md5(ms)>&dfid=-&clientver=11070&platform=AndroidFilter&signature=<md5(salt+src+salt)> HTTP/1.1
User-Agent: Android14-1070-11070-201-0-SearchSong-wifi
KG-Rec: 1
KG-RC: 1
KG-CLIENTTIMEMS: 1691256061923
mid: <md5(ms)>
x-router: complexsearch.kugou.com
```

**（B）歌曲 URL —— `GET {base}/song/url`**
```http
GET /song/url?hash=ABCDEF0123456789ABCDEF0123456789&quality=320&album_id=10729818&album_audio_id=123456789&cookie=...&timestamp=... HTTP/1.1
```
文档参数（`ku-go-api-docs.md:659-705`）：必选 `hash`；可选 `album_id`、`free_part`、`album_audio_id`、`quality`。
`quality` 取值：`128`、`320`、`flac`、`high`、`piano`、`acappella`、`subwoofer`、`ancient`、`surnay`、`dj`、
`viper_atmos`、`viper_clear`、`viper_tape`、`super`。
⚠️ 文档明确：**必须先调 `/register/dev` 拿 `dfid`**，否则提示 `本次请求需要验证`。
响应字段（由 `kugouProvider.ts:1048-1062` 反推）：
```json
{ "status": 1,
  "data": { "play_url": "https://...mp3", "playUrl": "...", "url": "...",
            "volume": -3.2, "volume_peak": 0.98,
            "album_id": "...", "album_audio_id": "..." },
  "errcode": 0, "error_code": 0 }
```
> 注意 `payload` 可能是 `data[0]`（数组）也可能是 `data`（对象）——`kugouProvider.ts:1049` 两者都处理。

**（C）歌词 —— 两步 `GET /search/lyric` → `GET /lyric`**
```http
GET /search/lyric?hash=ABCDEF...&duration=269000&man=no&album_audio_id=123456789&cookie=...&timestamp=... HTTP/1.1
```
```json
{ "status": 1, "candidates": [ { "id": 123456, "accesskey": "9f8e7d...", "product_from": "...", "duration": 269000 } ] }
```
```http
GET /lyric?id=123456&accesskey=9f8e7d...&fmt=krc&decode=true&cookie=...&timestamp=... HTTP/1.1
```
```json
{ "status": 1, "decodeContent": "[0,1000]<0,500,0>晴<500,500,0>天..." }
```
（`kugouProvider.ts:741-743` 只认 `response.decodeContent`。）

---

### 3.3 Navidrome（Subsonic）

**【源码】** `src/services/onlineMusic/README.md:21`
> “Navidrome 是独立的 Subsonic 服务，入口是 `src/services/navidromeService.ts`，**不属于 Omni provider**。”

**【源码】** `skills/online-song-omni-routing/SKILL.md:18`
> “`navidromeService.ts` is a separate Subsonic service, not an Omni provider.”

但 `PlaybackSourceRef` 有 `{ kind: 'navidrome'; mediaId: string }` 分支（`types/onlineMusic.ts:28`），
说明播放层仍把它当一种来源。**ArkTS 应保留这个独立 service，不要塞进 Omni registry。**

#### 3.3.1 认证方案（**逐字**）

**【源码】** `navidromeService.ts:136-155`

```ts
const buildAuthParamsWithSalt = (config: NavidromeConfig, salt: string): URLSearchParams => {
    // Subsonic API: token = md5(password + salt) where password is the plain text password
    // config.passwordHash actually contains the plain password (see hashPassword function)
    const token = md5(config.passwordHash + salt);

    const params = new URLSearchParams();
    params.set('u', config.username);
    params.set('t', token);
    params.set('s', salt);
    params.set('v', '1.16.1'); // Subsonic API version
    params.set('c', 'Folia'); // Client identifier
    params.set('f', 'json'); // Response format

    return params;
};
```

| 参数 | 值 |
| --- | --- |
| `u` | `config.username` |
| `t` | `md5(明文密码 + salt)` |
| `s` | salt |
| `v` | **`'1.16.1'`** |
| `c` | **`'Folia'`** |
| `f` | **`'json'`** |

**salt 生成**（`navidromeService.ts:130-134`）：
```ts
const generateSalt = (): string => {
    const array = new Uint8Array(8);
    crypto.getRandomValues(array);
    return Array.from(array, (byte) => byte.toString(16).padStart(2, '0')).join('');
};
```
→ **8 随机字节 → 16 位小写 hex 字符串**。

**明文密码存储**（`navidromeService.ts:122-127`）：
```ts
// For Subsonic API, we need the plain password to compute token = md5(password + salt)
// We store it as-is (Subsonic API requirement - unfortunately cannot pre-hash)
export const hashPassword = (password: string): string => {
    return password;   // 原样返回
};
```
`config.passwordHash` **实际存的是明文密码**。（ArkTS 侧应改用 `@ohos.security.huks`/`preferences` 加密存储。）

**URL 稳定性**：`buildStableUrlAuthParams(config, scope)`（`navidromeService.ts:167-186`）为
`stream:<songId>:<format>` 与 `cover:<coverArtId>:<size>` 两个 scope 各缓存一个 salt（LRU，上限
`MAX_STABLE_URL_SALT_CACHE_ENTRIES = 512`），使同一首歌的播放 URL 在一个会话内保持稳定（避免每次刷新 URL 变化导致播放器重载/缓存失效）。

#### 3.3.2 base URL 与请求构造

**【源码】** `navidromeService.ts:189-220`

```ts
const fetchSubsonic = async <T>(config, endpoint, extraParams?): Promise<SubsonicResponse<T>> => {
    const url = new URL(`${config.serverUrl}/rest/${endpoint}`);
    const authParams = buildAuthParams(config);
    authParams.forEach((value, key) => { url.searchParams.set(key, value); });
    if (extraParams) {
        Object.entries(extraParams).forEach(([key, value]) => {
            if (Array.isArray(value)) { value.forEach(item => url.searchParams.append(key, String(item))); return; }
            url.searchParams.set(key, String(value));
        });
    }
    const response = await fetch(url.toString());
    if (!response.ok) { throw new Error(`HTTP error: ${response.status}`); }
    return response.json();
};
```

- **URL 模板：`<serverUrl>/rest/<endpoint>`**（endpoint **不带** `.view` 后缀）。
- 方法：**GET**，全部参数在 query。
- 响应 envelope：`{ "subsonic-response": { ... } }`，成功判定 `res['subsonic-response'].status === 'ok'`。

#### 3.3.3 全部端点

| endpoint | 附加参数 | 用途 | 行 |
| --- | --- | --- | --- |
| `ping` | — | 连通性 | 253 |
| `getOpenSubsonicExtensions` | — | 能力发现 | 263 |
| `getUser` | `username=<user>` | 用户 | 275 |
| `getMusicFolders` | — | 媒体库 | 289 |
| `getLicense` | — | 授权 | 301 |
| `getAlbumList2` | `type`、`size`、`offset` | 专辑列表 | 347 |
| `getAlbum` | `id` | 专辑详情 | 364 |
| `getPlaylists` | — | 歌单列表 | 376 |
| `getPlaylist` | `id` | 歌单详情 | 388 |
| `createPlaylist` | 见源码 404 | 新建/更新歌单 | 404 |
| `deletePlaylist` | 见源码 419 | 删除歌单 | 419 |
| `updatePlaylist` | 见源码 441 | 编辑歌单 | 441 |
| `getRandomSongs` | `size` | 随机 | 458 |
| `getStarred2` | — | 收藏 | 472 |
| `star` | `id=<songId>` | 收藏单曲 | 485 |
| `unstar` | `id=<songId>` | 取消收藏 | 496 |
| **`scrobble`** | `id`、`time`、`submission` | 听歌上报 | 513 |
| `getArtists` | — | 歌手索引 | 527 |
| `getArtist` | `id` | 歌手详情 | 540 |
| `getSong` | `id` | 单曲 | 553 |
| **`stream`** | `id`、`format?` | 音频流 | 565 |
| `getCoverArt` | `id`、`size?` | 封面 | 582 |
| **`getLyrics`** | `artist`、`title` | 歌词（按艺名/曲名） | 604 |
| **`getLyricsBySongId`** | `id`、`enhanced=true` | 结构化歌词（OpenSubsonic） | 623 |
| **`search3`** | `query`、`artistCount`、`albumCount`、`songCount` | 搜索 | 645 |

`getAlbumList2` 的 `type` 取值（`navidromeService.ts:342`）：
`'alphabeticalByName' | 'alphabeticalByArtist' | 'newest' | 'recent' | 'frequent' | 'random'`。

`scrobble` 参数（`navidromeService.ts:513-517`）：
```ts
{ id: songId, time: options.time ?? Date.now(), submission: options.submission ?? true }
```

`search3` 默认计数（`navidromeService.ts:640-642`）：`artistCount = 5`、`albumCount = 10`、`songCount = 20`。

#### 3.3.4 音频流 URL

**【源码】** `navidromeService.ts:564-578`

```ts
getStreamUrl: (config: NavidromeConfig, songId: string, format?: string): string => {
    const url = new URL(`${config.serverUrl}/rest/stream`);
    const authParams = buildStableUrlAuthParams(config, `stream:${songId}:${format || ''}`);
    authParams.forEach((value, key) => { url.searchParams.set(key, value); });
    url.searchParams.set('id', songId);
    if (format) { url.searchParams.set('format', format); }
    return url.toString();
},
```

- **直接返回带认证参数的 URL**，播放器直接取用；**不需要** Referer / User-Agent / Cookie 头。
- 认证参数内嵌在 URL 里 → **URL 不会过期**（salt 是长期缓存的，仅在配置变更/缓存淘汰时更换）。
- 封面同理（`getCoverArtUrl`，`navidromeService.ts:581-595`，参数 `id` + `size`）。

#### 3.3.5 歌词

- `getLyrics({ artist, title })` → `res['subsonic-response'].lyrics.value`（**纯文本 LRC 字符串**）（`navidromeService.ts:604-610`）。
- `getLyricsBySongId({ id, enhanced: true })` → `res['subsonic-response'].lyricsList.structuredLyrics`（**结构化数组** `StructuredLyric[]`）（`navidromeService.ts:623-628`）。
- **无任何加密/解密**。

#### 3.3.6 配置存储

**【源码】** `navidromeService.ts:35-41`

```ts
const CONFIG_KEY = 'navidrome_config';
const ENABLED_KEY = 'navidrome_enabled';
const SERVER_PROFILE_KEY = 'navidrome_server_profile';
const CONFIG_ORIGIN_KEY = 'navidrome_config_origin';
const PRESET_DISMISSED_KEY = 'navidrome_server_preset_dismissed';
```

`NavidromeConfig`（`src/types/navidrome.ts:4-8`）：
```ts
export interface NavidromeConfig {
    serverUrl: string;
    username: string;
    passwordHash: string;   // ← 实际是明文密码
}
```
全部存 localStorage（`navidromeService.ts:60`、`82`）。**ArkTS 必须改为加密存储。**

#### 3.3.7 Navidrome 接口示例（3 个最重要端点）

**（A）搜索 —— `GET {serverUrl}/rest/search3`**
```http
GET /rest/search3?u=alice&t=8f14e45fceea167a5a36dedd4bea2543&s=a1b2c3d4e5f60718&v=1.16.1&c=Folia&f=json&query=%E6%99%B4%E5%A4%A9&artistCount=5&albumCount=10&songCount=20 HTTP/1.1
```
```json
{ "subsonic-response": {
    "status": "ok", "version": "1.16.1", "type": "navidrome", "serverVersion": "0.53.3",
    "openSubsonic": true,
    "searchResult3": {
      "artist": [ { "id": "ar-1", "name": "周杰伦", "albumCount": 14, "coverArt": "ar-1" } ],
      "album":  [ { "id": "al-1", "name": "叶惠美", "artist": "周杰伦", "artistId": "ar-1",
                    "coverArt": "al-1", "songCount": 11, "duration": 3000, "created": "2024-01-01T00:00:00Z" } ],
      "song":   [ { "id": "so-1", "parent": "al-1", "title": "晴天", "album": "叶惠美",
                    "artist": "周杰伦", "track": 1, "duration": 269, "suffix": "mp3",
                    "bitRate": 320, "coverArt": "al-1", "contentType": "audio/mpeg" } ]
    } } }
```

**（B）歌曲流 —— `GET {serverUrl}/rest/stream`**
```http
GET /rest/stream?u=alice&t=8f14e45fceea167a5a36dedd4bea2543&s=a1b2c3d4e5f60718&v=1.16.1&c=Folia&f=json&id=so-1 HTTP/1.1
```
→ 返回**音频二进制流**（`Content-Type: audio/mpeg`，支持 Range）。**无过期**。

**（C）歌词 —— `GET {serverUrl}/rest/getLyricsBySongId`**
```http
GET /rest/getLyricsBySongId?u=alice&t=...&s=...&v=1.16.1&c=Folia&f=json&id=so-1&enhanced=true HTTP/1.1
```
```json
{ "subsonic-response": { "status": "ok", "version": "1.16.1", "openSubsonic": true,
    "lyricsList": { "structuredLyrics": [
      { "displayArtist": "周杰伦", "displayTitle": "晴天", "lang": "zh",
        "synced": true, "line": [ { "start": 0, "value": "作词 : 徐若瑄" },
                                   { "start": 1000, "value": "作曲 : 周杰伦" } ] } ] } } }
```
纯文本备用：`GET /rest/getLyrics?...&artist=周杰伦&title=晴天` → `{"subsonic-response":{"status":"ok","lyrics":{"artist":"...","title":"...","value":"[00:00.00]..."}}}`

---

### 3.4 其他 provider（简略）

| provider | transport | 依赖 | 备注 |
| --- | --- | --- | --- |
| `bodian` 波点 | `bodianTransport.ts`（23 行）→ 受限 IPC | `bodian-music-api@0.1.2`（`package.json:213`） | 协议在**独立仓库**维护（`README.md:53-54`）；凭据不返回 renderer；**不建议移植** |
| `qq` QQ音乐 | `qqTransport.ts` → `VITE_QQ_API_BASE` | 私有后端 / `worker/qq.ts` | 集合身份必须用 `mid`，数字 `albumid`/`singer.id` 会被拒收（200 但 `code != 0`）；`README.md:57` |

**【源码】** `electron/bodianApiBridge.cjs:1-24` 全部内容：
```js
const { createBodianApi, BODIAN_OPERATIONS } = require('bodian-music-api');
const { createSessionRepository } = require('./bodian/session.cjs');
function createBodianApiBridge({ store, safeStorage, requestFactory, onAudioSource = () => {}, now = Date.now,
  warn = console.warn, apiFactory = createBodianApi }) {
  const sessions = createSessionRepository({ store, safeStorage, warn });
  const api = apiFactory({ deviceId: sessions.deviceId, sessions, requestFactory, now });
  return {
    async request(operation, params = {}) {
      try {
        if (!BODIAN_OPERATIONS.includes(operation)) {
          return { ok: false, error: { code: 'unsupported', message: 'Unsupported Bodian operation' } };
        }
        const result = await api.request(operation, params);
        if (result.ok && operation === 'audio' && result.data?.url) onAudioSource(result.data.url);
        return result;
      } catch {
        return { ok: false, error: { code: 'invalid-response', message: 'Bodian operation failed' } };
      }
    },
  };
}
```

---

## 4. Electron 主进程做了什么，HarmonyOS 必须自己做什么

### 4.1 IPC 桥清单

**【源码】** `electron/preload.cjs:132-145`

```js
    fetchLyricProxy: (url, init) => ipcRenderer.invoke('lyric-proxy-fetch', url, init),
    getNeteasePort: () => ipcRenderer.invoke('get-netease-port'),
    getKugouApiStatus: () => ipcRenderer.invoke('kugou-api-status'),
    kugouRequest: (operation, params) => ipcRenderer.invoke('kugou-api-request', operation, params),
    bodianRequest: (operation, params) => ipcRenderer.invoke('bodian-api-request', operation, params),
```

### 4.2 逐个桥的职责 → ArkTS 替代

| # | 桥 | 主进程做什么 | 为什么渲染进程做不了 | ArkTS 替代 |
| --- | --- | --- | --- | --- |
| 1 | `lyric-proxy-fetch` → `electron/lyricApi.cjs` | 代发任意 URL 的 HTTP（绕过 CORS） | 浏览器 fetch 受同源策略限制；酷狗的 `complexsearch.kugou.com`、`m.kugou.com` 无 CORS 头 | **不需要**：`@ohos.net.http` 无 CORS 概念，直接请求 |
| 2 | `get-netease-port` → `electron/neteaseBackend.cjs` | 拉起并管理内嵌 Node 服务（`@neteasecloudmusicapienhanced/api`）；返回动态端口 | 需要 Node runtime + npm 包 + 完整 crypto | **必须自实现**：weapi/eapi/xeapi crypto + 全部 42 个端点（§3.1.3），或保留服务端代理 |
| 3 | `kugou-api-status` → `electron/kugouApiBridge.cjs` | `ensureCookies()` + `loadApi()`，返回 `{available, authenticated, error}` | — | 自实现状态判定：本地是否有 `userid`/`token`（§3.2.10） |
| 4 | `kugou-api-request` → `electron/kugouApiBridge.cjs` | ①`require('kugoumusicapi')` 全部 36 个模块；②`process.env.platform='lite'`；③lite 设备 cookie 生成（`KUGOU_API_*`）；④`register_dev` 拿 `dfid` 与 20028 重试；⑤凭据注入 `{userid, uid, token, cookie}`；⑥响应 cookie 合并 + `safeStorage` 加密持久化；⑦响应体剥离 `token`/`dfid`/`cookie` | Node crypto + npm 包 + `safeStorage` | **必须自实现**：36 个端点的请求构造 + lite 设备 cookie（§3.2.6）+ `dfid` 注册/20028 重试 + 凭据加密（`@ohos.security.huks` 或 `preferences` + 自加密） |
| 5 | `bodian-api-request` → `electron/bodianApiBridge.cjs` | `bodian-music-api` 全协议 + session 仓库 | 协议在独立仓库 | **强烈不建议移植** |
| 6 | （无 IPC）QQ | `VITE_QQ_API_BASE` 私有后端 | 服务端持有 credential | 需要服务端 |

### 4.3 HarmonyOS 具体 API 映射

| 能力 | Electron/Node | HarmonyOS ArkTS |
| --- | --- | --- |
| HTTP 客户端 | `node:https` / axios / `fetch` | `@ohos.net.http`（`http.createHttp()`） |
| MD5 | `crypto.createHash('md5')` / `blueimp-md5` | `@ohos.security.cryptoFramework` 的 `Md`（`createMd('MD5')`） |
| AES-CBC / AES-ECB | `crypto.createCipheriv` | `@ohos.security.cryptoFramework` 的 `Cipher`（`createCipher('AES128|CBC|PKCS7')` 等） |
| RSA 公钥加密 | `crypto.publicEncrypt` | `@ohos.security.cryptoFramework` 的 `Cipher`（`RSA1024|PKCS1`）+ `AsyKeyGenerator`/`convertKey` 从 PEM |
| 随机数 / UUID | `crypto.randomBytes` / `crypto.randomUUID` | `@ohos.security.cryptoFramework` 的 `Random`；`@ohos.util` 的 `util.generateRandomUUID()` |
| Base64 | `Buffer.from(x).toString('base64')` | `@ohos.util` 的 `util.Base64Helper` |
| hex 编解码 | `Buffer` | `@ohos.util` 的 `util.TextEncoder`/手写 hex；或 `buffer` 库的 polyfill |
| BigInt hex→dec | `BigInt('0x'+hex).toString(10)` | ArkTS 支持 `BigInt` 需实测；否则手写大数十进制转换 |
| 压缩（如需） | `node:zlib` | `@ohos.zlib` |
| 安全存储 | `safeStorage.encryptString` | `@ohos.security.huks`（推荐）或 `@ohos.data.preferences` + 自加密 |
| localStorage | renderer DOM | `@ohos.data.preferences`（迁移 `online_provider:<id>:<key>` 键名） |
| 签名 Header | `Headers` | `http.HttpRequestOptions.header` |

---

## 5. 每个 Provider 的可行性判定

### 5.1 网易云 netease —— **高难度，建议保留服务端代理**

| 项 | 判定 |
| --- | --- |
| 能否纯端侧？ | **理论可以，实践代价极高** |
| 是否需要服务端代理？ | **推荐：是**（复用 `@neteasecloudmusicapienhanced/api` 的 Docker/Node 部署，ArkTS 只发 HTTP） |
| 需要的 crypto | weapi（AES-CBC + RSA）、eapi（AES-ECB + MD5 digest）、xeapi（动态公钥）、linuxapi（AES-ECB）——**常量全在 npm 包内，`未在源码中找到，需要抓包确认`** |
| 额外复杂度 | ①xeapi 公钥需动态获取并缓存（含重试/回落）；②匿名 token `MUSIC_A` 需注册并持久化；③deviceId 轮换；④cnIp 伪造且仅在 `randomCNIP=true` 时；⑤扫码用 eapi 且必须带对来源 IP；⑥上游无 timeout，需自加 10s |
| 难度 | **高** |
| 理由 | 桌面端自己都没有端侧实现——它选择内嵌一个完整 Node 服务。ArkTS 重写等于重写 `NeteaseCloudMusicApiEnhanced` 的 crypto 核心。 |

### 5.2 酷狗 kugou —— **高难度，但端侧路径存在**

| 项 | 判定 |
| --- | --- |
| 能否纯端侧？ | **部分可以**：匿名搜索（§3.2.5）已完全端侧；`/song/url`、`/search/lyric`、`/lyric`、`complexsearch` 都是普通 HTTP + MD5 |
| 是否需要服务端代理？ | **不必须**，前提是自实现 KuGouMusicApi 的模块逻辑与 lite 签名 |
| 需要的 crypto | 仅 **MD5** + 随机数 + hex/BigInt 转换（用于 `KUGOU_API_MID`/`KUGOU_API_WEBGL`）。ArkTS `@ohos.security.cryptoFramework` 完全够 |
| 已知签名常量 | `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`（匿名 Android 搜索，§3.2.5） |
| 未知 | 登录态 `/search` 等端点的 lite 签名 → **`未在源码中找到，需要抓包确认`** |
| 关键依赖 | `dfid`（`/register/dev`）必须先拿到；`20028` 时清 dfid 重注册 |
| 难度 | **高**（crypto 低，协议工作量大——36 个端点） |
| 理由 | crypto 门槛远低于网易云（只要 MD5），但端点数多、响应结构需要逐个对齐 `docs/ku-go-api-docs.md`，且登录态签名未知。 |

### 5.3 Navidrome —— **低难度，可完全端侧**

| 项 | 判定 |
| --- | --- |
| 能否纯端侧？ | ✅ **是** |
| 是否需要服务端代理？ | ❌ **否** |
| 需要的 crypto | **仅 MD5**（`md5(密码 + 16 位 hex salt)`）+ `crypto.getRandomValues(8)` |
| 端点 | 全部是 `GET {serverUrl}/rest/<endpoint>`，参数全在 query |
| 音频 | 直接 URL，认证内嵌，**不过期**，**不需要额外头** |
| 歌词 | 明文 LRC / 结构化 JSON，**无加密** |
| 难度 | **低** |
| 理由 | 纯 Subsonic 标准协议；Folia 的实现已完全在渲染进程（`fetch` + `blueimp-md5`），**没有一行 Node 代码**，可以近乎逐行翻译成 ArkTS。 |

---

## 6. 排序建议

**结论：先做 Navidrome，再做酷狗，网易云最后（或走代理）。波点/QQ 不做。**

| 排名 | Provider | 理由 |
| --- | --- | --- |
| **1** | **Navidrome** | ①唯一零 crypto 依赖（只需 MD5）；②唯一在桌面端已完全端侧实现，**逐行可翻译**；③标准 Subsonic，无协议逆向风险；④音频 URL 直连不过期；⑤歌词明文；⑥能最快跑通「搜索 → 播放 → 歌词」完整链路，验证 `@ohos.net.http` + `@ohos.security.cryptoFramework` + 播放器接线是否正确。**用最小成本把整个在线音乐骨架立起来。** |
| **2** | **酷狗** | ①crypto 只要 MD5，ArkTS 能力足够；②已有**可确证的签名常量**（`LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`）；③匿名搜索路径可立刻端侧跑通，先做出「能搜能播」的最小版本；④有 `docs/ku-go-api-docs.md` 全量文档。**风险点**：登录态签名未知、36 个端点的响应归一化工作量大。 |
| **3** | **网易云** | ①crypto 常量**完全不在源码内**，必须先逆向 `@neteasecloudmusicapienhanced/api` 并抓包验证；②xeapi 公钥是**动态**的，必须在运行时获取并缓存/回落；③匿名 token + deviceId 轮换 + cnIp 策略 + eapi 扫码来源 IP 耦合，任何一环错都会静默失败；④即使全部实现，上游改动会让端侧实现持续失效。**推荐：ArkTS 端保留 `VITE_NETEASE_API_BASE` 等价配置，指向自建/复用 Node 后端。** 这样 42 个端点全部可用，端侧零 crypto。 |
| **4** | QQ 音乐 | 协议本就在私有后端，无端侧可能。 |
| **5** | 波点 | 协议在独立仓库且非开源可审计，不建议投入。 |

**实施顺序建议**：
1. 抽象 `OmniProvider` 接口 + `providerRegistry` + 生成号防护（§1、§2）——**先做，与 provider 无关**。
2. `NavidromeService`（端侧，§3.3）——打通全链路。
3. `KugouTransport`：先做匿名搜索 + `song_url` + `lyric` 三步（端侧，§3.2.5/3.2.8/3.2.9）。
4. `KugouTransport` 扩展：lite 设备 cookie + `register_dev` + 登录 + 其余端点（§3.2.6/3.2.7）。
5. 网易云：实现 `NeteaseTransport` 只做 **HTTP 客户端 + base URL 配置**，把 crypto 留给服务端。

---

## 7. 实现检查清单（ArkTS）

- [ ] `OmniProvider` 接口与 §1.4 的**每个方法签名**逐一对齐（含可选方法的 `?`）。
- [ ] `sourceRef` 三元组身份贯穿：搜索、缓存 key、入队、mutation 都必须带 `providerId`。
- [ ] `OnlineProviderError` 的 `code` 分流保留（`auth-required` / `unsupported` / `network` / `invalid-response` / …）。
- [ ] 生成号（generation）防护：provider 切换后丢弃晚到响应。
- [ ] Navidrome salt 用 **8 随机字节 → 16 位小写 hex**；`v=1.16.1`、`c=Folia`、`f=json` 逐字一致。
- [ ] Navidrome 明文密码改为 `@ohos.security.huks` 加密存储。
- [ ] 酷狗匿名搜索签名：key 排序 → `k=v` 无分隔拼接 → 前后各包一次 `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA` → MD5。
- [ ] 酷狗 `mid = MD5(String(Date.now()))`，并且**同一个 mid 同时进 query 与请求头**。
- [ ] 酷狗 6 个请求头：`User-Agent`、`KG-Rec`、`KG-RC`、`KG-CLIENTTIMEMS`、`mid`、`x-router`。
- [ ] 酷狗 lite 设备 cookie 六项：`KUGOU_API_PLATFORM/GUID/MID/DEV/MAC/WEBGL`。
- [ ] 酷狗 `20028` / `本次请求需要验证` → 清 `dfid` → `register_dev` → 重发。
- [ ] 酷狗错误码 `152` 与 HTTP `401/403` → `auth-required`。
- [ ] 酷狗歌词走 `search_lyric` → `lyric?fmt=krc&decode=true`，只读 `decodeContent`。
- [ ] 网易云：Cookie 走 **query 参数 `cookie=`**（URL 编码），不是请求头。
- [ ] 网易云：`/song/url/v1` 必须带 `randomCNIP=true&https=true`。
- [ ] 网易云：只看 body `code`，不看 HTTP 状态。
- [ ] 网易云 crypto 常量**在实现前先抓包确认**，禁止臆造。
- [ ] `online_provider:<providerId>:<key>` 的存储键名保持兼容（便于迁移）。
- [ ] 音频源缓存 kind：`audio` / `lyric` / `cover` / `replayGain`。

---

## 附录 A：源码位置索引

| 主题 | 文件:行 |
| --- | --- |
| Provider 接口 | `src/types/onlineMusic.ts:249-456` |
| Omni facade | `src/services/onlineMusic/omni.ts` |
| Provider 注册 | `src/services/onlineMusic/providerRegistry.ts:81-84` |
| 层边界说明 | `src/services/onlineMusic/README.md:5-18` |
| Omni 规则 | `skills/online-song-omni-routing/SKILL.md` |
| 网易云 adapter | `src/services/onlineMusic/neteaseProvider.ts` |
| 网易云 HTTP 客户端 | `src/services/netease.ts:26-184` |
| 网易云端点清单 | `src/services/netease.ts:459-909` |
| 网易云内嵌后端 | `electron/neteaseBackend.cjs` |
| 网易云启动纯函数 | `electron/neteaseApiStartup.cjs` |
| 网易云歌词解析 | `src/utils/lyrics/neteaseProcessing.ts:26-96` |
| 酷狗 adapter | `src/services/onlineMusic/kugouProvider.ts` |
| 酷狗 transport | `src/services/onlineMusic/kugouTransport.ts` |
| 酷狗签名 | `kugouTransport.ts:192-241` |
| 酷狗 IPC 桥 | `electron/kugouApiBridge.cjs` |
| 酷狗 API 文档 | `docs/ku-go-api-docs.md` |
| Navidrome 服务 | `src/services/navidromeService.ts` |
| Navidrome 类型 | `src/types/navidrome.ts` |
| Subsonic 认证 | `navidromeService.ts:130-186` |
| 波点桥 | `electron/bodianApiBridge.cjs` |
| IPC 暴露面 | `electron/preload.cjs:132-145` |
| 依赖清单 | `package.json:209-220` |
| 歌词接口（本机只读 API） | `docs/lyric-api.md`（`127.0.0.1:32109`，`GET /v1/lyric`，无鉴权） |

## 附录 B：未找到、必须抓包确认的清单

1. **网易云 weapi/eapi/linuxapi/xeapi 的全部 crypto 常量**（AES key/IV/nonce、RSA 模指数、presetKey、公钥）
   —— 位于 `@neteasecloudmusicapienhanced/api@^4.41.1` 的 `util/request`、`util/crypto` 等模块，**不在本仓库**。
2. 网易云 `generateDeviceId()` 与 `generateRandomChineseIP()` 的算法。
3. 酷狗登录态（非匿名）请求的 lite 签名/lite-header 具体构造 —— 位于 `kugoumusicapi@v1.6.0`。
4. 酷狗 KRC 加密（DES）的密钥与算法 —— Folia 从不客户端解密（靠 `decode=true` 服务端解）。
5. 酷狗返回的音频 CDN URL 是否需要 Referer/User-Agent 才能播放、以及有效期。
6. 酷狗 `/lyric` 响应的完整字段（除 `decodeContent` 外 Folia 未使用）。
7. 波点 `bodian-music-api` 的全部协议细节 —— 在独立仓库。
