/**
 * Folia HarmonyOS - 酷狗 (KuGou) provider —— 仅匿名（未登录）能力
 *
 * 上游的酷狗能力分两条路（移植规范 §3.2.1）：
 *   1. Electron 主进程 require('kugoumusicapi')，凭据由主进程注入；
 *   2. Web 端打到 `VITE_KUGOU_API_BASE` 指向的 Node 服务。
 * HarmonyOS 没有 Node 主进程，因此本文件只实现**已确认可纯端侧**的部分：
 *
 *   ✅ 匿名搜索：`GET http://complexsearch.kugou.com/v2/search/song`，签名 + 6 个请求头逐字复刻（§3.2.5）
 *   ✅ 歌曲直链：优先走可选的自建 kugoumusicapi 服务 `/song/url`（§3.2.4 的 web 传输形状：参数 + timestamp，
 *      无 cookie 因为未登录）；未配置服务时回落到**纯端侧**的
 *      `https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=`（§3.2.8 的最后兜底）
 *   ✅ 歌词：`/search/lyric` → `/lyric?id=&accesskey=&fmt=krc&decode=true`，**只读 decodeContent**
 *      （KRC 解密在服务端完成，端侧不需要实现 DES，§3.2.9）
 *
 *   ❌ 登录态：lite 扫码登录、设备 cookie（KUGOU_API_*）、register_dev/dfid、/user/playlist、
 *      收藏、云盘 —— 这些的签名与凭据注入都在 `kugoumusicapi` npm 包内，
 *      **`未在源码中找到，需要抓包确认`**（§3.2.5 / §3.2.7），因此留 TODO(lite-login) 桩。
 *
 * ⚠️ 不臆造的常量：SALT 只有那一个（匿名 Android 搜索用），lite/登录签名一律不猜。
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
  HttpParam,
  HttpResponse,
  HttpTransport,
  toProviderError,
  trimTrailingSlash
} from './HttpTransport';
import { md5Hex } from './crypto/CryptoUtil';
import { KugouSettings, onlineSettings } from './OnlineSettings';
import {
  emptySearchResult,
  makeTrackId,
  normalizePage,
  normalizePageSize,
  OnlineProviderEx,
  originOf,
  ProviderAlbumDetail,
  ProviderArtistDetail,
  ProviderCodes,
  ProviderPlaylistSummary
} from './OnlineProvider';

const TAG: string = 'KugouProvider';

// ---------------------------------------------------------------------------
// 协议常量（全部来自移植规范 §3.2，禁止自行改动）
// ---------------------------------------------------------------------------

/** 匿名 Android 搜索签名盐（§3.2.5，前后各包一次） */
const KUGOU_SIGNATURE_SALT: string = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
/** 匿名搜索端点 */
// ⚠️ 平台适配（对上游规范的**有意偏离**）：
//    规范里这个地址是 **http 明文**（§3.2.2 逐字）。HarmonyOS 对明文流量有限制
//    （AVPlayer 侧有专门的 5411012「Http cleartext traffic is not permitted」错误码），
//    明文请求在部分设备/配置下会直接被拒绝。
//    这里默认改走 **https**：同 host、同路径，仅换 scheme，签名与请求头完全不受影响。
//    若某个网络环境下 https 不可用，把下面这行换回 KUGOU_SEARCH_URL_PLAINTEXT 即可。
const KUGOU_SEARCH_URL: string = 'https://complexsearch.kugou.com/v2/search/song';
/** 规范原文的明文地址，保留作为回退对照；导出以便需要时切换 */
export const KUGOU_SEARCH_URL_PLAINTEXT: string = 'http://complexsearch.kugou.com/v2/search/song';
/** 匿名搜索的 x-router 头 */
const KUGOU_SEARCH_ROUTER: string = 'complexsearch.kugou.com';
/** 匿名搜索 User-Agent（逐字） */
const KUGOU_SEARCH_UA: string = 'Android14-1070-11070-201-0-SearchSong-wifi';
/** appid（逐字） */
const KUGOU_APPID: string = '3116';
/** clientver（逐字） */
const KUGOU_CLIENTVER: string = '11070';
/** platform（逐字） */
const KUGOU_PLATFORM: string = 'AndroidFilter';
/** 旧版播放兜底端点（纯端侧，§3.2.8） */
const KUGOU_LEGACY_SONG_INFO_URL: string = 'https://m.kugou.com/app/i/getSongInfo.php';
/** 旧版播放兜底 User-Agent（逐字） */
const KUGOU_LEGACY_UA: string =
  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36';
