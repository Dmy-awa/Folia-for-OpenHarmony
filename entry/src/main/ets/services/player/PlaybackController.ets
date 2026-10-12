/**
 * Folia HarmonyOS - 播放控制器
 *
 * 全应用唯一的播放编排者，把下列部件粘合在一起：
 *   AudioEngine（AVPlayer） · PlaybackQueue（队列语义） · MediaSessionService（播控中心）
 *   BackgroundTaskKeeper（后台长时任务） · 歌词解析与时间轴
 *
 * 职责边界：
 *   - 只有本文件可以调用 AudioEngine 的播放方法；
 *   - UI 只读取本类暴露的 @Trace 状态，并调用本类的公开方法；
 *   - 在线直链解析、歌词获取通过构造函数注入的解析器完成，避免与 provider 层耦合。
 */
import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { KeyEvent } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import {
  LyricDocument,
  LyricFormat,
  LyricPayload,
  PlaybackSnapshot,
  PlaybackStatus,
  ProviderId,
  QueueItem,
  RepeatMode,
  Track,
  TrackOrigin
} from '../../core/Types';
import { AudioEngine, AudioSource } from './AudioEngine';
import { PlaybackQueue, QueueAddBehavior, QueueIdentity, trackKey } from './PlaybackQueue';
import { backgroundTaskKeeper, BackgroundTaskKeeper, ContinuousTaskObserver } from './BackgroundTaskKeeper';
import { MediaSessionHost, mediaSessionService, MediaSessionService } from '../media/MediaSessionService';
import { buildControlCenterLrc } from '../media/ControlCenterLyric';
import { parseLyric } from '../lyrics/LyricParsers';
import { findActiveLineIndexBinary, findLatestActiveLineIndex, toLyricTime } from '../lyrics/LyricTimeline';

const TAG: string = 'PlaybackController';

/** 由外部注入：把 Track 解析成可播放的音源（本地文件或在线直链） */
export type AudioSourceResolver = (track: Track) => Promise<AudioSource>;

/** 由外部注入：获取歌词原始载荷（本地侧车文件 / provider） */
export type LyricLoader = (track: Track) => Promise<LyricPayload | undefined>;

/** 输出设备不可用的原因码：拔出耳机 */
const DEVICE_REASON_OLD_UNAVAILABLE: number = 2;

/** 播放控制器对外暴露的可观察状态 */
@ObservedV2
export class PlaybackController implements MediaSessionHost, ContinuousTaskObserver {
  private engine: AudioEngine = new AudioEngine();
  private queue: PlaybackQueue = new PlaybackQueue();
  private session: MediaSessionService = mediaSessionService;
  private background: BackgroundTaskKeeper = backgroundTaskKeeper;

  private audioResolver: AudioSourceResolver | undefined = undefined;
  private lyricLoader: LyricLoader | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;

  // ---- 可观察状态（UI 直接绑定；@Trace 使变更能驱动 V2 组件刷新） ----
  @Trace status: PlaybackStatus = PlaybackStatus.IDLE;
  @Trace positionMs: number = 0;
  @Trace durationMs: number = 0;
  @Trace bufferedMs: number = 0;
  @Trace speed: number = 1.0;
  @Trace volume: number = 1.0;
  @Trace repeatMode: RepeatMode = RepeatMode.OFF;
  @Trace currentTrack: Track | undefined = undefined;
  @Trace lyricDoc: LyricDocument | undefined = undefined;
  @Trace currentLineIndex: number = -1;
  /** 队列版本号：队列内容变化时自增，UI 依赖它触发重算 */
  @Trace queueVersion: number = 0;
  @Trace errorMessage: string = '';
  @Trace isFavorite: boolean = false;
  /** 歌词时间轴偏移，毫秒 */
  @Trace lyricOffsetMs: number = 0;
  /** 是否处于加载中（解析直链 + 取歌词） */
  @Trace loading: boolean = false;

  private favorites: Set<string> = new Set<string>();
  /** 音量被系统 duck 之前的备份 */
  private volumeBeforeDuck: number = 1.0;
  private ducked: boolean = false;
  /** 用户手动暂停（区别于被系统中断导致的暂停），决定中断结束后是否自动恢复 */
  private pauseByUser: boolean = true;
  /** 记录已播放过的曲目，避免同一首歌重复上报相同元数据 */
  private lastReportedAssetId: string = '';

