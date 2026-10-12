/**
 * Folia HarmonyOS - 在线音乐 provider 配置
 *
 * 上游把 provider 配置散落在 `localStorage`（`navidrome_config`、`VITE_NETEASE_API_BASE`、
 * `KUGOU_API_SESSION_V2` 等）。HarmonyOS 侧统一收敛到本文件，用 `@kit.ArkData` 的
 * `preferences` 持久化，store 名为 `folia_online`（对齐移植规范 §7 的存储键名迁移要求）。
 *
 * 包含：
 *   - Navidrome：serverUrl / username / password（Subsonic 必须用**明文密码**算 token）
 *   - 网易云：自建 NeteaseCloudMusicApi 的 baseUrl + 登录 cookie / 匿名 cookie
 *   - 酷狗：可选的自建 kugoumusicapi baseUrl（匿名搜索不需要它；/song/url、/search/lyric、
 *          /lyric 需要），以及 lite 登录态字段（尚未实现，先留位）
 *   - 全局：首选音质、当前 active provider
 *
 * ⚠️ 安全说明：Subsonic 的 token = md5(明文密码 + salt)，因此**必须**落盘明文密码才能工作。
 *    移植规范 §7 要求改为 `@ohos.security.huks` 加密存储；当前先用 preferences 明文存，
 *    // TODO(security)：接入 huks 加密后再落盘（见 porting/online-providers.md §3.3.1 与 §7）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import { ProviderId } from '../../core/Types';

const TAG: string = 'OnlineSettings';
const STORE_NAME: string = 'folia_online';

/** 首选音质默认值：与 SettingsStore 的默认值保持一致，避免两处默认值分裂 */
const DEFAULT_QUALITY: string = 'exhigh';

const KEY_NAVIDROME_SERVER: string = 'navidrome_server_url';
const KEY_NAVIDROME_USER: string = 'navidrome_username';
const KEY_NAVIDROME_PASSWORD: string = 'navidrome_password';
const KEY_NETEASE_BASE: string = 'netease_base_url';
const KEY_NETEASE_COOKIE: string = 'netease_cookie';
const KEY_NETEASE_ANON_COOKIE: string = 'netease_anonymous_cookie';
const KEY_KUGOU_API_BASE: string = 'kugou_api_base';
const KEY_KUGOU_DFID: string = 'kugou_dfid';
const KEY_KUGOU_USERID: string = 'kugou_userid';
const KEY_KUGOU_TOKEN: string = 'kugou_token';
const KEY_QUALITY: string = 'online_quality';
const KEY_ACTIVE_PROVIDER: string = 'active_provider_id';

/** Navidrome 配置（password 是明文，见文件头安全说明） */
export interface NavidromeSettings {
  serverUrl: string;
  username: string;
  password: string;
}

/** 网易云配置：只指向自建/自托管的 NeteaseCloudMusicApi，端侧不做 weapi/eapi 加密 */
export interface NeteaseSettings {
  baseUrl: string;
  /** 登录 cookie（形如 `MUSIC_U=xxx; __csrf=yyy`） */
  cookie: string;
  /** 匿名 cookie（上游 /register/anonimous 的产物，响应里必须含 MUSIC_A） */
  anonymousCookie: string;
}

/** 酷狗配置 */
export interface KugouSettings {
  /** 可选：自建 kugoumusicapi 服务地址（等价于上游 VITE_KUGOU_API_BASE）；匿名搜索不需要它 */
  apiBase: string;
  /** ⚠️ 以下三项属于 lite 登录态，当前尚未实现（见 KugouProvider 的 TODO(lite-login)） */
  dfid: string;
  userid: string;
  token: string;
}

/** 在线层配置快照 */
export interface OnlineSettingsSnapshot {
  navidrome: NavidromeSettings;
  netease: NeteaseSettings;
  kugou: KugouSettings;
  quality: string;
  activeProviderId: ProviderId;
}

/** 每次返回一份全新的默认快照，避免多个持有者共享同一个可变对象 */
function createDefaultSnapshot(): OnlineSettingsSnapshot {
  const navidrome: NavidromeSettings = { serverUrl: '', username: '', password: '' };
  const netease: NeteaseSettings = { baseUrl: '', cookie: '', anonymousCookie: '' };
  const kugou: KugouSettings = { apiBase: '', dfid: '', userid: '', token: '' };
  const snapshot: OnlineSettingsSnapshot = {
    navidrome: navidrome,
    netease: netease,
    kugou: kugou,
    quality: DEFAULT_QUALITY,
    // 默认值给 NAVIDROME：OmniRouter 会检查是否已配置，未配置就回落到第一个可用的 provider
    activeProviderId: ProviderId.NAVIDROME
  };
  return snapshot;
}