/** 曲目元信息缓存上限（/song/url 与 /search/lyric 需要 duration 与 album_audio_id） */
const META_CACHE_LIMIT: number = 200;

/**
 * 酷狗签名（§3.2.5，精确到字节）：
 *   1. 参数 key 按字典序排序；
 *   2. 拼成 `k1=v1k2=v2...`（**无分隔符**）；
 *   3. signature = MD5(SALT + src + SALT)。
 * 注意 signature 自身不参与 src（它在之后才被加入参数表）。
 */
export function kugouSignature(params: HttpParam[]): string {
  const sorted: HttpParam[] = [];
  for (let index = 0; index < params.length; index++) {
    sorted.push(params[index]);
  }
  sorted.sort((left: HttpParam, right: HttpParam): number => {
    if (left.key < right.key) {
      return -1;
    }
    if (left.key > right.key) {
      return 1;
    }
    return 0;
  });
  const parts: string[] = [];
  for (let index = 0; index < sorted.length; index++) {
    parts.push(`${sorted[index].key}=${sorted[index].value}`);
  }
  const source: string = parts.join('');
  return md5Hex(`${KUGOU_SIGNATURE_SALT}${source}${KUGOU_SIGNATURE_SALT}`);
}

// ---------------------------------------------------------------------------
// 辅助纯函数
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

/** 取第一个非空文本（三候选） */
function firstTextOf3(
  a: string | undefined | null,
  b: string | undefined | null,
  c: string | undefined | null
): string {
  const first: string = firstText(a, b);
  return first.length > 0 ? first : firstText(c, undefined);
}

/** 数字或字符串 id → 文本 */
function idText(value: string | number | undefined | null): string {
  if (value === undefined || value === null) {
    return '';
  }
  return `${value}`;
}

/** 三选一的 id 字段（酷狗不同版本用 AlbumAudioID / MixSongID / Audioid 表示同一件事） */
function firstIdText(
  a: string | number | undefined | null,
  b: string | number | undefined | null,
  c: string | number | undefined | null
): string {
  const first: string = idText(a);
  if (first.length > 0) {
    return first;
  }
  const second: string = idText(b);
  if (second.length > 0) {
    return second;
  }
  return idText(c);
}

/** 取第一个非零数字（errcode / error_code 这类双写字段） */
function firstNumber(a: number | undefined | null, b: number | undefined | null): number {
  if (a !== undefined && a !== null) {
    return a;
  }
  if (b !== undefined && b !== null) {
    return b;
  }
  return 0;
}

/**
 * 酷狗时长 → 毫秒。
 * ⚠️ 未确认：匿名搜索响应里 Duration 字段的单位未在上游仓库的源码中出现过
 *    （上游只从 kugoumusicapi 的归一化结果里拿 durationMs）。
 *    这里按 KuGou 移动端惯例视为**秒**；若数值 > 100000 则按毫秒处理（>100 秒的合理上限）。
 */
function kugouDurationToMs(raw: number | undefined | null): number {
  if (raw === undefined || raw === null || raw <= 0) {
    return 0;
  }
  if (raw > 100000) {
    return Math.round(raw);
  }
  return Math.round(raw * 1000);
}

/** 音质档位 → 酷狗 quality 参数（§3.2.8：hires → high，lossless → flac，反直觉但逐字如此） */
function kugouQualityParam(quality: string): string {
  if (quality === 'standard') {
    return '128';
  }
  if (quality === 'high') {
    return '320';
  }
  if (quality === 'lossless') {
    return 'flac';
  }
  if (quality === 'hires') {
    return 'high';
  }
  // 已经是酷狗原生参数（128/320/flac/high/…）时原样透传
  return quality;
}

/** 音质降级链（§3.2.8 QUALITY_FALLBACKS） */
function kugouQualityFallbacks(quality: string): string[] {
  if (quality === 'standard') {
    return ['standard'];
  }
  if (quality === 'high') {
    return ['high', 'standard'];
  }
  if (quality === 'lossless') {
    return ['lossless', 'high', 'standard'];
  }
  if (quality === 'hires') {
    return ['hires', 'lossless', 'high', 'standard'];
  }
  return [quality];
}

// ---------------------------------------------------------------------------
// 响应结构（酷狗返回的字段大小写不统一，这里把见过的写法都列出来，用 firstXxx 兜住）
// ---------------------------------------------------------------------------