  constructor() {
    this.engine.setObserver({
      onStatusChange: (status: PlaybackStatus) => this.handleStatusChange(status),
      onTimeUpdate: (positionMs: number) => this.handleTimeUpdate(positionMs),
      onDurationChange: (durationMs: number) => this.handleDurationChange(durationMs),
      onBufferedChange: (bufferedMs: number) => {
        this.bufferedMs = bufferedMs;
      },
      onCompletion: () => this.handleCompletion(),
      onError: (error: Error) => this.handleError(error),
      onInterrupt: (event: audio.InterruptEvent) => this.handleInterrupt(event),
      onOutputDeviceChange: (reason: number) => this.handleOutputDeviceChange(reason)
    });
    this.session.setHost(this);
    this.background.setObserver(this);
  }

  /** 注入解析器。必须在首次播放前调用 */
  setResolvers(audioResolver: AudioSourceResolver, lyricLoader: LyricLoader): void {
    this.audioResolver = audioResolver;
    this.lyricLoader = lyricLoader;
  }

  /**
   * 绑定 Ability 上下文并初始化音频引擎、媒体会话。
   * 在 EntryAbility.onWindowStageCreate 之后调用（必须是 UIAbilityContext）。
   */
  async attach(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    await this.engine.init();
    await this.session.init(context);
    Logger.info(TAG, 'attached');
  }

  // -------------------------------------------------------------------------
  // 队列与播放
  // -------------------------------------------------------------------------

  getQueue(): QueueItem[] {
    return this.queue.getItems();
  }

  getQueueIndex(): number {
    return this.queue.getIndex();
  }

  getRepeatMode(): RepeatMode {
    return this.repeatMode;
  }

  setLyricOffset(offsetMs: number): void {
    this.lyricOffsetMs = Math.max(-2000, Math.min(2000, offsetMs));
    // 偏移变化会改变当前行，立即重算
    this.recalcActiveLine();
  }

  /** 用一批曲目替换队列并从 startIndex 开始播放 */
  async playTracks(tracks: Track[], startIndex: number): Promise<void> {
    const track = this.queue.replace(tracks, startIndex);
    this.queueVersion += 1;
    this.repeatMode = this.queue.getRepeatMode();
    if (track === undefined) {
      Logger.warn(TAG, 'playTracks with empty list');
      return;
    }
    await this.loadAndPlay(track);
    await this.syncQueueToSession();
  }

  /** 播放单曲：若已在队列中则跳转，否则追加到队尾并播放 */
  async playTrack(track: Track): Promise<void> {
    const key = trackKey(track);
    const items = this.queue.getItems();
    for (let i = 0; i < items.length; i += 1) {
      if (trackKey(items[i].track) === key) {
        this.queue.jumpTo(i);
        await this.loadAndPlay(track);
        return;
      }
    }
    this.queue.add([track], QueueAddBehavior.APPEND);
    this.queueVersion += 1;
    // 新加入的曲目位于队尾，直接跳过去
    const newItems = this.queue.getItems();
    for (let i = newItems.length - 1; i >= 0; i -= 1) {
      if (trackKey(newItems[i].track) === key) {
        this.queue.jumpTo(i);
        break;
      }
    }
    await this.loadAndPlay(track);
    await this.syncQueueToSession();
  }

  /** 加入队列；NEXT 表示插入到当前曲目之后 */
  addToQueue(tracks: Track[], behavior: QueueAddBehavior): void {
    if (tracks.length === 0) {
      return;
    }
    this.queue.add(tracks, behavior);
    this.queueVersion += 1;
    this.syncQueueToSession();
  }

  /** 从队列移除 */
  removeFromQueue(index: number): void {
    const removingCurrent = index === this.queue.getIndex();
    this.queue.removeAt(index);
    this.queueVersion += 1;
    if (removingCurrent) {
      const track = this.queue.current();
      if (track === undefined) {
        this.stopInternal();
      } else {
        this.loadAndPlay(track);
      }
    }
    this.syncQueueToSession();
  }

  /** 随机播放：一次性重排，当前曲固定首位 */
  shuffleQueue(): void {
    this.queue.shuffle();
    this.queueVersion += 1;
    this.syncQueueToSession();
  }

  clearQueue(): void {
    this.queue.clear();
    this.queueVersion += 1;
    this.stopInternal();
    this.syncQueueToSession();
  }

  /** 播放 / 暂停切换 */
  async togglePlay(): Promise<void> {
    if (this.status === PlaybackStatus.PLAYING) {
      await this.pause();
    } else if (this.status === PlaybackStatus.PAUSED) {
      await this.resume();
    } else if (this.currentTrack !== undefined) {
      await this.loadAndPlay(this.currentTrack);
    }
  }

