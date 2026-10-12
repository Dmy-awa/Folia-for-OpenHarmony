/**
 * Folia HarmonyOS - Omni 在线音乐路由（facade）
 *
 * 对齐上游 `src/services/onlineMusic/omni.ts`，是**在线音乐对外唯一入口**：
 *   - provider 注册表（注册顺序决定 UI 列表顺序：netease → kugou → navidrome）；
 *   - 歌曲操作按 `(providerId, songId)` 三元组身份路由，**不按 active provider**；
 *   - 集合/搜索类操作按 active provider 路由；
 *   - **生成号（generation）防护**：provider 切换后丢弃晚到的响应（上游 `omni.ts:99-110`）。
 *
 * 硬性架构约束（移植规范 §2.2）：
 *   UI / ViewModel 只能调用本文件，禁止 import 任何 `XxxProvider` / transport / raw API。
 *
 * ArkTS 替换说明：上游用 `DOMException('...', 'AbortError')` 表示「晚到响应被丢弃」，
 * ArkTS 没有 DOMException，改用 `ProviderError(code = 'abort')`，语义完全一致。
 */
import {
  LyricPayload,
  OnlineMusicProvider,
  PlaybackSourceRef,
  ProviderAudioSource,
  ProviderCapabilities,
  ProviderError,
  ProviderId,
  ProviderPage,
  SearchAlbumItem,
  SearchArtistItem,
  SearchResult,
  SearchSongItem,
  Track,
  TrackOrigin
} from '../../core/Types';
import { Logger } from '../../core/Logger';
import { onlineSettings } from './OnlineSettings';
import { toProviderError } from './HttpTransport';
import {
  emptyPage,
  emptySearchResult,
  makeTrackId,
  OnlineProviderEx,
  originOf,
  ProviderAlbumDetail,
  ProviderArtistDetail,
  ProviderCodes,
  ProviderPlaylistSummary
} from './OnlineProvider';

const TAG: string = 'OmniRouter';

/** UIS 列表固定顺序：网易云 → 酷狗 → Navidrome（对齐上游注册顺序） */
const PROVIDER_ORDER: ProviderId[] = [ProviderId.NETEASE, ProviderId.KUGOU, ProviderId.NAVIDROME];

/** 智能歌词匹配时每个 provider 取几条候选 */
const LYRIC_MATCH_CANDIDATES: number = 5;

/** 构造 Track 时的可选补充字段（搜索阶段拿不到封面尺寸/直链等） */
export interface TrackBuildExtra {
  title?: string;
  artist?: string;
  artists?: string[];
  album?: string;
  albumId?: string;
  durationMs?: number;
  coverUrl?: string;
  quality?: string;
  streamUrl?: string;
  headers?: Record<string, string>;
}

/** 归一化文本，用于标题比对（去掉空白 + 转小写） */
function normalizeForMatch(text: string): string {
  return text.replace(/\s+/g, '').toLowerCase();
}

/** 把 provider 拼接的歌手串拆回列表（只用 ' / ' 作为分隔，避免把 AC/DC 拆坏） */
function splitArtists(raw: string): string[] {
  const segments: string[] = raw.split(' / ');
  const parts: string[] = [];
  for (let index = 0; index < segments.length; index++) {
    const name: string = segments[index].trim();
    if (name.length > 0) {
      parts.push(name);
    }
  }
  if (parts.length === 0) {
    parts.push(raw);
  }
  return parts;
}

/** 在候选里挑最匹配的一首：先找标题完全相同，其次取第一条 */
function pickBestMatch(songs: SearchSongItem[], title: string): SearchSongItem | undefined {
  if (songs.length === 0) {
    return undefined;
  }
  const target: string = normalizeForMatch(title);
  for (let index = 0; index < songs.length; index++) {
    if (normalizeForMatch(songs[index].title) === target) {
      return songs[index];
    }
  }
  return songs[0];
}

/** provider 排序权重（未登记的 provider 排在最后） */
function orderWeight(providerId: ProviderId): number {
  for (let index = 0; index < PROVIDER_ORDER.length; index++) {
    if (PROVIDER_ORDER[index] === providerId) {
      return index;
    }
  }
  return PROVIDER_ORDER.length;
}

