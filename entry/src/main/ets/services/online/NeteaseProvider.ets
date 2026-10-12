/**
 * Folia HarmonyOS - 网易云 (netease) provider —— 自建服务端 HTTP 客户端
 *
 * 移植规范 §3.1.1 的结论：上游渲染进程里**没有任何** AES/RSA/MD5 实现，
 * 它只对主进程内嵌的 `@neteasecloudmusicapienhanced/api` 服务发普通 GET。
 * weapi / eapi / linuxapi / xeapi 的全部 crypto 常量都不在上游仓库里
 * （§3.1.5、附录 B 第 1、2 项，标注为「未在源码中找到，需要抓包确认」），
 * 因此本文件**不做任何端侧加密**，只做「可配置 base URL 的 HTTP 客户端」：
 * 指向用户自建/自托管的 NeteaseCloudMusicApi（等价于上游的 VITE_NETEASE_API_BASE）。
 *
 * 逐字对齐的协议事实：
 *   1. Cookie **通过 URL query 参数 `cookie=` 传递**（会被 URL 编码），不是 `Cookie:` 请求头（§3.1.4）
 *   2. **不看 HTTP 状态码，只看 body 的 `code`**（§3.1.4 注释）
 *   3. `/song/url/v1` 必须带 `randomCNIP=true&https=true`（§3.1.3）
 *   4. quality → level 映射：standard→standard、high→exhigh、lossless/hires 原样（§3.1.3）
 *   5. 无登录态时自动注册匿名 cookie（`/register/anonimous`，响应 cookie 必须含 MUSIC_A）
 *
 * ⚠️ 端点差异说明：
 *    移植规范 §3.1.3 的端点表里搜索是 `/cloudsearch`、歌词是 `/lyric/new`；
 *    本次任务书要求搜索 `/search/get`、歌词 `/lyric`。两者在本项目里都保留：
 *    以规范为准先请求 `/cloudsearch` / `/lyric/new`，失败后单次回落到 `/search/get` / `/lyric`。
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
  HttpMethod,
  HttpParam,
  HttpRequestSpec,
  HttpResponse,
  HttpTransport,
  mergeParams,
  toProviderError,
  trimTrailingSlash
} from './HttpTransport';
import { NeteaseSettings, onlineSettings } from './OnlineSettings';
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

const TAG: string = 'NeteaseProvider';

/** 搜索主/备端点（规范 vs 任务书） */
const ENDPOINT_SEARCH: string = '/cloudsearch';
const ENDPOINT_SEARCH_FALLBACK: string = '/search/get';
/** 歌词主/备端点 */
const ENDPOINT_LYRIC: string = '/lyric/new';
const ENDPOINT_LYRIC_FALLBACK: string = '/lyric';

/**
 * ⚠️ 未确认：网易云直链带签名会过期（§3.1.8「URL 带签名，会过期」），
 * 但上游源码与本规范都没有给出具体有效期，附录 B 也未收录该项。
 * 这里不臆造精确值，只取一个保守下限（30 分钟）并在注释中标明；
 * 真正失效时由播放层重新解析，而不是靠这个时间戳。
 */
const NETEASE_URL_TTL_MS: number = 30 * 60 * 1000;

// ---------------------------------------------------------------------------
// 响应结构（字段全部可选，逐层判空后才使用）
// ---------------------------------------------------------------------------

interface NeteaseArtist {
  id?: number;
  name?: string;
  picUrl?: string;
  albumSize?: number;
}

interface NeteaseAlbum {
  id?: number;
  name?: string;
  picUrl?: string;
  size?: number;
  artist?: NeteaseArtist | null;
  artists?: NeteaseArtist[] | null;
}

interface NeteasePrivilege {
  id?: number;
  fee?: number;
  st?: number;
  pl?: number;
  dl?: number;
}

interface NeteaseSong {
  id?: number;
  name?: string;
  /** 新接口（/cloudsearch、/song/detail）用 ar */
  ar?: NeteaseArtist[] | null;
  /** 旧接口（/search/get）用 artists */
  artists?: NeteaseArtist[] | null;
  /** 新接口用 al */
  al?: NeteaseAlbum | null;
  /** 旧接口用 album */
  album?: NeteaseAlbum | null;
  /** 新接口时长，毫秒 */
  dt?: number;
  /** 旧接口时长，毫秒 */
  duration?: number;
  alia?: string[] | null;
  tns?: string[] | null;
  fee?: number;
  privilege?: NeteasePrivilege | null;
}