  async pause(): Promise<void> {
    this.pauseByUser = true;
    await this.engine.pause();
    // 官方要求：暂停必须取消长时任务，否则会被判定为异常占用
    await this.stopBackgroundTask();
    await this.session.updatePlaybackState(this.snapshot());
  }

  async resume(): Promise<void> {
    this.pauseByUser = false;
    if (this.status === PlaybackStatus.PAUSED || this.status === PlaybackStatus.IDLE) {
      await this.engine.play();
      await this.ensureBackgroundTask();
      await this.session.activate();
      await this.session.updatePlaybackState(this.snapshot());
    }
  }

  async next(userTriggered: boolean = true): Promise<void> {
    const nextIndex = this.queue.nextIndex(userTriggered);
    if (nextIndex < 0) {
      // 没有下一首：停止播放但保留队列
      await this.engine.stop();
      await this.stopBackgroundTask();
      return;
    }
    const track = this.queue.jumpTo(nextIndex);
    if (track !== undefined) {
      this.queueVersion += 1;
      await this.loadAndPlay(track);
    }
  }

  async previous(): Promise<void> {
    const prevIndex = this.queue.previousIndex();
    const track = this.queue.jumpTo(prevIndex);
    if (track !== undefined) {
      this.queueVersion += 1;
      await this.loadAndPlay(track);
    }
  }

  async seek(positionMs: number): Promise<void> {
    await this.engine.seek(positionMs);
  }

  async seekBy(deltaMs: number): Promise<void> {
    await this.engine.seek(this.engine.getPosition() + deltaMs);
  }

  setVolume(volume: number): void {
    this.volume = volume;
    this.engine.setVolume(volume);
  }

  setSpeed(speed: number): void {
    this.speed = speed;
    this.engine.setSpeed(speed);
    this.session.updatePlaybackState(this.snapshot());
  }

  cycleRepeatMode(): void {
    this.repeatMode = this.queue.cycleRepeatMode();
    this.session.updatePlaybackState(this.snapshot());
  }

  setRepeatMode(mode: RepeatMode): void {
    this.repeatMode = mode;
    this.queue.setRepeatMode(mode);
    this.session.updatePlaybackState(this.snapshot());
  }

  toggleFavorite(trackId: string): void {
    if (this.favorites.has(trackId)) {
      this.favorites.delete(trackId);
    } else {
      this.favorites.add(trackId);
    }
    if (this.currentTrack !== undefined && this.currentTrack.id === trackId) {
      this.isFavorite = this.favorites.has(trackId);
    }
    this.session.updatePlaybackState(this.snapshot());
  }

  isTrackFavorite(trackId: string): boolean {
    return this.favorites.has(trackId);
  }

  // -------------------------------------------------------------------------
  // 核心装载流程
  // -------------------------------------------------------------------------

