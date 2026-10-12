/**
 * Folia HarmonyOS - 歌词解析公共内核
 *
 * 从上游 src/utils/lyrics/parserCore.ts 移植的公共部分：
 *   - 时间戳语法与解析
 *   - 假逐字时轴生成 buildTimedWords
 *   - 间奏行插入 attachInterludes
 *   - 翻译 / 罗马音配对 findTranslationsForSortedStartTimes
 *   - 渲染提示 annotateLyricLines
 *
 * ⚠️ 单位：本文件所有时间参数与返回值均为**秒（float）**，与上游保持一致。
 *    只有逐字族格式（YRC/QRC/KRC）的原始标签是毫秒，在各自解析器里 /1000。
 *
 * ⚠️ ArkTS 注意：带 g 标志的正则对象有 lastIndex 状态，跨调用复用会导致
 *    第二次匹配从错误位置开始。本文件所有全局匹配都在函数内部新建 RegExp，
 *    或在使用前显式把 lastIndex 归零。
 */
import { LyricLine, LyricWord } from '../../core/Types';

/** 间奏行的固定文本，UI 据此渲染波形/呼吸点 */
export const INTERLUDE_FULL_TEXT: string = '......';

/** 翻译 / 罗马音配对的时间窗口，单位秒 */
export const ALTERNATE_TRACK_MATCH_WINDOW: number = 1.0;

/** 含 CJK（汉字 / 假名 / 谚文）判据，用于决定逐字切分粒度 */
const CJK_REGEX: RegExp = /[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]/;

/** CJK 标点：权重 0，不占用时长但要推进一点点时间 */
const CJK_PUNCTUATION_REGEX: RegExp = /[，。！？、：；"'）]/;

/** 行首时间标签 */
const LINE_TIME_REGEX: RegExp = /^\[(\d{2}):(\d{2})[.:](\d{2,3})\]/;

/** 全部前导时间标签（多时间戳行） */
const LEADING_TAGS_REGEX: RegExp = /^((?:\[(?:\d{2}):(?:\d{2})[.:](?:\d{2,3})\])+)(.*)$/;

/** 尖括号逐字标签 */
const ANGLE_TIME_REGEX: RegExp = /<(\d{2}):(\d{2})[.:](\d{2,3})>/;

/** 元数据行：只认 [ti:] 与 [ar:] */
const METADATA_REGEX: RegExp = /^\[(ti|ar):([^\]]*)\]$/i;

/** 时间戳 -> 秒。`[01:02.5]` / `[01:02.50]` / `[01:02.500]` 均为 62.5s */
export function parseTimestamp(minute: string, second: string, fraction: string): number {
  return Number(minute) * 60 + Number(second) + parseFloat('0.' + fraction);
}

/** 解析单条「时间标签 + 文本」条目 */
export interface TimedTextEntry {
  startTime: number;
  text: string;
}

/** 解析简单时间行（LRC 普通行）。不匹配返回 undefined */
export function parseSimpleTimedTextEntry(rawLine: string): TimedTextEntry | undefined {
  const tagged = rawLine.match(LEADING_TAGS_REGEX);
  if (tagged === null) {
    return undefined;
  }
  // 多时间戳行只取第一个，后续时间戳被静默丢弃（与上游一致）
  const head = tagged[1].match(LINE_TIME_REGEX);
  if (head === null) {
    return undefined;
  }
  const text = tagged[2];
  if (text === undefined || text.length === 0) {
    return undefined;
  }
  const entry: TimedTextEntry = {
    startTime: parseTimestamp(head[1], head[2], head[3]),
    text: text
  };
  return entry;
}

/** 元数据行解析结果 */
export interface LyricMetadata {
  title?: string;
  artist?: string;
}

/**
 * 解析元数据行。
 * 返回 true 表示「本行已被消费」，调用方应跳过该行。
 * 注意：[al:] / [by:] / [offset:] 等一律不解析，其整行会被静默丢弃——这是上游的真实行为。
 */
export function parseMetadataLine(line: string, metadata: LyricMetadata): boolean {
  const matched = line.match(METADATA_REGEX);
  if (matched === null) {
    return false;
  }
  const key = matched[1].toLowerCase();
  const value = matched[2].trim();
  if (key === 'ti') {
    metadata.title = value;
  } else {
    metadata.artist = value;
  }
  return true;
}

interface WeightedToken {
  text: string;
  weight: number;
}

/**
 * 假逐字时轴生成。
 *
 * 上游 buildTimedWords 的逐行复刻：
 *  - CJK 逐 UTF-16 码元切分，标点权重 0；
 *  - 拉丁词权重 1 + 长度*0.15；
 *  - 只分配 0.9 的时长，留 10% 空白；
 *  - 单字最小时长 0.05s，标点推进 0.05s；
 *  - 若最后一词越过行尾，整体等比回缩。
 */