/** 字符串 → ProviderId；未知值回落到 KUGOU（匿名能力永远可用） */
function parseProviderId(raw: string): ProviderId {
  const netease: string = ProviderId.NETEASE;
  const kugou: string = ProviderId.KUGOU;
  const navidrome: string = ProviderId.NAVIDROME;
  const local: string = ProviderId.LOCAL;
  if (raw === netease) {
    return ProviderId.NETEASE;
  }
  if (raw === navidrome) {
    return ProviderId.NAVIDROME;
  }
  if (raw === local) {
    return ProviderId.LOCAL;
  }
  if (raw === kugou) {
    return ProviderId.KUGOU;
  }
  return ProviderId.KUGOU;
}

/** 去掉首尾空白 */
function trimmed(value: string): string {
  return value.trim();
}

/** 在线音乐配置holder（全局单例见文件末的 onlineSettings） */
export class OnlineSettings {
  private store: preferences.Preferences | undefined = undefined;
  private cache: OnlineSettingsSnapshot = createDefaultSnapshot();

  /** 由 AppBootstrap 在启动时调用；失败不致命，只是退化成「未配置」 */
  async init(context: common.UIAbilityContext): Promise<void> {
    const options: preferences.Options = { name: STORE_NAME };
    try {
      this.store = preferences.getPreferencesSync(context, options);
      this.reload();
      Logger.info(TAG, 'online settings loaded');
    } catch (error) {
      Logger.err(TAG, 'init preferences', error as Error);
      this.store = undefined;
    }
  }

  /** 是否已经成功打开 preferences（未打开时所有写入都会被丢弃，读取走内存缓存） */
  isReady(): boolean {
    return this.store !== undefined;
  }

  get(): OnlineSettingsSnapshot {
    return this.cache;
  }

  getQuality(): string {
    return this.cache.quality.length === 0 ? DEFAULT_QUALITY : this.cache.quality;
  }

  setQuality(quality: string): void {
    this.cache.quality = trimmed(quality);
    this.persistString(KEY_QUALITY, this.cache.quality);
  }

  getActiveProviderId(): ProviderId {
    return this.cache.activeProviderId;
  }

  setActiveProviderId(providerId: ProviderId): void {
    this.cache.activeProviderId = providerId;
    this.persistString(KEY_ACTIVE_PROVIDER, providerId);
  }

  // -------------------------------------------------------------------------
  // Navidrome
  // -------------------------------------------------------------------------

  getNavidrome(): NavidromeSettings {
    return this.cache.navidrome;
  }

  hasNavidrome(): boolean {
    const config: NavidromeSettings = this.cache.navidrome;
    return config.serverUrl.length > 0 && config.username.length > 0;
  }

  setNavidrome(serverUrl: string, username: string, password: string): void {
    this.cache.navidrome.serverUrl = trimmed(serverUrl);
    this.cache.navidrome.username = trimmed(username);
    this.cache.navidrome.password = password;
    this.persistString(KEY_NAVIDROME_SERVER, this.cache.navidrome.serverUrl);
    this.persistString(KEY_NAVIDROME_USER, this.cache.navidrome.username);
    // 密码单独走 putSync，且永远不进日志
    this.persistString(KEY_NAVIDROME_PASSWORD, this.cache.navidrome.password);
  }

  clearNavidrome(): void {
    this.cache.navidrome.serverUrl = '';
    this.cache.navidrome.username = '';
    this.cache.navidrome.password = '';
    this.persistString(KEY_NAVIDROME_SERVER, '');
    this.persistString(KEY_NAVIDROME_USER, '');
    this.persistString(KEY_NAVIDROME_PASSWORD, '');
  }

  // -------------------------------------------------------------------------
  // 网易云（HTTP 客户端 + 自建服务地址）
  // -------------------------------------------------------------------------

  getNetease(): NeteaseSettings {
    return this.cache.netease;
  }

  hasNeteaseServer(): boolean {
    return this.cache.netease.baseUrl.length > 0;
  }

  setNeteaseBaseUrl(baseUrl: string): void {
    this.cache.netease.baseUrl = trimmed(baseUrl);
    this.persistString(KEY_NETEASE_BASE, this.cache.netease.baseUrl);
  }