/** Omni 路由 */
export class OmniRouter {
  private providers: Map<ProviderId, OnlineProviderEx> = new Map();
  /** 注册表版本号：注册/注销都会 +1，UI 据此刷新 provider 列表 */
  private registryVersion: number = 0;
  /** 生成号：provider 切换时 +1，用于丢弃晚到响应 */
  private generation: number = 0;

  // -------------------------------------------------------------------------
  // 注册表
  // -------------------------------------------------------------------------

  /**
   * 注册 provider。
   * 参数类型按对外契约是 core 的 `OnlineMusicProvider`，但 Omni 需要使用扩展能力
   * （配置检查 / 连通性探测 / 单曲详情 …），因此这里做一次受控收窄并做运行时校验。
   */
  register(provider: OnlineMusicProvider): void {
    const extended: OnlineProviderEx = provider as OnlineProviderEx;
    if (extended.isConfigured === undefined || extended.ping === undefined) {
      throw new ProviderError(
        provider.id,
        ProviderCodes.UNSUPPORTED,
        `provider ${provider.id} 未实现 Omni 扩展契约（OnlineProviderEx），无法注册`,
        false
      );
    }
    this.providers.set(provider.id, extended);
    this.registryVersion += 1;
    Logger.info(TAG, `provider 已注册：${provider.id}（共 ${this.providers.size} 个）`);
  }

  /** 注销 provider（Folium mod 之类的运行时增删场景） */
  unregister(providerId: ProviderId): void {
    if (this.providers.delete(providerId)) {
      this.registryVersion += 1;
      Logger.info(TAG, `provider 已注销：${providerId}`);
    }
  }

  hasProvider(providerId: ProviderId): boolean {
    return this.providers.has(providerId);
  }

  getProviderRegistryVersion(): number {
    return this.registryVersion;
  }

  /** 按固定顺序返回已注册的 provider */
  listProviders(): OnlineProviderEx[] {
    const all: OnlineProviderEx[] = [];
    this.providers.forEach((provider: OnlineProviderEx) => {
      all.push(provider);
    });
    all.sort((left: OnlineProviderEx, right: OnlineProviderEx): number => {
      const leftWeight: number = orderWeight(left.id);
      const rightWeight: number = orderWeight(right.id);
      if (leftWeight === rightWeight) {
        return 0;
      }
      return leftWeight < rightWeight ? -1 : 1;
    });
    return all;
  }

  private requireProvider(providerId: ProviderId): OnlineProviderEx {
    const provider: OnlineProviderEx | undefined = this.providers.get(providerId);
    if (provider === undefined) {
      throw new ProviderError(
        providerId,
        ProviderCodes.UNAVAILABLE,
        `在线音乐服务未初始化或未注册：${providerId}`,
        false
      );
    }
    return provider;
  }

  // -------------------------------------------------------------------------
  // active provider
  // -------------------------------------------------------------------------

  /**
   * 当前生效的 provider：
   *   1. 设置里保存的选择（且它已注册、已配置）；
   *   2. 否则按固定顺序取第一个已配置的；
   *   3. 全都没配置时，仍返回第一个已注册的（调用时会抛出「未配置」的中文错误）。
   */
  getActiveProvider(): ProviderId {
    const stored: ProviderId = onlineSettings.getActiveProviderId();
    const storedProvider: OnlineProviderEx | undefined = this.providers.get(stored);
    if (storedProvider !== undefined && storedProvider.isConfigured()) {
      return stored;
    }
    const ordered: OnlineProviderEx[] = this.listProviders();
    for (let index = 0; index < ordered.length; index++) {
      if (ordered[index].isConfigured()) {
        return ordered[index].id;
      }
    }
    if (ordered.length > 0) {
      return ordered[0].id;
    }
    return stored;
  }

  /** active provider 的实例（内部/诊断用） */
  getActiveProviderInstance(): OnlineProviderEx {
    return this.requireProvider(this.getActiveProvider());
  }

  setActiveProvider(providerId: ProviderId): void {
    if (!this.providers.has(providerId)) {
      Logger.warn(TAG, `provider ${providerId} 尚未注册，先写入设置，注册后生效`);
    }
    onlineSettings.setActiveProviderId(providerId);
    // 切换 provider 必须让在途请求作废（上游 omni.ts 的 account switch transaction）
    this.invalidateActiveRequests();
    Logger.info(TAG, `active provider 切换为 ${providerId}`);
  }