interface NeteaseSearchResult {
  songs?: NeteaseSong[] | null;
  songCount?: number;
  albums?: NeteaseAlbum[] | null;
  artists?: NeteaseArtist[] | null;
}

interface NeteaseSearchResponse {
  result?: NeteaseSearchResult | null;
  code?: number;
  message?: string;
  msg?: string;
}

interface NeteaseSongUrlEntry {
  id?: number;
  url?: string | null;
  br?: number;
  size?: number;
  md5?: string;
  code?: number;
  type?: string;
  level?: string;
  encodeType?: string;
  time?: number;
  fee?: number;
}

interface NeteaseSongUrlResponse {
  data?: NeteaseSongUrlEntry[] | null;
  code?: number;
  message?: string;
}

interface NeteaseSongDetailResponse {
  songs?: NeteaseSong[] | null;
  privileges?: NeteasePrivilege[] | null;
  code?: number;
  message?: string;
}

/**
 * 歌词块。
 * 上游兼容读取路径（§3.1.6）：`source.lrc.yrc.lyric` / `source.lrc.ytlrc.lyric` /
 * `source.lrc.yromalrc.lyric` / `source.lrc.romalrc.lyric`，因此这里把嵌套块也声明出来。
 */
interface NeteaseLyricBlock {
  version?: number;
  lyric?: string;
  yrc?: NeteaseLyricBlock | null;
  ytlrc?: NeteaseLyricBlock | null;
  yromalrc?: NeteaseLyricBlock | null;
  romalrc?: NeteaseLyricBlock | null;
  tlyric?: NeteaseLyricBlock | null;
}

interface NeteaseLyricResponse {
  lrc?: NeteaseLyricBlock | null;
  yrc?: NeteaseLyricBlock | null;
  ytlrc?: NeteaseLyricBlock | null;
  yromalrc?: NeteaseLyricBlock | null;
  tlyric?: NeteaseLyricBlock | null;
  romalrc?: NeteaseLyricBlock | null;
  pureMusic?: boolean;
  code?: number;
  message?: string;
}

interface NeteaseAlbumDetailResponse {
  album?: NeteaseAlbum | null;
  songs?: NeteaseSong[] | null;
  code?: number;
  message?: string;
}

interface NeteaseAnonymousResponse {
  cookie?: string;
  code?: number;
  message?: string;
}

interface NeteaseLoginStatusResponse {
  data?: NeteaseLoginStatusData | null;
  code?: number;
  message?: string;
}

interface NeteaseLoginStatusData {
  code?: number;
  account?: NeteaseLoginAccount | null;
  profile?: NeteaseLoginProfile | null;
}

interface NeteaseLoginAccount {
  id?: number;
  status?: number;
}

interface NeteaseLoginProfile {
  userId?: number;
  nickname?: string;
}

// ---------------------------------------------------------------------------
// 纯函数工具
// ---------------------------------------------------------------------------

/** 取第一个非空文本 */
function firstText(a: string | undefined | null, b: string | undefined | null): string {
  if (a !== undefined && a !== null && a.length > 0) {
    return a;
  }
  if (b !== undefined && b !== null && b.length > 0) {
    return b;
  }
  return '';
}

/** 取第一个非零数字 */
function firstNumber(a: number | undefined | null, b: number | undefined | null): number {
  if (a !== undefined && a !== null) {
    return a;
  }
  if (b !== undefined && b !== null) {
    return b;
  }
  return 0;
}

/** 数字 id → 文本 */
function idText(value: number | undefined | null): string {
  if (value === undefined || value === null) {
    return '';
  }
  return `${value}`;
}

/** 歌词块 → 文本 */
function lyricText(block: NeteaseLyricBlock | null | undefined): string {
  if (block === undefined || block === null) {
    return '';
  }
  return block.lyric === undefined || block.lyric === null ? '' : block.lyric;
}

/** 取 `lrc` 嵌套的逐字块（上游兼容路径） */
function nestedYrc(outer: NeteaseLyricBlock | null | undefined): string {
  if (outer === undefined || outer === null) {
    return '';
  }
  return lyricText(outer.yrc);
}

/** 取 `lrc` 嵌套的逐字翻译块 */
function nestedYtlrc(outer: NeteaseLyricBlock | null | undefined): string {
  if (outer === undefined || outer === null) {
    return '';
  }
  return lyricText(outer.ytlrc);
}