export function buildTimedWords(text: string, startTime: number, endTime: number): LyricWord[] {
  const duration = Math.max(endTime - startTime, 0.1);
  const rawTokens = text.split(/\s+/).filter((t: string) => t.length > 0);

  const tokens: WeightedToken[] = [];
  let totalWeight = 0;
  for (const token of rawTokens) {
    if (CJK_REGEX.test(token)) {
      // 逐 UTF-16 码元；代理对会被拆开，与上游行为一致
      const chars = token.split('');
      for (const char of chars) {
        const isPunctuation = CJK_PUNCTUATION_REGEX.test(char);
        const weight = isPunctuation ? 0 : 1;
        tokens.push({ text: char, weight: weight });
        totalWeight += weight;
      }
    } else {
      const weight = 1 + token.length * 0.15;
      tokens.push({ text: token, weight: weight });
      totalWeight += weight;
    }
  }
  if (totalWeight === 0) {
    totalWeight = 1;
  }

  const activeDuration = duration * 0.9;
  const timePerWeight = activeDuration / totalWeight;

  const words: LyricWord[] = [];
  let currentWordStart = startTime;
  for (const token of tokens) {
    const wordDuration = token.weight * timePerWeight;
    const finalDuration = Math.max(wordDuration, 0.05);
    words.push({
      text: token.text,
      startTime: currentWordStart,
      endTime: currentWordStart + finalDuration
    });
    currentWordStart += token.weight > 0 ? wordDuration : 0.05;
  }

  // 尾部越界回缩
  if (words.length > 0) {
    const last = words[words.length - 1];
    if (last.endTime > endTime && last.endTime > startTime) {
      const scale = (endTime - startTime) / (last.endTime - startTime);
      for (const word of words) {
        word.startTime = startTime + (word.startTime - startTime) * scale;
        word.endTime = startTime + (word.endTime - startTime) * scale;
      }
    }
  }
  return words;
}

/** 是否为间奏行 */
export function isInterludeLine(line: LyricLine): boolean {
  return line.fullText === INTERLUDE_FULL_TEXT;
}

/** 构造间奏行：恰好 6 个等分的 '.' 词 */
function createInterlude(start: number, end: number): LyricLine {
  const duration = end - start;
  const words: LyricWord[] = [];
  const wordDuration = duration / 6;
  for (let index = 0; index < 6; index += 1) {
    words.push({
      text: '.',
      startTime: start + index * wordDuration,
      endTime: start + (index + 1) * wordDuration
    });
  }
  const line: LyricLine = {
    startTime: start,
    endTime: end,
    fullText: INTERLUDE_FULL_TEXT,
    words: words,
    isInterlude: true
  };
  return line;
}

/**
 * 首行晚于 3s 时在开头补间奏，相邻行间隔大于 3s 时在中间补间奏。
 * 上游 attachInterludes 的逐行复刻。
 */
export function attachInterludes(lines: LyricLine[]): LyricLine[] {
  if (lines.length === 0) {
    return lines;
  }
  const result: LyricLine[] = [];
  if (lines[0].startTime > 3) {
    result.push(createInterlude(0.5, lines[0].startTime - 0.5));
  }
  for (let index = 0; index < lines.length; index += 1) {
    const current = lines[index];
    result.push(current);
    if (index + 1 < lines.length) {
      const next = lines[index + 1];
      const gap = next.startTime - current.endTime;
      if (gap > 3) {
        result.push(createInterlude(current.endTime + 0.05, next.startTime - 0.05));
      }
    }
  }
  return result;
}

/**
 * 计算渲染提示。
 *
 * ⚠️ 简化说明：上游 renderHints 含 rawDuration / timingClass / renderEndTime /
 *    lineTransitionMode / wordRevealMode 五个字段，其中只有阈值（micro < 0.10s、
 *    short < 0.18s）在文档中被逐字确认。这里实现阈值与「短行最小停留」语义：
 *    过短的行会被拉到最小停留时长，避免 UI 闪烁；其余行 renderEndTime = endTime。
 *    lineTransitionMode / wordRevealMode 属于视觉层，ArkTS 版由主题自行决定。
 */
export function annotateLyricLines(lines: LyricLine[]): LyricLine[] {
  for (const line of lines) {
    const rawDuration = line.endTime - line.startTime;
    if (line.renderEndTime === undefined) {
      if (rawDuration < 0.10) {
        line.renderEndTime = Math.max(line.endTime, line.startTime + 0.10);
      } else if (rawDuration < 0.18) {
        line.renderEndTime = Math.max(line.endTime, line.startTime + 0.18);
      } else {
        line.renderEndTime = line.endTime;
      }
    }
  }
  return lines;
}