  isProviderConfigured(providerId: ProviderId): boolean {
    const provider: OnlineProviderEx | undefined = this.providers.get(providerId);
    return provider === undefined ? false : provider.isConfigured();
  }

  getProviderCapabilities(providerId: ProviderId): ProviderCapabilities {
    return this.requireProvider(providerId).capabilities;
  }

  getProviderLabel(providerId: ProviderId): string {
    const provider: OnlineProviderEx | undefined = this.providers.get(providerId);
    if (provider === undefined) {
      return `${providerId}`;
    }
    return provider.displayName;
  }

  // -------------------------------------------------------------------------
  // 生成号防护
  // -------------------------------------------------------------------------

  /** 生成号 +1：所有在途的 active-provider 请求都会在返回时被丢弃 */
  invalidateActiveRequests(): void {
    this.generation += 1;
  }

  getActiveRequestGeneration(): number {
    return this.generation;
  }

  /**
   * 在 active provider 上执行，并在结束后校验生成号与 provider 是否仍然一致。
   * 不一致 → 抛 `ProviderError(code='abort')`，调用方据此静默忽略（上游行为）。
   */
  private async withActiveProvider<T>(
    scene: string,
    run: (provider: OnlineProviderEx) => Promise<T>
  ): Promise<T> {
    const providerId: ProviderId = this.getActiveProvider();
    const generation: number = this.generation;
    const provider: OnlineProviderEx = this.requireProvider(providerId);

    let result: T;
    try {
      result = await run(provider);
    } catch (error) {
      throw toProviderError(providerId, scene, error as Error);
    }
    if (generation !== this.generation || providerId !== this.getActiveProvider()) {
      throw new ProviderError(providerId, ProviderCodes.ABORT, '在线音乐服务已切换，已丢弃晚到的响应', false);
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------------

  /** 用 active provider 搜索（page 为 1 起始） */
  async search(keyword: string, page: number, pageSize: number): Promise<SearchResult> {
    return this.withActiveProvider('在线搜索', async (provider: OnlineProviderEx): Promise<SearchResult> => {
      if (!provider.capabilities.search) {
        return emptySearchResult();
      }
      return provider.search(keyword, page, pageSize);
    });
  }

  /** 显式指定 provider 搜索（跨 provider 编排用，不受生成号防护影响，与上游一致） */
  async searchProvider(
    providerId: ProviderId,
    keyword: string,
    page: number,
    pageSize: number
  ): Promise<SearchResult> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    if (!provider.capabilities.search) {
      return emptySearchResult();
    }
    try {
      return await provider.search(keyword, page, pageSize);
    } catch (error) {
      throw toProviderError(providerId, '在线搜索', error as Error);
    }
  }

  /** active provider 的专辑搜索结果 */
  async searchAlbums(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchAlbumItem>> {
    return this.withActiveProvider(
      '专辑搜索',
      async (provider: OnlineProviderEx): Promise<ProviderPage<SearchAlbumItem>> => {
        if (provider.searchAlbums === undefined) {
          return emptyPage<SearchAlbumItem>();
        }
        return provider.searchAlbums(keyword, page, pageSize);
      }
    );
  }

  /** active provider 的歌手搜索结果 */
  async searchArtists(keyword: string, page: number, pageSize: number): Promise<ProviderPage<SearchArtistItem>> {
    return this.withActiveProvider(
      '歌手搜索',
      async (provider: OnlineProviderEx): Promise<ProviderPage<SearchArtistItem>> => {
        if (provider.searchArtists === undefined) {
          return emptyPage<SearchArtistItem>();
        }
        return provider.searchArtists(keyword, page, pageSize);
      }
    );
  }

  // -------------------------------------------------------------------------
  // 音源 / 歌词 / 详情
  // -------------------------------------------------------------------------

  /**
   * 解析在线音源。
   * **严格按 `ref.providerId` 路由**（在线歌曲身份是 (providerId, songId) 三元组，不是裸 id）。
   * 直链可能过期，因此每次播放都重新解析；ref.streamUrl 仅作为 provider 未配置时的兜底。
   */
  async resolveAudioSource(ref: PlaybackSourceRef, quality: string): Promise<ProviderAudioSource> {
    if (ref.providerId === ProviderId.LOCAL) {
      throw new ProviderError(
        ProviderId.LOCAL,
        ProviderCodes.UNSUPPORTED,
        '本地曲目不经过在线路由，请直接使用本地文件路径',
        false
      );
    }
    if (ref.songId.length === 0) {
      throw new ProviderError(ref.providerId, ProviderCodes.UNAVAILABLE, '曲目缺少在线 id，无法解析音源', false);
    }
    const provider: OnlineProviderEx = this.requireProvider(ref.providerId);

    try {
      const source: ProviderAudioSource = await provider.resolveAudioSource(ref.songId, quality);
      if (source.url.length === 0) {
        throw new ProviderError(ref.providerId, ProviderCodes.UNAVAILABLE, 'provider 返回了空的播放地址', true);
      }
      if (source.headers === undefined && ref.headers !== undefined) {
        source.headers = ref.headers;
      }
      return source;
    } catch (error) {
      throw toProviderError(ref.providerId, '解析在线音源', error as Error);
    }
  }

  /** 取歌词（显式 provider） */
  async fetchLyric(providerId: ProviderId, songId: string): Promise<LyricPayload> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    if (!provider.capabilities.lyric) {
      throw new ProviderError(
        providerId,
        ProviderCodes.UNSUPPORTED,
        `${provider.displayName} 不支持在线歌词`,
        false
      );
    }
    try {
      return await provider.fetchLyric(songId);
    } catch (error) {
      throw toProviderError(providerId, '获取歌词', error as Error);
    }
  }

  /** 取单曲详情；provider 查不到时抛 NOT_FOUND（对外契约是 Promise<Track>，不返回 null） */
  async fetchSongDetail(providerId: ProviderId, songId: string): Promise<Track> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    let detail: Track | null;
    try {
      detail = await provider.fetchSongDetail(songId);
    } catch (error) {
      throw toProviderError(providerId, '获取单曲详情', error as Error);
    }
    if (detail === null) {
      throw new ProviderError(
        providerId,
        ProviderCodes.NOT_FOUND,
        `${provider.displayName} 中找不到该曲目（id=${songId}）`,
        false
      );
    }
    return detail;
  }

