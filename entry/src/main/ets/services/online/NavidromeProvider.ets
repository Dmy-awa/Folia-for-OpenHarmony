/**
 * Folia HarmonyOS - Navidrome (Subsonic) provider
 *
 * 移植自上游 `src/services/navidromeService.ts`（移植规范 §3.3）。这是**唯一**可以完全端侧实现、
 * 且不需要任何服务端组件的 provider：只要 MD5，其余全是标准 Subsonic HTTP。
 *
 * 逐字对齐的协议事实（不可改动）：
 *   - token = md5(明文密码 + salt)，salt = 8 随机字节 → 16 位**小写** hex（§3.3.1）
 *   - 固定参数：u / t / s / v='1.16.1' / c='Folia' / f='json'
 *   - URL 模板：`<serverUrl>/rest/<endpoint>`（endpoint **不带** `.view` 后缀，§3.3.2）
 *   - 全部 GET，参数在 query；响应外层是 `{ "subsonic-response": {...} }`，成功判定 status === 'ok'
 *   - stream / getCoverArt 的认证参数**内联在 URL 里**，播放器直接用，不需要额外请求头，URL 不过期
 *
 * 与上游的差异（有意为之）：
 *   1. 上游用 `crypto.getRandomValues`，这里用 `cryptoFramework.createRandom()`（等价能力）。
 *   2. 上游 salt 是「每个 scope 一个、LRU 512 条」的稳定缓存；这里保留同样语义，
 *      让同一首歌的 stream/cover URL 在一个会话内保持稳定（否则播放器会因 URL 变化重载）。
 *   3. 上游把明文密码存 localStorage；这里存 preferences，
 *      并留下 TODO(security) 接入 huks（见 OnlineSettings 文件头）。
 */
import { common } from '@kit.AbilityKit';
import {
  LyricFormat,
  LyricPayload,
  ProviderAudioSource,
  ProviderCapabilities,
  ProviderError,
  ProviderId,
  ProviderPage,
  SearchAlbumItem,
  SearchArtistItem,
  SearchResult,
  SearchSongItem,
  Track
} from '../../core/Types';
import { Logger } from '../../core/Logger';
import {
  addParam,
  appendQuery,
  buildQueryString,
  HttpParam,
  HttpResponse,
  HttpTransport,
  mergeParams,
  toProviderError,
  trimTrailingSlash
} from './HttpTransport';
import { md5Hex, randomHex } from './crypto/CryptoUtil';
import { NavidromeSettings, onlineSettings } from './OnlineSettings';
import {
  buildPage,
  makeTrackId,
  normalizePage,
  normalizePageSize,
  OnlineProviderEx,
  originOf,
  pageOffset,
  ProviderAlbumDetail,
  ProviderArtistDetail,
  ProviderCodes,
  ProviderPlaylistSummary
} from './OnlineProvider';

const TAG: string = 'NavidromeProvider';

/** Subsonic 响应外层 key（连字符无法直接写进 ArkTS 接口属性名，见 unwrapSubsonic） */
const SUBSONIC_ROOT_KEY: string = 'subsonic-response';
/** Subsonic API 版本（逐字，禁止改动） */
const SUBSONIC_VERSION: string = '1.16.1';
/** 客户端标识（逐字，禁止改动） */
const SUBSONIC_CLIENT: string = 'Folia';
/** 响应格式（逐字，禁止改动） */
const SUBSONIC_FORMAT: string = 'json';
/** 稳定 salt 缓存上限（对齐上游 MAX_STABLE_URL_SALT_CACHE_ENTRIES） */
const MAX_SALT_CACHE_ENTRIES: number = 512;
/** 搜索默认计数（对齐上游 search3 的 5 / 10 / 20 语义，这里按页大小取） */
const DEFAULT_SEARCH_COUNT: number = 20;
/** 封面默认尺寸 */
const DEFAULT_COVER_SIZE: number = 300;

// ---------------------------------------------------------------------------
// Subsonic 响应结构（每个字段都可能缺失，逐层判空后再用）
// ---------------------------------------------------------------------------

interface SubsonicError {
  code?: number;
  message?: string;
}

interface SubsonicSong {
  id?: string;
  parent?: string;
  title?: string;
  album?: string;
  artist?: string;
  track?: number;
  /** ⚠️ 单位是**秒**（Subsonic 标准），转成 Track.duration 时要 ×1000 */
  duration?: number;
  suffix?: string;
  bitRate?: number;
  coverArt?: string;
  contentType?: string;
  year?: number;
  genre?: string;
}

