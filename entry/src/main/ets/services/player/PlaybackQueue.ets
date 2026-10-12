/**
 * Folia HarmonyOS - 播放队列
 *
 * 对齐上游语义（src/utils/queueAddBehavior.ts、stores/usePlaybackStore.ts）：
 *  - 「加入队列」(append) 与「下一首播放」(next) 两种插入行为。
 *  - **两种行为都先去重再重插**，因此对已在队列中的歌曲执行「下一首播放」是「移动」而非新增重复项。
 *  - 「上一首」= 当前下标 -1，不维护历史栈。
 *  - 随机播放是一次性重排（当前曲固定在首位，其余做反向 Fisher–Yates），而不是一个持续状态位。
 *  - 队列身份键：`<providerId>:<songId>`，跨 provider 同名歌曲视为不同曲目。
 */
import { QueueItem, RepeatMode, Track, ProviderId } from '../../core/Types';

/** 插入行为 */
export enum QueueAddBehavior {
  /** 追加到队尾 */
  APPEND = 'append',
  /** 插入到当前曲目之后 */
  NEXT = 'next'
}

/** 生成队列身份键，跨 provider 的同 id 歌曲必须视为不同曲目 */
export function trackKey(track: Track): string {
  return `${track.providerId}:${track.songId}`;
}

let queueSeq: number = 0;

function makeQueueId(track: Track): string {
  queueSeq += 1;
  return `${trackKey(track)}#${queueSeq}`;
}

export class PlaybackQueue {
  private items: QueueItem[] = [];
  private index: number = -1;
  private repeatMode: RepeatMode = RepeatMode.OFF;

  getItems(): QueueItem[] {
    return this.items;
  }

  getIndex(): number {
    return this.index;
  }

  size(): number {
    return this.items.length;
  }

  getRepeatMode(): RepeatMode {
    return this.repeatMode;
  }

  setRepeatMode(mode: RepeatMode): void {
    this.repeatMode = mode;
  }

  /** 按播放顺序轮转：顺序 -> 列表循环 -> 单曲循环 -> 随机 */
  cycleRepeatMode(): RepeatMode {
    switch (this.repeatMode) {
      case RepeatMode.OFF:
        this.repeatMode = RepeatMode.ALL;
        break;
      case RepeatMode.ALL:
        this.repeatMode = RepeatMode.ONE;
        break;
      case RepeatMode.ONE:
        this.repeatMode = RepeatMode.SHUFFLE;
        break;
      default:
        this.repeatMode = RepeatMode.OFF;
        break;
    }
    return this.repeatMode;
  }

  current(): Track | undefined {
    if (this.index < 0 || this.index >= this.items.length) {
      return undefined;
    }
    return this.items[this.index].track;
  }

  currentItem(): QueueItem | undefined {
    if (this.index < 0 || this.index >= this.items.length) {
      return undefined;
    }
    return this.items[this.index];
  }

  /** 直接替换整个队列并定位到指定曲目 */
  replace(tracks: Track[], startIndex: number): Track | undefined {
    this.items = tracks.map((track: Track) => {
      const item: QueueItem = { track: track, queueId: makeQueueId(track) };
      return item;
    });
    if (this.items.length === 0) {
      this.index = -1;
      return undefined;
    }
    this.index = Math.max(0, Math.min(startIndex, this.items.length - 1));
    return this.current();
  }

  /** 跳转到队列中的某个位置 */
  jumpTo(targetIndex: number): Track | undefined {
    if (targetIndex < 0 || targetIndex >= this.items.length) {
      return undefined;
    }
    this.index = targetIndex;
    return this.current();
  }

  /** 按 queueId 定位（播控中心 skipToQueueItem 使用 itemId=下标） */
  jumpToItemId(itemId: number): Track | undefined {
    return this.jumpTo(itemId);
  }

