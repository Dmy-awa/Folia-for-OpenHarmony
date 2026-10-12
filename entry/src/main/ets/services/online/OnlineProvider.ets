/**
 * Folia HarmonyOS - 在线音乐 provider 的内部扩展契约
 *
 * core/Types.ets 的 `OnlineMusicProvider` 只定义了三个最小能力（搜索 / 取直链 / 取歌词），
 * 是「所有 provider 必须实现」的下限。本文件定义 Omni 路由层与各 provider 之间的**内部**契约：
 *   - `OnlineProviderEx`：在最小能力之上补齐「配置检查 / 连通性探测 / 单曲详情 / 专辑 / 歌手 / 歌单」；
 *   - `ProviderCodes`：统一错误码（对齐移植规范 §1.7 的 ProviderErrorCode 语义）；
 *   - 若干纯函数工具：空搜索结果、分页构造、页码归一化、曲目 id 生成、来源枚举转换。
 *
 * ⚠️ 架构约束（移植规范 §2.2 的 Adapter/Transport 分层）：
 *    只有 OmniRouter 可以持有 `OnlineProviderEx`；UI / ViewModel 一律不允许 import 本文件，
 *    更不允许绕过 Omni 直接调用某个 provider。
 *
 * ⚠️ 为什么单独建这个文件：任务给定的文件清单里没有它，但 provider 的扩展能力（专辑/歌手/歌单/
 *    配置检查）需要一份共享类型才能被 OmniRouter 统一路由；若塞进 core/Types.ets 会污染领域模型，
 *    若塞进 OmniRouter.ets 会造成 provider ↔ router 的循环依赖。
 */
import {
  OnlineMusicProvider,
  ProviderId,
  ProviderPage,
  SearchAlbumItem,
  SearchArtistItem,
  SearchResult,
  SearchSongItem,
  Track,
  TrackOrigin
} from '../../core/Types';

/** 默认页大小（无分页语义的端点用不到时取这个值） */
export const DEFAULT_PAGE_SIZE: number = 30;

/** 专辑详情（含曲目列表） */
export interface ProviderAlbumDetail {
  id: string;
  name: string;
  artist: string;
  coverUrl?: string;
  songCount: number;
  songs: SearchSongItem[];
}

/** 歌手详情（含专辑列表） */
export interface ProviderArtistDetail {
  id: string;
  name: string;
  coverUrl?: string;
  albumCount: number;
  albums: SearchAlbumItem[];
}

/** 歌单 / 合集摘要 */
export interface ProviderPlaylistSummary {
  id: string;
  name: string;
  coverUrl?: string;
  songCount: number;
  owner?: string;
}

/**
 * provider 的统一错误码。
 * 用类常量而不是字符串字面量散落各处，避免拼写错误导致上层分流失效。
 */
export class ProviderCodes {
  /** 网络层失败（连接不上 / 超时 / 5xx），retryable = true */
  static readonly NETWORK: string = 'network';
  /** 响应结构不符合预期（JSON 解析失败、缺字段、Subsonic status != ok） */
  static readonly INVALID_RESPONSE: string = 'invalid-response';
  /** 需要登录态 / 凭据被拒 */
  static readonly AUTH_REQUIRED: string = 'auth-required';
  /** 该 provider 不支持该能力 */
  static readonly UNSUPPORTED: string = 'unsupported';
  /** 服务端可达但资源不可用（地区限制、下架） */
  static readonly UNAVAILABLE: string = 'unavailable';
  /** 本地未配置服务地址 / 账号 */
  static readonly NOT_CONFIGURED: string = 'not-configured';
  /** 服务端明确表示「找不到」 */
  static readonly NOT_FOUND: string = 'not-found';
  /** provider 切换后丢弃晚到响应（上游 omni.ts:99-110 的 AbortError 等价物） */
  static readonly ABORT: string = 'abort';
}