interface SubsonicAlbum {
  id?: string;
  name?: string;
  artist?: string;
  artistId?: string;
  coverArt?: string;
  songCount?: number;
  duration?: number;
  year?: number;
  song?: SubsonicSong[] | null;
}

interface SubsonicArtist {
  id?: string;
  name?: string;
  albumCount?: number;
  coverArt?: string;
  album?: SubsonicAlbum[] | null;
}

interface SubsonicPlaylist {
  id?: string;
  name?: string;
  songCount?: number;
  duration?: number;
  coverArt?: string;
  owner?: string;
}

interface SubsonicPlaylists {
  playlist?: SubsonicPlaylist[] | null;
}

interface SubsonicSearchResult {
  artist?: SubsonicArtist[] | null;
  album?: SubsonicAlbum[] | null;
  song?: SubsonicSong[] | null;
}

interface SubsonicLyricLine {
  /** 起始时间，毫秒；纯文本歌词时缺失 */
  start?: number;
  value?: string;
}

interface SubsonicStructuredLyric {
  displayArtist?: string;
  displayTitle?: string;
  lang?: string;
  synced?: boolean;
  line?: SubsonicLyricLine[] | null;
}

interface SubsonicLyricsList {
  structuredLyrics?: SubsonicStructuredLyric[] | null;
}

interface SubsonicLyrics {
  artist?: string;
  title?: string;
  value?: string;
}

interface SubsonicResponse {
  status?: string;
  version?: string;
  type?: string;
  serverVersion?: string;
  openSubsonic?: boolean;
  error?: SubsonicError | null;
  searchResult3?: SubsonicSearchResult | null;
  searchResult2?: SubsonicSearchResult | null;
  album?: SubsonicAlbum | null;
  artist?: SubsonicArtist | null;
  song?: SubsonicSong | null;
  playlists?: SubsonicPlaylists | null;
  lyrics?: SubsonicLyrics | null;
  lyricsList?: SubsonicLyricsList | null;
}

/** 空的搜索结果容器（复用同一个不可变对象，避免每次新建） */
const EMPTY_SEARCH_RESULT: SubsonicSearchResult = {};

/** 结构化歌词 → LRC 文本的转换结果（text 为空表示没有歌词，hasTiming 决定是否给解析器格式提示） */
interface LrcConversion {
  text: string;
  hasTiming: boolean;
}

/** 空的歌词转换结果 */
const EMPTY_LRC: LrcConversion = { text: '', hasTiming: false };

// ---------------------------------------------------------------------------
// 纯函数工具
// ---------------------------------------------------------------------------

/** 补齐两位 */
function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

/** 秒 → 毫秒（Subsonic 的 duration 单位是秒） */
function secondsToMs(seconds: number | undefined | null): number {
  if (seconds === undefined || seconds === null || seconds <= 0) {
    return 0;
  }
  return Math.round(seconds * 1000);
}

/** 取文本字段，缺失/空串时用兜底值 */
function pickText(value: string | undefined | null, fallback: string): string {
  if (value === undefined || value === null || value.length === 0) {
    return fallback;
  }
  return value;
}

/** 毫秒 → LRC 时间标签 `[mm:ss.xx]` */
function formatLrcTime(ms: number): string {
  const totalMs: number = ms < 0 ? 0 : Math.round(ms);
  const minutes: number = Math.floor(totalMs / 60000);
  const seconds: number = Math.floor((totalMs % 60000) / 1000);
  const hundredths: number = Math.floor((totalMs % 1000) / 10);
  return `${pad2(minutes)}:${pad2(seconds)}.${pad2(hundredths)}`;
}

/**
 * 取出 `{"subsonic-response": {...}}` 里的内层对象。
 * ArkTS 接口不能可靠地声明带连字符的属性名，因此先按 Record 拿到内层值，
 * 再用 stringify + parse 二次定型到 SubsonicResponse。
 * 解析失败返回 undefined（调用方转成 INVALID_RESPONSE）。
 */
function unwrapSubsonic(body: string): SubsonicResponse | undefined {
  let parsed: Object;
  try {
    parsed = JSON.parse(body);
  } catch (error) {
    Logger.err(TAG, 'parse subsonic body', error as Error);
    return undefined;
  }
  const record: Record<string, Object> = parsed as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let index = 0; index < keys.length; index++) {
    if (keys[index] !== SUBSONIC_ROOT_KEY) {
      continue;
    }
    const inner: string = JSON.stringify(record[keys[index]]);
    try {
      return JSON.parse(inner) as SubsonicResponse;
    } catch (error) {
      Logger.err(TAG, 'parse subsonic envelope', error as Error);
      return undefined;
    }
  }
  return undefined;
}