/** 取 `lrc` 嵌套的逐字罗马音块 */
function nestedYromalrc(outer: NeteaseLyricBlock | null | undefined): string {
  if (outer === undefined || outer === null) {
    return '';
  }
  return lyricText(outer.yromalrc);
}

/** 取 `lrc` 嵌套的罗马音块 */
function nestedRomalrc(outer: NeteaseLyricBlock | null | undefined): string {
  if (outer === undefined || outer === null) {
    return '';
  }
  return lyricText(outer.romalrc);
}

/**
 * 纯音乐判定。
 * ⚠️ 上游的 isPureMusicLyricText 在 src/utils/lyrics 下，本工程未移植其常量表；
 * 这里只做保守判定：去掉时间标签后为空、或只剩「纯音乐，请欣赏」这类占位文案。
 * 空文本**不算**纯音乐（那更可能是「没取到歌词」）。
 */
function isPureMusicText(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  const cleaned: string = text.replace(/\[\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?\]/g, '').trim();
  if (cleaned.length === 0) {
    return true;
  }
  return cleaned.indexOf('纯音乐') >= 0 && cleaned.length <= 24;
}

/** quality → 网易云 level（§3.1.3 逐字） */
function mapQualityToLevel(quality: string): string {
  if (quality === 'standard') {
    return 'standard';
  }
  if (quality === 'high') {
    return 'exhigh';
  }
  if (quality === 'lossless' || quality === 'hires') {
    return quality;
  }
  // 已经是网易云原生 level（exhigh / lossless / hires / jymaster…）时原样透传
  return quality;
}

/** 网易云 provider */
export class NeteaseProvider implements OnlineProviderEx {
  readonly id: ProviderId = ProviderId.NETEASE;
  readonly displayName: string = '网易云音乐';
  readonly capabilities: ProviderCapabilities = {
    search: true,
    songUrl: true,
    lyric: true,
    album: true,
    artist: true,
    playlist: false,
    login: false,
    favorite: false
  };

  /** 保留 context 供后续接入安全存储使用 */
  private context: common.UIAbilityContext;
  /** `/cloudsearch` 不可用时置位，后续直接走 `/search/get` */
  private searchFallbackEngaged: boolean = false;
  /** `/lyric/new` 不可用时置位，后续直接走 `/lyric` */
  private lyricFallbackEngaged: boolean = false;
  /** 匿名 cookie 只尝试注册一次 */
  private anonymousCookieAttempted: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // -------------------------------------------------------------------------
  // 配置（全部惰性读取，设置改完立即生效，不需要重启）
  // -------------------------------------------------------------------------

  private config(): NeteaseSettings {
    return onlineSettings.getNetease();
  }

  isConfigured(): boolean {
    return this.config().baseUrl.length > 0;
  }

  private requireBaseUrl(): string {
    const baseUrl: string = this.config().baseUrl;
    if (baseUrl.length === 0) {
      throw new ProviderError(
        ProviderId.NETEASE,
        ProviderCodes.NOT_CONFIGURED,
        '尚未配置网易云音乐：请先在设置里填写自建 NeteaseCloudMusicApi 的服务地址' +
          '（端侧不实现 weapi/eapi 加密，必须依赖服务端）',
        false
      );
    }
    return trimTrailingSlash(baseUrl);
  }

  // -------------------------------------------------------------------------
  // 传输层
  // -------------------------------------------------------------------------

  /** 上游对 /login、/user、/playlist/detail 追加时间戳防缓存（§3.1.3） */
  private needsTimestamp(endpoint: string): boolean {
    return endpoint.startsWith('/login') || endpoint.startsWith('/user') || endpoint.indexOf('/playlist/detail') >= 0;
  }

  /**
   * 无登录态时注册匿名 cookie。
   * 上游要求响应的 cookie 里必须含 `MUSIC_A`（§3.1.5 第 3 点），否则视为注册失败。
   * 失败不致命：后续请求以无 cookie 发出，由服务端自行决定。
   */
  private async registerAnonymousCookie(): Promise<string> {
    try {
      const params: HttpParam[] = [];
      addParam(params, 'timestamp', String(Date.now()));
      const response: HttpResponse = await HttpTransport.get(`${this.requireBaseUrl()}/register/anonimous`, params);
      const parsed: NeteaseAnonymousResponse = JSON.parse(response.body) as NeteaseAnonymousResponse;
      const cookie: string = parsed.cookie === undefined || parsed.cookie === null ? '' : parsed.cookie;
      if (cookie.length === 0) {
        Logger.warn(TAG, '匿名注册未返回 cookie');
        return '';
      }
      if (cookie.indexOf('MUSIC_A=') < 0) {
        Logger.warn(TAG, '匿名注册 cookie 缺少 MUSIC_A，已忽略');
        return '';
      }
      Logger.info(TAG, '已获取匿名 cookie');
      return cookie;
    } catch (error) {
      Logger.warn(TAG, '匿名注册失败，继续以无 cookie 请求');
      return '';
    }
  }

