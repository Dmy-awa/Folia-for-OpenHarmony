/**
 * Folia HarmonyOS - 媒体播控服务（AVSession）
 *
 * 这是「控制栏 / 播控中心 / 锁屏卡片 / 耳机按键」需求的实现核心。
 *
 * 结论（基于 OpenHarmony 官方文档核实）：
 *  - 正确接入 AVSession 并进入播放状态后，**通知中心与锁屏的播控卡片由系统自动发送**，
 *    应用不需要也不能主动发送媒体通知，因此本文件只负责「上报状态 + 注册命令」。
 *  - ⚠️「灵动岛 / 实况窗」在 OpenHarmony 文档中与 AVSession 无任何关联描述，
 *    本工程不臆造该能力；移动端可获得的等价物就是 AVSession 播控卡片。
 *  - ⚠️ AVMusicTemplate（音频模板）仅 API 23+ 的 Car 设备工程可用，且不渲染歌词，
 *    因此本工程不使用它，改为通过 AVMetadata.lyric 让播控中心显示歌词。
 *
 * 硬性顺序要求：createAVSession -> setAVMetadata -> setAVPlaybackState
 *              -> 注册控制命令 -> 最后 activate()。
 */
import { avSession } from '@kit.AVSessionKit';
import { audio } from '@kit.AudioKit';
import { KeyEvent } from '@kit.InputKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import {
  PlaybackSnapshot,
  PlaybackStatus,
  QueueItem,
  RepeatMode,
  Track
} from '../../core/Types';

const TAG: string = 'MediaSessionService';

/** 播控中心下发的命令，由播放控制器实现 */
export interface MediaSessionHost {
  onRemotePlay(): void;
  onRemotePause(): void;
  onRemoteStop(): void;
  onRemoteNext(): void;
  onRemotePrevious(): void;
  /** 单位：毫秒 */
  onRemoteSeek(positionMs: number): void;
  onRemoteSetSpeed(speed: number): void;
  onRemoteSetRepeat(mode: RepeatMode): void;
  onRemoteToggleFavorite(assetId: string): void;
  onRemoteSkipToQueueItem(itemId: number): void;
  /** 蓝牙 / 有线耳机多模按键 */
  onRemoteKeyEvent(event: KeyEvent): void;
}

/** 业务循环模式 -> 系统 LoopMode */
function toLoopMode(mode: RepeatMode): avSession.LoopMode {
  switch (mode) {
    case RepeatMode.ONE:
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    case RepeatMode.ALL:
      return avSession.LoopMode.LOOP_MODE_LIST;
    case RepeatMode.SHUFFLE:
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    default:
      return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }
}

/** 系统 LoopMode -> 业务循环模式 */
function fromLoopMode(mode: avSession.LoopMode): RepeatMode {
  switch (mode) {
    case avSession.LoopMode.LOOP_MODE_SINGLE:
      return RepeatMode.ONE;
    case avSession.LoopMode.LOOP_MODE_LIST:
      return RepeatMode.ALL;
    case avSession.LoopMode.LOOP_MODE_SHUFFLE:
      return RepeatMode.SHUFFLE;
    default:
      return RepeatMode.OFF;
  }
}

/** 业务状态 -> 系统播放状态 */
function toPlaybackState(status: PlaybackStatus): avSession.PlaybackState {
  switch (status) {
    case PlaybackStatus.PREPARING:
      return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    case PlaybackStatus.PLAYING:
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    case PlaybackStatus.PAUSED:
      return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    case PlaybackStatus.STOPPED:
      return avSession.PlaybackState.PLAYBACK_STATE_STOP;
    case PlaybackStatus.COMPLETED:
      return avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    case PlaybackStatus.ERROR:
      return avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    default:
      return avSession.PlaybackState.PLAYBACK_STATE_IDLE;
  }
}

export class MediaSessionService {
  private session: avSession.AVSession | undefined = undefined;
  private host: MediaSessionHost | undefined = undefined;
  private activated: boolean = false;
  /** 上一次上报的 assetId，用于判断是否需要整体刷新元数据 */
  private lastAssetId: string = '';

  setHost(host: MediaSessionHost): void {
    this.host = host;
  }

