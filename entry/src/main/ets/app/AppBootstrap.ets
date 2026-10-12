/**
 * Folia HarmonyOS - 应用启动引导
 *
 * 负责把各服务拼装起来并注入依赖：
 *   1. 初始化设置存储
 *   2. 初始化本地音乐库
 *   3. 初始化在线音乐（Omni 路由 + 各 provider）
 *   4. 给播放控制器注入「音源解析器」与「歌词加载器」
 *
 * 之所以集中在这里，是为了避免播放控制器直接依赖 provider 层——
 * 控制器只需要知道「给一首歌，返回一个可播放的音源」。
 */
import { common } from '@kit.AbilityKit';
import { Logger } from '../core/Logger';
import { LyricPayload, ProviderId, Track, TrackOrigin } from '../core/Types';
import { AudioSource } from '../services/player/AudioEngine';
import { playbackController } from '../services/player/PlaybackController';
import { SettingsStore, settingsStore } from '../services/settings/SettingsStore';
import { localLibraryService, LocalLibraryService } from '../services/library/LocalLibraryService';
import { omniRouter } from '../services/online/OmniRouter';
import { onlineSettings } from '../services/online/OnlineSettings';
import { NavidromeProvider } from '../services/online/NavidromeProvider';
import { KugouProvider } from '../services/online/KugouProvider';
import { NeteaseProvider } from '../services/online/NeteaseProvider';
import { appUiState, AppUiState } from '../state/AppUiState';

const TAG: string = 'AppBootstrap';

/** 全局单例化的引导器 */
class AppBootstrap {
  private initialized: boolean = false;

  async boot(context: common.UIAbilityContext, uiState: AppUiState): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    const settings: SettingsStore = settingsStore;
    try {
      await settings.init(context);
      await onlineSettings.init(context);
      await localLibraryService.init(context);
      this.registerProviders(context);
      playbackController.setResolvers(
        (track: Track) => this.resolveAudioSource(track),
        (track: Track) => this.resolveLyric(track)
      );
      await playbackController.attach(context);
      this.applySettings(settings);
      uiState.markReady();
      Logger.info(TAG, 'boot completed');
    } catch (error) {
      Logger.err(TAG, 'boot', error as Error);
      uiState.markFailed(`初始化失败：${(error as Error).message}`);
    }
  }

  /** 注册在线 provider；顺序与上游一致：netease -> kugou -> navidrome */
  private registerProviders(context: common.UIAbilityContext): void {
    omniRouter.register(new NeteaseProvider(context));
    omniRouter.register(new KugouProvider(context));
    omniRouter.register(new NavidromeProvider(context));
    // 有 Navidrome 配置时优先使用自建库，否则用酷狗匿名能力（无需登录即可搜索/试听）
    if (onlineSettings.hasNavidrome()) {
      omniRouter.setActiveProvider(ProviderId.NAVIDROME);
    } else if (onlineSettings.hasNeteaseServer()) {
      omniRouter.setActiveProvider(ProviderId.NETEASE);
    } else {
      omniRouter.setActiveProvider(ProviderId.KUGOU);
    }
  }

  private applySettings(settings: SettingsStore): void {
    playbackController.setLyricOffset(settings.get().lyricOffset);
    playbackController.setVolume(1.0);
    // 音质以 SettingsStore 为准，启动时同步给在线层，避免两处配置长期分叉；
    // 运行期在设置页改动时 SettingsView 会同时写两处。
    onlineSettings.setQuality(settings.get().quality);
  }

  /**
   * 把 Track 解析成可播放音源。
   *  - 本地曲目：直接给出沙箱路径，由 AudioEngine 走 fdSrc；
   *  - 在线曲目：交给 Omni 路由重新解析直链（直链会过期，不能缓存）。
   */
  private async resolveAudioSource(track: Track): Promise<AudioSource> {
    if (track.origin === TrackOrigin.LOCAL) {
      if (track.fileUri === undefined || track.fileUri.length === 0) {
        throw new Error(`本地曲目缺少文件路径：${track.title}`);
      }
      const source: AudioSource = { filePath: track.fileUri };
      return source;
    }
    const resolved = await omniRouter.resolveAudioSource(
      {
        providerId: track.providerId,
        songId: track.songId
      },
      onlineSettings.getQuality()
    );
    const source: AudioSource = {
      url: resolved.url,
      headers: resolved.headers
    };
    return source;
  }

  /**
   * 获取歌词。
   *  - 本地曲目：优先同目录同名侧车文件，其次内嵌歌词；
   *  - 在线曲目：走 Omni 路由。
   */
  private async resolveLyric(track: Track): Promise<LyricPayload | undefined> {
    if (track.origin === TrackOrigin.LOCAL) {
      const local = await localLibraryService.loadLyricFor(track);
      if (local !== undefined) {
        return local;
      }
      // 本地无歌词时，尝试用在线匹配（上游的「智能歌词匹配」）
      return omniRouter.fetchLyricByBestMatch(track);
    }
    return omniRouter.fetchLyric(track.providerId, track.songId);
  }

  async shutdown(): Promise<void> {
    await playbackController.release();
    this.initialized = false;
  }
}

export const appBootstrap: AppBootstrap = new AppBootstrap();

/** 便捷出口，供 EntryAbility 使用 */
export async function bootApp(context: common.UIAbilityContext): Promise<void> {
  await appBootstrap.boot(context, appUiState);
}
