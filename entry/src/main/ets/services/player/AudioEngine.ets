/**
 * Folia HarmonyOS - 音频引擎
 *
 * 对 @kit.MediaKit 的 AVPlayer 做一层面向「音乐播放器」的封装。
 *
 * 关键约束（来自 OpenHarmony 官方文档，务必按此顺序调用，否则会丢失事件或抛错）：
 *  1. createAVPlayer() 后处于 idle；必须先在 idle 注册 on('stateChange') 与 on('error')，
 *     再设置播放源；否则设置源过程中触发的 stateChange/error 会被漏掉。
 *  2. url / fdSrc / dataSrc 只能在 idle 设置。
 *  3. audioRendererInfo 与 setPlaybackStrategy 只能在 initialized 设置。
 *  4. audioInterruptMode 在 prepared 之后、首次 play() 之前设置。
 *  5. 时间单位：timeUpdate / durationUpdate / seekDone / seek(timeMs) / currentTime / duration
 *     全部是**毫秒**。唯一例外是 PlaybackStrategy.preferredBufferDuration（秒）。
 *  6. 拖动进度条后，在 seekDone 回调之前不要用 timeUpdate 覆盖 UI 进度，否则进度条会回跳。
 */
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import { PlaybackStatus } from '../../core/Types';

const TAG: string = 'AudioEngine';

/** 播放源描述 */
export interface AudioSource {
  /** 网络直链，与 fd 二选一 */
  url?: string;
  /** 本地文件沙箱路径，与 url 二选一 */
  filePath?: string;
  /** 附带请求头（防盗链平台需要） */
  headers?: Record<string, string>;
  /** 起始播放位置，毫秒 */
  startPositionMs?: number;
}

/** 引擎对外回调 */
export interface AudioEngineObserver {
  onStatusChange(status: PlaybackStatus): void;
  /** 播放进度，毫秒；已经在 seek 期间被屏蔽 */
  onTimeUpdate(positionMs: number): void;
  onDurationChange(durationMs: number): void;
  onBufferedChange(bufferedMs: number): void;
  /** 自然播放结束 */
  onCompletion(): void;
  onError(error: Error): void;
  /** 音频焦点中断 */
  onInterrupt(event: audio.InterruptEvent): void;
  /** 输出设备变化（拔耳机等） */
  onOutputDeviceChange(reason: number): void;
}

/** AVPlayer 状态到业务状态的映射 */
function mapState(state: string): PlaybackStatus {
  switch (state) {
    case 'idle':
      return PlaybackStatus.IDLE;
    case 'initialized':
      return PlaybackStatus.PREPARING;
    case 'prepared':
      return PlaybackStatus.PREPARING;
    case 'playing':
      return PlaybackStatus.PLAYING;
    case 'paused':
      return PlaybackStatus.PAUSED;
    case 'completed':
      return PlaybackStatus.COMPLETED;
    case 'stopped':
      return PlaybackStatus.STOPPED;
    case 'released':
      return PlaybackStatus.IDLE;
    case 'error':
      return PlaybackStatus.ERROR;
    default:
      return PlaybackStatus.IDLE;
  }
}

export class AudioEngine {
  private player: media.AVPlayer | undefined = undefined;
  private observer: AudioEngineObserver | undefined = undefined;
  private currentSource: AudioSource | undefined = undefined;

  /** 本地文件句柄，切换曲目时必须关闭，否则会泄漏 fd */
  private file: fileIo.File | undefined = undefined;

  private status: PlaybackStatus = PlaybackStatus.IDLE;
  private durationMs: number = 0;
  private positionMs: number = 0;
  private bufferedMs: number = 0;

  /** 用户请求的 seek 目标；在 seekDone 之前屏蔽 timeUpdate 回跳 */
  private pendingSeekMs: number = -1;
  private seeking: boolean = false;

  /** 上一次上报时间，用于节流 UI 刷新 */
  private lastReportMs: number = 0;
  private static readonly REPORT_INTERVAL_MS: number = 120;

  /** 是否已经释放，防止 release 后再次操作 */
  private released: boolean = false;

  private volume: number = 1.0;
  private speed: number = 1.0;
  private loop: boolean = false;

  setObserver(observer: AudioEngineObserver): void {
    this.observer = observer;
  }