  /** 解析本次请求要用的 cookie（登录 cookie 优先，其次匿名 cookie） */
  private async resolveCookie(allowAnonymous: boolean): Promise<string> {
    const settings: NeteaseSettings = this.config();
    if (settings.cookie.length > 0) {
      return settings.cookie;
    }
    if (!allowAnonymous) {
      return '';
    }
    if (settings.anonymousCookie.length > 0) {
      return settings.anonymousCookie;
    }
    if (this.anonymousCookieAttempted) {
      return '';
    }
    this.anonymousCookieAttempted = true;
    const cookie: string = await this.registerAnonymousCookie();
    if (cookie.length > 0) {
      onlineSettings.setNeteaseAnonymousCookie(cookie);
    }
    return cookie;
  }

  /**
   * 发一次请求，返回原始 body 文本。
   * 三点必须遵守：cookie 走 query 参数、忽略 HTTP 状态码、日志不带完整 URL。
   */
  private async requestRaw(endpoint: string, params: HttpParam[], allowAnonymous: boolean): Promise<string> {
    const baseUrl: string = this.requireBaseUrl();
    const query: HttpParam[] = [];
    mergeParams(query, params);
    if (this.needsTimestamp(endpoint)) {
      addParam(query, 'timestamp', String(Date.now()));
    }
    const cookie: string = await this.resolveCookie(allowAnonymous);
    if (cookie.length > 0) {
      addParam(query, 'cookie', cookie);
    }

    let response: HttpResponse;
    try {
      const spec: HttpRequestSpec = {
        url: `${baseUrl}${endpoint}`,
        method: HttpMethod.GET,
        params: query,
        // 网易云本地 API 的 HTTP 状态码无意义（§3.1.4），必须允许非 200 也能拿到 body
        allowNonOk: true
      };
      response = await HttpTransport.request(spec);
    } catch (error) {
      Logger.err(TAG, `request ${endpoint}`, error as Error);
      throw toProviderError(ProviderId.NETEASE, `请求网易云接口 ${endpoint}`, error as Error);
    }

    if (response.status !== 200) {
      Logger.warn(TAG, `${endpoint} 返回 HTTP ${response.status}，改按 body 的 code 判断`);
    }
    if (response.body.length === 0) {
      throw new ProviderError(
        ProviderId.NETEASE,
        ProviderCodes.INVALID_RESPONSE,
        `网易云接口 ${endpoint} 返回空响应（HTTP ${response.status}）`,
        true
      );
    }
    return response.body;
  }

  /** body 业务码校验（只看 code，不看 HTTP 状态） */
  private checkCode(code: number, endpoint: string, message: string): void {
    if (code === 200) {
      return;
    }
    let mapped: string = ProviderCodes.INVALID_RESPONSE;
    let retryable: boolean = false;
    if (code === 301 || code === 401 || code === 403) {
      mapped = ProviderCodes.AUTH_REQUIRED;
      // 匿名 cookie 被拒：清掉缓存，下次重新注册（§3.1.4）
      if (this.config().cookie.length === 0) {
        onlineSettings.setNeteaseAnonymousCookie('');
        this.anonymousCookieAttempted = false;
      }
    } else if (code === 404) {
      mapped = ProviderCodes.NOT_FOUND;
    } else if (code >= 500) {
      mapped = ProviderCodes.NETWORK;
      retryable = true;
    }
    const detail: string = message.length > 0 ? `：${message}` : '';
    throw new ProviderError(
      ProviderId.NETEASE,
      mapped,
      `网易云接口 ${endpoint} 返回 code=${code}${detail}`,
      retryable
    );
  }

  // -------------------------------------------------------------------------
  // 解析（每个响应类型一个具体函数，避免泛型 as 转换）
  // -------------------------------------------------------------------------

  private parseSearchResponse(body: string): NeteaseSearchResponse | undefined {
    try {
      return JSON.parse(body) as NeteaseSearchResponse;
    } catch (error) {
      Logger.err(TAG, 'parse search response', error as Error);
      return undefined;
    }
  }

