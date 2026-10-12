/**
 * Folia HarmonyOS - 歌词格式解析器
 *
 * 从上游 src/utils/lyrics/parserCore.ts 移植：
 *   parseLRC / parseEnhancedLRC / parseVTT / parseYRC / parseQRC / parseKrc / parseAwlrc
 * 以及 formatDetection.ts 的格式检测。
 *
 * ⚠️ 单位：所有时间均为**秒（float）**。YRC/QRC/KRC 的原始标签是毫秒，在各自解析器里 /1000。
 *
 * ⚠️ ArkTS 注意：所有带 g 标志的正则都在函数内新建，绝不跨调用复用，避免 lastIndex 污染。
 */
import { util } from '@kit.ArkTS';
import { LyricLine, LyricFormat, LyricDocument, LyricWord } from '../../core/Types';
import { Logger } from '../../core/Logger';
import {
  applyAlternateTracks,
  buildTimedWords,
  finalizeParsedLyricLines,
  INTERLUDE_FULL_TEXT,
  normalizeText,
  parseMetadataLine,
  LyricMetadata,
  parseSimpleTimedTextEntry,
  parseTimedTextEntries,
  sortByStartTimeIfNeeded,
  TimedTextEntry
} from './LyricCore';
import { decryptKrc } from './KrcDecoder';
import { decryptQrc } from './QrcDecoder';

const TAG: string = 'LyricParsers';

// ---------------------------------------------------------------------------
// 格式检测
// ---------------------------------------------------------------------------

const VTT_TIMING_LINE_REGEX: RegExp =
  /(?:^|\n)\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}\s*-->\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}/m;
const ENHANCED_LRC_ANGLE_REGEX: RegExp = /<\d{2}:\d{2}[.:]\d{2,3}>/;
const ENHANCED_LRC_INLINE_BRACKET_REGEX: RegExp =
  /(?:^|\n)\s*\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]+(?:\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]*)+/m;
const TTML_ROOT_REGEX: RegExp = /<tt(?:\s|>)/i;

/** 该格式是否携带真实逐字时间（只有这些格式才算逐字，LRC/VTT 的 words 是假时轴） */
export function isWordByWordFormat(format: LyricFormat): boolean {
  return format === LyricFormat.YRC || format === LyricFormat.QRC
    || format === LyricFormat.KRC || format === LyricFormat.ENHANCED_LRC
    || format === LyricFormat.TTML;
}

/** 按扩展名推断显式格式 */
export function formatFromFileName(fileName: string): LyricFormat | undefined {
  const matched = fileName.toLowerCase().match(/\.([^.]+)$/);
  if (matched === null) {
    return undefined;
  }
  switch (matched[1]) {
    case 'vtt':
      return LyricFormat.VTT;
    case 'ttml':
      return LyricFormat.TTML;
    case 'qrc':
      return LyricFormat.QRC;
    case 'yrc':
      return LyricFormat.YRC;
    case 'krc':
      return LyricFormat.KRC;
    default:
      return undefined;
  }
}

/**
 * 检测歌词文本格式。
 * 判定顺序即优先级：TTML -> VTT -> 增强 LRC -> LRC。
 * 与上游一致：仅有 `<tt` 不算 TTML，裸 `-->` 也不算 VTT，避免把歌词正文误判。
 */
export function detectFormat(content: string): LyricFormat {
  const normalized = normalizeText(content).trim();
  if (normalized.length === 0) {
    return LyricFormat.NONE;
  }
  if (TTML_ROOT_REGEX.test(normalized)) {
    const hasNs = normalized.includes('http://www.w3.org/ns/ttml')
      || normalized.includes('itunes:timing=')
      || normalized.includes('ttm:agent=')
      || normalized.includes('ttm:role=');
    if (hasNs) {
      return LyricFormat.TTML;
    }
  }
  if (normalized.startsWith('WEBVTT') || VTT_TIMING_LINE_REGEX.test(normalized)) {
    return LyricFormat.VTT;
  }
  if (ENHANCED_LRC_ANGLE_REGEX.test(normalized)
    || ENHANCED_LRC_INLINE_BRACKET_REGEX.test(normalized)) {
    return LyricFormat.ENHANCED_LRC;
  }
  return LyricFormat.LRC;
}

// ---------------------------------------------------------------------------
// 精确逐字草稿（增强 LRC 的 <mm:ss.xx> 分支与多时间戳括号分支共用）
// ---------------------------------------------------------------------------

interface ParseMarker {
  time: number;
  index: number;
  endIndex: number;
}

interface PreciseDraft {
  words: LyricWord[];
  startTime: number;
  endTime?: number;
  fullText: string;
}