  /**
   * 初始化媒体会话。
   * 必须在曲库/播放器就绪后调用，且只会成功创建一次（一个 UIAbility 只能有一个会话）。
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.session !== undefined) {
      return;
    }
    try {
      const sessionType: avSession.AVSessionType = 'audio';
      this.session = await avSession.createAVSession(context, 'folia_music', sessionType);
      Logger.info(TAG, 'AVSession created');
    } catch (error) {
      Logger.err(TAG, 'createAVSession', error as Error);
      this.session = undefined;
      return;
    }
    this.registerCommands();
  }

  /**
   * 注册播控命令。
   *
   * 注意：注册即代表「应用支持该指令」，未注册的系统按钮会置灰；
   * 文档明确要求不要做无逻辑的空实现监听，因此每个回调都真正转发给 host。
   *
   * ⚠️ 这里必须使用**字面量事件名**逐个注册：AVSession 的 `on` 是一组重载，
   *    传变量（即使强转为 keyof AVSessionEventMap）在 ArkTS 下无法完成重载解析。
   *    注销时同样使用字面量，见 destroy()。
   */
  private registerCommands(): void {
    const session = this.session;
    if (session === undefined) {
      return;
    }

    session.on('play', () => {
      this.host?.onRemotePlay();
    });
    session.on('pause', () => {
      this.host?.onRemotePause();
    });
    session.on('stop', () => {
      this.host?.onRemoteStop();
    });
    session.on('playNext', () => {
      this.host?.onRemoteNext();
    });
    session.on('playPrevious', () => {
      this.host?.onRemotePrevious();
    });
    // seek 的参数单位是毫秒
    session.on('seek', (time: number) => {
      this.host?.onRemoteSeek(time);
    });
    session.on('setSpeed', (speed: number) => {
      this.host?.onRemoteSetSpeed(speed);
    });
    session.on('setLoopMode', (mode: avSession.LoopMode) => {
      this.host?.onRemoteSetRepeat(fromLoopMode(mode));
    });
    session.on('toggleFavorite', (assetId: string) => {
      this.host?.onRemoteToggleFavorite(assetId);
    });
    session.on('skipToQueueItem', (itemId: number) => {
      this.host?.onRemoteSkipToQueueItem(itemId);
    });
    session.on('handleKeyEvent', (event: KeyEvent) => {
      this.host?.onRemoteKeyEvent(event);
    });
    // fastForward / rewind 参数单位是**秒**；audio 类型下播控中心不显示该按钮，
    // 这里仍然注册，以便车机 / 手表等控制方下发时可用。
    session.on('fastForward', (time?: number) => {
      const seconds = time ?? 15;
      this.host?.onRemoteSeek(this.lastPositionMs + seconds * 1000);
    });
    session.on('rewind', (time?: number) => {
      const seconds = time ?? 15;
      this.host?.onRemoteSeek(Math.max(0, this.lastPositionMs - seconds * 1000));
    });
  }

  private lastPositionMs: number = 0;
  private lastDurationMs: number = 0;

  /**
   * 上报当前曲目元数据。
   *
   * 关键点：
   *  - assetId 必填且不能为空，否则 setAVMetadata 返回 6600101。
   *  - assetId 变化会整体刷新；不变时未传字段不会被清空，所以切歌必须换 assetId。
   *  - mediaImage 传在线封面 URL 即可，系统自行下载。
   *  - lyric 必须是 Simple LRC 且总长度 < 40960 字节，超出会被截断。
   */
  async updateMetadata(track: Track, lyric: string, previousAssetId: string,
    nextAssetId: string): Promise<void> {
    const session = this.session;
    if (session === undefined) {
      return;
    }
    const assetId = track.id.length > 0 ? track.id : `local:${track.songId}`;
    const metadata: avSession.AVMetadata = {
      assetId: assetId,
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.duration,
      // 副标题用于播控中心第二行，优先展示专辑
      subtitle: track.album.length > 0 ? track.album : track.artist,
      mediaImage: this.resolveImage(track),
      previousAssetId: previousAssetId,
      nextAssetId: nextAssetId
    };
    if (lyric.length > 0) {
      metadata.lyric = lyric;
    }
    try {
      await session.setAVMetadata(metadata);
      this.lastAssetId = assetId;
      Logger.info(TAG, `metadata updated: ${track.title}`);
    } catch (error) {
      Logger.err(TAG, 'setAVMetadata', error as Error);
    }
  }

  /** 封面优先用在线 URL；本地内嵌封面暂不转 PixelMap，避免大图阻塞主线程 */
  private resolveImage(track: Track): string | undefined {
    const cover = track.cover;
    if (cover === undefined) {
      return undefined;
    }
    if (cover.url !== undefined && cover.url.length > 0) {
      return cover.url;
    }
    if (cover.uri !== undefined && cover.uri.length > 0) {
      return cover.uri;
    }
    return undefined;
  }