  setNeteaseCookie(cookie: string): void {
    this.cache.netease.cookie = trimmed(cookie);
    this.persistString(KEY_NETEASE_COOKIE, this.cache.netease.cookie);
  }

  setNeteaseAnonymousCookie(cookie: string): void {
    this.cache.netease.anonymousCookie = trimmed(cookie);
    this.persistString(KEY_NETEASE_ANON_COOKIE, this.cache.netease.anonymousCookie);
  }

  clearNeteaseCookie(): void {
    this.cache.netease.cookie = '';
    this.cache.netease.anonymousCookie = '';
    this.persistString(KEY_NETEASE_COOKIE, '');
    this.persistString(KEY_NETEASE_ANON_COOKIE, '');
  }

  // -------------------------------------------------------------------------
  // 酷狗
  // -------------------------------------------------------------------------

  getKugou(): KugouSettings {
    return this.cache.kugou;
  }

  hasKugouServer(): boolean {
    return this.cache.kugou.apiBase.length > 0;
  }

  setKugouApiBase(apiBase: string): void {
    this.cache.kugou.apiBase = trimmed(apiBase);
    this.persistString(KEY_KUGOU_API_BASE, this.cache.kugou.apiBase);
  }

  /** lite 登录态字段（尚未实现登录流程，预留给后续 TODO(lite-login)） */
  setKugouSession(dfid: string, userid: string, token: string): void {
    this.cache.kugou.dfid = trimmed(dfid);
    this.cache.kugou.userid = trimmed(userid);
    this.cache.kugou.token = trimmed(token);
    this.persistString(KEY_KUGOU_DFID, this.cache.kugou.dfid);
    this.persistString(KEY_KUGOU_USERID, this.cache.kugou.userid);
    this.persistString(KEY_KUGOU_TOKEN, this.cache.kugou.token);
  }

  clearKugouSession(): void {
    this.setKugouSession('', '', '');
  }

  // -------------------------------------------------------------------------
  // 内部：读写
  // -------------------------------------------------------------------------

  private reload(): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const snapshot: OnlineSettingsSnapshot = createDefaultSnapshot();
    snapshot.navidrome.serverUrl = store.getSync(KEY_NAVIDROME_SERVER, snapshot.navidrome.serverUrl) as string;
    snapshot.navidrome.username = store.getSync(KEY_NAVIDROME_USER, snapshot.navidrome.username) as string;
    snapshot.navidrome.password = store.getSync(KEY_NAVIDROME_PASSWORD, snapshot.navidrome.password) as string;
    snapshot.netease.baseUrl = store.getSync(KEY_NETEASE_BASE, snapshot.netease.baseUrl) as string;
    snapshot.netease.cookie = store.getSync(KEY_NETEASE_COOKIE, snapshot.netease.cookie) as string;
    snapshot.netease.anonymousCookie =
      store.getSync(KEY_NETEASE_ANON_COOKIE, snapshot.netease.anonymousCookie) as string;
    snapshot.kugou.apiBase = store.getSync(KEY_KUGOU_API_BASE, snapshot.kugou.apiBase) as string;
    snapshot.kugou.dfid = store.getSync(KEY_KUGOU_DFID, snapshot.kugou.dfid) as string;
    snapshot.kugou.userid = store.getSync(KEY_KUGOU_USERID, snapshot.kugou.userid) as string;
    snapshot.kugou.token = store.getSync(KEY_KUGOU_TOKEN, snapshot.kugou.token) as string;
    snapshot.quality = store.getSync(KEY_QUALITY, snapshot.quality) as string;
    const defaultProvider: string = ProviderId.NAVIDROME;
    const storedProvider: string = store.getSync(KEY_ACTIVE_PROVIDER, defaultProvider) as string;
    snapshot.activeProviderId = parseProviderId(storedProvider);
    this.cache = snapshot;
  }

  private persistString(key: string, value: string): void {
    const store = this.store;
    if (store === undefined) {
      Logger.warn(TAG, 'preferences 未初始化，配置仅保存在内存中');
      return;
    }
    try {
      store.putSync(key, value);
      store.flush((err: BusinessError) => {
        if (err !== undefined && err.code !== 0) {
          Logger.err(TAG, 'flush', err as Error);
        }
      });
    } catch (error) {
      Logger.err(TAG, `persist ${key}`, error as Error);
    }
  }
}

/** 全局单例 */
export const onlineSettings: OnlineSettings = new OnlineSettings();