/** 收集全部时间标记的下标与时间；每次重建正则以避免 lastIndex 污染 */
function collectTimestampMarkers(content: string, pattern: RegExp): ParseMarker[] {
  const markers: ParseMarker[] = [];
  const regex = new RegExp(pattern.source, 'g');
  let matched = regex.exec(content);
  while (matched !== null) {
    const index = matched.index;
    markers.push({
      time: parseTimestampFromGroups(matched[1], matched[2], matched[3]),
      index: index,
      endIndex: index + matched[0].length
    });
    if (regex.lastIndex === matched.index) {
      // 空匹配保护，避免死循环
      regex.lastIndex += 1;
    }
    matched = regex.exec(content);
  }
  return markers;
}

function parseTimestampFromGroups(minute: string, second: string, fraction: string): number {
  return Number(minute) * 60 + Number(second) + parseFloat('0.' + fraction);
}

/**
 * 由时间标记切出逐字草稿。
 * 关键：标记少于 2 个就不算逐字（单标记无法确定任何词的时长）。
 */
function buildPreciseLineDraft(content: string, markers: ParseMarker[]): PreciseDraft | undefined {
  if (markers.length < 2) {
    return undefined;
  }
  const words: LyricWord[] = [];
  let fullText = '';
  for (let index = 0; index < markers.length - 1; index += 1) {
    const segment = content.slice(markers[index].endIndex, markers[index + 1].index).replace(/\r/g, '');
    fullText += segment;
    if (segment.trim().length === 0) {
      continue;
    }
    words.push({
      text: segment,
      startTime: markers[index].time,
      endTime: markers[index + 1].time
    });
  }
  const lastMarker = markers[markers.length - 1];
  const trailingText = content.slice(lastMarker.endIndex).replace(/\r/g, '');
  fullText += trailingText;
  if (trailingText.trim().length > 0) {
    // 尾词的结束时间交给后续「下一词开始 / 行尾」回填
    words.push({ text: trailingText, startTime: lastMarker.time, endTime: lastMarker.time });
  }
  if (fullText.trim().length === 0) {
    return undefined;
  }
  const draft: PreciseDraft = {
    words: words,
    startTime: words.length > 0 ? words[0].startTime : markers[0].time,
    endTime: words.length > 0 ? words[words.length - 1].endTime : undefined,
    fullText: fullText
  };
  return draft;
}

// ---------------------------------------------------------------------------
// LRC
// ---------------------------------------------------------------------------

/**
 * 标准 LRC。
 * 末行时长恒为 5s（因为 duration=5 不满足 `> 5` 的压缩条件）；
 * 中段行若明显长于阅读时间则压缩到「阅读时间 + 2s」。
 */
export function parseLrc(content: string, translation: string = '',
  romanization: string = '', includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content);
  const metadata: LyricMetadata = {};
  const rawEntries: TimedTextEntry[] = [];
  let sorted = true;
  let previousStart = -1;

  const lines = normalized.split('\n');
  for (const rawLine of lines) {
    if (rawLine.length === 0) {
      continue;
    }
    if (parseMetadataLine(rawLine, metadata)) {
      continue;
    }
    const entry = parseSimpleTimedTextEntry(rawLine);
    if (entry === undefined || entry.text.trim().length === 0) {
      continue;
    }
    if (entry.startTime < previousStart) {
      sorted = false;
    }
    previousStart = entry.startTime;
    rawEntries.push(entry);
  }

  const orderedEntries = sortByStartTimeIfNeededEntries(rawEntries, sorted);
  const result: LyricLine[] = [];
  for (let index = 0; index < orderedEntries.length; index += 1) {
    const current = orderedEntries[index];
    const next = index + 1 < orderedEntries.length ? orderedEntries[index + 1] : undefined;
    let duration = next !== undefined ? next.startTime - current.startTime : 5;
    const estimatedReadingTime = current.text.length * 0.5;
    if (duration > estimatedReadingTime + 2 && duration > 5) {
      duration = Math.min(duration, estimatedReadingTime + 2);
    }
    const endTime = current.startTime + duration;
    const line: LyricLine = {
      startTime: current.startTime,
      endTime: endTime,
      fullText: current.text,
      words: buildTimedWords(current.text, current.startTime, endTime)
    };
    result.push(line);
  }

  applyAlternateTracks(result, translation, romanization);
  return buildDocument(LyricFormat.LRC, finalizeParsedLyricLines(result, includeInterludes), false);
}

function sortByStartTimeIfNeededEntries(entries: TimedTextEntry[], alreadySorted: boolean): TimedTextEntry[] {
  if (alreadySorted) {
    return entries;
  }
  return entries.slice().sort((a: TimedTextEntry, b: TimedTextEntry) => a.startTime - b.startTime);
}

// ---------------------------------------------------------------------------
// 增强 LRC（A2 逐字）
// ---------------------------------------------------------------------------