  /**
   * 上报播放状态。
   *
   * 文档要求：state / position / speed 任一变化都要重新上报，否则系统推算的进度会错；
   * 但**不要**逐帧上报 position，系统会自行按 elapsedTime + updateTime 推算。
   */
  async updatePlaybackState(snapshot: PlaybackSnapshot): Promise<void> {
    const session = this.session;
    if (session === undefined) {
      return;
    }
    this.lastPositionMs = snapshot.position;
    this.lastDurationMs = snapshot.duration;

    const state: avSession.AVPlaybackState = {
      state: toPlaybackState(snapshot.status),
      speed: snapshot.speed,
      position: {
        elapsedTime: snapshot.position,
        updateTime: Date.now()
      },
      bufferedTime: snapshot.buffered,
      loopMode: toLoopMode(snapshot.repeatMode),
      isFavorite: snapshot.isFavorite,
      duration: snapshot.duration
    };
    try {
      await session.setAVPlaybackState(state);
    } catch (error) {
      Logger.err(TAG, 'setAVPlaybackState', error as Error);
    }
  }

  /** 同步播放列表，让播控中心可以展示队列 */
  async updateQueue(items: QueueItem[], title: string): Promise<void> {
    const session = this.session;
    if (session === undefined) {
      return;
    }
    const descriptions: avSession.AVQueueItem[] = [];
    // 播控中心的队列 UI 只需要有限条目，全部推送既慢也无意义
    const limit = Math.min(items.length, 50);
    for (let i = 0; i < limit; i++) {
      const item = items[i];
      descriptions.push({
        itemId: i,
        description: {
          assetId: item.track.id,
          title: item.track.title,
          artist: item.track.artist,
          album: item.track.album,
          duration: item.track.duration,
          mediaImage: this.resolveImage(item.track)
        }
      });
    }
    try {
      await session.setAVQueueItems(descriptions);
      await session.setAVQueueTitle(title);
    } catch (error) {
      Logger.err(TAG, 'setAVQueueItems', error as Error);
    }
  }

  /**
   * 激活会话。
   * 必须在元数据、播放状态、控制命令全部就绪之后调用；
   * 未激活的会话无法阻止应用退到后台时被系统强制暂停。
   */
  async activate(): Promise<void> {
    const session = this.session;
    if (session === undefined || this.activated) {
      return;
    }
    try {
      await session.activate();
      this.activated = true;
      Logger.info(TAG, 'AVSession activated');
    } catch (error) {
      Logger.err(TAG, 'activate', error as Error);
    }
  }

  /** 暂停时可以让会话进入非激活态，避免长期占用播控中心 */
  async deactivate(): Promise<void> {
    const session = this.session;
    if (session === undefined || !this.activated) {
      return;
    }
    try {
      await session.deactivate();
      this.activated = false;
    } catch (error) {
      Logger.err(TAG, 'deactivate', error as Error);
    }
  }

  isActivated(): boolean {
    return this.activated;
  }

  getLastAssetId(): string {
    return this.lastAssetId;
  }

  /** 读取播控中心下发的命令是否被支持，用于调试面板 */
  async getValidCommands(): Promise<string[]> {
    const session = this.session;
    if (session === undefined) {
      return [];
    }
    try {
      const commands = await session.getValidCommands();
      return commands.map((c: avSession.AVControlCommandType) => c as string);
    } catch (error) {
      Logger.err(TAG, 'getValidCommands', error as Error);
      return [];
    }
  }

  /** 应用退出时销毁会话并注销全部回调 */
  async destroy(): Promise<void> {
    const session = this.session;
    if (session === undefined) {
      return;
    }
    // 逐个用字面量注销：off 与 on 同样是重载集合，传变量无法完成重载解析
    try {
      session.off('play');
      session.off('pause');
      session.off('stop');
      session.off('playNext');
      session.off('playPrevious');
      session.off('seek');
      session.off('setSpeed');
      session.off('setLoopMode');
      session.off('toggleFavorite');
      session.off('skipToQueueItem');
      session.off('handleKeyEvent');
      session.off('fastForward');
      session.off('rewind');
    } catch (error) {
      Logger.err(TAG, 'off commands', error as Error);
    }
    try {
      await session.destroy();
    } catch (error) {
      Logger.err(TAG, 'destroy', error as Error);
    }
    this.session = undefined;
    this.activated = false;
    Logger.info(TAG, 'AVSession destroyed');
  }
}

export const mediaSessionService: MediaSessionService = new MediaSessionService();