  /**
   * 加入队列。
   * 去重规则与上游一致：若队列中已存在同一 trackKey，先移除旧条目再插入到目标位置。
   */
  add(tracks: Track[], behavior: QueueAddBehavior): number {
    if (tracks.length === 0) {
      return this.index;
    }
    const currentKey = this.index >= 0 ? trackKey(this.items[this.index].track) : '';
    const incomingKeys = new Set<string>();
    tracks.forEach((t: Track) => incomingKeys.add(trackKey(t)));

    // 1) 去重：移除队列中与新增项重复的条目（保留当前正在播放的那一条位置语义）
    const kept: QueueItem[] = [];
    const keptOriginalIndex: number[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const key = trackKey(this.items[i].track);
      if (!incomingKeys.has(key)) {
        kept.push(this.items[i]);
        keptOriginalIndex.push(i);
      } else if (key === currentKey) {
        // 当前曲被重新加入时不移除，避免播放中断；改为把新条目插到其后
        kept.push(this.items[i]);
        keptOriginalIndex.push(i);
      }
    }

    // 2) 计算插入点
    let insertAt = kept.length;
    if (behavior === QueueAddBehavior.NEXT) {
      let currentPos = -1;
      for (let i = 0; i < kept.length; i++) {
        if (trackKey(kept[i].track) === currentKey) {
          currentPos = i;
          break;
        }
      }
      insertAt = currentPos >= 0 ? currentPos + 1 : kept.length;
    }

    const newItems: QueueItem[] = tracks.map((t: Track) => {
      const item: QueueItem = {
        track: t,
        queueId: makeQueueId(t),
        inserted: behavior === QueueAddBehavior.NEXT
      };
      return item;
    });

    const result = kept.slice(0, insertAt).concat(newItems, kept.slice(insertAt));
    this.items = result;

    // 3) 恢复当前曲下标
    if (currentKey.length > 0) {
      for (let i = 0; i < this.items.length; i++) {
        if (trackKey(this.items[i].track) === currentKey) {
          this.index = i;
          break;
        }
      }
    } else if (this.items.length > 0) {
      this.index = 0;
    }
    return this.index;
  }

  removeAt(targetIndex: number): void {
    if (targetIndex < 0 || targetIndex >= this.items.length) {
      return;
    }
    this.items.splice(targetIndex, 1);
    if (this.items.length === 0) {
      this.index = -1;
    } else if (targetIndex < this.index) {
      this.index -= 1;
    } else if (targetIndex === this.index) {
      this.index = Math.min(this.index, this.items.length - 1);
    }
  }

  /** 清空队列。正在播放的曲目一并移除，调用方需自行停止播放 */
  clear(): void {
    this.items = [];
    this.index = -1;
  }

  /**
   * 一次性随机重排：当前曲固定在下标 0，其余做反向 Fisher–Yates。
   * 与上游 shuffleQueue 行为一致；重复调用会再次重排。
   */
  shuffle(): void {
    if (this.items.length <= 1) {
      return;
    }
    const current = this.index >= 0 ? this.items[this.index] : undefined;
    const rest = this.items.filter((_: QueueItem, i: number) => i !== this.index);
    for (let i = rest.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const tmp = rest[i];
      rest[i] = rest[j];
      rest[j] = tmp;
    }
    this.items = current === undefined ? rest : [current].concat(rest);
    this.index = 0;
  }

  /**
   * 计算下一首下标。
   * 返回 -1 表示「没有下一首」，调用方应停止播放。
   */
  nextIndex(userTriggered: boolean): number {
    if (this.items.length === 0) {
      return -1;
    }
    if (this.repeatMode === RepeatMode.ONE && !userTriggered) {
      // 单曲循环：自然结束时重播当前曲；用户点「下一首」时仍然切歌
      return this.index;
    }
    if (this.index + 1 < this.items.length) {
      return this.index + 1;
    }
    if (this.repeatMode === RepeatMode.ALL || this.repeatMode === RepeatMode.SHUFFLE) {
      return 0;
    }
    return -1;
  }

  /** 计算上一首下标；位于队首时按循环模式决定是否回绕 */
  previousIndex(): number {
    if (this.items.length === 0) {
      return -1;
    }
    if (this.index - 1 >= 0) {
      return this.index - 1;
    }
    if (this.repeatMode === RepeatMode.ALL || this.repeatMode === RepeatMode.SHUFFLE) {
      return this.items.length - 1;
    }
    return 0;
  }

  /** 预取用的下一首曲目（不改变队列下标） */
  peekNext(): Track | undefined {
    const next = this.nextIndex(true);
    if (next < 0 || next >= this.items.length) {
      return undefined;
    }
    return this.items[next].track;
  }

  /** 上一首曲目 id，用于 AVMetadata.previousAssetId */
  peekPrevious(): Track | undefined {
    const prev = this.previousIndex();
    if (prev < 0 || prev >= this.items.length) {
      return undefined;
    }
    return this.items[prev].track;
  }

  /** 判断某个 trackKey 是否已在队列中 */
  contains(key: string): boolean {
    return this.items.some((item: QueueItem) => trackKey(item.track) === key);
  }

  /** 导出用于持久化的精简队列（只存身份，播放时重新解析直链） */
  exportIdentities(): QueueIdentity[] {
    return this.items.map((item: QueueItem) => {
      const identity: QueueIdentity = {
        providerId: item.track.providerId,
        songId: item.track.songId,
        title: item.track.title,
        artist: item.track.artist,
        album: item.track.album,
        duration: item.track.duration,
        fileUri: item.track.fileUri
      };
      return identity;
    });
  }
}

/** 持久化用的队列身份，不包含会过期的直链 */
export interface QueueIdentity {
  providerId: ProviderId;
  songId: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  fileUri?: string;
}