  getStatus(): PlaybackStatus {
    return this.status;
  }

  getDuration(): number {
    return this.durationMs;
  }

  getPosition(): number {
    return this.seeking ? this.pendingSeekMs : this.positionMs;
  }

  getBuffered(): number {
    return this.bufferedMs;
  }

  /** 创建底层播放器；必须在任何播放操作之前调用一次 */
  async init(): Promise<void> {
    if (this.player !== undefined) {
      return;
    }
    try {
      this.player = await media.createAVPlayer();
      this.bindEvents(this.player);
      Logger.info(TAG, 'AVPlayer created');
    } catch (error) {
      Logger.err(TAG, 'createAVPlayer', error as Error);
      throw error as Error;
    }
  }

  /**
   * 绑定全部事件。
   * 注意：必须在设置播放源之前完成绑定。
   */
  private bindEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      Logger.debug(TAG, `stateChange -> ${state}, reason=${reason}`);
      this.status = mapState(state);
      if (state === 'prepared') {
        this.durationMs = player.duration;
        this.observer?.onDurationChange(this.durationMs);
      }
      if (state === 'completed') {
        this.observer?.onCompletion();
      }
      this.observer?.onStatusChange(this.status);
    });

    player.on('error', (error: BusinessError) => {
      Logger.err(TAG, 'player error', error as Error);
      this.status = PlaybackStatus.ERROR;
      this.observer?.onStatusChange(this.status);
      this.observer?.onError(error as Error);
    });

    player.on('durationUpdate', (duration: number) => {
      // durationUpdate 的单位是毫秒
      if (duration > 0) {
        this.durationMs = duration;
        this.observer?.onDurationChange(duration);
      }
    });

    player.on('timeUpdate', (time: number) => {
      this.positionMs = time;
      // seek 目标达成前，忽略播放器回吐的旧时间，避免进度条回跳
      if (this.seeking) {
        return;
      }
      const now = Date.now();
      if (now - this.lastReportMs >= AudioEngine.REPORT_INTERVAL_MS) {
        this.lastReportMs = now;
        this.observer?.onTimeUpdate(time);
      }
    });

    player.on('seekDone', (time: number) => {
      // seekDone 回传的是**请求值**，不一定等于实际落点，但作为 UI 基准足够
      Logger.debug(TAG, `seekDone -> ${time}`);
      this.seeking = false;
      this.pendingSeekMs = -1;
      this.positionMs = time;
      this.observer?.onTimeUpdate(time);
    });

    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        this.bufferedMs = value;
        this.observer?.onBufferedChange(value);
      }
    });

    player.on('audioInterrupt', (event: audio.InterruptEvent) => {
      Logger.info(TAG, `audioInterrupt force=${event.forceType} hint=${event.hintType}`);
      this.observer?.onInterrupt(event);
    });

    player.on('audioOutputDeviceChangeWithInfo', (info: audio.AudioStreamDeviceChangeInfo) => {
      // REASON_OLD_DEVICE_UNAVAILABLE(2)：原设备不可用（如拔出耳机），音乐场景应暂停
      Logger.info(TAG, `outputDeviceChange reason=${info.changeReason}`);
      this.observer?.onOutputDeviceChange(info.changeReason);
    });
  }

  /**
   * 加载播放源。
   * 内部会先把播放器 reset 回 idle（因为 url/fdSrc 只能在 idle 设置）。
   */
  async load(source: AudioSource): Promise<void> {
    await this.init();
    const player = this.player;
    if (player === undefined) {
      throw new Error('AVPlayer 未初始化');
    }

    this.closeFile();
    this.currentSource = source;
    this.positionMs = source.startPositionMs ?? 0;
    this.pendingSeekMs = -1;
    this.seeking = false;
    this.bufferedMs = 0;
    this.durationMs = 0;

    // reset 到 idle，保证可以重新设置播放源
    if (player.state !== 'idle') {
      await player.reset();
    }

    try {
      if (source.filePath !== undefined && source.filePath.length > 0) {
        // 本地文件走 fdSrc，避免把沙箱路径暴露给媒体框架
        this.file = fileIo.openSync(source.filePath, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(source.filePath);
        const fdSrc: media.AVFileDescriptor = {
          fd: this.file.fd,
          offset: 0,
          length: stat.size
        };
        player.fdSrc = fdSrc;
      } else if (source.url !== undefined && source.url.length > 0) {
        // 防盗链平台需要 Referer/Cookie，通过 media.AVPlayer 的 http 头透传
        if (source.headers !== undefined && Object.keys(source.headers).length > 0) {
          player.setMediaSource(source.url, { headers: source.headers });
        } else {
          player.url = source.url;
        }
      } else {
        throw new Error('播放源为空');
      }
    } catch (error) {
      Logger.err(TAG, 'load source', error as Error);
      this.observer?.onError(error as Error);
      throw error as Error;
    }

    // 此处 state === 'initialized'，可以配置渲染信息与缓冲策略
    try {
      const rendererInfo: audio.AudioRendererInfo = {
        usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
        rendererFlags: 0
      };
      player.audioRendererInfo = rendererInfo;
      player.setPlaybackStrategy({
        preferredBufferDuration: 5,
        mutedMediaType: media.MediaType.MEDIA_TYPE_AUD
      });
    } catch (error) {
      // 渲染信息设置失败不应阻断播放，仅记录
      Logger.err(TAG, 'setPlaybackStrategy', error as Error);
    }

    await player.prepare();
    Logger.info(TAG, `prepared, duration=${this.durationMs}`);
  }

  /**
   * 开始播放。
   * 若设置了起始位置，则先 seek 再 play。
   */
  async play(): Promise<void> {
    const player = this.player;
    if (player === undefined) {
      return;
    }
    try {
      // 首次播放前设置中断模式：SHARE_MODE 允许与其他应用混音提示音
      player.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
    } catch (error) {
      Logger.err(TAG, 'set audioInterruptMode', error as Error);
    }

    const start = this.currentSource?.startPositionMs ?? 0;
    if (start > 0 && player.state === 'prepared') {
      this.seeking = true;
      this.pendingSeekMs = start;
      await player.seek(start);
    }
    await player.play();
  }

  async pause(): Promise<void> {
    const player = this.player;
    if (player !== undefined && player.state === 'playing') {
      await player.pause();
    }
  }

  /** 拖动进度，单位毫秒 */
  async seek(positionMs: number): Promise<void> {
    const player = this.player;
    if (player === undefined) {
      return;
    }
    const safe = Math.max(0, Math.min(positionMs, this.durationMs > 0 ? this.durationMs : positionMs));
    if (player.state === 'prepared' || player.state === 'playing'
      || player.state === 'paused' || player.state === 'completed') {
      this.seeking = true;
      this.pendingSeekMs = safe;
      try {
        await player.seek(safe);
      } catch (error) {
        this.seeking = false;
        this.pendingSeekMs = -1;
        Logger.err(TAG, 'seek', error as Error);
      }
    }
  }

  async stop(): Promise<void> {
    const player = this.player;
    if (player !== undefined && (player.state === 'playing' || player.state === 'paused'
      || player.state === 'prepared' || player.state === 'completed')) {
      await player.stop();
    }
  }

  setVolume(volume: number): void {
    this.volume = Math.max(0, Math.min(1, volume));
    const player = this.player;
    if (player !== undefined) {
      player.setVolume(this.volume);
    }
  }

  getVolume(): number {
    return this.volume;
  }

  setSpeed(speed: number): void {
    this.speed = speed;
    const player = this.player;
    if (player !== undefined && player.state === 'playing') {
      player.setSpeed(speed);
    }
  }

  getSpeed(): number {
    return this.speed;
  }

  setLoop(loop: boolean): void {
    this.loop = loop;
    const player = this.player;
    if (player !== undefined) {
      player.loop = loop;
    }
  }

  private closeFile(): void {
    if (this.file !== undefined) {
      try {
        fileIo.closeSync(this.file);
      } catch (error) {
        Logger.err(TAG, 'close fd', error as Error);
      }
      this.file = undefined;
    }
  }

  /** 释放播放器，应用退出时调用 */
  async release(): Promise<void> {
    if (this.released) {
      return;
    }
    this.released = true;
    this.closeFile();
    const player = this.player;
    if (player !== undefined) {
      try {
        await player.release();
      } catch (error) {
        Logger.err(TAG, 'release', error as Error);
      }
      this.player = undefined;
    }
    Logger.info(TAG, 'released');
  }
}
