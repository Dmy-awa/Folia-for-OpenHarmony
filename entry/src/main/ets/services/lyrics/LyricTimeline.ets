/**
 * Folia HarmonyOS - 歌词运行时时间模型
 *
 * 从上游 appPlaybackHelpers.ts / components/visualizer/runtime.ts 移植。
 *
 * ⚠️ 单位换算的唯一入口：
 *    歌词时间轴是**秒**，播放器位置是**毫秒**。
 *    UI 必须先 `positionMs / 1000` 再调用本文件的函数。
 *    本文件内部一律使用秒，绝不接受毫秒，避免调用方漏换算。
 */
import { LyricDocument, LyricLine, LyricWord } from '../../core/Types';
import { INTERLUDE_FULL_TEXT } from './LyricCore';

/** 词的高亮状态 */
export enum WordStatus {
  /** 还没唱到 */
  WAITING = 'waiting',
  /** 正在唱 */
  ACTIVE = 'active',
  /** 已唱过 */
  PASSED = 'passed'
}

/**
 * 播放位置 -> 当前活动行下标。
 *
 * 上游语义（必须保留）：
 *  - 从后往前扫，取第一个满足 `startTime <= time <= renderEndTime` 的行；
 *  - `renderEndTime` 允许活跃行越过 endTime 继续停留（淡出窗口），
 *    因此可能有多行同时满足，倒序扫描保证取「最后一行」；
 *  - 无匹配返回 -1，这是「无活动行」的规范值。
 *
 * @param timeSeconds 播放位置，**秒**
 */
export function findLatestActiveLineIndex(lines: LyricLine[], timeSeconds: number): number {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (line === undefined) {
      continue;
    }
    if (timeSeconds < line.startTime) {
      continue;
    }
    const upper = line.renderEndTime !== undefined ? line.renderEndTime : line.endTime;
    if (timeSeconds <= upper) {
      return index;
    }
  }
  return -1;
}

/** 取当前行；无活动行返回 undefined */
export function currentLine(doc: LyricDocument, timeSeconds: number): LyricLine | undefined {
  const index = findLatestActiveLineIndex(doc.lines, timeSeconds);
  return index < 0 ? undefined : doc.lines[index];
}

/**
 * 没有活动行时，取最近一句已结束的歌词。
 * 用途：行间隙里继续显示上一句（配合译文/罗马音展示）。
 */
export function getRecentCompletedLine(lines: LyricLine[], currentLineIndex: number,
  timeSeconds: number): LyricLine | undefined {
  if (currentLineIndex !== -1 || lines.length === 0) {
    return undefined;
  }
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (timeSeconds > lines[i].endTime) {
      return lines[i];
    }
  }
  return undefined;
}

/** 取下一行，用于预排布局与「即将到来」提示 */
export function getUpcomingLine(lines: LyricLine[], currentLineIndex: number): LyricLine | undefined {
  const nextIndex = currentLineIndex + 1;
  if (nextIndex < 0 || nextIndex >= lines.length) {
    return undefined;
  }
  return lines[nextIndex];
}

/** 行进度 0~1，用于逐行淡入/扫光 */
export function lineProgress(line: LyricLine, timeSeconds: number): number {
  const duration = line.endTime - line.startTime;
  if (duration <= 0) {
    return timeSeconds >= line.startTime ? 1 : 0;
  }
  const raw = (timeSeconds - line.startTime) / duration;
  return Math.max(0, Math.min(1, raw));
}

/**
 * 判定单个词的状态。
 *
 * lookahead 用于补偿渲染与音频的时间差（上游 Cadenza 主题按 wordRevealMode 取
 * 0.045 / 0 / 0.18 秒）。UI 主题可自行传值。
 */
export function resolveWordStatus(word: LyricWord, timeSeconds: number, lookahead: number = 0): WordStatus {
  const effective = timeSeconds + lookahead;
  if (effective < word.startTime) {
    return WordStatus.WAITING;
  }
  if (effective <= word.endTime) {
    return WordStatus.ACTIVE;
  }
  return WordStatus.PASSED;
}

/** 词进度 0~1，用于逐字扫光动效 */
export function wordProgress(word: LyricWord, timeSeconds: number, lookahead: number = 0): number {
  const duration = word.endTime - word.startTime;
  if (duration <= 0) {
    return timeSeconds + lookahead >= word.startTime ? 1 : 0;
  }
  const raw = (timeSeconds + lookahead - word.startTime) / duration;
  return Math.max(0, Math.min(1, raw));
}

/**
 * 应用全局 / 单曲时间轴偏移。
 *
 * 上游的偏移是**运行时**概念，不是文件内 `[offset:]` 标签
 * （Folia 的解析器根本不识别 `[offset:]`，见歌词规范 §3.1）。
 * 全局偏移被限制在 ±2000ms。
 *
 * @param positionMs 播放位置，毫秒
 * @param offsetMs 偏移，毫秒；正值表示歌词提前显示
 * @returns 歌词用的时间，秒
 */
export function toLyricTime(positionMs: number, offsetMs: number): number {
  const clamped = Math.max(-2000, Math.min(2000, offsetMs));
  return (positionMs - clamped) / 1000;
}

/**
 * 二分查找版本的当前行。
 * 保留 renderEndTime 上界语义：因为 renderEndTime 可能大于下一行 startTime，
 * 存在多行同时满足，这里在候选区间内仍取最后一个满足者。
 *
 * 行数很大（>2000 行）时优先使用本函数；否则用 findLatestActiveLineIndex 即可。
 */
export function findActiveLineIndexBinary(lines: LyricLine[], timeSeconds: number): number {
  if (lines.length === 0) {
    return -1;
  }
  // 先二分找到最后一个 startTime <= time 的位置
  let low = 0;
  let high = lines.length - 1;
  let candidate = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (lines[mid].startTime <= timeSeconds) {
      candidate = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  if (candidate < 0) {
    return -1;
  }
  // 从候选位置向后扫描（renderEndTime 可能覆盖后续行）
  let result = -1;
  for (let index = candidate; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.startTime > timeSeconds) {
      break;
    }
    const upper = line.renderEndTime !== undefined ? line.renderEndTime : line.endTime;
    if (timeSeconds <= upper) {
      result = index;
    }
  }
  return result;
}

/** 间奏行判定，UI 据此渲染呼吸点/波纹而不是文字 */
export function isInterlude(line: LyricLine): boolean {
  return line.fullText === INTERLUDE_FULL_TEXT || line.isInterlude === true;
}