interface KugouSearchSong {
  FileHash?: string;
  fileHash?: string;
  SongName?: string;
  songName?: string;
  SingerName?: string;
  singerName?: string;
  AlbumName?: string;
  albumName?: string;
  AlbumID?: string | number;
  albumId?: string | number;
  AlbumAudioID?: string | number;
  MixSongID?: string | number;
  Audioid?: string | number;
  audio_id?: string | number;
  /** ⚠️ 未确认单位（见 kugouDurationToMs） */
  Duration?: number;
  duration?: number;
  Image?: string;
  image?: string;
}

interface KugouSearchData {
  total?: number;
  lists?: KugouSearchSong[] | null;
}

interface KugouSearchResponse {
  status?: number;
  err_code?: number;
  error_code?: number;
  errcode?: number;
  data?: KugouSearchData | null;
}

interface KugouCandidate {
  id?: string | number;
  accesskey?: string;
  duration?: number;
  product_from?: string;
}

interface KugouSearchLyricResponse {
  status?: number;
  errcode?: number;
  error_code?: number;
  candidates?: KugouCandidate[] | null;
}

interface KugouLyricResponse {
  status?: number;
  errcode?: number;
  error_code?: number;
  /** 服务端已解码的 KRC 文本（fmt=krc&decode=true）；端侧只读这一个字段 */
  decodeContent?: string;
}

interface KugouSongUrlPayload {
  play_url?: string;
  playUrl?: string;
  url?: string;
  volume?: number;
  volume_peak?: number;
  album_id?: string | number;
  album_audio_id?: string | number;
}

interface KugouSongUrlResponse {
  status?: number;
  errcode?: number;
  error_code?: number;
  /** ⚠️ 未确认：payload 可能是对象也可能是数组（移植规范 §3.2.8 注） */
  data?: KugouSongUrlPayload | KugouSongUrlPayload[] | null;
  play_url?: string;
  playUrl?: string;
  url?: string;
}

interface KugouLegacySongInfo {
  status?: number;
  err_code?: number;
  url?: string | null;
  backup_url?: string | null;
  fileSize?: number;
  timeLength?: number;
  extName?: string;
}

/** 曲目元信息缓存项：/song/url 与 /search/lyric 需要 duration / album_audio_id */
interface KugouSongMeta {
  hash: string;
  title: string;
  artist: string;
  album: string;
  durationMs: number;
  albumId: string;
  albumAudioId: string;
}

/** 酷狗 provider（仅匿名能力） */
export class KugouProvider implements OnlineProviderEx {
  readonly id: ProviderId = ProviderId.KUGOU;
  readonly displayName: string = '酷狗音乐';
  readonly capabilities: ProviderCapabilities = {
    search: true,
    songUrl: true,
    lyric: true,
    album: false,
    artist: false,
    playlist: false,
    login: false,
    favorite: false
  };

  /** 保留 context 供后续 lite 登录接入安全存储使用 */
  private context: common.UIAbilityContext;
  /** hash → 元信息；匿名搜索拿到的 duration / albumAudioId 在这里中转给直链与歌词 */
  private metaCache: Map<string, KugouSongMeta> = new Map();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // -------------------------------------------------------------------------
  // 配置
  // -------------------------------------------------------------------------

  private config(): KugouSettings {
    return onlineSettings.getKugou();
  }

  /** 匿名搜索不需要任何配置，因此无条件可用；需要服务端的端点会各自再校验 */
  isConfigured(): boolean {
    return true;
  }

  private requireApiBase(scene: string): string {
    const base: string = this.config().apiBase;
    if (base.length === 0) {
      throw new ProviderError(
        ProviderId.KUGOU,
        ProviderCodes.NOT_CONFIGURED,
        `${scene}需要配置 KuGou API 服务地址（自建 kugoumusicapi），请先在设置中填写`,
        false
      );
    }
    return trimTrailingSlash(base);
  }

  // -------------------------------------------------------------------------
  // 响应解析（每个响应类型一个具体函数，避免泛型 as 转换）
  // -------------------------------------------------------------------------

  private parseSearchResponse(body: string): KugouSearchResponse | undefined {
    try {
      return JSON.parse(body) as KugouSearchResponse;
    } catch (error) {
      Logger.err(TAG, 'parse search response', error as Error);
      return undefined;
    }
  }

  private parseSearchLyricResponse(body: string): KugouSearchLyricResponse | undefined {
    try {
      return JSON.parse(body) as KugouSearchLyricResponse;
    } catch (error) {
      Logger.err(TAG, 'parse search/lyric response', error as Error);
      return undefined;
    }
  }

