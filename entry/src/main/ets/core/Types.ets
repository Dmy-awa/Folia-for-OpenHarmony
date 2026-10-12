/**
 * Folia HarmonyOS - 领域模型
 *
 * 本文件是移植自上游 src/types/appPlayback.ts / src/types/onlineMusic.ts 的规范化类型集合，
 * 是整个应用唯一的领域模型来源。所有 provider、播放器、UI 都使用这里的类型。
 *
 * 命名对齐说明：
 *  - 上游 `Track`            -> 本文件 `Track`
 *  - 上游 `PlaybackSourceRef` -> 本文件 `PlaybackSourceRef`
 *  - 上游 `ProviderLyricsResult` -> 本文件 `LyricPayload`
 */

/** 曲目来源：本地文件 / 在线服务 */
export enum TrackOrigin {
  LOCAL = 'local',
  ONLINE = 'online',
  NAVidrome = 'navidrome'
}

/** 在线服务标识，与上游 providerId 保持一致 */
export enum ProviderId {
  LOCAL = 'local',
  NETEASE = 'netease',
  KUGOU = 'kugou',
  NAVIDROME = 'navidrome'
}

/**
 * 播放源引用：描述「这首歌从哪里取音频」。
 * 本地曲目用 fileUri/fd，在线曲目用 providerId + songId 重新解析直链。
 */
export interface PlaybackSourceRef {
  providerId: ProviderId;
  /** provider 内部歌曲 id */
  songId: string;
  /** 本地文件的沙箱 URI 或 fd:// 描述 */
  fileUri?: string;
  /** 在线直链（可能过期，需要 refresh 时重新解析） */
  streamUrl?: string;
  /** 部分平台需要附带请求头（Referer/Cookie/User-Agent） */
  headers?: Record<string, string>;
}

/** 封面引用 */
export interface CoverRef {
  /** 本地资源路径 */
  uri?: string;
  /** 在线封面地址 */
  url?: string;
  /** 内嵌封面的偏移（本地文件），供按需解码 */
  embeddedOffset?: number;
  embeddedLength?: number;
}

/** 一首歌的规范化模型 */
export interface Track {
  /** 全局唯一 id，格式 `<providerId>:<songId>` */
  id: string;
  title: string;
  artist: string;
  /** 多歌手时的完整列表 */
  artists: string[];
  album: string;
  albumId?: string;
  duration: number;
  origin: TrackOrigin;
  providerId: ProviderId;
  songId: string;
  cover?: CoverRef;
  /** 音质标识，如 standard / exhigh / lossless */
  quality?: string;
  /** 本地曲目专用 */
  fileUri?: string;
  fileSize?: number;
  /** 本地文件的歌词文件绝对路径（同目录同名 .lrc 等） */
  localLyricPath?: string;
  /** 是否有内嵌歌词 */
  hasEmbeddedLyric?: boolean;
  /** 用户手动修正过的匹配结果 */
  matchedLyricId?: string;
  /** 加入媒体库的时间戳 */
  addedAt?: number;
}

/** 播放队列条目：Track + 队列元数据 */
export interface QueueItem {
  track: Track;
  /** 队列内唯一 id，允许同一首歌重复入队 */
  queueId: string;
  /** 由「下一首播放」插入的条目 */
  inserted?: boolean;
}

export enum RepeatMode {
  OFF = 'off',
  ALL = 'all',
  ONE = 'one',
  /** 随机播放；上游把 shuffle 与 repeat 分开，这里合并为一个枚举更贴近播放器语义 */
  SHUFFLE = 'shuffle'
}

export enum PlaybackStatus {
  IDLE = 'idle',
  PREPARING = 'preparing',
  PLAYING = 'playing',
  PAUSED = 'paused',
  STOPPED = 'stopped',
  COMPLETED = 'completed',
  ERROR = 'error'
}

/** 播放快照，UI 与 AVSession 都从这里读取 */
export interface PlaybackSnapshot {
  status: PlaybackStatus;
  /** 当前播放位置，单位毫秒 */
  position: number;
  /** 总时长，单位毫秒；-1 表示未知（直播/试听） */
  duration: number;
  /** 已缓冲到的位置，单位毫秒 */
  buffered: number;
  /** 播放速率 */
  speed: number;
  /** 音量 0~1 */
  volume: number;
  repeatMode: RepeatMode;
  /** 当前队列下标，-1 表示无 */
  index: number;
  isFavorite: boolean;
}

// ---------------------------------------------------------------------------
// 歌词模型
//
// ⚠️ 单位约定：与上游（src/types.ts）保持完全一致，歌词时间轴统一使用**秒（float）**，
//    只有格式边界（YRC/QRC/KRC 的原始毫秒标签）才做 /1000 转换。
//    播放器位置是毫秒，因此 UI 查当前行时需显式 `positionMs / 1000`，
//    全应用仅此一处单位换算，避免 ms/s 混用导致的时序漂移。
// ---------------------------------------------------------------------------

/**
 * 歌词中的一个「词」。
 * 对齐上游 wordSegmentation/graphemeTiming 的产物：逐字歌词由若干 Word 组成。
 */
export interface LyricWord {
  /** 词文本（已按 Grapheme 切分合并） */
  text: string;
  /** 起始时间，**秒**（绝对时间轴） */
  startTime: number;
  /** 结束时间，**秒** */
  endTime: number;
}