/**
 * Subsonic 错误码 → ProviderError 的 code / retryable。
 * 参考 Subsonic 规范：40/41/44 是认证类，50/60 是权限/试用，70 是数据不存在。
 */
function mapSubsonicErrorCode(subsonicCode: number): string {
  if (subsonicCode === 40 || subsonicCode === 41 || subsonicCode === 43 || subsonicCode === 44) {
    return ProviderCodes.AUTH_REQUIRED;
  }
  if (subsonicCode === 50 || subsonicCode === 60) {
    return ProviderCodes.UNAVAILABLE;
  }
  if (subsonicCode === 70) {
    return ProviderCodes.NOT_FOUND;
  }
  return ProviderCodes.INVALID_RESPONSE;
}

/** Subsonic provider */
export class NavidromeProvider implements OnlineProviderEx {
  readonly id: ProviderId = ProviderId.NAVIDROME;
  readonly displayName: string = 'Navidrome';
  readonly capabilities: ProviderCapabilities = {
    search: true,
    songUrl: true,
    lyric: true,
    album: true,
    artist: true,
    playlist: true,
    login: false,
    favorite: false
  };

  /** 保留 context 以便后续接入 huks 加密凭据（当前未使用网络之外的系统能力） */
  private context: common.UIAbilityContext;
  /** scope → salt 的稳定缓存，保证同一首歌的 URL 在一个会话内不变 */
  private saltCache: Map<string, string> = new Map();
  /** 服务器不支持 search3 时置位，后续直接走 search2 */
  private search3Unsupported: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // -------------------------------------------------------------------------
  // 配置
  // -------------------------------------------------------------------------

  private config(): NavidromeSettings {
    return onlineSettings.getNavidrome();
  }

  private baseUrlOf(config: NavidromeSettings): string {
    return trimTrailingSlash(config.serverUrl);
  }

  isConfigured(): boolean {
    const config: NavidromeSettings = this.config();
    return config.serverUrl.length > 0 && config.username.length > 0;
  }

  /** 未配置时抛出面向用户的中文错误（所有网络方法的统一入口） */
  private requireConfig(): NavidromeSettings {
    if (!this.isConfigured()) {
      throw new ProviderError(
        ProviderId.NAVIDROME,
        ProviderCodes.NOT_CONFIGURED,
        '尚未配置 Navidrome：请先在设置里填写服务器地址与用户名',
        false
      );
    }
    return this.config();
  }

  // -------------------------------------------------------------------------
  // Subsonic 认证与传输
  // -------------------------------------------------------------------------

  /** 固定认证参数：u / t / s / v / c / f（顺序与上游一致，便于抓包比对） */
  private buildAuthParams(salt: string, config: NavidromeSettings): HttpParam[] {
    const params: HttpParam[] = [];
    addParam(params, 'u', config.username);
    addParam(params, 't', md5Hex(`${config.password}${salt}`));
    addParam(params, 's', salt);
    addParam(params, 'v', SUBSONIC_VERSION);
    addParam(params, 'c', SUBSONIC_CLIENT);
    addParam(params, 'f', SUBSONIC_FORMAT);
    return params;
  }

  /**
   * scope 级稳定 salt：同一 scope 复用同一个 salt，超过上限时按 FCFS 淘汰一小批。
   * 这样 stream / cover URL 在会话内稳定，播放器缓存不会因为 URL 变化而失效。
   */
  private stableSalt(scope: string): string {
    const cached: string | undefined = this.saltCache.get(scope);
    if (cached !== undefined) {
      return cached;
    }
    if (this.saltCache.size >= MAX_SALT_CACHE_ENTRIES) {
      const dropCount: number = Math.max(1, Math.floor(MAX_SALT_CACHE_ENTRIES / 8));
      const oldest: string[] = [];
      this.saltCache.forEach((value: string, key: string) => {
        if (oldest.length < dropCount) {
          oldest.push(key);
        }
      });
      for (let index = 0; index < oldest.length; index++) {
        this.saltCache.delete(oldest[index]);
      }
    }
    const salt: string = randomHex(8);
    this.saltCache.set(scope, salt);
    return salt;
  }