  private parseLyricResponse(body: string): KugouLyricResponse | undefined {
    try {
      return JSON.parse(body) as KugouLyricResponse;
    } catch (error) {
      Logger.err(TAG, 'parse lyric response', error as Error);
      return undefined;
    }
  }

  private parseSongUrlResponse(body: string): KugouSongUrlResponse | undefined {
    try {
      return JSON.parse(body) as KugouSongUrlResponse;
    } catch (error) {
      Logger.err(TAG, 'parse song/url response', error as Error);
      return undefined;
    }
  }

  private parseLegacySongInfo(body: string): KugouLegacySongInfo | undefined {
    try {
      return JSON.parse(body) as KugouLegacySongInfo;
    } catch (error) {
      Logger.err(TAG, 'parse getSongInfo response', error as Error);
      return undefined;
    }
  }

  /**
   * 酷狗错误码 → ProviderError。
   * 152 = 认证请求缺少有效 cookie 凭据（§3.2.10）→ auth-required；
   * 20028 / “本次请求需要验证” = 需要设备验证，必须先 /register/dev 拿 dfid → 属于 lite 登录流程。
   */
  private throwForErrorCode(errorCode: number, scene: string): void {
    if (errorCode === 0 || errorCode === 200) {
      return;
    }
    if (errorCode === 152) {
      throw new ProviderError(
        ProviderId.KUGOU,
        ProviderCodes.AUTH_REQUIRED,
        `${scene}失败：酷狗要求登录凭据（error_code=152），当前为匿名模式`,
        false
      );
    }
    if (errorCode === 20028) {
      // TODO(lite-login)：需要先调 /register/dev 拿 dfid 再重发（§3.2.4 的设备校验重试）
      throw new ProviderError(
        ProviderId.KUGOU,
        ProviderCodes.AUTH_REQUIRED,
        `${scene}失败：酷狗要求设备验证（error_code=20028），需要 lite 设备注册流程（尚未实现）`,
        false
      );
    }
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.INVALID_RESPONSE,
      `${scene}失败：酷狗返回 error_code=${errorCode}`,
      false
    );
  }

  // -------------------------------------------------------------------------
  // 能力：连通性
  // -------------------------------------------------------------------------

  /** 用一次真实的匿名搜索做连通性探测（匿名路径不需要任何配置） */
  async ping(): Promise<string> {
    const result: SearchResult = await this.search('Folia', 1, 1);
    const hits: number = result.songs.length;
    return `酷狗匿名搜索可用（探测命中 ${hits} 条）`;
  }

  // -------------------------------------------------------------------------
  // 能力：匿名搜索
  // -------------------------------------------------------------------------

  /** 构造匿名搜索参数（顺序与上游一致，便于抓包比对） */
  private buildAnonymousSearchParams(
    keyword: string,
    page: number,
    pageSize: number,
    clientTimeMs: number,
    mid: string
  ): HttpParam[] {
    const clientTimeSec: number = Math.floor(clientTimeMs / 1000);
    const params: HttpParam[] = [];
    addParam(params, 'sorttype', '0');
    addParam(params, 'keyword', keyword);
    addParam(params, 'pagesize', String(pageSize));
    addParam(params, 'page', String(page));
    addParam(params, 'userid', '0');
    addParam(params, 'appid', KUGOU_APPID);
    addParam(params, 'token', '');
    addParam(params, 'clienttime', String(clientTimeSec));
    addParam(params, 'iscorrection', '1');
    addParam(params, 'uuid', '-');
    addParam(params, 'mid', mid);
    addParam(params, 'dfid', '-');
    addParam(params, 'clientver', KUGOU_CLIENTVER);
    addParam(params, 'platform', KUGOU_PLATFORM);
    return params;
  }

  /** 6 个请求头（逐字，§3.2.5）；mid 必须与 query 里的 mid 是同一个值 */
  private anonymousSearchHeaders(clientTimeMs: number, mid: string): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['User-Agent'] = KUGOU_SEARCH_UA;
    headers['KG-Rec'] = '1';
    headers['KG-RC'] = '1';
    headers['KG-CLIENTTIMEMS'] = String(clientTimeMs);
    headers['mid'] = mid;
    headers['x-router'] = KUGOU_SEARCH_ROUTER;
    return headers;
  }

  private rememberMeta(song: KugouSearchSong, hash: string, durationMs: number, albumId: string,
    albumAudioId: string): void {
    if (hash.length === 0) {
      return;
    }
    if (this.metaCache.size >= META_CACHE_LIMIT) {
      const oldest: string[] = [];
      this.metaCache.forEach((value: KugouSongMeta, key: string) => {
        if (oldest.length < 32) {
          oldest.push(key);
        }
      });
      for (let index = 0; index < oldest.length; index++) {
        this.metaCache.delete(oldest[index]);
      }
    }
    const meta: KugouSongMeta = {
      hash: hash,
      title: firstText(song.SongName, firstText(song.songName, '')),
      artist: firstText(song.SingerName, firstText(song.singerName, '')),
      album: firstText(song.AlbumName, firstText(song.albumName, '')),
      durationMs: durationMs,
      albumId: albumId,
      albumAudioId: albumAudioId
    };
    this.metaCache.set(hash, meta);
  }

  private metaOf(hash: string): KugouSongMeta | undefined {
    return this.metaCache.get(hash.toUpperCase());
  }

  async search(keyword: string, page: number, pageSize: number): Promise<SearchResult> {
    const safePage: number = normalizePage(page);
    const safeSize: number = normalizePageSize(pageSize);
    const clientTimeMs: number = Date.now();
    // mid = MD5(十进制毫秒时间戳)，同一个值同时进 query 与请求头（§3.2.5）
    const mid: string = md5Hex(String(clientTimeMs));
    const params: HttpParam[] = this.buildAnonymousSearchParams(keyword, safePage, safeSize, clientTimeMs, mid);
    addParam(params, 'signature', kugouSignature(params));

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(KUGOU_SEARCH_URL, params, this.anonymousSearchHeaders(clientTimeMs, mid));
    } catch (error) {
      Logger.err(TAG, 'anonymous search', error as Error);
      throw toProviderError(ProviderId.KUGOU, '酷狗匿名搜索', error as Error);
    }

    const parsed: KugouSearchResponse | undefined = this.parseSearchResponse(response.body);
    if (parsed === undefined) {
      throw new ProviderError(
        ProviderId.KUGOU,
        ProviderCodes.INVALID_RESPONSE,
        '酷狗匿名搜索返回了无法解析的响应',
        true
      );
    }
    this.throwForErrorCode(firstNumber(parsed.error_code, parsed.errcode), '酷狗匿名搜索');

    const songs: SearchSongItem[] = [];
    const data: KugouSearchData | null | undefined = parsed.data;
    if (data === undefined || data === null) {
      return emptySearchResult();
    }
    const lists: KugouSearchSong[] | null | undefined = data.lists;
    if (lists === undefined || lists === null) {
      return emptySearchResult();
    }

    for (let index = 0; index < lists.length; index++) {
      const raw: KugouSearchSong = lists[index];
      const hash: string = firstText(raw.FileHash, firstText(raw.fileHash, '')).toUpperCase();
      if (hash.length === 0) {
        continue;
      }
      const durationMs: number = kugouDurationToMs(firstNumber(raw.Duration, raw.duration));
      const albumId: string = firstIdText(raw.AlbumID, raw.albumId, undefined);
      // 不同协议版本分别用 AlbumAudioID / MixSongID / Audioid 表示同一个值，
      // 最后一个候选是 snake_case 的 audio_id
      let albumAudioId: string = firstIdText(raw.AlbumAudioID, raw.MixSongID, raw.Audioid);
      if (albumAudioId.length === 0) {
        albumAudioId = idText(raw.audio_id);
      }
      this.rememberMeta(raw, hash, durationMs, albumId, albumAudioId);

      const artist: string = firstText(raw.SingerName, firstText(raw.singerName, '未知艺术家'));
      const item: SearchSongItem = {
        id: hash,
        title: firstText(raw.SongName, firstText(raw.songName, '未知曲目')),
        artist: artist,
        album: firstText(raw.AlbumName, firstText(raw.albumName, '')),
        duration: durationMs
      };
      const cover: string = firstText(raw.Image, raw.image);
      if (cover.length > 0) {
        item.coverUrl = cover;
      }
      if (albumId.length > 0) {
        item.albumId = albumId;
      }
      songs.push(item);
    }

    // 匿名搜索端点不返回专辑/歌手分组
    const albums: SearchAlbumItem[] = [];
    const artists: SearchArtistItem[] = [];
    const result: SearchResult = { songs: songs, albums: albums, artists: artists };
    return result;
  }

  // -------------------------------------------------------------------------
  // 能力：歌曲直链
  // -------------------------------------------------------------------------

  /** 打自建 kugoumusicapi 服务的 /song/url；成功返回直链，失败/无数据返回空串 */
  private async requestSongUrlViaApi(
    hash: string,
    quality: string,
    meta: KugouSongMeta | undefined
  ): Promise<string> {
    const base: string = trimTrailingSlash(this.config().apiBase);
    const params: HttpParam[] = [];
    addParam(params, 'hash', hash);
    addParam(params, 'quality', kugouQualityParam(quality));
    if (meta !== undefined) {
      if (meta.albumId.length > 0) {
        addParam(params, 'album_id', meta.albumId);
      }
      if (meta.albumAudioId.length > 0) {
        addParam(params, 'album_audio_id', meta.albumAudioId);
      }
    }
    // 匿名模式：不带 cookie，只带 timestamp（§3.2.4 的 web 传输形状）
    addParam(params, 'timestamp', String(Date.now()));

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(`${base}/song/url`, params);
    } catch (error) {
      Logger.warn(TAG, 'kugoumusicapi /song/url 请求失败，将回落 m.kugou.com');
      return '';
    }
    const parsed: KugouSongUrlResponse | undefined = this.parseSongUrlResponse(response.body);
    if (parsed === undefined) {
      return '';
    }
    const errorCode: number = firstNumber(parsed.error_code, parsed.errcode);
    if (errorCode !== 0 && errorCode !== 200 && errorCode !== 152 && errorCode !== 20028) {
      Logger.warn(TAG, `/song/url 返回 error_code=${errorCode}`);
      return '';
    }
    if (errorCode === 152 || errorCode === 20028) {
      // 交给调用方决定是否报错（这里先当「没拿到」处理，让端侧兜底再试一次）
      Logger.warn(TAG, `/song/url 需要登录/设备验证（error_code=${errorCode}），回落端侧兜底`);
      return '';
    }

    const payload: KugouSongUrlPayload | null | undefined = this.pickSongUrlPayload(parsed);
    if (payload === undefined || payload === null) {
      return firstTextOf3(parsed.play_url, parsed.playUrl, parsed.url);
    }
    return firstTextOf3(payload.play_url, payload.playUrl, payload.url);
  }

  /** data 可能是对象也可能是数组（⚠️ 未确认，见接口注释） */
  private pickSongUrlPayload(response: KugouSongUrlResponse): KugouSongUrlPayload | null | undefined {
    const data: KugouSongUrlPayload | KugouSongUrlPayload[] | null | undefined = response.data;
    if (data === undefined || data === null) {
      return undefined;
    }
    if (Array.isArray(data)) {
      const list: KugouSongUrlPayload[] = data as KugouSongUrlPayload[];
      return list.length > 0 ? list[0] : undefined;
    }
    return data as KugouSongUrlPayload;
  }

  /** 纯端侧兜底：m.kugou.com 的 getSongInfo.php（返回的固定是 standard 档） */
  private async requestLegacySongUrl(hash: string): Promise<string> {
    const params: HttpParam[] = [];
    addParam(params, 'cmd', 'playInfo');
    addParam(params, 'hash', hash);
    const headers: Record<string, string> = {};
    headers['User-Agent'] = KUGOU_LEGACY_UA;

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(KUGOU_LEGACY_SONG_INFO_URL, params, headers);
    } catch (error) {
      Logger.err(TAG, 'legacy getSongInfo', error as Error);
      throw toProviderError(ProviderId.KUGOU, '酷狗旧版直链兜底', error as Error);
    }
    const parsed: KugouLegacySongInfo | undefined = this.parseLegacySongInfo(response.body);
    if (parsed === undefined) {
      return '';
    }
    return firstText(parsed.url, parsed.backup_url);
  }

  /**
   * 音频直链。
   * 顺序：配置了服务 → 自建 /song/url（按音质降级链逐个试）→ 端侧 m.kugou.com 兜底。
   * ⚠️ 未确认：酷狗 CDN 直链是否需要 Referer/User-Agent 才能播放、以及有效期（§3.2.8 与附录 B 第 5 项）；
   *    这里不改写返回头，expiresAt 取 0（未知 = 不主动过期，交给播放失败时重新解析）。
   */
  async resolveAudioSource(songId: string, quality: string): Promise<ProviderAudioSource> {
    const hash: string = songId.toUpperCase();
    if (hash.length === 0) {
      throw new ProviderError(ProviderId.KUGOU, ProviderCodes.UNAVAILABLE, '酷狗曲目缺少 hash，无法解析直链', false);
    }
    const meta: KugouSongMeta | undefined = this.metaOf(hash);
    const hasApiBase: boolean = this.config().apiBase.length > 0;

    if (hasApiBase) {
      const fallbacks: string[] = kugouQualityFallbacks(quality);
      for (let index = 0; index < fallbacks.length; index++) {
        const url: string = await this.requestSongUrlViaApi(hash, fallbacks[index], meta);
        if (url.length > 0) {
          const source: ProviderAudioSource = {
            url: url,
            quality: fallbacks[index],
            expiresAt: 0
          };
          if (meta !== undefined) {
            // size 未知，只有旧版兜底接口会给；这里不猜
            Logger.info(TAG, `解析到直链（服务端） quality=${fallbacks[index]}`);
          }
          return source;
        }
      }
    }

    const legacyUrl: string = await this.requestLegacySongUrl(hash);
    if (legacyUrl.length === 0) {
      throw new ProviderError(
        ProviderId.KUGOU,
        ProviderCodes.UNAVAILABLE,
        '酷狗未能返回可用的播放地址（该曲目可能需要登录或 VIP 权限）',
        true
      );
    }
    Logger.info(TAG, '解析到直链（端侧兜底，standard）');
    const source: ProviderAudioSource = {
      url: legacyUrl,
      quality: 'standard',
      expiresAt: 0
    };
    return source;
  }

  // -------------------------------------------------------------------------
  // 能力：歌词
  // -------------------------------------------------------------------------

  /** 第一步：/search/lyric 拿候选（id + accesskey） */
  private async searchLyricCandidate(hash: string, meta: KugouSongMeta | undefined): Promise<KugouCandidate | undefined> {
    const base: string = this.requireApiBase('酷狗歌词');
    const params: HttpParam[] = [];
    addParam(params, 'hash', hash);
    addParam(params, 'duration', String(meta === undefined ? 0 : meta.durationMs));
    addParam(params, 'man', 'no');
    if (meta !== undefined && meta.albumAudioId.length > 0) {
      addParam(params, 'album_audio_id', meta.albumAudioId);
    }
    addParam(params, 'timestamp', String(Date.now()));

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(`${base}/search/lyric`, params);
    } catch (error) {
      throw toProviderError(ProviderId.KUGOU, '酷狗歌词检索', error as Error);
    }
    const parsed: KugouSearchLyricResponse | undefined = this.parseSearchLyricResponse(response.body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.KUGOU, ProviderCodes.INVALID_RESPONSE, '酷狗歌词检索返回了无法解析的响应', true);
    }
    this.throwForErrorCode(firstNumber(parsed.error_code, parsed.errcode), '酷狗歌词检索');
    const candidates: KugouCandidate[] | null | undefined = parsed.candidates;
    if (candidates === undefined || candidates === null || candidates.length === 0) {
      return undefined;
    }
    return candidates[0];
  }

  /**
   * 歌词主入口。
   * `fmt=krc&decode=true` 时，**服务端**已经把 KRC 解好放在 `decodeContent` 里，
   * 端侧不需要实现 KRC 的 DES 解密（§3.2.9，附录 B 第 4 项）。
   */
  async fetchLyric(songId: string): Promise<LyricPayload> {
    const hash: string = songId.toUpperCase();
    const meta: KugouSongMeta | undefined = this.metaOf(hash);
    const candidate: KugouCandidate | undefined = await this.searchLyricCandidate(hash, meta);
    if (candidate === undefined) {
      const miss: LyricPayload = { lyric: '', pureMusic: false, source: 'kugou', format: LyricFormat.NONE };
      return miss;
    }
    const candidateId: string = idText(candidate.id);
    const accesskey: string = candidate.accesskey === undefined || candidate.accesskey === null ? '' : candidate.accesskey;
    if (candidateId.length === 0 || accesskey.length === 0) {
      const miss: LyricPayload = { lyric: '', pureMusic: false, source: 'kugou', format: LyricFormat.NONE };
      return miss;
    }

    const base: string = this.requireApiBase('酷狗歌词');
    const params: HttpParam[] = [];
    addParam(params, 'id', candidateId);
    addParam(params, 'accesskey', accesskey);
    addParam(params, 'fmt', 'krc');
    addParam(params, 'decode', 'true');
    addParam(params, 'timestamp', String(Date.now()));

    let response: HttpResponse;
    try {
      response = await HttpTransport.get(`${base}/lyric`, params);
    } catch (error) {
      throw toProviderError(ProviderId.KUGOU, '酷狗歌词下载', error as Error);
    }
    const parsed: KugouLyricResponse | undefined = this.parseLyricResponse(response.body);
    if (parsed === undefined) {
      throw new ProviderError(ProviderId.KUGOU, ProviderCodes.INVALID_RESPONSE, '酷狗歌词返回了无法解析的响应', true);
    }
    this.throwForErrorCode(firstNumber(parsed.error_code, parsed.errcode), '酷狗歌词下载');

    // 只认 decodeContent（其余字段 Folia 从不使用）
    const content: string = parsed.decodeContent === undefined || parsed.decodeContent === null ? '' : parsed.decodeContent;
    const payload: LyricPayload = {
      lyric: content,
      pureMusic: false,
      source: 'kugou:krc',
      // 服务端已解码的 KRC 文本：显式告知解析器，避免自动检测误判成 LRC
      format: LyricFormat.KRC
    };
    return payload;
  }

  // -------------------------------------------------------------------------
  // 能力：单曲详情（匿名模式没有该端点）
  // -------------------------------------------------------------------------

  /**
   * TODO(kugou-extended)：酷狗的 `/song/detail` 等价端点属于 kugoumusicapi 的登录态能力，
   * 匿名端侧只有搜索列表；这里只从搜索缓存回填，缓存未命中返回 null。
   */
  async fetchSongDetail(songId: string): Promise<Track | null> {
    const hash: string = songId.toUpperCase();
    const meta: KugouSongMeta | undefined = this.metaOf(hash);
    if (meta === undefined) {
      return null;
    }
    const artists: string[] = [meta.artist.length > 0 ? meta.artist : '未知艺术家'];
    const track: Track = {
      id: makeTrackId(ProviderId.KUGOU, hash),
      title: meta.title.length > 0 ? meta.title : '未知曲目',
      artist: artists[0],
      artists: artists,
      album: meta.album,
      duration: meta.durationMs,
      origin: originOf(ProviderId.KUGOU),
      providerId: ProviderId.KUGOU,
      songId: hash
    };
    return track;
  }

  // -------------------------------------------------------------------------
  // 未实现能力（登录态 / 集合类）
  // -------------------------------------------------------------------------

  /** TODO(lite-login)：酷狗专辑详情需要登录态签名（lite header），尚未实现 */
  async fetchAlbum(albumId: string): Promise<ProviderAlbumDetail | null> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.UNSUPPORTED,
      '酷狗专辑详情尚未实现（需要登录态签名）',
      false
    );
  }

  /** TODO(lite-login)：酷狗歌手详情需要登录态签名（lite header），尚未实现 */
  async fetchArtist(artistId: string): Promise<ProviderArtistDetail | null> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.UNSUPPORTED,
      '酷狗歌手详情尚未实现（需要登录态签名）',
      false
    );
  }

  /** TODO(lite-login)：酷狗歌单列表需要 token/cookie 注入，匿名模式不可用 */
  async getPlaylists(): Promise<ProviderPlaylistSummary[]> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.AUTH_REQUIRED,
      '酷狗歌单需要登录后才能使用（lite 登录尚未实现）',
      false
    );
  }

  /** TODO(lite-login)：lite 扫码/key 登录尚未实现（/login/qr/key → /login/qr/create → /login/qr/check） */
  async login(): Promise<void> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.UNSUPPORTED,
      '酷狗登录尚未实现：lite 设备 cookie 与登录签名位于 kugoumusicapi 包内，需要抓包确认',
      false
    );
  }

  /** TODO(lite-login)：本地清除凭据；登录未实现，因此只清设置里的残留字段 */
  async logout(): Promise<void> {
    onlineSettings.clearKugouSession();
    Logger.info(TAG, '已清除本地酷狗登录残留字段');
  }

  /** TODO(lite-login)：/user/playlist 需要 userid + token */
  async getUserPlaylists(): Promise<ProviderPlaylistSummary[]> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.AUTH_REQUIRED,
      '酷狗用户歌单需要登录（lite 登录尚未实现）',
      false
    );
  }

  /** TODO(lite-login)：收藏列表需要登录态（酷狗的收藏还需要 fileId，接口属于登录能力） */
  async getLikedSongIds(): Promise<string[]> {
    throw new ProviderError(
      ProviderId.KUGOU,
      ProviderCodes.AUTH_REQUIRED,
      '酷狗收藏列表需要登录（lite 登录尚未实现）',
      false
    );
  }
}