  /** 专辑详情（provider 未实现时抛 UNSUPPORTED） */
  async fetchAlbum(providerId: ProviderId, albumId: string): Promise<ProviderAlbumDetail | null> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    if (provider.fetchAlbum === undefined) {
      throw new ProviderError(
        providerId,
        ProviderCodes.UNSUPPORTED,
        `${provider.displayName} 不支持专辑详情`,
        false
      );
    }
    try {
      return await provider.fetchAlbum(albumId);
    } catch (error) {
      throw toProviderError(providerId, '获取专辑详情', error as Error);
    }
  }

  /** 歌手详情 */
  async fetchArtist(providerId: ProviderId, artistId: string): Promise<ProviderArtistDetail | null> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    if (provider.fetchArtist === undefined) {
      throw new ProviderError(
        providerId,
        ProviderCodes.UNSUPPORTED,
        `${provider.displayName} 不支持歌手详情`,
        false
      );
    }
    try {
      return await provider.fetchArtist(artistId);
    } catch (error) {
      throw toProviderError(providerId, '获取歌手详情', error as Error);
    }
  }

  /** 歌单列表；需要登录态的 provider 会抛 AUTH_REQUIRED */
  async getPlaylists(providerId: ProviderId): Promise<ProviderPlaylistSummary[]> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    if (provider.getPlaylists === undefined) {
      throw new ProviderError(
        providerId,
        ProviderCodes.UNSUPPORTED,
        `${provider.displayName} 不支持歌单列表`,
        false
      );
    }
    try {
      return await provider.getPlaylists();
    } catch (error) {
      throw toProviderError(providerId, '获取歌单列表', error as Error);
    }
  }

  /** 连通性探测 */
  async ping(providerId: ProviderId): Promise<string> {
    const provider: OnlineProviderEx = this.requireProvider(providerId);
    try {
      return await provider.ping();
    } catch (error) {
      throw toProviderError(providerId, '连通性探测', error as Error);
    }
  }

  // -------------------------------------------------------------------------
  // Track 构造
  // -------------------------------------------------------------------------

  /** 由搜索结果构造可播放 Track（UI 点击搜索结果时调用） */
  buildTrackFromSearch(item: SearchSongItem, providerId: ProviderId): Track {
    const artists: string[] = splitArtists(item.artist);
    const track: Track = {
      id: makeTrackId(providerId, item.id),
      title: item.title,
      artist: item.artist,
      artists: artists,
      album: item.album,
      duration: item.duration,
      origin: originOf(providerId),
      providerId: providerId,
      songId: item.id
    };
    if (item.coverUrl !== undefined && item.coverUrl.length > 0) {
      track.cover = { url: item.coverUrl };
    }
    if (item.albumId !== undefined && item.albumId.length > 0) {
      track.albumId = item.albumId;
    }
    return track;
  }

  /** 由 (providerId, songId) + 补充字段构造 Track（手动拼装/缓存回填时调用） */
  buildTrack(providerId: ProviderId, songId: string, extra: TrackBuildExtra): Track {
    const title: string = extra.title === undefined ? '未知曲目' : extra.title;
    const artist: string = extra.artist === undefined ? '未知艺术家' : extra.artist;
    let artists: string[] = extra.artists === undefined ? [artist] : extra.artists;
    if (artists.length === 0) {
      artists = [artist];
    }
    const track: Track = {
      id: makeTrackId(providerId, songId),
      title: title,
      artist: artist,
      artists: artists,
      album: extra.album === undefined ? '' : extra.album,
      duration: extra.durationMs === undefined ? 0 : extra.durationMs,
      origin: originOf(providerId),
      providerId: providerId,
      songId: songId
    };
    if (extra.albumId !== undefined && extra.albumId.length > 0) {
      track.albumId = extra.albumId;
    }
    if (extra.coverUrl !== undefined && extra.coverUrl.length > 0) {
      track.cover = { url: extra.coverUrl };
    }
    if (extra.quality !== undefined && extra.quality.length > 0) {
      track.quality = extra.quality;
    }
    return track;
  }

  // -------------------------------------------------------------------------
  // 智能歌词匹配
  // -------------------------------------------------------------------------

  /**
   * 给本地歌曲做「智能歌词匹配」：按固定顺序依次尝试各在线源，返回第一个有内容的歌词。
   * **永不 reject**：找不到、未配置、网络失败一律返回 undefined（上游同语义）。
   */
  async fetchLyricByBestMatch(track: Track): Promise<LyricPayload | undefined> {
    // 已经是在线曲目：优先用自己 provider 的歌词
    if (track.origin !== TrackOrigin.LOCAL && this.hasProvider(track.providerId)) {
      try {
        const own: LyricPayload = await this.fetchLyric(track.providerId, track.songId);
        if (own.lyric.length > 0) {
          return own;
        }
      } catch (error) {
        Logger.warn(TAG, `自身 provider 取歌词失败，转为跨源匹配：${track.providerId}`);
      }
    }

    const keyword: string = track.artist.length > 0 ? `${track.title} ${track.artist}` : track.title;
    const ordered: OnlineProviderEx[] = this.listProviders();
    for (let index = 0; index < ordered.length; index++) {
      const provider: OnlineProviderEx = ordered[index];
      if (!provider.capabilities.search || !provider.capabilities.lyric) {
        continue;
      }
      if (!provider.isConfigured()) {
        continue;
      }
      try {
        const result: SearchResult = await provider.search(keyword, 1, LYRIC_MATCH_CANDIDATES);
        const best: SearchSongItem | undefined = pickBestMatch(result.songs, track.title);
        if (best === undefined) {
          continue;
        }
        const payload: LyricPayload = await provider.fetchLyric(best.id);
        if (payload.lyric.length > 0) {
          Logger.info(TAG, `智能歌词匹配命中：${provider.id} / ${best.id}`);
          return payload;
        }
      } catch (error) {
        // 单个源失败（含「未配置」的 ProviderError）绝不能中断整条匹配链
        Logger.warn(TAG, `${provider.id} 歌词匹配失败，尝试下一个源`);
      }
    }
    return undefined;
  }
}

/**
 * 进程内单例：UI 与 AppBootstrap 都从这里取
 */
export const omniRouter: OmniRouter = new OmniRouter();