/** 行后处理链：插间奏 -> 计算渲染提示 */
export function finalizeParsedLyricLines(lines: LyricLine[], includeInterludes: boolean = true): LyricLine[] {
  const withInterludes = includeInterludes ? attachInterludes(lines) : lines;
  return annotateLyricLines(withInterludes);
}

/** 按开始时间升序排序（若已有序则原样返回，避免无谓重排） */
export function sortByStartTimeIfNeeded(lines: LyricLine[], alreadySorted: boolean): LyricLine[] {
  if (alreadySorted) {
    return lines;
  }
  return lines.slice().sort((a: LyricLine, b: LyricLine) => a.startTime - b.startTime);
}

/** 解析通用「时间标签 + 文本」轨（用于翻译 / 罗马音） */
export function parseTimedTextEntries(raw: string): TimedTextEntry[] {
  const entries: TimedTextEntry[] = [];
  if (raw === undefined || raw === null || raw.length === 0) {
    return entries;
  }
  const lines = raw.split(/\r?\n/);
  for (const rawLine of lines) {
    if (rawLine.length === 0) {
      continue;
    }
    const entry = parseSimpleTimedTextEntry(rawLine);
    if (entry !== undefined && entry.text.trim().length > 0) {
      entries.push({ startTime: entry.startTime, text: entry.text.trim() });
    }
  }
  entries.sort((a: TimedTextEntry, b: TimedTextEntry) => a.startTime - b.startTime);
  return entries;
}

interface PairCandidate {
  diff: number;
  line: number;
  entry: number;
}

/**
 * 翻译 / 罗马音配对：±1.0s 窗口内的贪心最近配对，每条线、每条目最多用一次。
 *
 * 上游特别注明的动机（不要「优化」掉）：早期实现用最近邻查询，会让 1 秒内的一条译文
 * 被多行重复使用。精确同时间戳必然优先命中，因此排序键必须是 (diff, line, entry)。
 */
export function findTranslationsForSortedStartTimes(lineStartTimes: number[],
  entries: TimedTextEntry[]): (string | undefined)[] {
  const result: (string | undefined)[] = new Array<string | undefined>(lineStartTimes.length).fill(undefined);
  if (entries.length === 0) {
    return result;
  }
  const lineTaken: boolean[] = new Array<boolean>(lineStartTimes.length).fill(false);
  const entryTaken: boolean[] = new Array<boolean>(entries.length).fill(false);

  const candidates: PairCandidate[] = [];
  for (let lineIndex = 0; lineIndex < lineStartTimes.length; lineIndex += 1) {
    const lineTime = lineStartTimes[lineIndex];
    for (let entryIndex = 0; entryIndex < entries.length; entryIndex += 1) {
      const entryTime = entries[entryIndex].startTime;
      // 左闭右开窗口
      if (entryTime < lineTime - ALTERNATE_TRACK_MATCH_WINDOW) {
        continue;
      }
      if (entryTime >= lineTime + ALTERNATE_TRACK_MATCH_WINDOW) {
        // entries 已按时间升序，可以提前跳出
        break;
      }
      const diff = Math.abs(entryTime - lineTime);
      if (diff < ALTERNATE_TRACK_MATCH_WINDOW) {
        candidates.push({ diff: diff, line: lineIndex, entry: entryIndex });
      }
    }
  }

  candidates.sort((a: PairCandidate, b: PairCandidate) => {
    if (a.diff !== b.diff) {
      return a.diff - b.diff;
    }
    if (a.line !== b.line) {
      return a.line - b.line;
    }
    return a.entry - b.entry;
  });

  for (const candidate of candidates) {
    if (lineTaken[candidate.line] || entryTaken[candidate.entry]) {
      continue;
    }
    lineTaken[candidate.line] = true;
    entryTaken[candidate.entry] = true;
    result[candidate.line] = entries[candidate.entry].text;
  }
  return result;
}

/** 把翻译 / 罗马音写回行；两者都不存在时不动 */
export function applyAlternateTracks(lines: LyricLine[], translation: string,
  romanization: string): void {
  const lineStartTimes = lines.map((line: LyricLine) => line.startTime);
  if (translation.length > 0) {
    const translations = findTranslationsForSortedStartTimes(lineStartTimes, parseTimedTextEntries(translation));
    for (let i = 0; i < lines.length; i += 1) {
      const t = translations[i];
      if (t !== undefined) {
        lines[i].translation = t;
      }
    }
  }
  if (romanization.length > 0) {
    const romanizations = findTranslationsForSortedStartTimes(lineStartTimes, parseTimedTextEntries(romanization));
    for (let i = 0; i < lines.length; i += 1) {
      const r = romanizations[i];
      if (r !== undefined) {
        lines[i].romanization = r;
      }
    }
  }
}

/** 统一换行并去掉 BOM */
export function normalizeText(raw: string): string {
  let text = raw;
  if (text.charCodeAt(0) === 0xFEFF) {
    text = text.slice(1);
  }
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}