const LINE_TIME_REGEX: RegExp = /^\[(\d{2}):(\d{2})[.:](\d{2,3})\]/;
const GLOBAL_ANGLE_SOURCE: string = '<(\\d{2}):(\\d{2})[.:](\\d{2,3})>';
const GLOBAL_BRACKET_SOURCE: string = '\\[(\\d{2}):(\\d{2})[.:](\\d{2,3})\\]';

/**
 * 增强 LRC：逐行三分支，顺序固定
 *  1. `<mm:ss.xx>` 尖括号逐字（在剥掉行首 [mm:ss.xx] 之后的 body 上找）
 *  2. 同一行多个 `[...]` 时间戳
 *  3. 普通行（退化为整行）
 */
export function parseEnhancedLrc(content: string, translation: string = '',
  romanization: string = '', includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content);
  const metadata: LyricMetadata = {};
  const drafts: PreciseDraft[] = [];
  let sorted = true;
  let previousStart = -1;

  const lines = normalized.split('\n');
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    if (parseMetadataLine(line, metadata)) {
      continue;
    }

    const lineTag = line.match(LINE_TIME_REGEX);
    const body = lineTag !== null ? line.slice(lineTag[0].length) : line;

    // 分支 1：尖括号逐字
    if (body.includes('<')) {
      const markers = collectTimestampMarkers(body, new RegExp(GLOBAL_ANGLE_SOURCE, 'g'));
      const draft = buildPreciseLineDraft(body, markers);
      if (draft !== undefined) {
        if (draft.startTime < previousStart) {
          sorted = false;
        }
        previousStart = draft.startTime;
        drafts.push(draft);
        continue;
      }
    }

    // 分支 2：同行多个方括号时间戳
    if (line.indexOf('[', 1) !== -1) {
      const markers = collectTimestampMarkers(line, new RegExp(GLOBAL_BRACKET_SOURCE, 'g'));
      const draft = buildPreciseLineDraft(line, markers);
      if (draft !== undefined) {
        if (draft.startTime < previousStart) {
          sorted = false;
        }
        previousStart = draft.startTime;
        drafts.push(draft);
        continue;
      }
    }

    // 分支 3：普通整行
    const entry = parseSimpleTimedTextEntry(line);
    if (entry !== undefined) {
      const draft: PreciseDraft = {
        words: [],
        startTime: entry.startTime,
        fullText: entry.text
      };
      if (draft.startTime < previousStart) {
        sorted = false;
      }
      previousStart = draft.startTime;
      drafts.push(draft);
    }
  }

  const ordered = sortDraftsIfNeeded(drafts, sorted);
  const hasWordTiming = ordered.some((draft: PreciseDraft) => draft.words.length > 0);

  const result: LyricLine[] = [];
  for (let index = 0; index < ordered.length; index += 1) {
    const draft = ordered[index];
    const next = index + 1 < ordered.length ? ordered[index + 1] : undefined;
    const fallbackEnd = draft.endTime ?? (next !== undefined ? next.startTime : draft.startTime + 5);
    let lineEndTime = Math.max(fallbackEnd, draft.startTime + 0.001);

    let words: LyricWord[];
    if (draft.words.length > 0) {
      words = [];
      for (let wordIndex = 0; wordIndex < draft.words.length; wordIndex += 1) {
        const word = draft.words[wordIndex];
        const nextWord = wordIndex + 1 < draft.words.length ? draft.words[wordIndex + 1] : undefined;
        const wordFallbackEnd = nextWord !== undefined ? nextWord.startTime : lineEndTime;
        const endTime = Math.max(word.endTime > 0 ? word.endTime : wordFallbackEnd, word.startTime + 0.001);
        words.push({ text: word.text, startTime: word.startTime, endTime: endTime });
      }
    } else {
      words = buildTimedWords(draft.fullText, draft.startTime, lineEndTime);
    }
    if (words.length > 0) {
      lineEndTime = Math.max(lineEndTime, words[words.length - 1].endTime);
    }

    const line: LyricLine = {
      startTime: draft.startTime,
      endTime: lineEndTime,
      fullText: draft.fullText,
      words: words
    };
    result.push(line);
  }

  applyAlternateTracks(result, translation, romanization);
  // 上游只有「至少一行带真实逐字」才算逐字文件；混合文件也算逐字
  return buildDocument(LyricFormat.ENHANCED_LRC, finalizeParsedLyricLines(result, includeInterludes), hasWordTiming);
}

function sortDraftsIfNeeded(drafts: PreciseDraft[], alreadySorted: boolean): PreciseDraft[] {
  if (alreadySorted) {
    return drafts;
  }
  return drafts.slice().sort((a: PreciseDraft, b: PreciseDraft) => a.startTime - b.startTime);
}

