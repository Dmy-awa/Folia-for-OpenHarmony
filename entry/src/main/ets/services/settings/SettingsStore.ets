/**
 * Folia HarmonyOS - 应用设置
 *
 * 使用 @kit.ArkData 的 preferences 做键值持久化。
 * 所有读写都是同步接口，避免设置读取成为 UI 卡顿来源。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import { AppSettings } from '../../core/Types';

const TAG: string = 'SettingsStore';
const STORE_NAME: string = 'folia_settings';

const KEY_QUALITY: string = 'quality';
const KEY_WORD_BY_WORD: string = 'word_by_word_lyric';
const KEY_LYRIC_OFFSET: string = 'lyric_offset';
const KEY_LYRIC_THEME: string = 'lyric_theme';
const KEY_CC_LYRIC: string = 'show_lyric_in_control_center';
const KEY_BACKGROUND: string = 'background_playback';
const KEY_AUTO_HIDE: string = 'auto_hide_chrome';

/** 默认设置 */
const DEFAULTS: AppSettings = {
  quality: 'exhigh',
  wordByWordLyric: true,
  lyricOffset: 0,
  lyricTheme: 'fume',
  showLyricInControlCenter: true,
  backgroundPlayback: true,
  autoHideChrome: false
};

export class SettingsStore {
  private store: preferences.Preferences | undefined = undefined;
  private cache: AppSettings = DEFAULTS;

  async init(context: common.UIAbilityContext): Promise<void> {
    const options: preferences.Options = { name: STORE_NAME };
    try {
      this.store = preferences.getPreferencesSync(context, options);
      this.reload();
      Logger.info(TAG, 'settings loaded');
    } catch (error) {
      Logger.err(TAG, 'init preferences', error as Error);
      this.store = undefined;
    }
  }

  private reload(): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    const settings: AppSettings = {
      quality: store.getSync(KEY_QUALITY, DEFAULTS.quality) as string,
      wordByWordLyric: store.getSync(KEY_WORD_BY_WORD, DEFAULTS.wordByWordLyric) as boolean,
      lyricOffset: store.getSync(KEY_LYRIC_OFFSET, DEFAULTS.lyricOffset) as number,
      lyricTheme: store.getSync(KEY_LYRIC_THEME, DEFAULTS.lyricTheme) as string,
      showLyricInControlCenter: store.getSync(KEY_CC_LYRIC, DEFAULTS.showLyricInControlCenter) as boolean,
      backgroundPlayback: store.getSync(KEY_BACKGROUND, DEFAULTS.backgroundPlayback) as boolean,
      autoHideChrome: store.getSync(KEY_AUTO_HIDE, DEFAULTS.autoHideChrome) as boolean
    };
    this.cache = settings;
  }

  private persist(): void {
    const store = this.store;
    if (store === undefined) {
      return;
    }
    try {
      store.putSync(KEY_QUALITY, this.cache.quality);
      store.putSync(KEY_WORD_BY_WORD, this.cache.wordByWordLyric);
      store.putSync(KEY_LYRIC_OFFSET, this.cache.lyricOffset);
      store.putSync(KEY_LYRIC_THEME, this.cache.lyricTheme);
      store.putSync(KEY_CC_LYRIC, this.cache.showLyricInControlCenter);
      store.putSync(KEY_BACKGROUND, this.cache.backgroundPlayback);
      store.putSync(KEY_AUTO_HIDE, this.cache.autoHideChrome);
      store.flush((err: BusinessError) => {
        if (err !== undefined && err.code !== 0) {
          Logger.err(TAG, 'flush', err as Error);
        }
      });
    } catch (error) {
      Logger.err(TAG, 'persist', error as Error);
    }
  }

  get(): AppSettings {
    return this.cache;
  }

  setQuality(quality: string): void {
    this.cache.quality = quality;
    this.persist();
  }

  setWordByWordLyric(enabled: boolean): void {
    this.cache.wordByWordLyric = enabled;
    this.persist();
  }

  setLyricOffset(offsetMs: number): void {
    this.cache.lyricOffset = Math.max(-2000, Math.min(2000, offsetMs));
    this.persist();
  }

  setLyricTheme(themeId: string): void {
    this.cache.lyricTheme = themeId;
    this.persist();
  }

  setShowLyricInControlCenter(enabled: boolean): void {
    this.cache.showLyricInControlCenter = enabled;
    this.persist();
  }

  setBackgroundPlayback(enabled: boolean): void {
    this.cache.backgroundPlayback = enabled;
    this.persist();
  }

  setAutoHideChrome(enabled: boolean): void {
    this.cache.autoHideChrome = enabled;
    this.persist();
  }
}

export const settingsStore: SettingsStore = new SettingsStore();