/** 歌词行 */
export interface LyricLine {
  /** 行起始时间，**秒** */
  startTime: number;
  /** 行结束时间 = 下一行 startTime，末行取 startTime + 5s */
  endTime: number;
  /**
   * 该行实际停留到的时刻，秒。
   * 上游 renderHints.renderEndTime：允许活跃行在 endTime 之后继续停留（淡出窗口），
   * 查当前行时优先用它作为上界。
   */
  renderEndTime?: number;
  /** 行文本（由 words 拼接或直接来自 LRC） */
  fullText: string;
  /** 逐字时间；为空表示整行歌词（无逐字信息） */
  words: LyricWord[];
  /** 翻译文本 */
  translation?: string;
  /** 音译/罗马音文本 */
  romanization?: string;
  /** 背景和声 */
  background?: string;
  /** 是否是间奏/纯音乐占位行 */
  isInterlude?: boolean;
  /** 该行是否为「元信息行」（作词/作曲等），UI 可弱化 */
  isCredit?: boolean;
  /** 合唱段落标记 */
  isChorus?: boolean;
}

/** 歌词来源格式 */
export enum LyricFormat {
  NONE = 'none',
  LRC = 'lrc',
  ENHANCED_LRC = 'enhanced_lrc',
  VTT = 'vtt',
  TTML = 'ttml',
  KRC = 'krc',
  QRC = 'qrc',
  YRC = 'yrc',
  /** Navidrome/OpenSubsonic 结构化歌词 */
  STRUCTURED = 'structured'
}

/** 一次解析的完整产物 */
export interface LyricDocument {
  format: LyricFormat;
  lines: LyricLine[];
  /** 全局时间偏移，毫秒（来自 [offset:] 或用户手动调整） */
  offset: number;
  /** 原始文本的哈希，用于缓存与匹配去重 */
  hash?: string;
  /** 来源标签，用于 UI 展示 */
  sourceLabel?: string;
  /** 是否包含逐字时间 */
  hasWordTiming: boolean;
}

/** 歌词加载结果：可能成功、可能明确「纯音乐」、可能失败 */
export interface LyricPayload {
  /** 主歌词文本（原始，未经解析） */
  lyric: string;
  /** 翻译歌词文本 */
  translation?: string;
  /** 罗马音/音译 */
  romaji?: string;
  /** 纯音乐标记 */
  pureMusic: boolean;
  /** 来源标识 */
  source: string;
  /**
   * 已知格式提示。
   * 本地侧车文件可凭扩展名确定格式（如 .qrc / .krc 解密后），
   * 此时自动检测会误判，必须显式告知解析器；NONE 表示交给自动检测。
   */
  format?: LyricFormat;
}

// ---------------------------------------------------------------------------
// 在线音乐 provider 契约
// ---------------------------------------------------------------------------

/** 分页结果 */
export interface ProviderPage<T> {
  items: T[];
  total: number;
  hasMore: boolean;
}

/** 搜索结果条目（比 Track 多了「未解析直链」的语义） */
export interface SearchSongItem {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  /** 部分平台在搜索阶段就返回封面 */
  coverUrl?: string;
  /** 部分平台搜索阶段返回的额外信息 */
  albumId?: string;
}

export interface SearchAlbumItem {
  id: string;
  name: string;
  artist: string;
  coverUrl?: string;
  songCount?: number;
}

export interface SearchArtistItem {
  id: string;
  name: string;
  coverUrl?: string;
  albumCount?: number;
}

export interface SearchResult {
  songs: SearchSongItem[];
  albums: SearchAlbumItem[];
  artists: SearchArtistItem[];
}

/** 在线音频直链 */
export interface ProviderAudioSource {
  url: string;
  /** 建议请求头（部分平台防盗链） */
  headers?: Record<string, string>;
  /** 音质 */
  quality: string;
  /** 过期时间戳（毫秒），0 表示不过期 */
  expiresAt: number;
  /** 文件大小，供本地缓存判断 */
  size?: number;
}

/** provider 能力声明，Omni 路由据此决定降级策略 */
export interface ProviderCapabilities {
  search: boolean;
  songUrl: boolean;
  lyric: boolean;
  album: boolean;
  artist: boolean;
  playlist: boolean;
  login: boolean;
  favorite: boolean;
}

/** provider 统一错误 */
export class ProviderError extends Error {
  readonly providerId: ProviderId;
  readonly code: string;
  readonly retryable: boolean;

  constructor(providerId: ProviderId, code: string, message: string, retryable: boolean = false) {
    super(message);
    this.providerId = providerId;
    this.code = code;
    this.retryable = retryable;
  }
}

/**
 * 在线音乐 provider 契约。
 * 所有 provider 必须实现 searchSong / resolveAudioSource / fetchLyric 三个最小能力。
 */
export interface OnlineMusicProvider {
  readonly id: ProviderId;
  readonly displayName: string;
  readonly capabilities: ProviderCapabilities;

  search(keyword: string, page: number, pageSize: number): Promise<SearchResult>;

  resolveAudioSource(songId: string, quality: string): Promise<ProviderAudioSource>;

  fetchLyric(songId: string): Promise<LyricPayload>;
}

/** 应用设置 */
export interface AppSettings {
  /** 默认在线音质 */
  quality: string;
  /** 是否启用逐字歌词 */
  wordByWordLyric: boolean;
  /** 歌词全局偏移，毫秒 */
  lyricOffset: number;
  /** 当前歌词主题 id */
  lyricTheme: string;
  /** 是否在播控中心展示歌词 */
  showLyricInControlCenter: boolean;
  /** 是否开启后台长时任务 */
  backgroundPlayback: boolean;
  /** 进入播放页时自动隐藏控制栏 */
  autoHideChrome: boolean;
}