// ---------------------------------------------------------------------------
// VTT
// ---------------------------------------------------------------------------

const VTT_CUE_TIMING_REGEX: RegExp =
  /^((?:\d{2}:)?\d{2}:\d{2}\.\d{3})\s*-->\s*((?:\d{2}:)?\d{2}:\d{2}\.\d{3})(?:\s+.*)?$/;

function parseVttTimestamp(value: string): number {
  const parts = value.split(':');
  if (parts.length === 3) {
    return Number(parts[0]) * 3600 + Number(parts[1]) * 60 + parseFloat(parts[2]);
  }
  if (parts.length === 2) {
    return Number(parts[0]) * 60 + parseFloat(parts[1]);
  }
  return parseFloat(value);
}

function stripVttCueText(text: string): string {
  return text.replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

interface VttEntry {
  startTime: number;
  endTime: number;
  text: string;
}

/** WebVTT：按空行分块，块内找 cue 时间行，其余行拼接为文本 */
export function parseVtt(content: string, includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content).trim();
  if (normalized.length === 0) {
    return buildDocument(LyricFormat.VTT, [], false);
  }
  const entries: VttEntry[] = [];
  const blocks = normalized.split(/\n{2,}/);
  for (const block of blocks) {
    const lines = block.split('\n')
      .map((l: string) => l.trim())
      .filter((l: string) => l.length > 0);
    if (lines.length === 0) {
      continue;
    }
    const head = lines[0];
    if (head === 'WEBVTT' || head.startsWith('NOTE') || head === 'STYLE' || head === 'REGION') {
      continue;
    }
    let timingLineIndex = -1;
    for (let i = 0; i < lines.length; i += 1) {
      if (VTT_CUE_TIMING_REGEX.test(lines[i])) {
        timingLineIndex = i;
        break;
      }
    }
    if (timingLineIndex === -1) {
      continue;
    }
    const matched = lines[timingLineIndex].match(VTT_CUE_TIMING_REGEX);
    if (matched === null) {
      continue;
    }
    const text = stripVttCueText(lines.slice(timingLineIndex + 1).join(' '));
    if (text.length === 0) {
      continue;
    }
    entries.push({
      startTime: parseVttTimestamp(matched[1]),
      endTime: parseVttTimestamp(matched[2]),
      text: text
    });
  }
  entries.sort((a: VttEntry, b: VttEntry) => a.startTime - b.startTime);

  const result: LyricLine[] = [];
  for (let index = 0; index < entries.length; index += 1) {
    const current = entries[index];
    const next = index + 1 < entries.length ? entries[index + 1] : undefined;
    const fallbackEnd = next !== undefined ? next.startTime : current.startTime + 5;
    const endTime = Math.max(current.endTime > 0 ? current.endTime : fallbackEnd, current.startTime + 0.1);
    const line: LyricLine = {
      startTime: current.startTime,
      endTime: endTime,
      fullText: current.text,
      words: buildTimedWords(current.text, current.startTime, endTime)
    };
    result.push(line);
  }
  // VTT 没有真实逐字时间
  return buildDocument(LyricFormat.VTT, finalizeParsedLyricLines(result, includeInterludes), false);
}

// ---------------------------------------------------------------------------
// YRC（网易云逐字）
// ---------------------------------------------------------------------------

const YRC_LINE_REGEX: RegExp = /^\[(\d+),(\d+)\](.*)/;

/**
 * YRC：行标签 `[绝对毫秒,时长毫秒]`，词标签 `(绝对毫秒,时长毫秒,?,文本)`。
 * 词时间是**绝对毫秒**。
 */
export function parseYrc(content: string, translation: string = '',
  romanization: string = '', includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content);
  const result: LyricLine[] = [];
  let sorted = true;
  let previousStart = -1;

  const rawLines = normalized.split('\n');
  for (const rawLine of rawLines) {
    const matched = rawLine.match(YRC_LINE_REGEX);
    if (matched === null) {
      continue;
    }
    const lineStartMs = Number(matched[1]);
    const lineDurationMs = Number(matched[2]);
    const rest = matched[3];

    const words: LyricWord[] = [];
    let fullText = '';
    const wordRegex = new RegExp('\\((\\d+),(\\d+),\\d+\\)([^\\(]*)', 'g');
    let wordMatched = wordRegex.exec(rest);
    while (wordMatched !== null) {
      const wordStartMs = Number(wordMatched[1]);
      const wordDurationMs = Number(wordMatched[2]);
      const text = wordMatched[3];
      if (text.length > 0) {
        words.push({
          text: text,
          startTime: wordStartMs / 1000,
          endTime: (wordStartMs + wordDurationMs) / 1000
        });
        fullText += text;
      }
      wordMatched = wordRegex.exec(rest);
    }
    if (words.length === 0) {
      continue;
    }
    const startTime = lineStartMs / 1000;
    const endTime = (lineStartMs + lineDurationMs) / 1000;
    if (startTime < previousStart) {
      sorted = false;
    }
    previousStart = startTime;
    result.push({ startTime: startTime, endTime: endTime, fullText: fullText, words: words });
  }

  const ordered = sortByStartTimeIfNeeded(result, sorted);
  applyAlternateTracks(ordered, translation, romanization);
  return buildDocument(LyricFormat.YRC, finalizeParsedLyricLines(ordered, includeInterludes), true);
}