  private parseSongUrlResponse(body: string): NeteaseSongUrlResponse | undefined {
    try {
      return JSON.parse(body) as NeteaseSongUrlResponse;
    } catch (error) {
      Logger.err(TAG, 'parse song/url response', error as Error);
      return undefined;
    }
  }

  private parseSongDetailResponse(body: string): NeteaseSongDetailResponse | undefined {
    try {
      return JSON.parse(body) as NeteaseSongDetailResponse;
    } catch (error) {
      Logger.err(TAG, 'parse song/detail response', error as Error);
      return undefined;
    }
  }

  private parseLyricResponse(body: string): NeteaseLyricResponse | undefined {
    try {
      return JSON.parse(body) as NeteaseLyricResponse;
    } catch (error) {
      Logger.err(TAG, 'parse lyric response', error as Error);
      return undefined;
    }
  }

  private parseAlbumDetailResponse(body: string): NeteaseAlbumDetailResponse | undefined {
    try {
      return JSON.parse(body) as NeteaseAlbumDetailResponse;
    } catch (error) {
      Logger.err(TAG, 'parse album response', error as Error);
      return undefined;
    }
  }

  // -------------------------------------------------------------------------
  // 归一化
  // -------------------------------------------------------------------------

  /** 歌手名列表：新接口 ar，旧接口 artists */
  private artistNames(song: NeteaseSong): string[] {
    const names: string[] = [];
    const primary: NeteaseArtist[] | null | undefined = song.ar;
    if (primary !== undefined && primary !== null) {
      for (let index = 0; index < primary.length; index++) {
        const name: string | undefined = primary[index].name;
        if (name !== undefined && name !== null && name.length > 0) {
          names.push(name);
        }
      }
    }
    if (names.length === 0) {
      const legacy: NeteaseArtist[] | null | undefined = song.artists;
      if (legacy !== undefined && legacy !== null) {
        for (let index = 0; index < legacy.length; index++) {
          const name: string | undefined = legacy[index].name;
          if (name !== undefined && name !== null && name.length > 0) {
            names.push(name);
          }
        }
      }
    }
    return names;
  }

  /** 专辑：新接口 al，旧接口 album */
  private albumOf(song: NeteaseSong): NeteaseAlbum | undefined {
    const primary: NeteaseAlbum | null | undefined = song.al;
    if (primary !== undefined && primary !== null) {
      return primary;
    }
    const legacy: NeteaseAlbum | null | undefined = song.album;
    if (legacy !== undefined && legacy !== null) {
      return legacy;
    }
    return undefined;
  }

  /** 时长：新接口 dt，旧接口 duration（都是毫秒） */
  private durationOf(song: NeteaseSong): number {
    return firstNumber(song.dt, song.duration);
  }

  private toSearchSong(song: NeteaseSong): SearchSongItem {
    const artists: string[] = this.artistNames(song);
    const album: NeteaseAlbum | undefined = this.albumOf(song);
    const item: SearchSongItem = {
      id: idText(song.id),
      title: firstText(song.name, '未知曲目'),
      artist: artists.length > 0 ? artists.join(' / ') : '未知艺术家',
      album: album === undefined ? '' : firstText(album.name, ''),
      duration: this.durationOf(song)
    };
    if (album !== undefined) {
      const cover: string = firstText(album.picUrl, '');
      if (cover.length > 0) {
        item.coverUrl = cover;
      }
      const albumId: string = idText(album.id);
      if (albumId.length > 0) {
        item.albumId = albumId;
      }
    }
    return item;
  }

  private toSearchAlbum(album: NeteaseAlbum): SearchAlbumItem {
    const item: SearchAlbumItem = {
      id: idText(album.id),
      name: firstText(album.name, '未知专辑'),
      artist: '未知艺术家'
    };
    const cover: string = firstText(album.picUrl, '');
    if (cover.length > 0) {
      item.coverUrl = cover;
    }
    // 专辑搜索结果的 artist / artists 是歌手对象，而不是字符串
    const single: NeteaseArtist | null | undefined = album.artist;
    if (single !== undefined && single !== null) {
      const name: string = firstText(single.name, '');
      if (name.length > 0) {
        item.artist = name;
      }
    } else {
      const list: NeteaseArtist[] | null | undefined = album.artists;
      if (list !== undefined && list !== null && list.length > 0) {
        const name: string = firstText(list[0].name, '');
        if (name.length > 0) {
          item.artist = name;
        }
      }
    }
    if (album.size !== undefined && album.size !== null) {
      item.songCount = album.size;
    }
    return item;
  }