  /** 发起一次 Subsonic GET 并校验 `subsonic-response.status` */
  private async requestSubsonic(endpoint: string, extra: HttpParam[], salt: string): Promise<SubsonicResponse> {
    const config: NavidromeSettings = this.requireConfig();
    const params: HttpParam[] = [];
    mergeParams(params, this.buildAuthParams(salt, config));
    mergeParams(params, extra);
    const url: string = `${this.baseUrlOf(config)}/rest/${endpoint}`;

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(url, params);
    } catch (error) {
      // 日志里只出现 endpoint，不出现带 t/s 的完整 URL
      Logger.err(TAG, `request ${endpoint}`, error as Error);
      throw toProviderError(ProviderId.NAVIDROME, `请求 Navidrome 接口 ${endpoint}`, error as Error);
    }

    const parsed: SubsonicResponse | undefined = unwrapSubsonic(response.body);
    if (parsed === undefined) {
      throw new ProviderError(
        ProviderId.NAVIDROME,
        ProviderCodes.INVALID_RESPONSE,
        `Navidrome 返回了无法解析的响应（${endpoint}）`,
        true
      );
    }
    if (parsed.status !== 'ok') {
      const subsonicError: SubsonicError | null | undefined = parsed.error;
      let subsonicCode: number = 0;
      let detail: string = '未知错误';
      if (subsonicError !== undefined && subsonicError !== null) {
        subsonicCode = subsonicError.code === undefined ? 0 : subsonicError.code;
        detail = pickText(subsonicError.message, '未知错误');
      }
      const code: string = mapSubsonicErrorCode(subsonicCode);
      Logger.warn(TAG, `${endpoint} 返回 Subsonic 错误 ${subsonicCode}`);
      throw new ProviderError(
        ProviderId.NAVIDROME,
        code,
        `Navidrome 返回错误（${endpoint}，code=${subsonicCode}）：${detail}`,
        false
      );
    }
    return parsed;
  }

  // -------------------------------------------------------------------------
  // 归一化
  // -------------------------------------------------------------------------

  private toSearchSong(song: SubsonicSong): SearchSongItem {
    const id: string = pickText(song.id, '');
    const artist: string = pickText(song.artist, '未知艺术家');
    const item: SearchSongItem = {
      id: id,
      title: pickText(song.title, '未知曲目'),
      artist: artist,
      album: pickText(song.album, ''),
      duration: secondsToMs(song.duration)
    };
    const coverId: string | undefined = song.coverArt;
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      item.coverUrl = this.buildCoverUrl(coverId);
    }
    const albumId: string | undefined = song.parent;
    if (albumId !== undefined && albumId !== null && albumId.length > 0) {
      item.albumId = albumId;
    }
    return item;
  }

  private toSearchAlbum(album: SubsonicAlbum): SearchAlbumItem {
    const item: SearchAlbumItem = {
      id: pickText(album.id, ''),
      name: pickText(album.name, '未知专辑'),
      artist: pickText(album.artist, '未知艺术家')
    };
    const coverId: string | undefined = album.coverArt;
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      item.coverUrl = this.buildCoverUrl(coverId);
    }
    const songCount: number | undefined = album.songCount;
    if (songCount !== undefined && songCount !== null) {
      item.songCount = songCount;
    }
    return item;
  }

  private toSearchArtist(artist: SubsonicArtist): SearchArtistItem {
    const item: SearchArtistItem = {
      id: pickText(artist.id, ''),
      name: pickText(artist.name, '未知歌手')
    };
    const coverId: string | undefined = artist.coverArt;
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      item.coverUrl = this.buildCoverUrl(coverId);
    }
    const albumCount: number | undefined = artist.albumCount;
    if (albumCount !== undefined && albumCount !== null) {
      item.albumCount = albumCount;
    }
    return item;
  }

  /** Subsonic song → Track（duration 秒转毫秒） */
  private toTrack(song: SubsonicSong, fallbackSongId: string): Track {
    const songId: string = pickText(song.id, fallbackSongId);
    const artist: string = pickText(song.artist, '未知艺术家');
    const artists: string[] = [artist];
    const track: Track = {
      id: makeTrackId(ProviderId.NAVIDROME, songId),
      title: pickText(song.title, '未知曲目'),
      artist: artist,
      artists: artists,
      album: pickText(song.album, ''),
      duration: secondsToMs(song.duration),
      origin: originOf(ProviderId.NAVIDROME),
      providerId: ProviderId.NAVIDROME,
      songId: songId
    };
    const albumId: string | undefined = song.parent;
    if (albumId !== undefined && albumId !== null && albumId.length > 0) {
      track.albumId = albumId;
    }
    const coverId: string | undefined = song.coverArt;
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      const coverUrl: string = this.buildCoverUrl(coverId);
      if (coverUrl.length > 0) {
        track.cover = { url: coverUrl };
      }
    }
    return track;
  }

  // -------------------------------------------------------------------------
  // 能力：连通性 / 搜索
  // -------------------------------------------------------------------------

  async ping(): Promise<string> {
    const response: SubsonicResponse = await this.requestSubsonic('ping', [], randomHex(8));
    const version: string = pickText(response.version, '未知');
    const serverVersion: string = pickText(response.serverVersion, '');
    const openSubsonic: boolean = response.openSubsonic === true;
    return `Navidrome 可用（Subsonic ${version}${serverVersion.length > 0 ? `，服务端 ${serverVersion}` : ''}${openSubsonic ? '，OpenSubsonic' : ''}）`;
  }

  /** search3 优先，服务器不支持时回落 search2（两者响应结构一致，只是 key 不同） */
  private async searchRaw(extra: HttpParam[]): Promise<SubsonicSearchResult> {
    if (!this.search3Unsupported) {
      try {
        const response: SubsonicResponse = await this.requestSubsonic('search3', extra, randomHex(8));
        const result: SubsonicSearchResult | null | undefined = response.searchResult3;
        return result === undefined || result === null ? EMPTY_SEARCH_RESULT : result;
      } catch (error) {
        // 老服务器 / 关闭 OpenSubsonic 的服务器没有 search3：标记后回落 search2
        Logger.warn(TAG, 'search3 不可用，回落 search2');
        this.search3Unsupported = true;
      }
    }
    const fallback: SubsonicResponse = await this.requestSubsonic('search2', extra, randomHex(8));
    const result: SubsonicSearchResult | null | undefined = fallback.searchResult2;
    return result === undefined || result === null ? EMPTY_SEARCH_RESULT : result;
  }

  /** 构造 search3/search2 的查询参数（两个端点参数名完全一致） */
  private searchParams(keyword: string, page: number, pageSize: number): HttpParam[] {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const offset: number = pageOffset(safePage, safeSize);
    const params: HttpParam[] = [];
    addParam(params, 'query', keyword);
    addParam(params, 'artistCount', String(safeSize));
    addParam(params, 'artistOffset', String(offset));
    addParam(params, 'albumCount', String(safeSize));
    addParam(params, 'albumOffset', String(offset));
    addParam(params, 'songCount', String(safeSize));
    addParam(params, 'songOffset', String(offset));
    return params;
  }

  async search(keyword: string, page: number, pageSize: number): Promise<SearchResult> {
    const raw: SubsonicSearchResult = await this.searchRaw(this.searchParams(keyword, page, pageSize));
    const songs: SearchSongItem[] = [];
    const albums: SearchAlbumItem[] = [];
    const artists: SearchArtistItem[] = [];

    const rawSongs: SubsonicSong[] | null | undefined = raw.song;
    if (rawSongs !== undefined && rawSongs !== null) {
      for (let index = 0; index < rawSongs.length; index++) {
        songs.push(this.toSearchSong(rawSongs[index]));
      }
    }
    const rawAlbums: SubsonicAlbum[] | null | undefined = raw.album;
    if (rawAlbums !== undefined && rawAlbums !== null) {
      for (let index = 0; index < rawAlbums.length; index++) {
        albums.push(this.toSearchAlbum(rawAlbums[index]));
      }
    }
    const rawArtists: SubsonicArtist[] | null | undefined = raw.artist;
    if (rawArtists !== undefined && rawArtists !== null) {
      for (let index = 0; index < rawArtists.length; index++) {
        artists.push(this.toSearchArtist(rawArtists[index]));
      }
    }
    const result: SearchResult = { songs: songs, albums: albums, artists: artists };
    return result;
  }

  async searchAlbums(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchAlbumItem>> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    // 复用 search3（Subsonic 没有单独的专辑搜索端点）：这里故意保留默认的 songCount，
    // 只取 album 部分，避免因为传 0 被某些服务端判成非法参数
    const params: HttpParam[] = [];
    addParam(params, 'query', keyword);
    addParam(params, 'artistCount', '0');
    addParam(params, 'albumCount', String(safeSize));
    addParam(params, 'albumOffset', String(pageOffset(safePage, safeSize)));
    addParam(params, 'songCount', String(DEFAULT_SEARCH_COUNT));
    addParam(params, 'songOffset', '0');
    const raw: SubsonicSearchResult = await this.searchRaw(params);
    const albums: SearchAlbumItem[] = [];
    const rawAlbums: SubsonicAlbum[] | null | undefined = raw.album;
    if (rawAlbums !== undefined && rawAlbums !== null) {
      for (let index = 0; index < rawAlbums.length; index++) {
        albums.push(this.toSearchAlbum(rawAlbums[index]));
      }
    }
    return buildPage(albums, safePage, safeSize, -1);
  }

  async searchArtists(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchArtistItem>> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const params: HttpParam[] = [];
    addParam(params, 'query', keyword);
    addParam(params, 'artistCount', String(safeSize));
    addParam(params, 'artistOffset', String(pageOffset(safePage, safeSize)));
    addParam(params, 'albumCount', '0');
    addParam(params, 'songCount', String(DEFAULT_SEARCH_COUNT));
    addParam(params, 'songOffset', '0');
    const raw: SubsonicSearchResult = await this.searchRaw(params);
    const artists: SearchArtistItem[] = [];
    const rawArtists: SubsonicArtist[] | null | undefined = raw.artist;
    if (rawArtists !== undefined && rawArtists !== null) {
      for (let index = 0; index < rawArtists.length; index++) {
        artists.push(this.toSearchArtist(rawArtists[index]));
      }
    }
    return buildPage(artists, safePage, safeSize, -1);
  }

  // -------------------------------------------------------------------------
  // 能力：专辑 / 歌手 / 歌单 / 单曲详情
  // -------------------------------------------------------------------------

  async fetchAlbum(albumId: string): Promise<ProviderAlbumDetail | null> {
    const params: HttpParam[] = [];
    addParam(params, 'id', albumId);
    const response: SubsonicResponse = await this.requestSubsonic('getAlbum', params, randomHex(8));
    const album: SubsonicAlbum | null | undefined = response.album;
    if (album === undefined || album === null) {
      return null;
    }
    const songs: SearchSongItem[] = [];
    const rawSongs: SubsonicSong[] | null | undefined = album.song;
    if (rawSongs !== undefined && rawSongs !== null) {
      for (let index = 0; index < rawSongs.length; index++) {
        songs.push(this.toSearchSong(rawSongs[index]));
      }
    }
    const coverId: string | undefined = album.coverArt;
    const detail: ProviderAlbumDetail = {
      id: pickText(album.id, albumId),
      name: pickText(album.name, '未知专辑'),
      artist: pickText(album.artist, '未知艺术家'),
      songCount: album.songCount === undefined || album.songCount === null ? songs.length : album.songCount,
      songs: songs
    };
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      detail.coverUrl = this.buildCoverUrl(coverId);
    }
    return detail;
  }

  async fetchArtist(artistId: string): Promise<ProviderArtistDetail | null> {
    const params: HttpParam[] = [];
    addParam(params, 'id', artistId);
    const response: SubsonicResponse = await this.requestSubsonic('getArtist', params, randomHex(8));
    const artist: SubsonicArtist | null | undefined = response.artist;
    if (artist === undefined || artist === null) {
      return null;
    }
    const albums: SearchAlbumItem[] = [];
    const rawAlbums: SubsonicAlbum[] | null | undefined = artist.album;
    if (rawAlbums !== undefined && rawAlbums !== null) {
      for (let index = 0; index < rawAlbums.length; index++) {
        albums.push(this.toSearchAlbum(rawAlbums[index]));
      }
    }
    const coverId: string | undefined = artist.coverArt;
    const detail: ProviderArtistDetail = {
      id: pickText(artist.id, artistId),
      name: pickText(artist.name, '未知歌手'),
      albumCount: artist.albumCount === undefined || artist.albumCount === null ? albums.length : artist.albumCount,
      albums: albums
    };
    if (coverId !== undefined && coverId !== null && coverId.length > 0) {
      detail.coverUrl = this.buildCoverUrl(coverId);
    }
    return detail;
  }

  async getPlaylists(): Promise<ProviderPlaylistSummary[]> {
    const response: SubsonicResponse = await this.requestSubsonic('getPlaylists', [], randomHex(8));
    const playlists: ProviderPlaylistSummary[] = [];
    const container: SubsonicPlaylists | null | undefined = response.playlists;
    if (container === undefined || container === null) {
      return playlists;
    }
    const rawList: SubsonicPlaylist[] | null | undefined = container.playlist;
    if (rawList === undefined || rawList === null) {
      return playlists;
    }
    for (let index = 0; index < rawList.length; index++) {
      const raw: SubsonicPlaylist = rawList[index];
      const summary: ProviderPlaylistSummary = {
        id: pickText(raw.id, ''),
        name: pickText(raw.name, '未命名歌单'),
        songCount: raw.songCount === undefined || raw.songCount === null ? 0 : raw.songCount
      };
      const coverId: string | undefined = raw.coverArt;
      if (coverId !== undefined && coverId !== null && coverId.length > 0) {
        summary.coverUrl = this.buildCoverUrl(coverId);
      }
      const owner: string | undefined = raw.owner;
      if (owner !== undefined && owner !== null && owner.length > 0) {
        summary.owner = owner;
      }
      playlists.push(summary);
    }
    return playlists;
  }

  async fetchSongDetail(songId: string): Promise<Track | null> {
    const params: HttpParam[] = [];
    addParam(params, 'id', songId);
    const response: SubsonicResponse = await this.requestSubsonic('getSong', params, randomHex(8));
    const song: SubsonicSong | null | undefined = response.song;
    if (song === undefined || song === null) {
      return null;
    }
    return this.toTrack(song, songId);
  }

  // -------------------------------------------------------------------------
  // 能力：音频直链 / 封面
  // -------------------------------------------------------------------------

  /**
   * Subsonic stream URL：认证参数内联，**永不过期**（salt 稳定缓存），
   * 播放器直接加载即可，不需要 Referer / User-Agent / Cookie。
   */
  async resolveAudioSource(songId: string, quality: string): Promise<ProviderAudioSource> {
    const config: NavidromeSettings = this.requireConfig();
    // Subsonic 的 format 是转码格式（mp3/opus…），不是音质档位；上游只在显式指定 format 时才带该参数，
    // 因此这里不把 quality 映射进 URL，只在返回值里回显，供上层展示。
    const salt: string = this.stableSalt(`stream:${songId}:`);
    const params: HttpParam[] = [];
    mergeParams(params, this.buildAuthParams(salt, config));
    addParam(params, 'id', songId);
    const url: string = appendQuery(`${this.baseUrlOf(config)}/rest/stream`, buildQueryString(params));
    Logger.info(TAG, `解析到音频直链 songId=${songId}`);
    const source: ProviderAudioSource = {
      url: url,
      quality: quality.length === 0 ? 'original' : quality,
      // 0 = 不过期：Subsonic 的 stream URL 认证参数是长期有效的
      expiresAt: 0
    };
    return source;
  }

  /**
   * 封面地址（同步方法）。
   * 未配置或 coverId 为空时返回空串，调用方据此决定是否展示占位图。
   */
  buildCoverUrl(coverId: string, size?: number): string {
    if (coverId.length === 0 || !this.isConfigured()) {
      return '';
    }
    const config: NavidromeSettings = this.config();
    const sizeValue: number = size === undefined ? DEFAULT_COVER_SIZE : size;
    const salt: string = this.stableSalt(`cover:${coverId}:${sizeValue}`);
    const params: HttpParam[] = [];
    mergeParams(params, this.buildAuthParams(salt, config));
    addParam(params, 'id', coverId);
    if (sizeValue > 0) {
      addParam(params, 'size', String(sizeValue));
    }
    return appendQuery(`${this.baseUrlOf(config)}/rest/getCoverArt`, buildQueryString(params));
  }

  // -------------------------------------------------------------------------
  // 能力：歌词
  // -------------------------------------------------------------------------

  /** OpenSubsonic 结构化歌词 → LRC 文本；没有逐行时间时退化成纯文本行 */
  private structuredToLrc(structured: SubsonicStructuredLyric): LrcConversion {
    const lines: SubsonicLyricLine[] | null | undefined = structured.line;
    if (lines === undefined || lines === null) {
      return EMPTY_LRC;
    }
    const out: string[] = [];
    let hasTiming: boolean = false;
    for (let index = 0; index < lines.length; index++) {
      const line: SubsonicLyricLine = lines[index];
      const text: string = pickText(line.value, '');
      const start: number | undefined = line.start;
      if (start !== undefined && start !== null && start >= 0) {
        out.push(`[${formatLrcTime(start)}]${text}`);
        hasTiming = true;
      } else {
        out.push(text);
      }
    }
    const conversion: LrcConversion = { text: out.join('\n'), hasTiming: hasTiming };
    return conversion;
  }

  /** 走 getLyricsBySongId（OpenSubsonic）；任何失败都返回空结果，交给调用方回落 */
  private async fetchStructuredLyricText(songId: string): Promise<LrcConversion> {
    const params: HttpParam[] = [];
    addParam(params, 'id', songId);
    addParam(params, 'enhanced', 'true');
    try {
      const response: SubsonicResponse = await this.requestSubsonic('getLyricsBySongId', params, randomHex(8));
      const list: SubsonicLyricsList | null | undefined = response.lyricsList;
      if (list === undefined || list === null) {
        return EMPTY_LRC;
      }
      const structuredList: SubsonicStructuredLyric[] | null | undefined = list.structuredLyrics;
      if (structuredList === undefined || structuredList === null || structuredList.length === 0) {
        return EMPTY_LRC;
      }
      // 优先取带时间轴的版本，其次取第一条
      let chosen: SubsonicStructuredLyric = structuredList[0];
      for (let index = 0; index < structuredList.length; index++) {
        if (structuredList[index].synced === true) {
          chosen = structuredList[index];
          break;
        }
      }
      return this.structuredToLrc(chosen);
    } catch (error) {
      // 服务器不支持 OpenSubsonic 扩展是常态，这里只记日志不抛错
      Logger.warn(TAG, 'getLyricsBySongId 不可用，将回落 getLyrics');
      return EMPTY_LRC;
    }
  }

  /** 经典 getLyrics（按 artist + title），返回纯文本 LRC */
  private async fetchPlainLyricText(artist: string, title: string): Promise<string> {
    const params: HttpParam[] = [];
    addParam(params, 'artist', artist);
    addParam(params, 'title', title);
    try {
      const response: SubsonicResponse = await this.requestSubsonic('getLyrics', params, randomHex(8));
      const lyrics: SubsonicLyrics | null | undefined = response.lyrics;
      if (lyrics === undefined || lyrics === null) {
        return '';
      }
      return pickText(lyrics.value, '');
    } catch (error) {
      Logger.warn(TAG, 'getLyrics 失败，返回空歌词');
      return '';
    }
  }

  /** 按 id 取 song，失败返回 undefined（歌词回落链路用） */
  private async fetchSongOrUndefined(songId: string): Promise<SubsonicSong | undefined> {
    try {
      const params: HttpParam[] = [];
      addParam(params, 'id', songId);
      const response: SubsonicResponse = await this.requestSubsonic('getSong', params, randomHex(8));
      const song: SubsonicSong | null | undefined = response.song;
      return song === undefined || song === null ? undefined : song;
    } catch (error) {
      Logger.warn(TAG, 'getSong 失败，无法走 getLyrics 回落');
      return undefined;
    }
  }

  /**
   * 歌词主入口。
   * 顺序：getLyricsBySongId（结构化）→ getSong + getLyrics（纯文本）→ 空歌词。
   * Subsonic 没有「纯音乐」标记，因此取不到歌词时 lyric 为空串、pureMusic 保持 false，
   * 由上层决定 UI 文案（不要谎报纯音乐）。
   */
  async fetchLyric(songId: string): Promise<LyricPayload> {
    this.requireConfig();

    const structured: LrcConversion = await this.fetchStructuredLyricText(songId);
    if (structured.text.length > 0) {
      const payload: LyricPayload = {
        lyric: structured.text,
        pureMusic: false,
        source: 'navidrome:structured',
        // 生成物恒为 LRC 语法；没有时间轴时交给自动检测
        format: structured.hasTiming ? LyricFormat.LRC : LyricFormat.NONE
      };
      return payload;
    }

    const song: SubsonicSong | undefined = await this.fetchSongOrUndefined(songId);
    if (song !== undefined) {
      const artist: string = pickText(song.artist, '');
      const title: string = pickText(song.title, '');
      if (artist.length > 0 && title.length > 0) {
        const plain: string = await this.fetchPlainLyricText(artist, title);
        if (plain.length > 0) {
          const payload: LyricPayload = {
            lyric: plain,
            pureMusic: false,
            source: 'navidrome:getLyrics',
            // Subsonic 的 getLyrics 返回的是服务端给的原文，格式交给自动检测
            format: LyricFormat.NONE
          };
          return payload;
        }
      }
    }

    const empty: LyricPayload = {
      lyric: '',
      pureMusic: false,
      source: 'navidrome',
      format: LyricFormat.NONE
    };
    return empty;
  }
}