// ---------------------------------------------------------------------------
// QRC（QQ 音乐逐字）
// ---------------------------------------------------------------------------

const QRC_LINE_REGEX: RegExp = /^\[(\d+),(\d+)\](.*)/;

interface QrcTag {
  startMs: number;
  durationMs: number;
  tagStart: number;
  tagEnd: number;
}

/**
 * QRC：行标签与 YRC 相同；词标签 `(开始毫秒,时长毫秒[,可选])`。
 *
 * 难点在于**词标签与文本的相对位置不固定**（`(t,d)词`、`词(t,d)`、`(t,d)词(t,d)词` 都合法），
 * 因此先收集全部标签位置，把文本切成 tags.length+1 个片段，再按前瞻/后置偏好决定每个词取哪一段。
 */
export function parseQrc(content: string, translation: string = '',
  romanization: string = '', includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content);
  const result: LyricLine[] = [];
  let sorted = true;
  let previousStart = -1;

  const rawLines = normalized.split('\n');
  for (const rawLine of rawLines) {
    const matched = rawLine.match(QRC_LINE_REGEX);
    if (matched === null) {
      continue;
    }
    const lineStartMs = Number(matched[1]);
    const lineDurationMs = Number(matched[2]);
    const rest = matched[3];

    // 1) 收集标签
    const tags: QrcTag[] = [];
    const tagRegex = new RegExp('\\((\\d+),(\\d+)(?:,\\d+)?\\)', 'g');
    let tagMatched = tagRegex.exec(rest);
    while (tagMatched !== null) {
      tags.push({
        startMs: Number(tagMatched[1]),
        durationMs: Number(tagMatched[2]),
        tagStart: tagMatched.index,
        tagEnd: tagMatched.index + tagMatched[0].length
      });
      tagMatched = tagRegex.exec(rest);
    }
    if (tags.length === 0) {
      continue;
    }

    // 2) 切成 tags.length + 1 段文本
    const textChunks: string[] = [];
    let cursor = 0;
    for (const tag of tags) {
      textChunks.push(rest.slice(cursor, tag.tagStart));
      cursor = tag.tagEnd;
    }
    textChunks.push(rest.slice(cursor));

    const firstChunk = textChunks[0];
    const lastChunk = textChunks[textChunks.length - 1];
    const prefersLeadingText = firstChunk.trim().length > 0 && lastChunk.trim().length === 0;
    const prefersTrailingText = firstChunk.trim().length === 0 && lastChunk.trim().length > 0;

    // 3) 决定每个词取前段还是后段
    const words: LyricWord[] = [];
    let fullText = '';
    for (let index = 0; index < tags.length; index += 1) {
      const leadingText = index < textChunks.length ? textChunks[index] : '';
      const trailingText = index + 1 < textChunks.length ? textChunks[index + 1] : '';
      let text: string;
      if (prefersLeadingText) {
        text = leadingText;
      } else if (prefersTrailingText) {
        text = trailingText;
      } else if (trailingText.trim().length > 0 && leadingText.trim().length === 0) {
        text = trailingText;
      } else if (leadingText.trim().length > 0 && trailingText.trim().length === 0) {
        text = leadingText;
      } else {
        text = trailingText.length >= leadingText.length ? trailingText : leadingText;
      }
      if (text.length === 0) {
        continue;
      }
      words.push({
        text: text,
        startTime: tags[index].startMs / 1000,
        endTime: (tags[index].startMs + tags[index].durationMs) / 1000
      });
      fullText += text;
    }
    if (words.length === 0) {
      continue;
    }
    const startTime = lineStartMs / 1000;
    const endTime = (lineStartMs + lineDurationMs) / 1000;
    if (startTime < previousStart) {
      sorted = false;
    }
    previousStart = startTime;
    result.push({ startTime: startTime, endTime: endTime, fullText: fullText, words: words });
  }

  const ordered = sortByStartTimeIfNeeded(result, sorted);
  applyAlternateTracks(ordered, translation, romanization);
  return buildDocument(LyricFormat.QRC, finalizeParsedLyricLines(ordered, includeInterludes), true);
}

// ---------------------------------------------------------------------------
// KRC（酷狗逐字，解密后解析）
// ---------------------------------------------------------------------------