  private toSearchArtist(artist: NeteaseArtist): SearchArtistItem {
    const item: SearchArtistItem = {
      id: idText(artist.id),
      name: firstText(artist.name, '未知歌手')
    };
    const cover: string = firstText(artist.picUrl, '');
    if (cover.length > 0) {
      item.coverUrl = cover;
    }
    if (artist.albumSize !== undefined && artist.albumSize !== null) {
      item.albumCount = artist.albumSize;
    }
    return item;
  }

  private toTrack(song: NeteaseSong, fallbackSongId: string): Track {
    const songId: string = idText(song.id).length > 0 ? idText(song.id) : fallbackSongId;
    const artists: string[] = this.artistNames(song);
    const safeArtists: string[] = artists.length > 0 ? artists : ['未知艺术家'];
    const album: NeteaseAlbum | undefined = this.albumOf(song);
    const track: Track = {
      id: makeTrackId(ProviderId.NETEASE, songId),
      title: firstText(song.name, '未知曲目'),
      artist: safeArtists[0],
      artists: safeArtists,
      album: album === undefined ? '' : firstText(album.name, ''),
      duration: this.durationOf(song),
      origin: originOf(ProviderId.NETEASE),
      providerId: ProviderId.NETEASE,
      songId: songId
    };
    if (album !== undefined) {
      const albumId: string = idText(album.id);
      if (albumId.length > 0) {
        track.albumId = albumId;
      }
      const cover: string = firstText(album.picUrl, '');
      if (cover.length > 0) {
        track.cover = { url: cover };
      }
    }
    return track;
  }

  // -------------------------------------------------------------------------
  // 能力：连通性 / 搜索
  // -------------------------------------------------------------------------