  /**
   * 装载并播放一首曲目。
   * 顺序：解析音源 -> 引擎 load -> 上报元数据/队列 -> 取歌词 -> 播放 -> 申请后台任务 -> 激活会话。
   */
  private async loadAndPlay(track: Track): Promise<void> {
    if (this.audioResolver === undefined) {
      this.handleError(new Error('未注入音源解析器'));
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.currentTrack = track;
    this.currentLineIndex = -1;
    this.lyricDoc = undefined;
    this.positionMs = 0;
    this.durationMs = track.duration;
    this.isFavorite = this.favorites.has(track.id);

    try {
      const source = await this.audioResolver(track);
      await this.engine.load(source);
      await this.engine.setVolume(this.volume);
      if (this.speed !== 1.0) {
        this.engine.setSpeed(this.speed);
      }
    } catch (error) {
      this.loading = false;
      this.handleError(error as Error);
      return;
    }

    // 元数据与队列先于播放上报，保证播控中心第一时间有内容
    await this.publishMetadata(track);

    await this.engine.play();
    this.loading = false;

    await this.ensureBackgroundTask();
    await this.session.activate();
    await this.session.updatePlaybackState(this.snapshot());

    // 歌词异步加载，不阻塞播放
    this.loadLyricAsync(track);
  }

  /** 歌词加载与解析放到播放开始之后，避免首次播放被网络阻塞 */
  private async loadLyricAsync(track: Track): Promise<void> {
    const loader = this.lyricLoader;
    if (loader === undefined) {
      return;
    }
    try {
      const payload = await loader(track);
      if (payload === undefined || this.currentTrack?.id !== track.id) {
        return;
      }
      if (payload.pureMusic) {
        this.lyricDoc = undefined;
        this.currentLineIndex = -1;
        Logger.info(TAG, `pure music: ${track.title}`);
        return;
      }
      // 已知格式走显式分派（本地侧车文件按扩展名确定），未知则自动检测
      const doc = parseLyric(payload.lyric, payload.translation ?? '', payload.romaji ?? '',
        payload.format ?? LyricFormat.NONE);
      if (this.currentTrack?.id !== track.id) {
        return;
      }
      this.lyricDoc = doc;
      this.recalcActiveLine();
      // 歌词变化后需要重新上报播控中心歌词，但 assetId 不变，
      // 因此必须重新调用 setAVMetadata（相同 assetId 下 lyric 仍会更新）
      await this.publishMetadata(track);
      Logger.info(TAG, `lyric loaded: ${doc.lines.length} lines, wordTiming=${doc.hasWordTiming}`);
    } catch (error) {
      Logger.err(TAG, 'load lyric', error as Error);
    }
  }

  /** 上报曲目元数据（含播控中心歌词） */
  private async publishMetadata(track: Track): Promise<void> {
    const items = this.queue.getItems();
    const index = this.queue.getIndex();
    const prev = index > 0 ? items[index - 1].track.id : '';
    const next = index >= 0 && index + 1 < items.length ? items[index + 1].track.id : '';
    const lrc = buildControlCenterLrc(this.lyricDoc, this.lyricOffsetMs);
    await this.session.updateMetadata(track, lrc, prev, next);
    this.lastReportedAssetId = track.id;
  }

  private async syncQueueToSession(): Promise<void> {
    const items = this.queue.getItems();
    if (items.length === 0) {
      return;
    }
    await this.session.updateQueue(items, 'Folia 播放队列');
  }

  private snapshot(): PlaybackSnapshot {
    const snap: PlaybackSnapshot = {
      status: this.status,
      position: this.positionMs,
      duration: this.durationMs,
      buffered: this.bufferedMs,
      speed: this.speed,
      volume: this.volume,
      repeatMode: this.repeatMode,
      index: this.queue.getIndex(),
      isFavorite: this.isFavorite
    };
    return snap;
  }

  // -------------------------------------------------------------------------
  // 引擎回调
  // -------------------------------------------------------------------------

  private handleStatusChange(status: PlaybackStatus): void {
    this.status = status;
    this.session.updatePlaybackState(this.snapshot());
  }

  private handleTimeUpdate(positionMs: number): void {
    this.positionMs = positionMs;
    this.recalcActiveLine();
  }

  private handleDurationChange(durationMs: number): void {
    this.durationMs = durationMs;
  }

  private async handleCompletion(): Promise<void> {
    if (this.repeatMode === RepeatMode.ONE) {
      // 单曲循环：重新播放当前曲
      await this.engine.seek(0);
      await this.engine.play();
      return;
    }
    await this.next(false);
  }

  private handleError(error: Error): void {
    const code = (error as BusinessError).code;
    this.errorMessage = `播放失败：${error.message}`;
    Logger.error(TAG, `playback error code=${code} message=${error.message}`);
    this.session.updatePlaybackState(this.snapshot());
  }

  /**
   * 音频焦点中断处理。
   *
   * forceType:
   *   INTERRUPT_FORCE  系统已经代为执行（如已暂停），应用只需同步 UI 状态
   *   INTERRUPT_SHARE  系统交由应用决定
   * hintType: RESUME / PAUSE / STOP / DUCK / UNDUCK
   */
  private async handleInterrupt(event: audio.InterruptEvent): Promise<void> {
    const forceType = event.forceType;
    const hintType = event.hintType;
    Logger.info(TAG, `interrupt force=${forceType} hint=${hintType}`);

    if (hintType === audio.InterruptHint.INTERRUPT_HINT_DUCK) {
      // 系统已把音量降到 20%，这里只记录，不再叠加
      this.ducked = true;
      return;
    }
    if (hintType === audio.InterruptHint.INTERRUPT_HINT_UNDUCK) {
      if (this.ducked) {
        this.engine.setVolume(this.volume);
        this.ducked = false;
      }
      return;
    }
    if (hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      // 系统代停时引擎状态已变，这里只需同步业务状态并取消长时任务
      await this.engine.pause();
      await this.stopBackgroundTask();
      this.session.updatePlaybackState(this.snapshot());
      return;
    }
    if (hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      // RESUME 恒为 SHARE：只有用户本意就是播放时才自动恢复
      if (!this.pauseByUser) {
        await this.resume();
      }
      return;
    }
    if (forceType === audio.InterruptForceType.INTERRUPT_FORCE
      && hintType === audio.InterruptHint.INTERRUPT_HINT_NONE) {
      Logger.info(TAG, 'forced interrupt with no hint, waiting for next hint');
    }
  }

  /**
   * 输出设备变化。
   * 拔出耳机（原设备不可用）时按官方建议暂停播放，并取消长时任务。
   */
  private async handleOutputDeviceChange(reason: number): Promise<void> {
    if (reason === DEVICE_REASON_OLD_UNAVAILABLE) {
      Logger.info(TAG, 'output device unavailable, pausing');
      await this.pause();
    }
  }

  // -------------------------------------------------------------------------
  // 后台长时任务
  // -------------------------------------------------------------------------

  private async ensureBackgroundTask(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    await this.background.start(context);
  }

  private async stopBackgroundTask(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    await this.background.stop(context);
  }

  /** 长时任务被取消（用户或系统），必须同步暂停，否则会造成「幽灵播放」 */
  onTaskCancelled(reason: number): void {
    Logger.warn(TAG, `continuous task cancelled reason=${reason}`);
    this.engine.pause();
    this.session.updatePlaybackState(this.snapshot());
  }

  // -------------------------------------------------------------------------
  // MediaSessionHost：播控中心命令
  // -------------------------------------------------------------------------

  onRemotePlay(): void {
    this.resume();
  }

  onRemotePause(): void {
    this.pause();
  }

  onRemoteStop(): void {
    this.pauseByUser = true;
    this.stopInternal();
  }

  onRemoteNext(): void {
    this.next(true);
  }

  onRemotePrevious(): void {
    this.previous();
  }

  onRemoteSeek(positionMs: number): void {
    // 播控中心的 seek 参数单位是毫秒
    this.seek(positionMs);
  }

  onRemoteSetSpeed(speed: number): void {
    this.setSpeed(speed);
  }

  onRemoteSetRepeat(mode: RepeatMode): void {
    this.setRepeatMode(mode);
  }

  onRemoteToggleFavorite(assetId: string): void {
    this.toggleFavorite(assetId);
  }

  onRemoteSkipToQueueItem(itemId: number): void {
    const track = this.queue.jumpToItemId(itemId);
    if (track !== undefined) {
      this.queueVersion += 1;
      this.loadAndPlay(track);
    }
  }

  /**
   * 蓝牙/有线耳机按键。
   * AVSession 会把多模按键与佩戴检测转成这些指令，这里只处理播放控制相关的键。
   */
  onRemoteKeyEvent(event: KeyEvent): void {
    // KeyEvent.keyCode 的具体取值随系统版本变化，这里按「播放/暂停」语义处理，
    // 其余按键交给系统播控中心已注册的命令路径，避免重复响应。
    Logger.info(TAG, `key event code=${event.keyCode} action=${event.type}`);
  }

  // -------------------------------------------------------------------------
  // 歌词时间轴
  // -------------------------------------------------------------------------

  /** 重算当前歌词行；由 positionMs 驱动 */
  private recalcActiveLine(): void {
    const doc = this.lyricDoc;
    if (doc === undefined || doc.lines.length === 0) {
      if (this.currentLineIndex !== -1) {
        this.currentLineIndex = -1;
      }
      return;
    }
    const timeSeconds = toLyricTime(this.positionMs, this.lyricOffsetMs);
    // 行数很大时用二分版本，语义与线性版本一致
    const index = doc.lines.length > 2000
      ? findActiveLineIndexBinary(doc.lines, timeSeconds)
      : findLatestActiveLineIndex(doc.lines, timeSeconds);
    if (index !== this.currentLineIndex) {
      this.currentLineIndex = index;
    }
  }

  // -------------------------------------------------------------------------
  // 持久化与释放
  // -------------------------------------------------------------------------

  /** 导出当前播放状态，供持久化 */
  exportQueue(): QueueIdentity[] {
    return this.queue.exportIdentities();
  }

  exportCurrentTrack(): Track | undefined {
    return this.currentTrack;
  }

  /** 恢复队列；不自动播放，由调用方决定 */
  restoreQueue(tracks: Track[], index: number): void {
    this.queue.replace(tracks, index);
    this.queueVersion += 1;
    const track = this.queue.current();
    if (track !== undefined) {
      this.currentTrack = track;
      this.durationMs = track.duration;
    }
  }

  private async stopInternal(): Promise<void> {
    await this.engine.stop();
    await this.stopBackgroundTask();
    this.currentLineIndex = -1;
    this.session.updatePlaybackState(this.snapshot());
  }

  /** 应用退出：释放播放器与会话 */
  async release(): Promise<void> {
    await this.stopBackgroundTask();
    await this.session.destroy();
    await this.engine.release();
    Logger.info(TAG, 'released');
  }
}

/** 进程内单例 */
export const playbackController: PlaybackController = new PlaybackController();