const KRC_LINE_REGEX: RegExp = /^\[(\d+),(\d+)\](.*)/;
const KRC_LANGUAGE_REGEX: RegExp = /\[language:([^\]]*)\]/;

/** KRC 内嵌语言轨的 JSON 结构 */
interface KrcLanguageItem {
  type: number;
  lyricContent: string[] | string[][];
}

interface KrcLanguageRoot {
  content?: KrcLanguageItem[];
}

/**
 * 从 `[language:BASE64]` 解出内嵌的罗马音（type 0）与翻译（type 1）轨。
 * 不解析这一块会导致酷狗的翻译与罗马音全部丢失。
 */
function readEmbeddedKrcTrack(krcText: string): KrcLanguageTracks {
  const tracks: KrcLanguageTracks = { romanization: [], translation: [] };
  const matched = krcText.match(KRC_LANGUAGE_REGEX);
  if (matched === null) {
    return tracks;
  }
  try {
    let b64 = matched[1].trim();
    while (b64.length % 4 !== 0) {
      b64 += '=';
    }
    const decoded = decodeBase64Utf8(b64);
    if (decoded.length === 0) {
      return tracks;
    }
    const root = JSON.parse(decoded) as KrcLanguageRoot;
    const content = root.content;
    if (content === undefined) {
      return tracks;
    }
    tracks.romanization = readTrackByType(content, 0);
    tracks.translation = readTrackByType(content, 1);
  } catch (error) {
    // 解码失败不影响主歌词
    Logger.err(TAG, 'parse krc language track', error as Error);
  }
  return tracks;
}

interface KrcLanguageTracks {
  romanization: string[];
  translation: string[];
}

function readTrackByType(content: KrcLanguageItem[], type: number): string[] {
  for (const item of content) {
    if (item.type !== type) {
      continue;
    }
    const raw = item.lyricContent;
    const out: string[] = [];
    if (typeof raw === 'string') {
      out.push(raw.trim());
      return out;
    }
    for (const entry of raw) {
      if (typeof entry === 'string') {
        out.push(entry.trim());
      } else {
        out.push(entry.join('').trim());
      }
    }
    return out;
  }
  return [];
}