  async ping(): Promise<string> {
    const body: string = await this.requestRaw('/login/status', [], false);
    let parsed: NeteaseLoginStatusResponse | undefined = undefined;
    try {
      parsed = JSON.parse(body) as NeteaseLoginStatusResponse;
    } catch (error) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云 login/status 响应无法解析', true);
    }
    const code: number = parsed.code === undefined || parsed.code === null ? 0 : parsed.code;
    this.checkCode(code, '/login/status', '');
    return '网易云 API 可用（自建服务端已连通）';
  }

  async search(keyword: string, page: number, pageSize: number): Promise<SearchResult> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const params: HttpParam[] = [];
    addParam(params, 'keywords', keyword);
    addParam(params, 'limit', String(safeSize));
    addParam(params, 'offset', String(pageOffset(safePage, safeSize)));

    let body: string;
    if (this.searchFallbackEngaged) {
      body = await this.requestRaw(ENDPOINT_SEARCH_FALLBACK, params, true);
    } else {
      try {
        body = await this.requestRaw(ENDPOINT_SEARCH, params, true);
      } catch (error) {
        Logger.warn(TAG, `${ENDPOINT_SEARCH} 不可用，回落 ${ENDPOINT_SEARCH_FALLBACK}`);
        this.searchFallbackEngaged = true;
        body = await this.requestRaw(ENDPOINT_SEARCH_FALLBACK, params, true);
      }
    }

    const parsed: NeteaseSearchResponse | undefined = this.parseSearchResponse(body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云搜索返回了无法解析的响应', true);
    }
    const code: number = parsed.code === undefined || parsed.code === null ? 0 : parsed.code;
    this.checkCode(code, '网易云搜索', '');

    const songs: SearchSongItem[] = [];
    const albums: SearchAlbumItem[] = [];
    const artists: SearchArtistItem[] = [];
    const result: NeteaseSearchResult | null | undefined = parsed.result;
    if (result !== undefined && result !== null) {
      const rawSongs: NeteaseSong[] | null | undefined = result.songs;
      if (rawSongs !== undefined && rawSongs !== null) {
        for (let index = 0; index < rawSongs.length; index++) {
          songs.push(this.toSearchSong(rawSongs[index]));
        }
      }
      const rawAlbums: NeteaseAlbum[] | null | undefined = result.albums;
      if (rawAlbums !== undefined && rawAlbums !== null) {
        for (let index = 0; index < rawAlbums.length; index++) {
          albums.push(this.toSearchAlbum(rawAlbums[index]));
        }
      }
      const rawArtists: NeteaseArtist[] | null | undefined = result.artists;
      if (rawArtists !== undefined && rawArtists !== null) {
        for (let index = 0; index < rawArtists.length; index++) {
          artists.push(this.toSearchArtist(rawArtists[index]));
        }
      }
    }
    const searchResult: SearchResult = { songs: songs, albums: albums, artists: artists };
    return searchResult;
  }

  /** 专辑/歌手搜索复用同一个搜索端点，只取对应分组 */
  async searchAlbums(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchAlbumItem>> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const result: SearchResult = await this.search(keyword, safePage, safeSize);
    return buildPage(result.albums, safePage, safeSize, -1);
  }

  async searchArtists(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchArtistItem>> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const result: SearchResult = await this.search(keyword, safePage, safeSize);
    return buildPage(result.artists, safePage, safeSize, -1);
  }

  async fetchAlbum(albumId: string): Promise<ProviderAlbumDetail | null> {
    const params: HttpParam[] = [];
    addParam(params, 'id', albumId);
    const body: string = await this.requestRaw('/album', params, true);
    const parsed: NeteaseAlbumDetailResponse | undefined = this.parseAlbumDetailResponse(body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云专辑接口返回了无法解析的响应', true);
    }
    this.checkCode(parsed.code === undefined || parsed.code === null ? 0 : parsed.code, '/album', '');
    const album: NeteaseAlbum | null | undefined = parsed.album;
    if (album === undefined || album === null) {
      return null;
    }
    const songs: SearchSongItem[] = [];
    const rawSongs: NeteaseSong[] | null | undefined = parsed.songs;
    if (rawSongs !== undefined && rawSongs !== null) {
      for (let index = 0; index < rawSongs.length; index++) {
        songs.push(this.toSearchSong(rawSongs[index]));
      }
    }
    const detail: ProviderAlbumDetail = {
      id: idText(album.id).length > 0 ? idText(album.id) : albumId,
      name: firstText(album.name, '未知专辑'),
      artist: '未知艺术家',
      songCount: album.size === undefined || album.size === null ? songs.length : album.size,
      songs: songs
    };
    const cover: string = firstText(album.picUrl, '');
    if (cover.length > 0) {
      detail.coverUrl = cover;
    }
    const single: NeteaseArtist | null | undefined = album.artist;
    if (single !== undefined && single !== null) {
      detail.artist = firstText(single.name, '未知艺术家');
    }
    return detail;
  }

  // -------------------------------------------------------------------------
  // 能力：单曲详情
  // -------------------------------------------------------------------------

  async fetchSongDetail(songId: string): Promise<Track | null> {
    const params: HttpParam[] = [];
    addParam(params, 'ids', songId);
    const body: string = await this.requestRaw('/song/detail', params, true);
    const parsed: NeteaseSongDetailResponse | undefined = this.parseSongDetailResponse(body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云单曲详情返回了无法解析的响应', true);
    }
    this.checkCode(parsed.code === undefined || parsed.code === null ? 0 : parsed.code, '/song/detail', '');
    const songs: NeteaseSong[] | null | undefined = parsed.songs;
    if (songs === undefined || songs === null || songs.length === 0) {
      return null;
    }
    return this.toTrack(songs[0], songId);
  }

  // -------------------------------------------------------------------------
  // 能力：音频直链
  // -------------------------------------------------------------------------

  async resolveAudioSource(songId: string, quality: string): Promise<ProviderAudioSource> {
    const level: string = mapQualityToLevel(quality);
    const params: HttpParam[] = [];
    addParam(params, 'id', songId);
    addParam(params, 'level', level);
    // randomCNIP 与 https 是 §3.1.3 明确要求的两个参数，缺一个都可能拿不到链接
    addParam(params, 'randomCNIP', 'true');
    addParam(params, 'https', 'true');

    const body: string = await this.requestRaw('/song/url/v1', params, true);
    const parsed: NeteaseSongUrlResponse | undefined = this.parseSongUrlResponse(body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云取直链接口返回了无法解析的响应', true);
    }
    this.checkCode(parsed.code === undefined || parsed.code === null ? 0 : parsed.code, '/song/url/v1', '');

    const list: NeteaseSongUrlEntry[] | null | undefined = parsed.data;
    if (list === undefined || list === null || list.length === 0) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.UNAVAILABLE, '网易云未返回直链数据', false);
    }
    const entry: NeteaseSongUrlEntry = list[0];
    const url: string = entry.url === undefined || entry.url === null ? '' : entry.url;
    if (url.length === 0) {
      // code=200 但 url 为 null 表示无播放权限（VIP/版权），不是网络问题
      throw new ProviderError(
        ProviderId.NETEASE,
        ProviderCodes.AUTH_REQUIRED,
        '网易云未返回可播放地址：该曲目可能需要 VIP 或已下架',
        false
      );
    }
    const source: ProviderAudioSource = {
      url: url,
      quality: level,
      expiresAt: Date.now() + NETEASE_URL_TTL_MS
    };
    if (entry.size !== undefined && entry.size !== null) {
      source.size = entry.size;
    }
    Logger.info(TAG, `解析到直链 level=${level}`);
    return source;
  }

  // -------------------------------------------------------------------------
  // 能力：歌词
  // -------------------------------------------------------------------------

  /**
   * 歌词。
   * 主文本优先用逐字歌词（YRC），否则用普通 LRC；翻译/罗马音按上游的优先级挑（§3.1.6）。
   */
  async fetchLyric(songId: string): Promise<LyricPayload> {
    const params: HttpParam[] = [];
    addParam(params, 'id', songId);

    let body: string;
    if (this.lyricFallbackEngaged) {
      body = await this.requestRaw(ENDPOINT_LYRIC_FALLBACK, params, true);
    } else {
      try {
        body = await this.requestRaw(ENDPOINT_LYRIC, params, true);
      } catch (error) {
        Logger.warn(TAG, `${ENDPOINT_LYRIC} 不可用，回落 ${ENDPOINT_LYRIC_FALLBACK}`);
        this.lyricFallbackEngaged = true;
        body = await this.requestRaw(ENDPOINT_LYRIC_FALLBACK, params, true);
      }
    }

    const parsed: NeteaseLyricResponse | undefined = this.parseLyricResponse(body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.NETEASE, ProviderCodes.INVALID_RESPONSE, '网易云歌词接口返回了无法解析的响应', true);
    }
    this.checkCode(parsed.code === undefined || parsed.code === null ? 0 : parsed.code, '网易云歌词', '');

    const mainLrc: string = lyricText(parsed.lrc);
    const yrcLrc: string = firstText(lyricText(parsed.yrc), nestedYrc(parsed.lrc));
    const ytlrc: string = firstText(lyricText(parsed.ytlrc), nestedYtlrc(parsed.lrc));
    const yromalrc: string = firstText(lyricText(parsed.yromalrc), nestedYromalrc(parsed.lrc));
    const tlyric: string = firstText(lyricText(parsed.tlyric), '');
    const romalrc: string = firstText(lyricText(parsed.romalrc), nestedRomalrc(parsed.lrc));

    const hasWordTiming: boolean = yrcLrc.length > 0;
    const translation: string = hasWordTiming && ytlrc.length > 0 ? ytlrc : tlyric;
    const romanization: string = hasWordTiming && yromalrc.length > 0 ? yromalrc : romalrc;
    const mainText: string = hasWordTiming ? yrcLrc : mainLrc;
    const pureMusic: boolean = parsed.pureMusic === true || isPureMusicText(mainText);

    const payload: LyricPayload = {
      lyric: mainText,
      pureMusic: pureMusic,
      source: hasWordTiming ? 'netease:yrc' : 'netease:lrc',
      format: hasWordTiming ? LyricFormat.YRC : LyricFormat.LRC
    };
    if (translation.length > 0) {
      payload.translation = translation;
    }
    if (romanization.length > 0) {
      payload.romaji = romanization;
    }
    return payload;
  }

  // -------------------------------------------------------------------------
  // 未实现能力
  // -------------------------------------------------------------------------

  /**
   * TODO(netease-account)：`/artist/detail` 的响应结构与 `data.artist` 的字段在上游源码里
   * 没有可确证的使用点（§3.1.3 只列出端点），因此暂不实现歌手详情。
   */
  async fetchArtist(artistId: string): Promise<ProviderArtistDetail | null> {
    throw new ProviderError(
      ProviderId.NETEASE,
      ProviderCodes.UNSUPPORTED,
      '网易云歌手详情尚未实现（响应结构需要抓包确认）',
      false
    );
  }

  /**
   * TODO(netease-account)：歌单列表需要登录态 userId（`/user/playlist?uid=`），
   * 匿名模式拿不到 uid，因此不实现。
   */
  async getPlaylists(): Promise<ProviderPlaylistSummary[]> {
    throw new ProviderError(
      ProviderId.NETEASE,
      ProviderCodes.AUTH_REQUIRED,
      '网易云歌单需要登录后才能获取（尚未实现账号登录）',
      false
    );
  }
}