/**
 * Omni 内部使用的 provider 契约。
 * 必选方法 = core 的三个最小能力 + 配置检查 + 连通性探测 + 单曲详情；
 * 可选方法按能力声明实现，未实现时用 `?` 标注，Omni 会走降级分支而不是抛错。
 */
export interface OnlineProviderEx extends OnlineMusicProvider {
  /** 配置是否齐全；返回 false 时所有网络方法都必须抛 NOT_CONFIGURED */
  isConfigured(): boolean;
  /** 连通性探测：成功返回可读描述（如服务器版本），失败抛 ProviderError */
  ping(): Promise<string>;
  /** 按 provider 内部 id 取单曲详情；服务端没有这首歌时返回 null */
  fetchSongDetail(songId: string): Promise<Track | null>;

  /** 专辑搜索 */
  searchAlbums?(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchAlbumItem>>;
  /** 歌手搜索 */
  searchArtists?(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchArtistItem>>;
  /** 专辑详情 */
  fetchAlbum?(albumId: string): Promise<ProviderAlbumDetail | null>;
  /** 歌手详情 */
  fetchArtist?(artistId: string): Promise<ProviderArtistDetail | null>;
  /** 歌单列表（需要登录态的 provider 抛 AUTH_REQUIRED） */
  getPlaylists?(): Promise<ProviderPlaylistSummary[]>;
  /** 构造把凭据内联进去的封面地址（Subsonic 这类平台需要），无封面时返回空串 */
  buildCoverUrl?(coverId: string, size?: number): string;
}

/** 空搜索结果：能力不支持时返回它，而不是抛错（对齐上游 emptyPage 的做法） */
export function emptySearchResult(): SearchResult {
  const songs: SearchSongItem[] = [];
  const albums: SearchAlbumItem[] = [];
  const artists: SearchArtistItem[] = [];
  const result: SearchResult = { songs: songs, albums: albums, artists: artists };
  return result;
}

/** 空分页 */
export function emptyPage<T>(): ProviderPage<T> {
  const items: T[] = [];
  const page: ProviderPage<T> = { items: items, total: 0, hasMore: false };
  return page;
}

/**
 * 构造分页结果。
 * @param page 1 起始页码
 * @param total 服务端声明的总数；未知时传 -1，会退化成「本页条数」
 */
export function buildPage<T>(items: T[], page: number, pageSize: number, total: number): ProviderPage<T> {
  const safeTotal: number = total < 0 ? items.length : total;
  const result: ProviderPage<T> = {
    items: items,
    total: safeTotal,
    hasMore: page * pageSize < safeTotal
  };
  return result;
}

/** 归一化 1 起始页码 */
export function normalizePage(page: number): number {
  if (!Number.isFinite(page) || page < 1) {
    return 1;
  }
  return Math.floor(page);
}

/** 归一化页大小（1 ~ 100，非法值回落默认值） */
export function normalizePageSize(pageSize: number): number {
  if (!Number.isFinite(pageSize) || pageSize < 1) {
    return DEFAULT_PAGE_SIZE;
  }
  return Math.min(100, Math.floor(pageSize));
}

/** 1 起始页码 → 偏移量 */
export function pageOffset(page: number, pageSize: number): number {
  return (normalizePage(page) - 1) * normalizePageSize(pageSize);
}

/** 生成全局曲目 id，格式 `<providerId>:<songId>`（与 Types.ets 的 Track.id 约定一致） */
export function makeTrackId(providerId: ProviderId, songId: string): string {
  return `${providerId}:${songId}`;
}

/**
 * 在线曲目的 TrackOrigin。
 * Navidrome 使用 Types.ets 专门保留的独立来源值，其余在线 provider 归为 ONLINE；
 * 播放层只区分 LOCAL 与非 LOCAL，因此这个区分不影响播放。
 */
export function originOf(providerId: ProviderId): TrackOrigin {
  return providerId === ProviderId.NAVIDROME ? TrackOrigin.NAVidrome : TrackOrigin.ONLINE;
}