/** base64 -> UTF-8 字符串 */
function decodeBase64Utf8(b64: string): string {
  const bytes = new util.Base64Helper().decodeSync(b64);
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

/**
 * KRC：行标签 `[绝对毫秒,时长毫秒]`，词标签 `<相对行首毫秒,时长毫秒[,?]>文本`。
 * ⚠️ 词 offset 是**相对行首**的，与 YRC 的绝对毫秒不同，这里是最容易搞错的地方。
 */
export function parseKrc(decrypted: string, includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(decrypted);
  const embedded = readEmbeddedKrcTrack(normalized);

  const result: LyricLine[] = [];
  let sorted = true;
  let previousStart = -1;

  const rawLines = normalized.split('\n');
  for (const rawLine of rawLines) {
    const matched = rawLine.match(KRC_LINE_REGEX);
    if (matched === null) {
      continue;
    }
    const lineStartMs = Number(matched[1]);
    const lineDurationMs = Number(matched[2]);
    const rest = matched[3];

    const words: LyricWord[] = [];
    let fullText = '';
    const wordRegex = new RegExp('<(\\d+),(\\d+)(?:,\\d+)?>([^<]*)', 'g');
    let wordMatched = wordRegex.exec(rest);
    while (wordMatched !== null) {
      const offsetMs = Number(wordMatched[1]);
      const wordDurationMs = Number(wordMatched[2]);
      const text = wordMatched[3];
      if (text.length > 0) {
        // 相对行首 -> 绝对时间
        const absoluteStartMs = lineStartMs + offsetMs;
        words.push({
          text: text,
          startTime: absoluteStartMs / 1000,
          endTime: (absoluteStartMs + wordDurationMs) / 1000
        });
        fullText += text;
      }
      wordMatched = wordRegex.exec(rest);
    }

    const startTime = lineStartMs / 1000;
    const endTime = (lineStartMs + lineDurationMs) / 1000;

    // 没有词标签但有纯文本：退化为假逐字
    if (words.length === 0) {
      const trimmed = rest.trim();
      if (trimmed.length === 0 || trimmed.startsWith('[') || trimmed.startsWith('<')) {
        continue;
      }
      const fallbackWords = buildTimedWords(trimmed, startTime, endTime);
      if (startTime < previousStart) {
        sorted = false;
      }
      previousStart = startTime;
      result.push({ startTime: startTime, endTime: endTime, fullText: trimmed, words: fallbackWords });
      continue;
    }

    if (startTime < previousStart) {
      sorted = false;
    }
    previousStart = startTime;
    result.push({ startTime: startTime, endTime: endTime, fullText: fullText, words: words });
  }

  const ordered = sortByStartTimeIfNeeded(result, sorted);

  // 翻译优先级：内嵌轨按下标一一对应；为空才退回单行最近匹配
  if (embedded.translation.length > 0) {
    for (let i = 0; i < ordered.length; i += 1) {
      const text = i < embedded.translation.length ? embedded.translation[i] : '';
      if (text.length > 0) {
        ordered[i].translation = text;
      } else {
        const fallback = parseTimedTextEntries('');
        const nearest = findNearestSingle(ordered[i].startTime, fallback);
        if (nearest !== undefined) {
          ordered[i].translation = nearest;
        }
      }
    }
  }
  if (embedded.romanization.length > 0) {
    for (let i = 0; i < ordered.length; i += 1) {
      const text = i < embedded.romanization.length ? embedded.romanization[i] : '';
      if (text.length > 0) {
        ordered[i].romanization = text;
      }
    }
  }

  return buildDocument(LyricFormat.KRC, finalizeParsedLyricLines(ordered, includeInterludes), true);
}

function findNearestSingle(startTime: number, entries: TimedTextEntry[]): string | undefined {
  if (entries.length === 0) {
    return undefined;
  }
  let best: TimedTextEntry | undefined = undefined;
  let bestDiff = Number.MAX_VALUE;
  for (const entry of entries) {
    const diff = Math.abs(entry.startTime - startTime);
    if (diff < bestDiff && diff < 1.0) {
      bestDiff = diff;
      best = entry;
    }
  }
  return best === undefined ? undefined : best.text;
}

// ---------------------------------------------------------------------------
// AWLRC（洛雪 / LDDC 容器逐字轨）
// ---------------------------------------------------------------------------

const AWLRC_LINE_REGEX: RegExp = /^\[(\d{1,3}(?::\d{1,3}){0,2})\.(\d{1,3})\](.*)$/;
const AWLRC_WORD_SOURCE: string = '<(\\d+),(\\d+)(?:,\\d+)?>([^<]*)';

/**
 * AWLRC 时间戳：小数部分是**毫秒**而非十进制小数，
 * `[02:43.97]` = 163s + 97ms，而不是 163.97s。读错会最多偏 900ms。
 */
function parseAwlrcTimestamp(fields: string, fraction: string): number {
  const parts = fields.split(':').map((p: string) => parseInt(p, 10));
  while (parts.length < 3) {
    parts.unshift(0);
  }
  return parts[0] * 3600 + parts[1] * 60 + parts[2] + parseInt(fraction, 10) / 1000;
}

/**
 * AWLRC 逐字轨：音节 offset 同样相对行首，并额外用 cursor 修复零时长/时间倒退的标记。
 */
export function parseAwlrc(content: string, translation: string = '',
  romanization: string = '', includeInterludes: boolean = true): LyricDocument {
  const normalized = normalizeText(content);
  const metadata: LyricMetadata = {};
  const drafts: PreciseDraft[] = [];

  const rawLines = normalized.split('\n');
  for (const rawLine of rawLines) {
    const line = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    if (parseMetadataLine(line, metadata)) {
      continue;
    }
    const matched = line.match(AWLRC_LINE_REGEX);
    if (matched === null) {
      continue;
    }
    const startTime = parseAwlrcTimestamp(matched[1], matched[2]);
    const body = matched[3];

    const words: LyricWord[] = [];
    let fullText = '';
    let cursorMs = 0;
    const wordRegex = new RegExp(AWLRC_WORD_SOURCE, 'g');
    let wordMatched = wordRegex.exec(body);
    while (wordMatched !== null) {
      // 修复零时长或时间倒退的音节标记
      const offsetMs = Math.max(parseInt(wordMatched[1], 10), cursorMs);
      const durationMs = Math.max(parseInt(wordMatched[2], 10), 1);
      const text = wordMatched[3];
      words.push({
        text: text,
        startTime: startTime + offsetMs / 1000,
        endTime: startTime + (offsetMs + durationMs) / 1000
      });
      fullText += text;
      cursorMs = offsetMs + durationMs;
      wordMatched = wordRegex.exec(body);
    }
    if (words.length === 0 || fullText.trim().length === 0) {
      continue;
    }
    drafts.push({
      words: words,
      startTime: startTime,
      endTime: startTime + cursorMs / 1000,
      fullText: fullText
    });
  }

  // 无条件排序：有的导出按小数位数而非数值排序
  drafts.sort((a: PreciseDraft, b: PreciseDraft) => a.startTime - b.startTime);

  const result: LyricLine[] = [];
  for (let index = 0; index < drafts.length; index += 1) {
    const draft = drafts[index];
    const next = index + 1 < drafts.length ? drafts[index + 1] : undefined;
    let endTime = draft.endTime ?? draft.startTime + 5;
    if (next !== undefined) {
      endTime = Math.min(endTime, next.startTime);
    }
    endTime = Math.max(endTime, draft.startTime);
    result.push({
      startTime: draft.startTime,
      endTime: endTime,
      fullText: draft.fullText,
      words: draft.words
    });
  }

  applyAlternateTracks(result, translation, romanization);
  return buildDocument(LyricFormat.LRC, finalizeParsedLyricLines(result, includeInterludes), true);
}

// ---------------------------------------------------------------------------
// 统一出口
// ---------------------------------------------------------------------------

function buildDocument(format: LyricFormat, lines: LyricLine[], hasWordTiming: boolean): LyricDocument {
  const doc: LyricDocument = {
    format: format,
    lines: lines,
    offset: 0,
    hasWordTiming: hasWordTiming
  };
  return doc;
}

/** 纯音乐 / 无歌词判定：没有任何带时间戳的行 */
export function hasTimedContent(content: string): boolean {
  if (content.length === 0) {
    return false;
  }
  const normalized = normalizeText(content);
  const lines = normalized.split('\n');
  for (const rawLine of lines) {
    if (rawLine.length === 0) {
      continue;
    }
    if (rawLine.indexOf('[') !== -1 && rawLine.indexOf(']') !== -1) {
      return true;
    }
    if (rawLine.indexOf('<') !== -1 && rawLine.indexOf('>') !== -1) {
      return true;
    }
  }
  return false;
}

/**
 * 解析入口：根据来源与扩展名选择解析器。
 *
 * @param content 原始歌词文本（KRC 传入已解密的文本，QRC 传入密文）
 * @param translation 翻译轨
 * @param romanization 罗马音轨
 * @param explicitFormat 已知格式（来自扩展名或 provider），为 NONE 时自动检测
 */
export function parseLyric(content: string, translation: string = '',
  romanization: string = '', explicitFormat: LyricFormat = LyricFormat.NONE,
  includeInterludes: boolean = true): LyricDocument {
  if (content.length === 0) {
    return buildDocument(LyricFormat.NONE, [], false);
  }
  let format = explicitFormat;
  if (format === LyricFormat.NONE) {
    // 先尝试密文识别
    if (content.startsWith('[') && isQrcCipherLike(content)) {
      const decrypted = decryptQrc(content);
      if (decrypted.length > 0) {
        return parseQrc(decrypted, translation, romanization, includeInterludes);
      }
    }
    format = detectFormat(content);
  }

  switch (format) {
    case LyricFormat.YRC:
      return parseYrc(content, translation, romanization, includeInterludes);
    case LyricFormat.QRC: {
      const decrypted = decryptQrc(content);
      const payload = decrypted.length > 0 ? decrypted : content;
      return parseQrc(payload, translation, romanization, includeInterludes);
    }
    case LyricFormat.KRC:
      return parseKrc(content, includeInterludes);
    case LyricFormat.VTT:
      return parseVtt(content, includeInterludes);
    case LyricFormat.ENHANCED_LRC:
      return parseEnhancedLrc(content, translation, romanization, includeInterludes);
    case LyricFormat.TTML:
      // TTML 需要 XML 解析器，本期退回按增强 LRC 处理并在 UI 标注来源
      Logger.warn(TAG, 'TTML 暂按增强 LRC 解析');
      return parseEnhancedLrc(content, translation, romanization, includeInterludes);
    default:
      return parseLrc(content, translation, romanization, includeInterludes);
  }
}

/** QRC 密文特征：十六进制字符串且长度可观 */
function isQrcCipherLike(content: string): boolean {
  const trimmed = content.trim();
  if (trimmed.length < 32) {
    return false;
  }
  return /^[0-9a-fA-F]+$/.test(trimmed);
}

/** 供本地侧车文件使用：先解密 KRC 二进制再解析 */
export function parseKrcFromBytes(bytes: Uint8Array, includeInterludes: boolean = true): LyricDocument {
  const decrypted = decryptKrc(bytes);
  if (decrypted.length === 0) {
    return buildDocument(LyricFormat.NONE, [], false);
  }
  return parseKrc(decrypted, includeInterludes);
}

/** 导出间奏常量，供 UI 判断 */
export const INTERLUDE_TEXT: string = INTERLUDE_FULL_TEXT;

/** 供测试与调试：把文档转成便于阅读的字符串 */
export function describeDocument(doc: LyricDocument): string {
  const first = doc.lines.length > 0 ? doc.lines[0] : undefined;
  return `format=${doc.format} lines=${doc.lines.length} wordTiming=${doc.hasWordTiming}`
    + (first !== undefined ? ` first=${first.fullText}` : '');
}
