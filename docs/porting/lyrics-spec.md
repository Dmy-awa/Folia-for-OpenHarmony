# Folia 歌词引擎移植规范（HarmonyOS / ArkTS）

> 来源仓库：`_upstream/folia-major-main`（Folia，Electron + React）。
> 本文档是移植歌词引擎的**唯一**参考：所有标识符、正则、常量、权重均逐字取自上游源码，**未做任何改写**。
> 凡属推断（上游未明写、但移植必须做的决定）一律以 `【推断】` 标注。
> 单位约定：**`Line` / `Word` / `LyricSyllable` / `LyricRuby` 的时间字段一律为「秒」，浮点**；
> 毫秒只出现在格式层（YRC/QRC/KRC 标签、Navidrome `start/end`、`offset`）与运行时的 `offsetMs`，
> **换算边界固定在解析器内**（`ms / 1000`）。ArkTS 侧必须保持同一约定，否则全部时序助手失效。

上游歌词引擎文件清单（本规范覆盖范围）：

```
src/types.ts                                        # Line / Word / LyricData / LyricSyllable / LyricRuby / LyricAlternateText / LyricBackgroundVocal
src/types/lyricSegmentation.ts                      # LyricSegmentationRecord
src/types/navidrome.ts                              # StructuredLyric / StructuredLyricLine / StructuredLyricCue / StructuredLyricCueLine / StructuredLyricAgent
src/types/onlineMusic.ts                            # ChorusRange / ProviderLyricsResult
src/utils/lyrics/types.ts                           # Raw*Lyric 源类型 / LyricProcessingOptions / UnifiedLyric
src/utils/lyrics/parserCore.ts                      # 解析核心（LRC / 增强 LRC / VTT / TTML / YRC / QRC / KRC / AWLRC）
src/utils/lyrics/formatDetection.ts                 # 格式嗅探
src/utils/lyrics/LyricParserFactory.ts              # 源 → 适配器分发
src/utils/lyrics/LyricAdapter.ts                    # 适配器接口
src/utils/lyrics/adapters/*.ts                      # 5 个适配器
src/utils/lyrics/timelineSplitter.ts                # 合并时间轴拆轨
src/utils/lyrics/embeddedLrcNormalization.ts        # 内嵌 USLT / structured 归一化
src/utils/lyrics/awlrcContainer.ts                  # 洛雪 [awlrc:] 容器
src/utils/lyrics/foliaLyricDocument.ts              # .fia 自有格式
src/utils/lyrics/lyricFileDecoding.ts               # 字节 → 文本（BOM/UTF-8/GB18030/KRC）
src/utils/lyrics/localLyricFormatOrder.ts           # 同名多歌词文件优先级
src/utils/lyrics/localSongLyrics.ts                 # 本地歌曲歌词来源选择
src/utils/lyrics/enhancedLrcSerializer.ts           # LyricData → 增强 LRC
src/utils/lyrics/wordSegmentation.ts                # 唯一分词入口
src/utils/lyrics/graphemeTiming.ts                  # 字素时序
src/utils/lyrics/sentenceLayout.ts                  # 句子切分（SentenceLayout）
src/utils/lyrics/cjkSemanticLayout.ts               # 布局单元（LyricLayoutUnit）
src/utils/lyrics/renderHints.ts                     # LineRenderHints
src/utils/lyrics/noLyricLines.ts / pureMusic.ts / validity.ts / filtering.ts
src/utils/lyrics/providers/krcDecrypt.ts            # KRC 解密
src/utils/lyrics/providers/qrcDecrypt.ts            # QRC 解密
src/utils/lyrics/providers/qqLyricProvider.ts       # QQ 搜索/取词
src/utils/lyrics/providers/kugouLyricProvider.ts    # 酷狗搜索/取词
src/utils/lyrics/providers/amllApi.ts / amllDbProvider.ts / amllDbCandidates.ts
src/utils/lyrics/neteaseProcessing.ts               # 网易云载荷提取
src/utils/lyrics/navidromeStructuredLyrics.ts       # OpenSubsonic v2 cue 转换
src/utils/lyrics/ttmlConversion.ts                  # TTMLResult → LyricData
src/utils/lyrics/matchScore.ts                      # 匹配打分
src/utils/lyrics/autoMatchBestLyric.ts              # 自动匹配主流程
src/utils/lyrics/lyricMatchSources.ts               # 各源搜索/取词分派
src/utils/lyrics/sourcePriority.ts / searchQuery.ts / duration.ts
src/utils/appPlaybackHelpers.ts                     # findLatestActiveLineIndex
src/components/visualizer/runtime.ts                # getRecentCompletedLine / getUpcomingLine / getUpcomingLines
src/hooks/usePlaybackVisualizerBridge.ts            # 时间 → 行号主循环
src/stores/motionSignals.ts                         # currentTime / lyricCurrentTime
src/utils/lyrics/lyricOffsetMemory.ts               # 每曲偏移记忆
src/stores/useLyricSettingsStore.ts                 # 全局偏移（±2000ms）
src/workers/lyricsParser.worker.ts                  # 解析 worker 协议
```

---

## 1. 规范数据模型（canonical data model）

### 1.1 时间与音节（`src/types.ts:5-33`）

```ts
export interface LyricRuby {
  text: string;
  startTime: number; // Seconds
  endTime: number;   // Seconds
}

export interface LyricSyllable {
  text: string;
  startTime: number; // Seconds
  endTime: number;   // Seconds
  endsWithSpace?: boolean; // TTML：该音节后是否跟空格（决定西文音节是否合并成一个 Word）
  ruby?: LyricRuby[];      // 注音（TTML <ruby>）
  obscene?: boolean;       // TTML：消音/屏蔽标记
  emptyBeat?: number;      // TTML：空拍计数
}

export interface LyricAlternateText {
  role: 'translation' | 'romanization' | string; // 注意：是 string 联合，允许第三方 role
  language?: string;
  text: string;
  syllables?: LyricSyllable[]; // 逐字版副文本（TTML 专有）
}

export interface Word {
  text: string;
  startTime: number; // Seconds
  endTime: number;   // Seconds
  syllables?: LyricSyllable[]; // 仅 TTML 会填充；逐行解析器的 Word 无 syllables
}
```

### 1.2 背景和声（`src/types.ts:35-44`）

```ts
export interface LyricBackgroundVocal {
  text: string;
  startTime: number; // Seconds
  endTime: number;   // Seconds
  words: Word[];
  agentId?: string;
  translation?: string;
  romanization?: string;
  alternateTexts?: LyricAlternateText[];
}
```

### 1.3 行（`src/types.ts:56-76`）——**核心**

```ts
export interface Line {
  words: Word[];
  startTime: number;   // Seconds
  endTime: number;     // Seconds
  fullText: string;    // 显示文本，权威；words.join('') 不保证等于它（LRC 均为假时轴）
  translation?: string;
  id?: string;
  agentId?: string;    // TTML 演唱者 id，对应 LyricData.ttml.agents
  songPart?: string;   // TTML，'chorus' 会被转成 isChorus
  blockIndex?: number; // TTML 段落号，用于 agent 重叠合声的块内判定
  romanization?: string;
  alternateTexts?: LyricAlternateText[];
  backgroundVocal?: LyricBackgroundVocal;   // 首个和声（兼容字段）
  backgroundVocals?: LyricBackgroundVocal[]; // 全部和声（TTML 合声折叠产物）
  renderHints?: LineRenderHints;            // 解析后由 annotateLyricLines 计算
  isChorus?: boolean;
  chorusEffect?: 'bars' | 'circles' | 'beams';
  // 用户保存的精细分词；join('') 必须等于 fullText。存在时优先于 Intl.Segmenter。
  wordSegments?: string[];
}
```

### 1.4 顶层（`src/types.ts:50-87`）

```ts
export interface LyricAgent {
  id: string;
  name?: string;
  type?: string;
}

export interface LyricData {
  lines: Line[];
  title?: string;
  artist?: string;
  isWordByWord?: boolean; // 唯一可信的「是否逐字」标志；见 §3.10
  ttml?: {
    timingMode?: 'Word' | 'Line';
    agents?: Record<string, LyricAgent>;
  };
}

// src/utils/lyrics/types.ts:5
export type UnifiedLyric = LyricData;

export type SubtitleContentMode = 'translation' | 'romanization' | 'both' | 'none';
```

### 1.5 渲染提示（`src/utils/lyrics/renderHints.ts`）

```ts
export type LineTimingClass = 'normal' | 'short' | 'micro';
export type LineTransitionMode = 'normal' | 'fast' | 'none';
export type WordRevealMode = 'normal' | 'fast' | 'instant';

export interface LineRenderHints {
  rawDuration: number;            // max(endTime - startTime, 0)，秒
  timingClass: LineTimingClass;
  renderEndTime: number;          // 行可停留到的最晚时刻（秒）
  lineTransitionMode: LineTransitionMode;
  wordRevealMode: WordRevealMode;
}

export const MICRO_LINE_DURATION_THRESHOLD = 0.10;
export const SHORT_LINE_DURATION_THRESHOLD = 0.18;
export const MICRO_LINE_RENDER_FLOOR = 0.067;

export interface LineTransitionTiming {
  enterDuration: number;
  exitDuration: number;
  linePassHold: number;
}

export const getLineTransitionTiming = (
  rawDuration: number,
  lineTransitionMode: LineTransitionMode,
  wordRevealMode: WordRevealMode
): LineTransitionTiming;
export const buildLineRenderHints: {
  (line: RenderHintLineLike): LineRenderHints;
  (startTime: number, endTime: number): LineRenderHints;
};
export const getLineRenderHints = <T extends RenderHintLineLike>(line: T | null | undefined): LineRenderHints | null;
export const getLineRenderEndTime = <T extends RenderHintLineLike>(line: T | null | undefined): number;
export const migrateLyricLinesRenderHints / annotateLyricLines / ensureLyricLinesRenderHints;
export const migrateLyricDataRenderHints / ensureLyricDataRenderHints;
```

计算规则（逐字复刻，`renderHints.ts:43-163`）：

| 项目 | 规则 |
|---|---|
| `getLastWordEndTime(line)` | `line.words[last]?.endTime ?? line.endTime` |
| `getTimingClass(raw)` | `< 0.10` → `'micro'`；`< 0.18` → `'short'`；否则 `'normal'` |
| `getLineTransitionMode` | micro→`'none'`，short→`'fast'`，normal→`'normal'` |
| `getWordRevealMode` | micro→`'instant'`，short→`'fast'`，normal→`'normal'` |
| `lineTransitionMode === 'none'` | `enter=exit=linePassHold=0`；`renderEndTime = max(endTime, startTime + 0.067)` |
| `lineTransitionMode === 'fast'` | `enterDuration = clamp(raw*0.45, 0.045, 0.06)`；`exitDuration = clamp(raw*0.22, 0.03, 0.04)`；`linePassHold = wordRevealMode==='instant' ? 0 : 0.03` |
| 其余（normal） | `enterDuration = min(0.42, max(0.22, max(raw,0.12)*0.34))`；`exitDuration = min(0.32, max(0.18, max(raw,0.12)*0.18))`；`linePassHold = wordRevealMode==='instant' ? 0 : 0.06` |
| 非 `'none'` 的 `renderEndTime` | `linePassStart = max(getLastWordEndTime(line), startTime) + linePassHold`；`exitStart = (fast ? max(startTime+enter+0.01, linePassStart, endTime-exit) : max(linePassStart, endTime-exit))`；`renderEndTime = max(endTime, exitStart + exitDuration)` |
| `clamp(v,min,max)` | `Math.min(Math.max(v, min), max)` |

`annotateLyricLines(lines) === migrateLyricLinesRenderHints(lines).value`：逐行 `buildLineRenderHints`，五个字段（`rawDuration/timingClass/renderEndTime/lineTransitionMode/wordRevealMode`）全等则保留原对象引用（**不可变约定**：未变化不新建对象）。

### 1.6 处理选项与原始来源（`src/utils/lyrics/types.ts`）

```ts
export interface LyricProcessingOptions {
  includeInterludes?: boolean;   // 缺省 true；见 §3.3
  filterPattern?: string | null; // 正则字符串
  songId?: number;
  fetchChorusRanges?: (songId: number) => Promise<Array<{ startTime: number; endTime: number }>>;
}

export interface RawEmbeddedLyric {
  type: 'embedded';
  usltTags?: Array<{ language?: string; descriptor?: string; text: string }>;
  textContent?: string;
  translationContent?: string;
}
export interface RawLocalFileLyric {
  type: 'local';
  lrcContent: string;
  tLrcContent?: string;
  rLrcContent?: string;   // 独立罗马音轨；优先于合并时间轴拆出来的那条
  formatHint?: LyricParseFormat;
}
export interface RawQrcLyric { type: 'qrc'; qrcContent: string; translationContent?: string; }
export interface RawNeteaseLyric {
  type: 'netease';
  lrc?: { lyric?: string; pureMusic?: boolean;
          yrc?: {lyric?:string;pureMusic?:boolean}; ytlrc?: {...}; yromalrc?: {...}; romalrc?: {...} };
  yrc?: {...}; ytlrc?: {...}; yromalrc?: {...}; tlyric?: {...}; romalrc?: {...};
  pureMusic?: boolean;
}
export interface RawNavidromeLyric {
  type: 'navidrome';
  structuredLyrics?: StructuredLyric | StructuredLyric[] | StructuredLyricLine[];
  plainLyrics?: string;
}
export type RawLyricSource =
  | RawEmbeddedLyric | RawLocalFileLyric | RawQrcLyric | RawNeteaseLyric | RawNavidromeLyric;
```

### 1.7 解析格式与适配器接口

```ts
// src/utils/lyrics/parserCore.ts:9
export type LyricParseFormat = TimedLyricFormat | 'yrc' | 'qrc' | 'krc' | 'awlrc';
// TimedLyricFormat = 'lrc' | 'enhanced-lrc' | 'vtt' | 'ttml'   （formatDetection.ts:1）

// src/utils/lyrics/LyricAdapter.ts
export interface LyricAdapter<T extends RawLyricSource> {
  parse(source: T, options?: LyricProcessingOptions): Promise<LyricData | null>;
}
```

### 1.8 中间草稿类型（`parserCore.ts:11-44`，移植时保留）

```ts
export interface TimedTextEntry { startTime: number; endTime?: number; text: string; }
interface DraftWord  { text: string; startTime: number; endTime?: number; }
interface DraftLine  { words: DraftWord[]; startTime: number; endTime?: number; fullText: string; }
interface TimestampMarker { time: number; index: number; endIndex: number; }
interface LrcMetadata { title?: string; artist?: string; }
interface ParsedTimedEntriesResult { entries: TimedTextEntry[]; isSorted: boolean; }
```

### 1.9 OpenSubsonic 结构化歌词（`src/types/navidrome.ts:275-313`）

```ts
export interface StructuredLyricLine { start: number; value: string; }            // start 单位：毫秒
export interface StructuredLyricCue  { start?: number; end?: number; value: string; byteStart?: number; byteEnd?: number; }
export interface StructuredLyricCueLine {
  index: number; start?: number; end?: number; value: string; agentId?: string; cue?: StructuredLyricCue[];
}
export interface StructuredLyricAgent { id: string; role?: string; name?: string; }
export interface StructuredLyric {
  displayArtist?: string; displayTitle?: string; lang?: string;
  kind?: 'main' | 'translation' | 'pronunciation' | string;
  line: StructuredLyricLine[];
  cueLine?: StructuredLyricCueLine[];
  agents?: StructuredLyricAgent[];
  offset?: number;   // 毫秒
  synced?: boolean;
}
```

### 1.10 提供商结果与合唱区间（`src/types/onlineMusic.ts:103-116`）

```ts
export interface ChorusRange { startTime: number; endTime: number; } // 秒
export interface ProviderLyricsResult {
  lyrics: LyricData | null;
  mainText?: string | null;
  wordByWordText?: string | null;
  translationText?: string | null;
  romanizationText?: string | null;
  isPureMusic: boolean;
  chorusRanges?: ChorusRange[];
}
export type AmllDbPlatform = 'ncm' | 'qq';                          // src/types.ts:1209
export type LyricProviderSource = 'netease' | 'qq' | 'kugou' | 'amll'; // src/types.ts:1208
```

### 1.11 用户分词记录（`src/types/lyricSegmentation.ts`）

```ts
export type LyricSegmentationSource = 'ai' | 'manual';
export interface LyricSegmentationRecord {
  version: 1;
  songKey: string;   // getPlaybackSongKey 的结果，如 'online:netease:123'
  updatedAt: number;
  source: LyricSegmentationSource;
  lines: Record<string, string[]>; // 行 key -> 边界数组，join('') === line.fullText
}
export const LYRIC_SEGMENTATION_RECORD_VERSION = 1;

// src/utils/lyrics/lyricSegmentationRecord.ts:24
export const getLyricLineSegmentationKey = (line: Pick<Line,'startTime'|'fullText'>): string =>
  `${Math.round(line.startTime * 1000)}|${line.fullText}`;
export const SEGMENTATION_DELIMITER = '/';
```

### 1.12 **模型不变量（移植测试必须断言）**

1. 所有 `startTime` / `endTime` 均为秒；行内 `word.startTime` 单调不减（解析器保证）。
2. `line.endTime >= line.startTime`；`word.endTime >= word.startTime`（解析器反复用 `Math.max(..., start + ε)` 保证）。
3. `lines` 按 `startTime` 升序（每个解析器都会排序，见 §3.3）。
4. `isWordByWord === true` **仅**当格式本身带逐字时轴（YRC / QRC / KRC / AWLRC / 带 `<...>` 的增强 LRC / TTML `timingMode === 'Word'`）。**绝不**用 `words.length > 0` 推断——LRC/VTT 也会用 `buildTimedWords` 造出假逐字。（`enhancedLrcSerializer.ts:56-64` 明确写了这条。）
5. `Line.words` 可以包含分隔解析产生的空段排除后的片段；`fullText` 才是权威显示文本。
6. `NO_LYRIC_LINES`（`noLyricLines.ts`）是全局冻结的 `[]`，代表「无歌词」，与「纯音乐」不同：纯音乐在网易云分支里返回 `lyrics: null`。

---

## 2. 支持的输入格式与检测规则

### 2.1 检测函数（`formatDetection.ts` 全文）

```ts
export type TimedLyricFormat = 'lrc' | 'enhanced-lrc' | 'vtt' | 'ttml';
export type NonTtmlTimedLyricFormat = Exclude<TimedLyricFormat, 'ttml'>;
export type ExplicitFileTimedLyricFormat = Exclude<TimedLyricFormat, 'lrc' | 'enhanced-lrc'> | 'yrc' | 'qrc' | 'krc';

const VTT_TIMING_LINE_REGEX = /(?:^|\n)\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}\s*-->\s*(?:\d{2}:)?\d{2}:\d{2}\.\d{3}/m;
const ENHANCED_LRC_ANGLE_REGEX = /<\d{2}:\d{2}[.:]\d{2,3}>/;
const ENHANCED_LRC_INLINE_BRACKET_REGEX = /(?:^|\n)\s*\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]+(?:\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]*)+/m;
const TTML_ROOT_REGEX = /<tt(?:\s|>)/i;
const EXPLICIT_FILE_FORMATS: Record<string, ExplicitFileTimedLyricFormat> = {
  vtt: 'vtt', ttml: 'ttml', qrc: 'qrc', yrc: 'yrc', krc: 'krc',
};
```

`detectTimedLyricFormat(content?: string): TimedLyricFormat` 的**精确判定顺序**（顺序即优先级）：

1. `normalized = content?.replace(/^\uFEFF/, '').trim() || ''`。
2. **TTML**：`TTML_ROOT_REGEX.test(normalized)` **且** `normalized` 含以下任一字符串之一 →
   `'http://www.w3.org/ns/ttml'`、`'itunes:timing='`、`'ttm:agent='`、`'ttm:role='`。
   （仅有 `<tt` 不算；注释里写明这是为了避免把歌词正文里的尖括号文本误判。）
3. **VTT**：`normalized.startsWith('WEBVTT')` **或** `VTT_TIMING_LINE_REGEX.test(normalized)`。
   （注释明确：裸 `-->` 不够，歌词正文可以含 `go --> there`；只有 `VTT_TIMING_LINE_REGEX` 命中的 cue 才会被 `parseVTT` 认下。）
4. **enhanced-lrc**：`ENHANCED_LRC_ANGLE_REGEX.test(normalized)` **或** `ENHANCED_LRC_INLINE_BRACKET_REGEX.test(normalized)`。
   - 前者 = 存在 `<mm:ss.xx>` 或 `<mm:ss.xx.x>`/`<mm:ss.xxx>`（`[.:]` 允许 `:` 或 `.`，小数位 2~3 位）。
   - 后者 = 同一行有「行首时间戳 + 非空文本 + 至少再一个时间戳」（即旧式多时间戳同行的合并布局）。
5. 兜底 → `'lrc'`。

```ts
export function detectNonTtmlTimedLyricFormat(content?: string): NonTtmlTimedLyricFormat {
  const format = detectTimedLyricFormat(content);
  return format === 'ttml' ? 'lrc' : format;
}

export function resolveExplicitFileTimedLyricFormat(fileName?: string): ExplicitFileTimedLyricFormat | undefined {
  const extension = fileName?.toLowerCase().match(/\.([^.]+)$/)?.[1];
  return extension ? EXPLICIT_FILE_FORMATS[extension] : undefined;
}
```

### 2.2 完整格式清单（含**来源**与**检测/分派路径**）

| 编号 | 格式 | 载体 / 来源 | 检测或分派规则 | 解析入口 | `isWordByWord` |
|---|---|---|---|---|---|
| 1 | **LRC**（标准行级） | 本地文件 `.lrc`、内嵌 ID3 USLT、Navidrome plain、缓存 | `detectTimedLyricFormat` 兜底 `'lrc'` | `parseLRC` | `false`（恒） |
| 2 | **增强 LRC / A2 逐字 LRC** | 本地 `.lrc`、内嵌、酷狗下载 | 命中 `ENHANCED_LRC_ANGLE_REGEX` 或 `ENHANCED_LRC_INLINE_BRACKET_REGEX` | `parseEnhancedLRC` | `sortedDrafts.some(d => d.words.length > 0)` |
| 3 | **VTT (WebVTT)** | 本地 `.vtt`、侧车 `.t.vtt` | `startsWith('WEBVTT')` 或 `VTT_TIMING_LINE_REGEX` | `parseVTT` | `false`（恒） |
| 4 | **TTML (AMLL/Apple)** | 本地 `.ttml`、AMLL DB 官方 API | `TTML_ROOT_REGEX` + 命名空间/itunes/ttm 特征串 | `parseTTML` → `TTMLParser.parse` + `buildLyricDataFromTTMLResult` | `result.metadata.timingMode === 'Word'` |
| 5 | **YRC（网易云逐字）** | 网易云 `yrc` / `lrc.yrc` | 上游**不嗅探**：`extractNeteaseLyricPayload` 有 `yrcLrc` 就强制 `'yrc'` | `parseYRC` | `true`（恒） |
| 6 | **QRC（QQ 解密后）** | QQ `GetPlayLyricInfo` → `qrcDecrypt` | `detectIsQrc(content) = content.includes('(') && content.includes(')') && /\[\d+,\d+\]/.test(content)`（`qqLyricProvider.ts:86-88`） | `parseQRC` | `true` |
| 7 | **KRC（酷狗解密后）** | 酷狗下载（`krc1` 头）、本地 `.krc` | 魔数 `[0x6b,0x72,0x63,0x31]` = `"krc1"`（`lyricFileDecoding.isEncryptedKrc`）；酷狗 API 走 `contenttype === '2'` 或非 KRC 头 → 按文本嗅探；成功解密即 `'krc'` | `parseKRC` | `true` |
| 8 | **内嵌 ID3 LRC（USLT / SYLT / 缓存文本）** | `RawEmbeddedLyric` | `usltTags.length > 0` → `normalizeEmbeddedUsltTags`；否则 `textContent` → `normalizeEmbeddedLrcText`；再做 `detectTimedLyricFormat` | `EmbeddedLyricAdapter` → `parseLyricsAsync` | 由实际格式决定 |
| 9 | **LDDC / 洛雪增强（`[awlrc:]` 容器，即 `LyricParseFormat='awlrc'`）** | 酷狗/洛雪导出的 LRC 尾部；内嵌文本 | `extractAwlrcContainer(content)` 命中 `/\[awlrc:(.+)\]/` 且至少一轨解码成功 | `parseAwlrc` | `true` |
| 10 | **Navidrome / OpenSubsonic structured** | `RawNavidromeLyric.structuredLyrics` | `isNavidromeStructuredLyricCollection`（`Array.isArray && every(item => Array.isArray(item.line))`）→ 集合路径；单个对象有 `cueLine` → cue 路径；否则 `line` → 行级路径；再否则 `plainLyrics` | `parseNavidromeStructuredLyrics` / `...Collection` / `normalizeEmbeddedStructuredLyrics` + `parseLyricsAsync` | cue 路径 `words` 有值；否则按嗅探 |
| 11 | **AMLL DB / AMLL TTML DB** | `https://api.amll.dev/v1/lyrics/get`、`/v1/lyrics/search` | 响应 `data.lyrics` 必须含 `<tt`（`/<tt(?:\s|>)/i`），否则丢弃 | 强制 `parseLyricsByFormat('ttml', ttml)` | TTML `timingMode` |
| 12 | **网易云（Netease）** | provider `netease` | `primaryLyrics = yrcLrc || mainLrc`；`format = yrcLrc ? 'yrc' : detectTimedLyricFormat(mainLrc)` | `processNeteaseLyrics` | 强制 `lyrics.isWordByWord = !!yrcLrc` |
| 13 | **QQ 音乐（QQ）** | provider `qq` | 解密后 `detectIsQrc` → `'qrc'`，否则 `detectTimedLyricFormat` | `fetchQQLyrics` → `parseLyricsByFormat` | `parsed.isWordByWord = isQrc` |
| 14 | **酷狗（Kugou）** | provider `kugou` | `decodeKugouDownloadedLyric(bytes, contentType)`：KRC 头 → `krcDecrypt` → `'krc'`；否则 UTF-8 文本 → `detectNonTtmlTimedLyricFormat` | `fetchKugouLyrics` → `parseLyricsByFormat` | 强制 `format === 'krc' || format === 'enhanced-lrc'` |
| 15 | **Folia `.fia`（自有 JSON 信封，非上游请求格式但为本地侧车格式）** | 本地 `.fia` | `looksLikeFoliaLyricDocument`：去 BOM、trimStart 后 `startsWith('{')` 且含 `"folia-lyricdata"` | `parseFoliaLyricDocument`（**跳过全部解析器**） | 取文件内值 |

### 2.3 本地侧车文件格式优先级（`localLyricFormatOrder.ts`）

```ts
export const LOCAL_LYRIC_FILE_FORMATS = ['lrc', 'vtt', 'ttml', 'qrc', 'yrc', 'krc'] as const;
export const DEFAULT_LOCAL_LYRIC_FORMAT_ORDER: readonly LocalLyricFileFormat[] = LOCAL_LYRIC_FILE_FORMATS;

export const getLocalLyricFilePriority = (fileName: string, order: readonly LocalLyricFileFormat[]): number => {
  const extension = fileName.toLowerCase().split('.').pop() || '';
  if (extension === 'fia') return -1;                       // .fia 永远最高
  const index = isLocalLyricFileFormat(extension) ? order.indexOf(extension) : -1;
  return index === -1 ? Number.MAX_SAFE_INTEGER : index;    // 数值越小越优先
};
```

`normalizeLocalLyricFormatOrder(value)`：过滤非法项 → 去重 → 按默认顺序补齐缺失项。

### 2.4 本地歌曲来源选择（`localSongLyrics.ts:12-30`，逐条照抄）

```ts
export const selectLocalSongLyricsSource = (song, priority) => {
  if (song.lyricsSource) {
    if (song.lyricsSource === 'online' && (song.matchedLyrics || song.matchedIsPureMusic)) return 'online';
    if (song.lyricsSource === 'local' && song.localLyricsContent) return 'local';
    if (song.lyricsSource === 'embedded' && song.embeddedLyricsContent) return 'embedded';
    return null;
  }
  if (song.markedPureMusic) return 'online';                                  // 用户标记纯音乐 → 空歌词
  if (priority === 'online' && song.matchedLyrics) return 'online';
  if (song.hasLocalLyrics && song.localLyricsContent) return 'local';
  if (song.hasEmbeddedLyrics && song.embeddedLyricsContent) return 'embedded';
  if (song.matchedLyrics) return 'online';
  return null;
};
```

---

## 3. 解析算法

### 3.1 时间戳与元数据语法（公共正则，`parserCore.ts:46-56`）

```ts
const GLOBAL_LRC_TIME_REGEX = /\[(\d{2}):(\d{2})[.:](\d{2,3})\]/g;
const GLOBAL_ANGLE_TIME_REGEX = /<(\d{2}):(\d{2})[.:](\d{2,3})>/g;
const LRC_LINE_TIME_REGEX = /^\[(\d{2}):(\d{2})[.:](\d{2,3})\]/;
const LEADING_LRC_TAGS_REGEX = /^((?:\[(?:\d{2}):(?:\d{2})[.:](?:\d{2,3})\])+)(.*)$/;
const LRC_METADATA_REGEX = /^\[(ti|ar):([^\]]*)\]$/i;
const AWLRC_LINE_REGEX = /^\[(\d{1,3}(?::\d{1,3}){0,2})\.(\d{1,3})\](.*)$/;
const AWLRC_WORD_REGEX = /<(\d+),(\d+)(?:,\d+)?>([^<]*)/g;
export const INTERLUDE_FULL_TEXT = '......';
```

- 时间戳 = `minute*60 + second + parseFloat('0.' + fraction)`（`parseTimestamp`，`parserCore.ts:249-254`）。
  ⇒ `[01:02.5]` = 62.5s，`[01:02.50]` = 62.5s，`[01:02.500]` = 62.5s；`[01:02:50]` 这类非法形式不匹配。
  分隔符可为 `:` 或 `.`（`[.:]`）。
- **元数据标签只认 `[ti:]` 与 `[ar:]`**（`parseMetadataLine`，大小写不敏感，值是 `[^\]]*` 再 `.trim()`）。
  **`[al:]`、`[by:]`、`[offset:]`、`[re:]`、`[length:]`、`[language:]`（除 KRC 特例）都不会被解析**：
  它们既不进 metadata，也无法匹配 `LEADING_LRC_TAGS_REGEX`，因此**整行被丢弃**。
  这是上游真实行为，移植时不得「顺手支持」`[offset:]`——Folia 的时间轴偏移是运行时偏移，不是文件内偏移（见 §8.4）。
- `parseMetadataLine` 返回 `true` 即表示「本行已消费」，调用方 `continue`。
- **多时间戳行**：`LEADING_LRC_TAGS_REGEX` 捕获**全部**前导时间戳但 `parseSimpleTimedTextEntry` **只取第一个**
  （`match[1].match(LRC_LINE_TIME_REGEX)`），所以 `[00:01.00][00:05.00]文案` 在 `parseLRC` 里只产出一行、时间 1.0s，
  第二个时间戳被静默丢弃。同一行若被 `parseEnhancedLRC` 处理，则会走 `GLOBAL_LRC_TIME_REGEX` 的 bracket 分支
  切成两个 word（见 §3.10 的 bracket 分支）。
- `[language:BASE64]` **仅在 `parseKRC`** 里被识别（`/\[language:([^\]]*)\]/`），见 §3.9。

### 3.2 假逐字时轴生成：`buildTimedWords`（`parserCore.ts:58-117`，**逐行复刻必需**）

```
buildTimedWords(text, startTime, endTime) -> Word[]
duration   = max(endTime - startTime, 0.1)
rawTokens  = text.split(/\s+/).filter(t => t)          // 按空白切
tokens     = []
totalWeight= 0
for token of rawTokens:
    if /[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]/.test(token):     // 含 CJK（汉字/假名/谚文）
        for char of token.split(''):                                // 逐 UTF-16 码元
            isPunctuation = /[，。！？、：；"'）]/.test(char)
            weight = isPunctuation ? 0 : 1
            tokens.push({text: char, weight}); totalWeight += weight
    else:
        weight = 1 + (token.length * 0.15)
        tokens.push({text: token, weight}); totalWeight += weight
if totalWeight === 0: totalWeight = 1
activeDuration = duration * 0.9
timePerWeight  = activeDuration / totalWeight
currentWordStart = startTime
for token of tokens:
    wordDuration  = token.weight * timePerWeight
    finalDuration = max(wordDuration, 0.05)
    words.push({text: token.text, startTime: currentWordStart, endTime: currentWordStart + finalDuration})
    currentWordStart += token.weight > 0 ? wordDuration : 0.05
// 尾部越界回缩（等比缩放到 endTime）
if words.length > 0 && words[last].endTime > endTime:
    scale = (endTime - startTime) / (words[last].endTime - startTime)
    for w of words: w.startTime = startTime + (w.startTime - startTime) * scale
                    w.endTime   = startTime + (w.endTime   - startTime) * scale
return words
```

要点：
- CJK 逐**码元**（不是字素），代理对会被拆开；标点权重 0（时长 0，但推进 0.05s）。
- 拉丁词权重 `1 + len*0.15`，权重和随时间线性分配。
- 只用到 `0.9 * duration`，剩余 10% 是「留白」；仅当最后一词越过行尾才整体回缩。
- 该函数是 `Word[]` 的唯一「假时轴」来源，也是 TTML 无 `words` 时的 fallback。

### 3.3 行后处理链（顺序固定）

```ts
export const isInterludeLine = (line: Pick<Line,'fullText'>): boolean => line.fullText === INTERLUDE_FULL_TEXT;

export const attachInterludes = (lines: Line[]): Line[] => {
  const createInterlude = (start, end): Line => {
    const duration = end - start; const words = []; const wordDuration = duration / 6;
    for (let index = 0; index < 6; index += 1)
      words.push({ text: '.', startTime: start + index*wordDuration, endTime: start + (index+1)*wordDuration });
    return { startTime: start, endTime: end, fullText: INTERLUDE_FULL_TEXT, words };
  };
  if (lines.length > 0 && lines[0].startTime > 3) finalLines.push(createInterlude(0.5, lines[0].startTime - 0.5));
  for (let index = 0; index < lines.length; index += 1) {
    finalLines.push(lines[index]);
    const next = lines[index + 1];
    if (next) { const gap = next.startTime - current.endTime;
                if (gap > 3) finalLines.push(createInterlude(current.endTime + 0.05, next.startTime - 0.05)); }
  }
};

export const finalizeParsedLyricLines = (lines, options: Pick<LyricProcessingOptions,'includeInterludes'> = {}): Line[] =>
  annotateLyricLines(options.includeInterludes === false ? lines : attachInterludes(lines));
```

- 首行 `startTime > 3s` → 插入 `<0.5, firstStart-0.5>` 的间奏行。
- 相邻行间隔 `> 3s` → 插入 `<curEnd+0.05, nextStart-0.05>` 的间奏行。
- 间奏行恒为 `fullText === '......'`、恰好 6 个 `'.'` 的 `Word`（等分）。
- `includeInterludes !== false` 才插；`resolveLyricProcessingOptions` 里 `includeInterludes ??= !regex`，
  即**只要设置了过滤正则，就默认不插间奏**（`filtering.ts:39-47`）。
- 最后一步恒为 `annotateLyricLines`（计算 `renderHints`）。
- `applyLyricDisplayFilter`（工厂出口，`filtering.ts:86-104`）：若有正则，先 `stripInterludes`（去掉 `......` 行），
  再删掉 `regex.test(line.fullText)` 为真的行，然后 `finalizeParsedLyricLines(filtered, { includeInterludes: true })`。

### 3.4 翻译 / 罗马音配对：`findTranslationsForSortedStartTimes`（`parserCore.ts:184-247`）

```
ALTERNATE_TRACK_MATCH_WINDOW = 1.0   // 秒
lowerBoundByStartTime(entries, time) -> 第一个 startTime >= time 的下标（二分，要求 entries 已按 startTime 升序）
```

算法（**贪心最近配对，每条线/每条目最多用一次**）：

1. 对每条线的 `startTime`，扫描 `[startTime - 1.0, startTime + 1.0)` 区间内的条目（左闭右开）。
2. 对每个候选算 `diff = |entry.startTime - line.startTime|`，`diff < 1.0` 才进候选。
3. `candidates.sort((l,r) => l.diff - r.diff || l.line - r.line || l.entry - r.entry)`。
4. 顺序遍历，`lineTaken` / `entryTaken` 双向去重，命中即写 `translations[line] = entry.text`。
5. 未命中的行得到 `undefined`。

注释里的关键动机（不要「优化」掉）：旧实现用最近邻查询，会让 1 秒内的一条译文被多行重复使用
（刚被翻译过的那一行会重复显示翻译；同起点的对唱两行都拿到第一行的翻译）。**精确同时间戳必然优先命中。**

`resolveAlternateTracks`（`parserCore.ts:1125-1147`，仅 AWLRC 用）：
先建 `exactByMs: Map<round(startTime*1000) -> text>`（先到先得，不覆盖）；
若任一行有精确命中，则**全部走精确**（无命中者就是 `undefined`，不外借）；
只有「零精确命中」时才退回 `findTranslationsForSortedStartTimes`。

### 3.5 通用时序文本解析：`parseTimedTextEntries`（`parserCore.ts:369-426`）

用于**译文 / 罗马音轨**（以及 `parseQrcTrackEntries` 的兜底）。步骤：

```
content 去 BOM → split(/\r?\n/)
for rawLine:
    line = rawLine.trim(); 空 → skip
    parseMetadataLine(line, metadata) === true → skip      // 只吃 [ti:]/[ar:]
    lineTagMatch = line.match(LRC_LINE_TIME_REGEX)
    body = lineTagMatch ? line.slice(lineTagMatch[0].length) : line
    angleDraft   = body.includes('<') ? buildPreciseLineDraft(body, GLOBAL_ANGLE_TIME_REGEX 标记) : null
    bracketDraft = angleDraft ? null
                 : (line.indexOf('[', 1) !== -1 ? buildPreciseLineDraft(line, GLOBAL_LRC_TIME_REGEX 标记) : null)
    entry = angleDraft    ? {startTime: angleDraft.startTime, endTime: angleDraft.endTime, text: angleDraft.fullText}
          : bracketDraft  ? {同 angleDraft}
          : parseSimpleTimedTextEntry(line)
    entry 为 null 或 entry.text.length === 0 → skip
    记录 isSorted（entry.startTime < lastStartTime 则 false）
return { entries: sortByStartTimeIfNeeded(entries, isSorted), isSorted }
```

- `parseSimpleTimedTextEntry(line)`（`:347-367`）：要求 `LEADING_LRC_TAGS_REGEX` 命中，取**第一个** `[mm:ss.xx]`，文本 `match[2].trim()`，**空文本返回 null**（整行丢弃）。
- `sortByStartTimeIfNeeded(items, isSorted)`（`:176-182`）：`isSorted === true` 时**原数组原样返回**（不复制、不排序），否则 `[...items].sort((l,r) => l.startTime - r.startTime)`。

### 3.6 精确分词草稿：`buildPreciseLineDraft`（`parserCore.ts:287-345`）

```
maybeBuildPreciseLineDraft(content, pattern, enabled) = enabled ? buildPreciseLineDraft(content, collectTimestampMarkers(content, pattern)) : null
buildPreciseLineDraft(content, markers):
    if markers.length < 2 → null                       // 关键：单标记不算逐字
    words = []; fullText = ''
    for index in 0 .. markers.length-2:
        segment = content.slice(markers[index].endIndex, markers[index+1].index).replace(/\r/g,'')
        fullText += segment
        if (!segment.trim()) continue                  // 纯空白段：计入 fullText，不入 words
        words.push({ text: segment, startTime: markers[index].time, endTime: markers[index+1].time })
    trailingText = content.slice(markers[last].endIndex).replace(/\r/g,'')
    fullText += trailingText
    if (trailingText.trim()) words.push({ text: trailingText, startTime: markers[last].time })  // 注意：无 endTime
    if (!fullText.trim()) → null
    return { words, startTime: words[0]?.startTime ?? markers[0].time, endTime: words[last]?.endTime, fullText }
```

`collectTimestampMarkers(content, pattern)`（`:256-267`）：用 `new RegExp(pattern.source, 'g')` 重建正则（**避免 `lastIndex` 污染**），
`Array.from(content.matchAll(regex))` → `{ time: parseTimestamp(m1,m2,m3), index: match.index ?? 0, endIndex: index + match[0].length }`。

**关键**：`body` 与 `line` 的区别决定了 `<...>` 优先于 `[...]`，且行首的 `[mm:ss.xx]` 会在 angle 分支里被剥掉。

### 3.7 `parseLRC`（`parserCore.ts:428-487`）

```
parseLRC(lrcString, translationString = '', options = {}, romanizationString = ''): LyricData
```

1. 逐行 `parseSimpleTimedTextEntry(rawLine)`（**注意：用未 trim 的 rawLine，但 `^\s*` 不存在于正则，所以行首有空格的时间戳行会失败**）。
2. `entry` 为空或文本空 → skip；记录 `rawEntriesSorted`。
3. `sortedRawEntries = sortByStartTimeIfNeeded(rawEntries, rawEntriesSorted)`。
4. `transEntries = parseTimedTextEntries(translationString).entries`；`romanizationEntries` 同。
5. `translations = findTranslationsForSortedStartTimes(sortedRawEntries.map(e => e.startTime), transEntries)`；romaji 同。
6. 每行时长：
   ```
   duration = next ? next.startTime - current.startTime : 5
   estimatedReadingTime = current.text.length * 0.5
   if (duration > estimatedReadingTime + 2 && duration > 5) duration = Math.min(duration, estimatedReadingTime + 2)
   endTime = current.startTime + duration
   ```
   （**先 `> est+2` 且 `> 5`**，再取 `min(duration, est+2)`。注意末行 `duration = 5` 不满足 `> 5`，故末行恒为 5s。）
7. `lines.push({ words: buildTimedWords(current.text, current.startTime, endTime), startTime, endTime, fullText: current.text, translation, romanization })`。
8. `return { lines: finalizeParsedLyricLines(lines, options), isWordByWord: false }`（**无 `title`/`artist`**：`parseLRC` 不产出 metadata）。

### 3.8 逐字族：YRC / QRC / KRC / AWLRC

#### 3.8.1 `parseYRC`（`:489-568`）

行正则 `/^\[(\d+),(\d+)\](.*)/`（**行首绝对毫秒 + 行时长毫秒**）。
词正则 `/\((\d+),(\d+),(\d+)\)([^\(]*)/g`（`(startMs,durationMs,?,text)`，第 3 字段被解析但忽略），
词时间是**绝对毫秒**：`startTime = wordStartMs/1000`，`endTime = (wordStartMs+wordDurationMs)/1000`。
`fullText = words.map(w=>w.text).join('')`。`words.length === 0` 的行丢弃。
行时间：`lineStartTime = lineStartTimeMs/1000`，`lineEndTime = (lineStartTimeMs+lineDurationMs)/1000`。
翻译/罗马音走 `parseTimedTextEntries` + `findTranslationsForSortedStartTimes`。
返回 `isWordByWord: true`。**YRC 不处理 `[language:]`。**

#### 3.8.2 `parseQRC`（`:570-700`）——最复杂的一个

行正则同上 `^\[(\d+),(\d+)\](.*)`。词标签正则 `/\((\d+),(\d+)(?:,\d+)?\)/g`（**第 3 字段可选**）。

关键点：**QRC 的词标签与文本的相对位置不固定**（有的写出 `(t,d)词`，有的写 `词(t,d)` 或 `(t,d)词(t,d)词`），
所以先收集所有标签的 `{startMs, durationMs, tagStart, tagEnd}`，再把文本切成 `textChunks`：

```
textChunks = []; cursor = 0
for tag of tags: textChunks.push(rest.slice(cursor, tag.tagStart)); cursor = tag.tagEnd
textChunks.push(rest.slice(cursor))
// 长度 = tags.length + 1

prefersLeadingText  = textChunks[0].trim().length > 0 && textChunks[last].trim().length === 0
prefersTrailingText = textChunks[0].trim().length === 0 && textChunks[last].trim().length > 0

for index of 0..tags.length-1:
    leadingText  = textChunks[index]     ?? ''
    trailingText = textChunks[index + 1] ?? ''
    if (prefersLeadingText)        text = leadingText
    else if (prefersTrailingText)  text = trailingText
    else if (trailingText.trim().length > 0 && leadingText.trim().length === 0) text = trailingText
    else if (leadingText.trim().length > 0 && trailingText.trim().length === 0) text = leadingText
    else text = trailingText.length >= leadingText.length ? trailingText : leadingText
    if (!text) continue
    words.push({ text, startTime: tag.startMs/1000, endTime: (tag.startMs + tag.durationMs)/1000 })
    fullText += text
```

`tags.length === 0` 的行整行丢弃。`words.length === 0` 的行丢弃。

翻译/罗马音的解析用**内嵌递归**：

```
const parseQrcTrackEntries = (track: string): TimedTextEntry[] => {
  if (!track.trim()) return [];
  const qrcLines = parseQRC(track).lines;            // 先按 QRC 自己解一遍
  if (qrcLines.length > 0) return qrcLines.map(l => ({ startTime: l.startTime, text: l.fullText }));
  return parseTimedTextEntries(track).entries;        // 兜底当普通定时文本
};
```

返回 `isWordByWord: true`。

#### 3.8.3 `parseKRC`（`:953-1078`）

行正则 `^\[(\d+),(\d+)\](.*)`；词正则 `/\<(\d+),(\d+)(?:,\d+)?\>([^\<]*)/g`。
**词 offset 相对行首**：`wordStartMs = lineStartTimeMs + wordStartOffsetMs`。

`[language:]` 内嵌轨解码（**必须移植，否则酷狗翻译/罗马音全丢**）：

```
langMatch = krcString.match(/\[language:([^\]]*)\]/)
cleanB64 = langMatch[1].trim(); while (cleanB64.length % 4 !== 0) cleanB64 += '='
decoded = base64-utf8-decode(cleanB64)                 // Node: Buffer.from(cleanB64,'base64').toString('utf8')
                                                       // 浏览器: TextDecoder('utf-8').decode(Uint8Array.from(atob(cleanB64), c=>c.charCodeAt(0)))
obj = JSON.parse(decoded)
readEmbeddedTrack(type) = (obj.content?.find(item => item.type === type)?.lyricContent ?? [])
                            .map(lines => Array.isArray(lines) ? lines.join('').trim() : String(lines).trim())
embeddedRomanizations = readEmbeddedTrack(0)   // type 0 = 罗马音
embeddedTranslations  = readEmbeddedTrack(1)   // type 1 = 翻译
```

- 解码失败仅 `console.error`，不抛出。
- 无词标签但有纯文本时：`if (words.length === 0 && trimmedRest.length > 0 && !trimmedRest.startsWith('[') && !trimmedRest.startsWith('<'))`
  → `words = buildTimedWords(trimmedRest, lineStartTime, lineEndTime); fullText = trimmedRest`。
- 翻译优先级：**内嵌轨下标 `index`**（与行序一一对应）优先；为空才用外部轨做**单行**最近匹配
  （`findTranslationsForSortedStartTimes([line.startTime], entries)[0]`）。
- 返回 `isWordByWord: true`。

#### 3.8.4 `parseAwlrc`（洛雪容器逐字轨，`:1089-1232`）

时间戳语义**与 LRC 不同**（注释 `:1080-1088` 明确警告）：

```
parseAwlrcTimestamp(fields, fraction):
    parts = fields.split(':').map(p => parseInt(p, 10))
    while (parts.length < 3) parts.unshift(0)
    [hours, minutes, seconds] = parts
    return hours*3600 + minutes*60 + seconds + parseInt(fraction, 10) / 1000
```

⇒ 小数部分是**逐字毫秒数**，不是十进制小数：`[02:43.97]` = 163s + 97ms（**不是** 163.97s）。
只有 QQ 适配器会补零到三位；酷狗/咪咕不补零。读成 LRC 的厘秒会最多偏 900ms。

主轨算法：

```
for line of awlrcString (去 BOM, split /\r?\n/, trim, 空行/元数据行 skip):
    lineMatch = AWLRC_LINE_REGEX              // 不命中 skip
    startTime = parseAwlrcTimestamp(m1, m2)
    cursorMs = 0                              // 修复零时长/倒退的音节标记
    AWLRC_WORD_REGEX.lastIndex = 0
    while wordMatch = AWLRC_WORD_REGEX.exec(lineMatch[3]):
        offsetMs   = Math.max(parseInt(m1,10), cursorMs)
        durationMs = Math.max(parseInt(m2,10), 1)
        words.push({ text: m3, startTime: startTime + offsetMs/1000, endTime: startTime + (offsetMs+durationMs)/1000 })
        cursorMs = offsetMs + durationMs
        fullText += m3
    if (words.length === 0 || !fullText.trim()) skip
    drafts.push({ words, startTime, endTime: startTime + cursorMs/1000, fullText })

drafts.sort((l,r) => l.startTime - r.startTime)     // 无条件排序（注释：有的导出按小数位数而非数值排）
translations  = resolveAlternateTracks(startTimes, parseAwlrcAlternateTrack(translationString))
romanizations = resolveAlternateTracks(startTimes, parseAwlrcAlternateTrack(romanizationString))
line.endTime  = next ? Math.min(draft.endTime, next.startTime) : draft.endTime
line.endTime  = Math.max(endTime, draft.startTime)
```

`parseAwlrcAlternateTrack(content)`（`:1100-1114`）：用 `AWLRC_LINE_REGEX` 逐行取 `m3.trim()` 非空者，
`startTime = parseAwlrcTimestamp(m1, m2)`，**同缩进同时间戳语义**（关键：容器各轨由同一 LX writer 写，必须同解析）。
返回 `isWordByWord: true`，并带 `title`/`artist`（来自 `[ti:]`/`[ar:]`）。

### 3.9 VTT（`parserCore.ts:702-816`）

```
parseVttTimestamp(value): split(':')；3 段→h*3600+m*60+s；2 段→m*60+s；1 段→s（秒为 parseFloat）
stripVttCueText(text): 去掉 /<[^>]+>/g → '&nbsp;'→' ' → '&amp;'→'&' → '&lt;'→'<' → '&gt;'→'>' → /\s+/g→' ' → trim
parseVTTEntries(vttString):
    normalized = 去 BOM → \r\n→\n → trim；空 → []
    blocks = normalized.split(/\n{2,}/)
    timingLineRegex = /^((?:\d{2}:)?\d{2}:\d{2}\.\d{3})\s*-->\s*((?:\d{2}:)?\d{2}:\d{2}\.\d{3})(?:\s+.*)?$/
    for block:
        lines = block.split('\n').map(trim).filter(Boolean)
        lines 空 || lines[0] === 'WEBVTT' || lines[0].startsWith('NOTE') || lines[0] === 'STYLE' || lines[0] === 'REGION' → skip
        timingLineIndex = lines.findIndex(l => timingLineRegex.test(l))；-1 → skip
        text = stripVttCueText(lines.slice(timingLineIndex+1).join(' '))；空 → skip
        push { startTime, endTime, text }
    return entries.sort((l,r) => l.startTime - r.startTime)     // 恒排序
```

`parseVTT`：行 `endTime = Math.max(current.endTime || fallbackEndTime, current.startTime + 0.1)`，
其中 `fallbackEndTime = next ? next.startTime : current.startTime + 5`。
`words = buildTimedWords(current.text, current.startTime, endTime)`（**VTT 无逐字，但有假时轴**）。
返回 `isWordByWord: false`。

### 3.10 增强 LRC（`parseEnhancedLRC`，`:838-946`）

逐行三分支，**顺序固定**：

1. `line = rawLine.trim()`；空 → skip；`parseMetadataLine` 命中 → skip（会写 `metadata.title/artist`）。
2. `lineTagMatch = line.match(LRC_LINE_TIME_REGEX)`；`body = lineTagMatch ? line.slice(lineTagMatch[0].length) : line`。
3. **angle 分支**：`body.includes('<')` → `maybeBuildPreciseLineDraft(body, GLOBAL_ANGLE_TIME_REGEX, true)`；命中即 `drafts.push` 并 `continue`。
4. **bracket 分支**：`line.indexOf('[', 1) !== -1` → `maybeBuildPreciseLineDraft(line, GLOBAL_LRC_TIME_REGEX, true)`；命中即 push 并 `continue`。
5. **普通行**：`parseSimpleTimedTextEntry(line)` 命中 → push `{ words: [], startTime, fullText: text }`（**无 endTime**），继续。
6. 每分支都更新 `isSorted`。

出稿：

```
sortedDrafts = sortByStartTimeIfNeeded(drafts, isSorted)
translations  = findTranslationsForSortedStartTimes(sortedDrafts.map(d => d.startTime), transEntries)
romanizations = findTranslationsForSortedStartTimes(..., romanizationEntries)

for draft, index:
    lineEndTime = Math.max(draft.endTime ?? sortedDrafts[index+1]?.startTime ?? (draft.startTime + 5), draft.startTime + 0.001)
    words = draft.words.length > 0
        ? draft.words.map((word, wordIndex) => {
              nextWordStart = draft.words[wordIndex+1]?.startTime
              fallbackEnd   = nextWordStart ?? lineEndTime
              endTime       = Math.max(word.endTime ?? fallbackEnd, word.startTime + 0.001)
              return { text: word.text, startTime: word.startTime, endTime }
          })
        : buildTimedWords(draft.fullText, draft.startTime, lineEndTime)
    if (words.length > 0) lineEndTime = Math.max(lineEndTime, words[words.length-1].endTime)

return {
  lines: finalizeParsedLyricLines(lines, options),
  title: metadata.title, artist: metadata.artist,
  isWordByWord: sortedDrafts.some(draft => draft.words.length > 0),   // 混合文件也算逐字
}
```

### 3.11 TTML（`parseTTML` + `ttmlConversion.ts`）

```ts
export const parseTTML = (ttmlString, _translationString = '', options = {}, _romanizationString = ''): LyricData => {
  const ttmlResult = TTMLParser.parse(ttmlString.replace(/^\uFEFF/, ''), { domParser: new DOMParser() });
  const parsed = buildLyricDataFromTTMLResult(ttmlResult, buildTimedWords);
  return { ...parsed, lines: finalizeParsedLyricLines(parsed.lines, options) };
};
```

- 依赖：`@applemusic-like-lyrics/ttml@^1.0.1`（`TTMLParser.parse(text, { domParser })`）+
  `@xmldom/xmldom@^0.9.12` 的 `DOMParser`。**译文/罗马音参数被忽略（`_` 前缀）**——TTML 自带多轨。
- `buildLyricDataFromTTMLResult(result, buildTimedWords)` 的映射规则：
  - `seconds(ms) = Math.max((ms ?? 0)/1000, 0)`。
  - `convertSyllable(syllable): LyricSyllable` —— 只在为真时写 `endsWithSpace` / `obscene` / `emptyBeat` / `ruby`。
  - `convertRuby`：`{ text, startTime: seconds(tag.startTime), endTime: seconds(tag.endTime) }`。
  - `buildWordsFromSyllables(syllables, fallbackText, startTime, endTime, buildTimedWords)`：
    - 无 syllables → `fallbackText.trim() ? buildTimedWords(fallbackText, startTime, endTime) : []`。
    - 否则按「西文可连接音节合并」规则分组，**组内合并成一个 `Word` 但保留 `syllables`**：
      ```
      NON_WESTERN_TEXT_REGEX = /[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]/u
      WESTERN_JOINABLE_TEXT_REGEX = /[\p{Script=Latin}\p{N}'’`-]/u
      isWesternJoinableSyllable(text): trimmed 非空 && 不含非西文 && 命中 WESTERN_JOINABLE
      shouldMergeWithNext = next && !current.endsWithSpace
                          && isWesternJoinableSyllable(current.text) && isWesternJoinableSyllable(next.text)
      ```
      合并后的 `Word = { text: 组内 text 拼接, startTime: 首个音节.startTime, endTime: 末个音节.endTime, syllables: 组 }`。
  - `convertAlternateTexts(role, entries)` → `LyricAlternateText[]`（过滤空 text；带 `language`、`syllables`）。
  - `convertLine(line)` 产出 `Line`，其中：`isChorus` 由 `songPart?.trim().toLowerCase() === 'chorus'` 推出；
    `backgroundVocal` 与 `backgroundVocals: [backgroundVocal]` 同时写；`translation`/`romanization` 取各自**首个**非空条目。
  - `foldAgentOverlapHarmonyLines(lines)`：把「同 `blockIndex`（任一为 undefined 视为相同）、
    `agentId` 不同、时间区间相交（`candidate.startTime < mainLine.endTime && candidate.endTime > mainLine.startTime`）」
    的后一行折叠成前一行的 `backgroundVocals`，并把 `backgroundVocal` 设为 `backgroundVocals[0]`。
  - `convertAgents` → `LyricData.ttml.agents`；`LyricData.ttml.timingMode = result.metadata.timingMode`；
    `isWordByWord = result.metadata.timingMode === 'Word'`。

### 3.12 适配器层

#### `LocalFileLyricAdapter`（`adapters/LocalFileLyricAdapter.ts`，顺序即优先级）

```
if (!source.lrcContent) return null
1) parseFoliaLyricDocument(source.lrcContent) 命中 → 直接返回（跳过所有解析器）
2) extractAwlrcContainer(source.lrcContent) 命中且 (awlrc || lrc) →
     translation = source.tLrcContent || container.tlrc || ''
     romanization = source.rLrcContent || container.rlrc || ''
     有 awlrc → parseLyricsAsync('awlrc', container.awlrc, ...) 否则 parseLyricsAsync('lrc', container.lrc, ...)
3) format = source.formatHint || detectTimedLyricFormat(mainLrc)
   if (format !== 'ttml'):
       {main, trans, romanization} = splitCombinedTimeline(mainLrc)
       mainLrc = main; transLrc ||= trans; romanizationLrc ||= romanization
       format = source.formatHint || detectTimedLyricFormat(mainLrc)     // 拆轨后重新嗅探
4) parseLyricsAsync(format, mainLrc, transLrc, options, romanizationLrc)
```

**`source.formatHint` 会同时压制初始嗅探与拆轨后的重嗅探**（两处都是 `source.formatHint || ...`）。

#### `EmbeddedLyricAdapter`

```
usltTags 非空 → normalizeEmbeddedUsltTags(usltTags)
否则 textContent 非空 → normalizeEmbeddedLrcText(textContent, translationContent)
mainLrc 为空 → null
→ extractAwlrcContainer(mainLrc)；命中则翻译取 transLrc || container.tlrc，罗马音取 container.rlrc || romanizationLrc
→ 否则 parseLyricsAsync(detectTimedLyricFormat(mainLrc), mainLrc, transLrc, options, romanizationLrc)
```

#### `NeteaseLyricAdapter` / `neteaseProcessing.extractNeteaseLyricPayload`

```
mainLrc   = source?.lrc?.lyric || null
yrcLrc    = source?.yrc?.lyric || source?.lrc?.yrc?.lyric || null
ytlrc     = source?.ytlrc?.lyric || source?.lrc?.ytlrc?.lyric || null
yromalrc  = source?.yromalrc?.lyric || source?.lrc?.yromalrc?.lyric || null
tlyric    = source?.tlyric?.lyric || null
romalrc   = source?.romalrc?.lyric || source?.lrc?.romalrc?.lyric || null
transLrc        = (yrcLrc && ytlrc) ? ytlrc : tlyric
romanizationLrc = (yrcLrc && yromalrc) ? yromalrc : romalrc
isPureMusic     = hasNeteasePureMusicFlag(source) || isPureMusicLyricText(mainLrc)
```

`processNeteaseLyrics`：`primaryLyrics = yrcLrc || mainLrc`；`!primaryLyrics || isPureMusic` → `{ lyrics: null, chorusRanges: [] }`；
否则 `format = yrcLrc ? 'yrc' : detectTimedLyricFormat(mainLrc || primaryLyrics)`，
解析后**覆盖** `lyrics.isWordByWord = !!yrcLrc`。
`parseNeteaseChorusRanges(chorusRes)`：`code !== 200` → `[]`；`ranges = chorusRes.chorus || chorusRes.data || []`；
映射 `{ startTime: (range.startTime ?? 0)/1000, endTime: (range.endTime ?? 0)/1000 }`，
过滤非有限值且 `endTime > startTime`。

#### `NavidromeLyricAdapter`（OpenSubsonic v2，优先级 4 级）

```
1) structuredLyrics 是「集合」(Array 且每项 .line 是数组) →
     parseNavidromeStructuredLyricsCollection(...) 成功即返回
     否则 main = selectPreferredNavidromeStructuredLyric(collection, 'main')
          translation = selectPreferredNavidromeStructuredLyric(collection, 'translation')
          normalizeEmbeddedStructuredLyrics(main.line) / (translation.line).mainText
          → parseLyricsAsync(detectTimedLyricFormat(mainText), mainText, transText, options)
2) structuredLyrics 是单个对象 → parseNavidromeStructuredLyrics(...) 成功即返回；
     否则 normalizeEmbeddedStructuredLyrics(source.structuredLyrics.line) → parseLyricsAsync(...)
3) structuredLyrics 是非空数组（行数组） → normalizeEmbeddedStructuredLyrics(lines) → parseLyricsAsync(...)
4) plainLyrics → normalizeEmbeddedLrcText(plainLyrics) → parseLyricsAsync(...)
5) null
```

`navidromeStructuredLyrics.ts` 关键规则：
- `finiteTime(v) = (typeof v === 'number' && Number.isFinite(v)) ? v/1000 : undefined`；`getOffsetSeconds = finiteTime(lyrics.offset) ?? 0`；
  `getAdjustedTime(v, lyrics) = finiteTime(v) + offsetSeconds`（**`offset` 以毫秒存，转秒后加到每行/每词**）。
- `hasCueTiming`：`cueLine?.some(cl => cl.cue?.some(c => finiteTime(c.start) !== undefined))`。
- `hasEnhancedLineTiming`：`line?.some(l => detectTimedLyricFormat(l.value) === 'enhanced-lrc')`。
- `hasEnhancedNavidromeStructuredLyrics = cueTiming || enhancedLineTiming`。
- `isNavidromeStructuredLyricCollection(l) = Array.isArray(l) && l.every(item => Array.isArray(item.line))`。
- `selectPreferredNavidromeStructuredLyric(items, kind = 'main')`：
  ```
  candidates = items.filter(i => i.kind === kind && hasNonEmptyLines(i))
  kind === 'main':
      candidates.find(hasCueTiming) || candidates.find(hasEnhancedLineTiming) || candidates.find(i => i.synced) || candidates[0]
      || items.find(i => hasNonEmptyLines(i) && hasCueTiming(i))
      || fallbackCandidates.find(hasEnhancedLineTiming) || fallbackCandidates.find(i => i.synced) || fallbackCandidates[0] || null
      （fallbackCandidates = items.filter(hasNonEmptyLines)）
  否则（translation/pronunciation）: candidates.find(i => i.synced) || candidates[0] || null
  ```
  （注释：翻译**故意只取一条显示行**。）
- `pickMainCueLines(lyrics)`：按 `index` 去重，主 agent（`agents.filter(a => a.role === 'main')` 的 id 集合）优先，
  最后按 `index || (start ?? 0)` 排序。
- cue 路径：行 `startTime = adjusted(cueLine.start) ?? adjusted(cues[0].start) ?? 0`；
  `fallbackLineEnd = adjusted(cueLine.end) ?? nextLineStart ?? (startTime + 5)`；
  每个 cue 生成一个 `Word`：`start = adjusted(cue.start)`（undefined 则跳过），
  `end = max(adjusted(cue.end) ?? nextWordStart ?? fallbackLineEnd, start + 0.001)`；
  `fullText = cueLine.value || words.map(w=>w.text).join('')`；`endTime = max(explicitEnd ?? words[last].endTime ?? fallbackLineEnd, startTime + 0.001)`。
- `findInlineAlternates(lyrics, cueLine)`：主行 = `lyrics.line[cueLine.index]`；从 `cueLine.index + 1` 起，
  只要 `lyrics.line[i].start === mainLine.start` 且该下标**不在** `cueLine` 里，就把非空且不等于 `cueLine.value` 的值收进 `alternates`；
  1 条 → `{translation: alternates[0]}`；多条 → 若 `hasCjkScript(mainLine.value)` 且恰好一个 `isRomanizationCandidate`
  则它是 `romanization`，其余第一条是 `translation`。
- 行级回退 `parseNavidromeLineLyrics`：仅 `lyrics.synced && !hasEnhancedLineTiming`；**存在重复时间戳就返回 null**（对唱/多轨）；
  `endTime = max(next.startTime ?? startTime + 5, startTime + 0.001)`，`words: []`。
- 集合合并（`parseNavidromeStructuredLyricsCollection`）：翻译/发音轨的
  `getTrackTimedEntries` 结果与主行 `startTime` 做 `findTranslationsForSortedStartTimes`，
  命中覆盖 `line.translation/romanization`，未命中保留行内已有值。

#### `QrcLyricAdapter`

```
if (!source.qrcContent?.trim()) return null
parseLyricsAsync('qrc', source.qrcContent, source.translationContent || '', options)
```

### 3.13 合并时间轴拆轨：`splitCombinedTimeline`（`timelineSplitter.ts`）

用途：一份文本里「原文/译文/罗马音共用同一时间戳依次排列」的布局（内嵌 LRC、酷狗导出）。

```ts
export const hasCjkScript = (text: string): boolean =>
  /[\u3400-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/u.test(text);

export const isRomanizationCandidate = (text: string): boolean => {
  const lyricText = text.replace(/\[[^\]]*\]|<[^>]*>/gu, '');
  const letters = lyricText.match(/[A-Za-z\u00c0-\u024f]/gu) || [];
  const nonWhitespace = lyricText.match(/\S/gu) || [];
  return letters.length >= 2
      && letters.length / Math.max(nonWhitespace.length, 1) >= 0.45
      && !hasCjkScript(text);
};
```

算法：

1. 逐行 trim、去空。对每行用 `timeRegex = /\[(\d{2}):(\d{2})[.:](\d{2,3})\]/g` 收集
   `timestampSignature`（所有时间戳拼接）与 `startTimestamp`（第一个）；无方括号时间戳时改用
   `enhancedAngleTimestampRegex = /<\d{2}:\d{2}[.:]\d{2,3}>/g` 收集。
   同时算 `isEnhancedLike = enhancedAngleRegex.test(line) || (line.indexOf('[',1) !== -1 && enhancedBracketRegex.test(line))`
   （`enhancedBracketRegex = /^\s*\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]+(?:\[\d{2}:\d{2}[.:]\d{2,3}\][^\[\]\n]*)+$/`），
   以及 `isBlank = !line.replace(/\[[^\]]*\]|<[^>]*>/gu, '').trim()`。
   无任何时间戳的行 `{timestampSignature:'', startTimestamp:'', isEnhancedLike:false, isBlank:false}`。
2. 分组：`sharesTimeline(left, right) = (left.timestampSignature !== '' && left.timestampSignature === right.timestampSignature)
   || (left.startTimestamp !== '' && left.startTimestamp === right.startTimestamp && (left.isEnhancedLike || right.isEnhancedLike))`。
   从当前行起，连续满足 `sharesTimeline` 的并入同组。
3. `members = group.length > 1 ? group.filter(l => !l.isBlank) : group`
   （注释：空白定时行只标记上一行结束，若与下一行共享时间戳不能占位，否则会把真正的原文挤进翻译轨而消失）。
4. `members.length > 1` 时：`[main, ...alternates] = members`；
   `romanizationCandidates = hasCjkScript(main.raw) ? alternates.filter(c => isRomanizationCandidate(c.raw)) : []`；
   `romanization = romanizationCandidates.length === 1 ? romanizationCandidates[0] : undefined`；
   `translation = alternates.find(c => c !== romanization)`；各自 push；`isCombined = true`。
   否则 `mainLines.push((members[0] ?? current).raw)`。
5. `isCombined` 为真才返回 `{ main: mainLines.join('\n'), trans: transLines.join('\n'), romanization: romanizationLines.join('\n') }`；
   否则 **原样返回 `{ main: rawText, trans: '', romanization: '' }`**（不做任何重排）。

### 3.14 内嵌归一化（`embeddedLrcNormalization.ts`）

```ts
function formatStructuredTimestamp(totalMs: number): string {
  const safeTotalMs = Math.max(0, totalMs);
  const minutes = Math.floor(safeTotalMs / 60000);
  const seconds = Math.floor((safeTotalMs % 60000) / 1000);
  const ms = safeTotalMs % 1000;
  return `[${mm}:${ss}.${xx}]`;   // mm/ss 两位，xx = Math.floor(ms/10) 两位
}

function isTranslationUsltTag(tag): boolean {
  const language = tag.language?.toLowerCase();
  const descriptor = tag.descriptor?.toLowerCase() || '';
  return language === 'chi' || language === 'zho'
      || descriptor.includes('translation') || descriptor.includes('trans');
}

export function normalizeEmbeddedLrcText(textContent?, translationContent?):
    { mainText: string; translationText: string; romanizationText?: string } {
  if (!textContent) return { mainText: '', translationText: '' };
  const { main, trans, romanization } = splitCombinedTimeline(textContent);
  const hasTranslationTimestamp =
    /(?:\[\d+(?::\d+){0,2}[.:]\d+\]|<\d{2}:\d{2}[.:]\d{2,3}>)/.test(translationContent || '');
  return {
    mainText: main,
    translationText: hasTranslationTimestamp ? translationContent! : trans || translationContent || '',
    romanizationText: romanization
  };
}
```

- **无条件先用正文拆轨**（注释：正文自己就可能是合并时间轴，译文行留在主轨会被当独立歌词渲染）。
- 独立定时译文优先（避免正文里不完整的译文覆盖整轨）。
- `normalizeEmbeddedUsltTags(tags)`：空 → 空；1 个 → `normalizeEmbeddedLrcText(tags[0].text)`；
  多个 → 找 `isTranslationUsltTag` 的那个当译文，主轨取**第一个不是它的** tag；
  都不匹配 → `normalizeEmbeddedLrcText(tags[0].text, tags[1].text)`。
- `normalizeEmbeddedStructuredLyrics(lines)`：按 `line.start || 0` 分组（`Map<number, string[]>`，跳过空 value），
  按 start 升序，`values[0]` → 主轨、`values[1]` → 译轨，前缀 = `formatStructuredTimestamp(start)`，
  最后 `join('\n')`。

### 3.15 洛雪 `[awlrc:]` 容器（`awlrcContainer.ts`）

```ts
const AWLRC_CONTAINER_REGEX = /\[awlrc:(.+)\]/;   // 不锚定；base64 无 ']'，贪婪组不会越界
export interface AwlrcContainerTracks { lrc?: string; tlrc?: string; rlrc?: string; awlrc?: string; }
```

- 四个键对应洛雪内部的 `lyric` / `tlyric` / `rlyric` / `lxlyric`；`lxlyric` 是逐字轨
  （`[mm:ss.ms]<相对行首偏移ms,时长ms>text`）。
- 容器体按 `,` 切段，每段按**第一个 `:`** 分成 `key` 与 base64 值；key 只接受上面四个，其余忽略。
- base64 解码：补 `=` 到 4 的倍数；Node 用 `Buffer.from(padded,'base64').toString('utf8')`，
  浏览器用 `TextDecoder('utf-8').decode(Uint8Array.from(atob(padded), c => c.charCodeAt(0)))`。
- `isHanTransliteration(track)`：`cjkCount > latinCount`（
  `CJK_SCRIPT_REGEX = /[\u3400-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/gu`，`LATIN_LETTER_REGEX = /[A-Za-z]/g`）；
  命中则 **删除 `rlrc`**（韩文汉字音译在 Folia 里没有承载位；按整轨字符构成判定，不看单行）。
- 无命中或全部解码失败 → `null`（调用方回退普通 LRC 流程）。

### 3.16 空行 / 无歌词 / 纯音乐 / 间奏 的表示

| 情形 | 表示 |
|---|---|
| 定时但文本为空的行（`[00:01.00]`） | `parseSimpleTimedTextEntry` 返回 `null` → **整行被丢弃**，不产生空 `Line`。 |
| 逐字标签但无文本的段 | 计入 `fullText` 但**不入 `words`**（`buildPreciseLineDraft` 的 `if (!segment.trim()) continue`）。 |
| 纯音乐（网易云 flag 或提示语文本） | `processNeteaseLyrics` 返回 `lyrics: null, chorusRanges: []`；自动匹配返回 `{ isPureMusic: true, source, id }`。 |
| 纯音乐判定（`pureMusic.isPureMusicLyricText`） | 去掉 LRC 标签与逐字标签后**整行锚定** `^${NOTICE_PREFIX}[纯純]音[乐樂]敬?[请請][您你]?欣[赏賞]$`（去空白/标点后匹配）；必须**至少一行**命中，其余行只能是署名 / `字段：内容` / `歌名 - 歌手` / 纯符号占位；出现任何像歌词的行即 `false`；空文本 `false`。 |
| 无歌词 | `LyricData \| null`；渲染侧用 `NO_LYRIC_LINES`（冻结空数组，身份稳定）。 |
| 可渲染性判据 | `hasRenderableLyrics(d) = d?.lines?.length > 0 && d.lines.some(l => l.fullText.trim().length > 0 \|\| (l.translation?.trim().length ?? 0) > 0)`。 |
| 间奏 / 前奏 | `Line.fullText === '......'`，恰 6 个 `'.'` 的 `Word`，等分时长；首行 > 3s 补 `<0.5, first-0.5>`，行间隙 > 3s 补 `<curEnd+0.05, nextStart-0.05>`。 |

### 3.17 增强 LRC 序列化（`enhancedLrcSerializer.ts`，移植需保留以支持导出/往返）

```ts
const MAX_TIMESTAMP_MS = (99 * 60 + 59) * 1000 + 999;
export const formatLrcLineTimestamp = (seconds) => `[${pad2(minutes)}:${pad2(secs)}.${pad2(Math.floor(millis/10))}]`;   // 2 位小数
export const formatLrcWordTimestamp = (seconds) => `<${pad2(minutes)}:${pad2(secs)}.${`${millis}`.padStart(3,'0')}>`;  // 3 位小数
export const inferLyricWordTiming = (lyrics: LyricData): 'word' | 'line' => lyrics.isWordByWord === true ? 'word' : 'line';
```

输出顺序：`[ti:]`（`metadata.title ?? lyrics.title`）→ `[ar:]` → `[al:]` → `[length:mm:ss]`（`metadata.durationMs` 四舍五入到秒）
→ `[re:Folia]` → 每行。
`sanitizeTagValue(v) = v.replace(/[\]\r\n]/g, ' ').trim()`；`oneLine(t) = t.replace(/\s*[\r\n]+\s*/g, ' ').trim()`。
逐行写：`lineTag + (useWordTiming ? serializeWordTimedBody(line) : text)`，其中
`useWordTiming = timing === 'word' && line.words.length > 0`；翻译、罗马音各写成**同一 `lineTag`** 的后续行。
行首标签去重：`tagMs = Math.max(Math.floor(Math.round(Math.max(line.startTime,0)*1000)/10)*10, previousTagMs + 10)`，
`tagMs > MAX_TIMESTAMP_MS` 时 `break`。
`serializeWordTimedBody`：`alignWordSegments`（把 `fullText` 里的空白/标点对齐回词）；
词间有空档（`word.startTime - previousEnd > 0.0005`）时补一个空段 `<previousEnd>`；行尾补 `<lineEnd>`。
`isInterludeLine(line)` 的行**不写**。这是**有损**格式：背景和声、`agent`、`ruby`、音节、`wordSegments` 无处可放（无损请用 `.fia`）。

### 3.18 `.fia`（Folia 自有，`foliaLyricDocument.ts`）

```ts
export const FOLIA_LYRIC_DOCUMENT_FORMAT = 'folia-lyricdata';
export const FOLIA_LYRIC_DOCUMENT_VERSION = 1;
export const FOLIA_LYRIC_FILE_EXTENSION = 'fia';
export type FoliaLyricDocumentSource = 'online' | 'imported' | 'local' | 'embedded' | 'navidrome';
export interface FoliaLyricDocument {
  format: typeof FOLIA_LYRIC_DOCUMENT_FORMAT; version: typeof FOLIA_LYRIC_DOCUMENT_VERSION;
  exportedAt: string; song: FoliaLyricDocumentSong; source?: FoliaLyricDocumentSource;
  offsetMs?: number;   // 仅元数据，时间轴本身不平移
  lyrics: LyricData;
}
```

- `looksLikeFoliaLyricDocument(text)`：去 BOM、`trimStart()` 后 `startsWith('{')` 且含 `"folia-lyricdata"`。
- 版本不符 → `console.warn` 后 `null`。
- 行校验：`fullText` 为 string、`startTime`/`endTime` 有限、`words` 数组且每项 `{text:string,startTime,endTime}` 均有限。
- `sanitizeLine`：可选字段**逐个收窄**（类型不对就丢，不整份拒收）；
  `word.syllables` 非法则降级成 `{text,startTime,endTime}`；`wordSegments` 必须通过 `isValidWordSegmentation`；
  `endTime = Math.max(endTime, startTime)`。
- 解析后 `lines.sort((l,r) => l.startTime - r.startTime)` + `ensureLyricDataRenderHints`（补回 `renderHints`）。
- 导出时 `stripLineRenderHints`（`renderHints` 是派生数据，不写进文件）。

---

## 4. 加密格式：KRC 与 QRC 解密（**逐常量照抄，不可猜**）

### 4.1 KRC（`providers/krcDecrypt.ts` 全文逻辑）

```ts
const KRC_KEY = new Uint8Array([
  64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105
]);   // 长度 16
```

```ts
export async function krcDecrypt(encryptedBytes: Uint8Array): Promise<string> {
  if (encryptedBytes.length <= 4) throw new Error('Invalid KRC data: too short');

  const data = encryptedBytes.subarray(4);        // 跳过前 4 字节头部 "krc1" (0x6b 0x72 0x63 0x31)
  const decrypted = new Uint8Array(data.length);
  for (let i = 0; i < data.length; i++) {
    decrypted[i] = data[i] ^ KRC_KEY[i % KRC_KEY.length];   // 循环 XOR，密钥长度 16
  }
  return await decompressDeflate(decrypted);
}
```

解压（`decompressDeflate`，`krcDecrypt.ts:15-50`）：浏览器 `new DecompressionStream('deflate')`（= **zlib 包装**，非 raw deflate），
写入全部字节后 `close()`，分块读 `reader.read()` 直到 `done`，`chunks` 拼接，`new TextDecoder('utf-8').decode(result)`。
读循环抛错但已收到数据时只 `console.warn('DecompressionStream warning (ignored):', error)` 并返回已有数据。
**无 base64 步骤**（KRC 走二进制；酷狗 API 的 `content` 字段是 base64，由 `fetchKugouLyrics` 用 `atob` 转成字节后再调用）。

酷狗下载响应判定（`kugouLyricProvider.ts:20-65`）：

```
hasKrcHeader(bytes) = bytes.length >= 4 && bytes[0]===107 && bytes[1]===114 && bytes[2]===99 && bytes[3]===49
isPlainTextContent  = String(contentType) === '2'
if (isPlainTextContent || !hasKrcHeader(bytes)) → { lyricText: utf8(bytes) 去 BOM, format: detectNonTtmlTimedLyricFormat(text) }
try  → { lyricText: await krcDecrypt(bytes), format: 'krc' }
catch→ utf8 文本若 matches /\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]/ 或 /<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>/ 或 startsWith('WEBVTT')
        → 警告后按文本嗅探；否则重新抛出
```

### 4.2 QRC（`providers/qrcDecrypt.ts`）——**自定义 S-box 的 3DES**

**入口**

```ts
export async function qrcDecrypt(encryptedHexOrBytes: string | Uint8Array): Promise<string> {
  let encryptedBytes: Uint8Array;
  if (typeof encryptedHexOrBytes === 'string') {
    const hex = encryptedHexOrBytes.trim();
    encryptedBytes = new Uint8Array(hex.match(/.{1,2}/g)!.map(byte => parseInt(byte, 16)));
  } else encryptedBytes = encryptedHexOrBytes;
  if (encryptedBytes.length === 0) throw new Error('No data to decrypt');

  const QRC_KEY = new TextEncoder().encode('!@#)(*$%123ZXC!@!@#)(NHL');   // 24 字节 → 3DES 三组 8 字节密钥
  const schedule = tripledes_key_setup(QRC_KEY, 0);                        // 0 = DECRYPT

  const decryptedBytes = new Uint8Array(encryptedBytes.length);
  for (let i = 0; i < encryptedBytes.length; i += 8) {
    const block = encryptedBytes.subarray(i, Math.min(i + 8, encryptedBytes.length));
    let paddedBlock = block;
    if (block.length < 8) { paddedBlock = new Uint8Array(8); paddedBlock.set(block); }   // 末尾零填充
    const decryptedBlock = tripledes_crypt(paddedBlock, schedule);
    decryptedBytes.set(decryptedBlock.subarray(0, block.length), i);                     // 只写回原始长度
  }
  return await decompressDeflate(decryptedBytes);   // 同 KRC：DecompressionStream('deflate') → TextDecoder('utf-8')
}
```

`QRC_KEY` 明文 = `!@#)(*$%123ZXC!@!@#)(NHL`，**24 字节**，UTF-8 编码。

**位操作工具（必须逐字移植）**

```ts
function bitnum(a: Uint8Array, b: number, c: number): number {
  const index = Math.floor(b / 32) * 4 + 3 - Math.floor((b % 32) / 8);
  const shift = 7 - (b % 8);
  return ((a[index] >> shift) & 1) << c;
}
function bitnum_intr(a: number, b: number, c: number): number { return ((a >>> (31 - b)) & 1) << c; }
function bitnum_intl(a: number, b: number, c: number): number { return (((a << b) & 0x80000000) >>> c); }
function sbox_bit(a: number): number { return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4); }
```

**SBOX（8 组 × 64，**非标准 DES S-box**）**

```ts
const SBOX: number[][] = [
  [ 14, 4,13, 1, 2,15,11, 8, 3,10, 6,12, 5, 9, 0, 7,
     0,15, 7, 4,14, 2,13, 1,10, 6,12,11, 9, 5, 3, 8,
     4, 1,14, 8,13, 6, 2,11,15,12, 9, 7, 3,10, 5, 0,
    15,12, 8, 2, 4, 9, 1, 7, 5,11, 3,14,10, 0, 6,13 ],
  [ 15, 1, 8,14, 6,11, 3, 4, 9, 7, 2,13,12, 0, 5,10,
     3,13, 4, 7,15, 2, 8,15,12, 0, 1,10, 6, 9,11, 5,
     0,14, 7,11,10, 4,13, 1, 5, 8,12, 6, 9, 3, 2,15,
    13, 8,10, 1, 3,15, 4, 2,11, 6, 7,12, 0, 5,14, 9 ],
  [ 10, 0, 9,14, 6, 3,15, 5, 1,13,12, 7,11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6,10, 2, 8, 5,14,12,11,15, 1,
    13, 6, 4, 9, 8,15, 3, 0,11, 1, 2,12, 5,10,14, 7,
     1,10,13, 0, 6, 9, 8, 7, 4,15,14, 3,11, 5, 2,12 ],
  [  7,13,14, 3, 0, 6, 9,10, 1, 2, 8, 5,11,12, 4,15,
    13, 8,11, 5, 6,15, 0, 3, 4, 7, 2,12, 1,10,14, 9,
    10, 6, 9, 0,12,11, 7,13,15, 1, 3,14, 5, 2, 8, 4,
     3,15, 0, 6,10,10,13, 8, 9, 4, 5,11,12, 7, 2,14 ],
  [  2,12, 4, 1, 7,10,11, 6, 8, 5, 3,15,13, 0,14, 9,
    14,11, 2,12, 4, 7,13, 1, 5, 0,15,10, 3, 9, 8, 6,
     4, 2, 1,11,10,13, 7, 8,15, 9,12, 5, 6, 3, 0,14,
    11, 8,12, 7, 1,14, 2,13, 6,15, 0, 9,10, 4, 5, 3 ],
  [ 12, 1,10,15, 9, 2, 6, 8, 0,13, 3, 4,14, 7, 5,11,
    10,15, 4, 2, 7,12, 9, 5, 6, 1,13,14, 0,11, 3, 8,
     9,14,15, 5, 2, 8,12, 3, 7, 0, 4,10, 1,13,11, 6,
     4, 3, 2,12, 9, 5,15,10,11,14, 1, 7, 6, 0, 8,13 ],
  [  4,11, 2,14,15, 0, 8,13, 3,12, 9, 7, 5,10, 6, 1,
    13, 0,11, 7, 4, 9, 1,10,14, 3, 5,12, 2,15, 8, 6,
     1, 4,11,13,12, 3, 7,14,10,15, 6, 8, 0, 5, 9, 2,
     6,11,13, 8, 1, 4,10, 7, 9, 5, 0,15,14, 2, 3,12 ],
  [ 13, 2, 8, 4, 6,15,11, 1,10, 9, 3,14, 5, 0,12, 7,
     1,15,13, 8,10, 3, 7, 4,12, 5, 6,11, 0,14, 9, 2,
     7,11, 4, 1, 9,12,14, 2, 0, 6,10,13,15, 3, 5, 8,
     2, 1,14, 7, 4,10, 8,13,15,12, 9, 0, 3, 5, 6,11 ]
];
```

**初始置换 `initial_permutation(input_data: Uint8Array): [number, number]`**——返回 `[s0, s1]`，每项 `>>> 0`：

```
s0 = bitnum(d,57,31)|bitnum(d,49,30)|bitnum(d,41,29)|bitnum(d,33,28)|bitnum(d,25,27)|bitnum(d,17,26)|bitnum(d,9,25)|bitnum(d,1,24)
   | bitnum(d,59,23)|bitnum(d,51,22)|bitnum(d,43,21)|bitnum(d,35,20)|bitnum(d,27,19)|bitnum(d,19,18)|bitnum(d,11,17)|bitnum(d,3,16)
   | bitnum(d,61,15)|bitnum(d,53,14)|bitnum(d,45,13)|bitnum(d,37,12)|bitnum(d,29,11)|bitnum(d,21,10)|bitnum(d,13,9)|bitnum(d,5,8)
   | bitnum(d,63,7) |bitnum(d,55,6) |bitnum(d,47,5) |bitnum(d,39,4) |bitnum(d,31,3) |bitnum(d,23,2) |bitnum(d,15,1)|bitnum(d,7,0)
s1 = bitnum(d,56,31)|bitnum(d,48,30)|bitnum(d,40,29)|bitnum(d,32,28)|bitnum(d,24,27)|bitnum(d,16,26)|bitnum(d,8,25)|bitnum(d,0,24)
   | bitnum(d,58,23)|bitnum(d,50,22)|bitnum(d,42,21)|bitnum(d,34,20)|bitnum(d,26,19)|bitnum(d,18,18)|bitnum(d,10,17)|bitnum(d,2,16)
   | bitnum(d,60,15)|bitnum(d,52,14)|bitnum(d,44,13)|bitnum(d,36,12)|bitnum(d,28,11)|bitnum(d,20,10)|bitnum(d,12,9)|bitnum(d,4,8)
   | bitnum(d,62,7) |bitnum(d,54,6) |bitnum(d,46,5) |bitnum(d,38,4) |bitnum(d,30,3) |bitnum(d,22,2) |bitnum(d,14,1)|bitnum(d,6,0)
```

**逆置换 `inverse_permutation(s0, s1): Uint8Array(8)`**（`data[3] … data[4]` 顺序照抄）：

```
data[3] = intr(s1,7,7)|intr(s0,7,6)|intr(s1,15,5)|intr(s0,15,4)|intr(s1,23,3)|intr(s0,23,2)|intr(s1,31,1)|intr(s0,31,0)
data[2] = intr(s1,6,7)|intr(s0,6,6)|intr(s1,14,5)|intr(s0,14,4)|intr(s1,22,3)|intr(s0,22,2)|intr(s1,30,1)|intr(s0,30,0)
data[1] = intr(s1,5,7)|intr(s0,5,6)|intr(s1,13,5)|intr(s0,13,4)|intr(s1,21,3)|intr(s0,21,2)|intr(s1,29,1)|intr(s0,29,0)
data[0] = intr(s1,4,7)|intr(s0,4,6)|intr(s1,12,5)|intr(s0,12,4)|intr(s1,20,3)|intr(s0,20,2)|intr(s1,28,1)|intr(s0,28,0)
data[7] = intr(s1,3,7)|intr(s0,3,6)|intr(s1,11,5)|intr(s0,11,4)|intr(s1,19,3)|intr(s0,19,2)|intr(s1,27,1)|intr(s0,27,0)
data[6] = intr(s1,2,7)|intr(s0,2,6)|intr(s1,10,5)|intr(s0,10,4)|intr(s1,18,3)|intr(s0,18,2)|intr(s1,26,1)|intr(s0,26,0)
data[5] = intr(s1,1,7)|intr(s0,1,6)|intr(s1,9,5) |intr(s0,9,4) |intr(s1,17,3)|intr(s0,17,2)|intr(s1,25,1)|intr(s0,25,0)
data[4] = intr(s1,0,7)|intr(s0,0,6)|intr(s1,8,5) |intr(s0,8,4) |intr(s1,16,3)|intr(s0,16,2)|intr(s1,24,1)|intr(s0,24,0)
// intr = bitnum_intr
```

**轮函数 `f(state: number, key: number[]): number`**（`key` 为 6 字节数组）：

```
t1 = intl(state,31,0) | ((state & 0xf0000000) >>> 1) | intl(state,4,5)  | intl(state,3,6)  | ((state & 0x0f000000) >>> 3)
   | intl(state,8,11) | intl(state,7,12) | ((state & 0x00f00000) >>> 5) | intl(state,12,17) | intl(state,11,18)
   | ((state & 0x000f0000) >>> 7) | intl(state,16,23)                      // >>> 0
t2 = intl(state,15,0) | ((state & 0x0000f000) << 15) | intl(state,20,5) | intl(state,19,6) | ((state & 0x00000f00) << 13)
   | intl(state,24,11) | intl(state,23,12) | ((state & 0x000000f0) << 11) | intl(state,28,17) | intl(state,27,18)
   | ((state & 0x0000000f) << 9) | intl(state,0,23)                        // >>> 0
lrgstate = [ (t1>>>24)&0xff, (t1>>>16)&0xff, (t1>>>8)&0xff, (t2>>>24)&0xff, (t2>>>16)&0xff, (t2>>>8)&0xff ]
xorState = lrgstate.map((item, idx) => item ^ key[idx])
outputState = ( SBOX[0][sbox_bit(xorState[0] >>> 2)] << 28
              | SBOX[1][sbox_bit(((xorState[0] & 0x03) << 4) | (xorState[1] >>> 4))] << 24
              | SBOX[2][sbox_bit(((xorState[1] & 0x0f) << 2) | (xorState[2] >>> 6))] << 20
              | SBOX[3][sbox_bit(xorState[2] & 0x3f)] << 16
              | SBOX[4][sbox_bit(xorState[3] >>> 2)] << 12
              | SBOX[5][sbox_bit(((xorState[3] & 0x03) << 4) | (xorState[4] >>> 4))] << 8
              | SBOX[6][sbox_bit(((xorState[4] & 0x0f) << 2) | (xorState[5] >>> 6))] << 4
              | SBOX[7][sbox_bit(xorState[5] & 0x3f)] ) >>> 0
return ( intl(outputState,15,0) | intl(outputState,6,1)  | intl(outputState,19,2) | intl(outputState,20,3)
       | intl(outputState,28,4) | intl(outputState,11,5) | intl(outputState,27,6) | intl(outputState,16,7)
       | intl(outputState,0,8)  | intl(outputState,14,9) | intl(outputState,22,10)| intl(outputState,25,11)
       | intl(outputState,4,12) | intl(outputState,17,13)| intl(outputState,30,14)| intl(outputState,9,15)
       | intl(outputState,1,16) | intl(outputState,7,17) | intl(outputState,23,18)| intl(outputState,13,19)
       | intl(outputState,31,20)| intl(outputState,26,21)| intl(outputState,2,22) | intl(outputState,8,23)
       | intl(outputState,18,24)| intl(outputState,12,25)| intl(outputState,29,26)| intl(outputState,5,27)
       | intl(outputState,21,28)| intl(outputState,10,29)| intl(outputState,3,30) | intl(outputState,24,31) ) >>> 0
// intl = bitnum_intl
```

**单块 `crypt(input_data, key)`**：16 轮 Feistel，**最后一轮不交换**（`i<15` 循环后额外一次 `s0 = f(s1,key[15]) ^ s0`）：

```ts
function crypt(input_data: Uint8Array, key: number[][]): Uint8Array {
  let [s0, s1] = initial_permutation(input_data);
  for (let idx = 0; idx < 15; idx++) { const prev = s1; s1 = (f(s1, key[idx]) ^ s0) >>> 0; s0 = prev; }
  s0 = (f(s1, key[15]) ^ s0) >>> 0;
  return inverse_permutation(s0, s1);
}
```

**密钥编排 `key_schedule(key: Uint8Array, mode: number): number[][]`**（16 × 6）：

```ts
const key_rnd_shift   = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
const key_perm_c      = [56,48,40,32,24,16,8,0, 57,49,41,33,25,17,9,1, 58,50,42,34,26,18,10,2, 59,51,43,35];
const key_perm_d      = [62,54,46,38,30,22,14,6, 61,53,45,37,29,21,13,5, 60,52,44,36,28,20,12,4, 27,19,11,3];
const key_compression = [13,16,10,23,0,4,2,27,14,5,20,9,22,18,11,3,25,7,15,6,26,19,12,1,
                         40,51,30,36,46,54,29,39,50,44,32,47,43,48,38,55,33,52,45,41,49,35,28,31];

let c = 0; for (let i = 0; i < 28; i++) c |= bitnum(key, key_perm_c[i], 31 - i); c >>>= 0;
let d = 0; for (let i = 0; i < 28; i++) d |= bitnum(key, key_perm_d[i], 31 - i); d >>>= 0;

for (let i = 0; i < 16; i++) {
  c = (((c << key_rnd_shift[i]) | (c >>> (28 - key_rnd_shift[i]))) & 0xfffffff0) >>> 0;
  d = (((d << key_rnd_shift[i]) | (d >>> (28 - key_rnd_shift[i]))) & 0xfffffff0) >>> 0;
  const togen = mode === 0 ? 15 - i : i;
  for (let j = 0; j < 6; j++) schedule[togen][j] = 0;
  for (let j = 0;  j < 24; j++) schedule[togen][Math.floor(j/8)] |= bitnum_intr(c, key_compression[j],      7 - (j % 8));
  for (let j = 24; j < 48; j++) schedule[togen][Math.floor(j/8)] |= bitnum_intr(d, key_compression[j] - 27, 7 - (j % 8));
}
```

**3DES 组装**：

```ts
function tripledes_key_setup(key: Uint8Array, mode: number): number[][][] {
  const key0 = key.subarray(0, 8), key8 = key.subarray(8, 16), key16 = key.subarray(16, 24);
  if (mode === 1) { // ENCRYPT
    return [ key_schedule(key0, 1), key_schedule(key8, 0), key_schedule(key16, 1) ];
  } else {          // DECRYPT
    return [ key_schedule(key16, 0), key_schedule(key8, 1), key_schedule(key0, 0) ];
  }
}

function tripledes_crypt(data: Uint8Array, keySchedule: number[][][]): Uint8Array {
  let temp = data;
  for (let i = 0; i < 3; i++) temp = crypt(temp, keySchedule[i]);
  return temp;
}
```

- QRC 调用的是 `tripledes_key_setup(QRC_KEY, 0)`（**DECRYPT**）。
- **重要**：SBOX 与标准 DES 不同（`SBOX[1]` 与 `SBOX[3]` 里存在重复值，这是 QQ Music 自有的变体），
  所以**不能**用系统 3DES（HarmonyOS `@ohos.security.cryptoFramework` 的 `DES192`）替代，必须逐位移植上面的实现。
- 尾部不足 8 字节的块用全零补齐，解密后**只写回原长度**。
- QQ 侧格式判定（`qqLyricProvider.detectIsQrc`）：`content.includes('(') && content.includes(')') && /\[\d+,\d+\]/.test(content)`。

### 4.3 QQ 请求参数（`qqLyricProvider.fetchQQLyrics`，移植需要）

```
URL   : https://u.y.qq.com/cgi-bin/musicu.fcg        （Web 走 /api/lyric-proxy?url=<encodeURIComponent(target)>）
POST  : { comm: { ct:11, cv:"1003006", v:"1003006", os_ver:"15", phonetype:"24122RKC7C",
                  rom:"Redmi/miro/miro:15/AE3A.240806.005/OS2.0.102.0.VOMCNXM:user/release-keys",
                  tmeAppID:"qqmusiclight", nettype:"NETWORK_WIFI", udid:"0", uid:"0" },
          request: { method:"GetPlayLyricInfo", module:"music.musichallSong.PlayLyricInfo", param } }
Headers: Content-Type: application/json; Cookie: tmeLoginType=-1; User-Agent: okhttp/3.14.9
校验   : data.code === 0 && data.request.code === 0，取 data.request.data
param  : { albumName: b64(album.name||''), crypt:1, ct:19, cv:2111,
           interval: Math.floor(song.durationMs/1000), lrc_t:0, qrc:1, qrc_t:0,
           roma:1, roma_t:0, singerName: b64(artists.join(', ')), songID: Number(song.id),
           songName: b64(song.name), trans:1, trans_t:0, type:0 }
响应字段: data.lyric / data.trans / data.roma   （均为待解密的十六进制字符串）
```

`toBase64(str)`：`btoa(unescape(encodeURIComponent(str)))`，失败时退化为
`btoa(encodeURIComponent(str).replace(/%([0-9A-F]{2})/g, (_,p1) => String.fromCharCode(parseInt(p1,16))))`。
搜索：`requestQQ("DoSearchForQQMusicLite", "music.search.SearchCgiService", param)`，
`param = { search_id: String(Math.floor(Math.random()*100000000000000 + Date.now()%86400000)),
remoteplace:"search.android.keyboard", query(<=60 字符), search_type:0, num_per_page, page_num, highlight:0,
nqc_flag:0, page_id:1, grp:1 }`，结果取 `data.body.item_song`。

### 4.4 酷狗请求签名（`kugouLyricProvider.signParams`）

```ts
function signParams(params: Record<string, any>): string {
  const sortedKeys = Object.keys(params).sort();
  let str = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
  for (const key of sortedKeys) str += `${key}=${params[key]}`;
  str += 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';
  return md5(str);            // blueimp-md5
}
```

- `clientTimeMs = Date.now()`，`clientTimeSec = Math.floor(clientTimeMs/1000)`，`mid = md5(String(clientTimeMs))`。
- `module !== 'Lyric'` 时补齐 `userid:'0', appid:'3116', token:'', clienttime:clientTimeSec, iscorrection:'1',
  uuid:'-', mid, dfid:'-', clientver:'11070', platform:'AndroidFilter'`；
  `module === 'Lyric'` 时只补 `appid:'3116', clientver:'11070'`。
- 之后追加 `signature = signParams(finalParams)`，全部塞进 query（`URL.searchParams.set`）。
- 请求头：`User-Agent: Android14-1070-11070-201-0-${module}-wifi`、`Connection: Keep-Alive`、
  `Accept-Encoding: gzip, deflate`、`KG-Rec: 1`、`KG-RC: 1`、`KG-CLIENTTIMEMS: ${clientTimeMs}`、`mid`，外加调用方头
  （搜索时 `x-router: complexsearch.kugou.com`）。
- 搜索：`http://complexsearch.kugou.com/v2/search/song`，`{ sorttype:'0', keyword, pagesize, page }`；
  失败回退 `http://mobiles.kugou.com/api/v3/search/song`。
- 取词：`https://lyrics.kugou.com/v1/search`（`{ album_audio_id?, duration: song.durationMs, hash, keyword: "${artists} - ${name}", lrctxt:'1', man:'no' }`）
  → 取 `candidates[0]` → `http://lyrics.kugou.com/download`（`{ accesskey, charset:'utf8', client:'mobi', fmt:'krc', id, ver:'1' }`）
  → `content` 是 base64，`atob` → `Uint8Array` → `decodeKugouDownloadedLyric`。

---

## 5. 分词与字素时序

### 5.1 `wordSegmentation.ts`——**全仓唯一分词入口**

```ts
export interface LyricWordSegment {
  segment: string;
  index: number;      // 段在源文本中的 UTF-16 码元偏移
  isWordLike: boolean;
}

const PUNCTUATION_ONLY = /^[\s\p{P}\p{S}]+$/u;
const isWordLikeText = (text: string) => !PUNCTUATION_ONLY.test(text);

export const segmentsFromBoundaries = (boundaries: string[]): LyricWordSegment[] => {
  let cursor = 0;
  return boundaries.map(segment => {
    const part = { segment, index: cursor, isWordLike: isWordLikeText(segment) };
    cursor += segment.length;                  // 累积 UTF-16 长度
    return part;
  });
};

export const segmentTextWords = (text: string): LyricWordSegment[] => {
  if (!text) return [];
  const Segmenter = typeof Intl !== 'undefined' ? Intl.Segmenter : undefined;
  if (Segmenter) {
    try {
      return Array.from(new Segmenter(undefined, { granularity: 'word' }).segment(text),
        part => ({ segment: part.segment, index: part.index,
                   isWordLike: part.isWordLike ?? isWordLikeText(part.segment) }));
    } catch { /* 落到字素兜底 */ }
  }
  return segmentsFromBoundaries(splitLyricGraphemes(text));   // 兜底：逐字素，保留每个码元
};

export const isValidWordSegmentation = (text: string, boundaries: string[] | undefined): boolean =>
  Array.isArray(boundaries) && boundaries.length > 0
  && boundaries.every(s => typeof s === 'string')
  && boundaries.join('') === text;                 // 必须精确重建原文本

const EDGE_WHITESPACE = /^(\s*)(.*?)(\s*)$/su;
const splitEdgeWhitespace = (boundaries: string[]): string[] => boundaries.flatMap(boundary => {
  const [, lead, core, trail] = EDGE_WHITESPACE.exec(boundary) ?? [];
  return core ? [lead, core, trail].filter(Boolean) : [boundary].filter(Boolean);
});

export const segmentLyricWords = (line: Pick<Line,'fullText'|'wordSegments'>): LyricWordSegment[] => {
  if (isValidWordSegmentation(line.fullText, line.wordSegments))
    return segmentsFromBoundaries(splitEdgeWhitespace(line.wordSegments!));
  return segmentTextWords(line.fullText);
};

export const getWordSegmentationKey = (line: Pick<Line,'wordSegments'>): string =>
  line.wordSegments ? line.wordSegments.map(s => s.length).join(',') : '';

export const hasWordSegmentationOverride = (line: Pick<Line,'fullText'|'wordSegments'>): boolean =>
  isValidWordSegmentation(line.fullText, line.wordSegments);
```

关键语义：
- **只有 `Intl.Segmenter(undefined, {granularity:'word'})` 一条路径**；无 Segmenter 时退化为字素（保证偏移与行时序不丢）。
- `splitEdgeWhitespace` 是**必需**的：`Intl.Segmenter` 把空白单独成段，而下游（tempera 靠偏移空洞区分「真词间隙」与「CJK 词边界」；
  `cjkSemanticLayout` 会跳过空白段）都按这个形状写。用户保存的格式相反（空格粘在前一段），所以要把边界空白抬出来。
  **段内部**空白故意保留（那是该格式唯一能表达「多词短语」的方式），标点也粘着不移除。
- 偏移是 **UTF-16 码元**偏移（`cursor += segment.length`），ArkTS 的 `String.length` 语义相同。

### 5.2 `graphemeTiming.ts`——字素时序

```ts
export interface GraphemeTiming { char: string; startTime: number; endTime: number; wordIndex?: number; }

const graphemeSegmenter = typeof Intl !== 'undefined' && Intl.Segmenter
  ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null;

export const splitLyricGraphemes = (text: string): string[] => {
  if (!text) return [];
  if (graphemeSegmenter) return Array.from(graphemeSegmenter.segment(text), ({ segment }) => segment);
  return Array.from(text);                        // 兜底：逐码元
};

const buildEvenGraphemeTimings = (text, startTime, endTime, wordIndex?): GraphemeTiming[] => {
  const graphemes = splitLyricGraphemes(text);
  if (graphemes.length === 0) return [];
  const duration = Math.max(endTime - startTime, 0);
  const unitDuration = duration / graphemes.length;   // 等分，最后一字精确收在 endTime
  return graphemes.map((char, index) => ({
    char,
    startTime: startTime + unitDuration * index,
    endTime: index === graphemes.length - 1 ? endTime : startTime + unitDuration * (index + 1),
    ...(typeof wordIndex === 'number' ? { wordIndex } : {}),
  }));
};

// 有 syllables 就按音节逐个等分，否则整词等分
export const buildWordGraphemeTimings = (word: Word, wordIndex?: number): GraphemeTiming[] =>
  !word.syllables?.length
    ? buildEvenGraphemeTimings(word.text, word.startTime, word.endTime, wordIndex)
    : word.syllables.flatMap(s => buildEvenGraphemeTimings(s.text, s.startTime, s.endTime, wordIndex));

const findGraphemeSequence = (source: string[], target: string[], fromIndex: number): number => {
  if (target.length === 0) return fromIndex;
  for (let index = fromIndex; index <= source.length - target.length; index += 1) {
    let matched = true;
    for (let t = 0; t < target.length; t += 1)
      if (source[index + t] !== target[t]) { matched = false; break; }
    if (matched) return index;
  }
  return -1;
};

export const buildLineGraphemeTimeline = (line: Line): GraphemeTiming[] => {
  const lineGraphemes = splitLyricGraphemes(line.fullText);
  if (lineGraphemes.length === 0) return [];
  if (line.words.length === 0) return buildEvenGraphemeTimings(line.fullText, line.startTime, line.endTime);

  const timeline: GraphemeTiming[] = [];
  let cursor = 0;
  let lastResolvedTime = line.startTime;

  line.words.forEach((word, wordIndex) => {
    const wordGraphemes = splitLyricGraphemes(word.text);
    if (wordGraphemes.length === 0) return;

    const matchedStart = findGraphemeSequence(lineGraphemes, wordGraphemes, cursor);
    const start = matchedStart >= 0 ? matchedStart : cursor;
    const end = Math.min(start + wordGraphemes.length, lineGraphemes.length);

    // 词之间的空洞（空格、解析器没覆盖的标点）：零时长，钉在下一词起点
    for (let gapIndex = cursor; gapIndex < start; gapIndex += 1)
      timeline[gapIndex] = { char: lineGraphemes[gapIndex], startTime: word.startTime, endTime: word.startTime };

    const wordTimings = buildWordGraphemeTimings(word, wordIndex);
    for (let localIndex = 0; localIndex < end - start; localIndex += 1) {
      const timing = wordTimings[localIndex]
        ?? buildEvenGraphemeTimings(wordGraphemes[localIndex] ?? '', word.startTime, word.endTime, wordIndex)[0];
      if (!timing) continue;
      timeline[start + localIndex] = { ...timing, char: lineGraphemes[start + localIndex] };
      lastResolvedTime = Math.max(lastResolvedTime, timing.endTime);
    }
    cursor = Math.max(cursor, end);
  });

  // 未解析到的位置（行首/行尾残留）：零时长，钉在最后一个已解析结束时刻
  for (let index = 0; index < lineGraphemes.length; index += 1) {
    if (timeline[index]) continue;
    timeline[index] = { char: lineGraphemes[index], startTime: lastResolvedTime, endTime: lastResolvedTime };
  }
  return timeline;
};
```

- **不是**动画曲线，只是「每个显示字素 → 起止秒」的映射；可视化的缓动属于各 visualizer。
- 空白/未覆盖字素是**零时长**，不是插值，避免 sweep 动画把它们当成可播内容。
- 若 `Intl.Segmenter` 不可用，`splitLyricGraphemes` 退化成逐码元（emoji/组合字可能被拆开 → 需 ArkTS 侧自建字素切分，见 §9）。

### 5.3 标点与 CJK 分组对照（上游各处使用的脚本判据，统一列出）

| 判据 | 正则 | 使用处 |
|---|---|---|
| CJK（宽） | `/[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]/` | `buildTimedWords`、`cjkSemanticLayout.hasCjkText`、`sentenceLayout.CJK_REGEX`、`cadenzaEnvelopes.isCJK` |
| CJK（宽 + 扩展 A/兼容） | `/[\u3400-\u9fff\uf900-\ufaff\u3040-\u30ff\uac00-\ud7af]/u` | `timelineSplitter.hasCjkScript`、`awlrcContainer.CJK_SCRIPT_REGEX`（带 `g`） |
| CJK（含扩展） | `/[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]/u` | `ttmlConversion.NON_WESTERN_TEXT_REGEX` |
| 中文标点（权重 0） | `/[，。！？、：；"'）]/` | `buildTimedWords` |
| 标点/符号整体 | `/^[\s\p{P}\p{S}]+$/u` | `wordSegmentation.PUNCTUATION_ONLY` |
| 拉丁字母 + 变音符 | `/[A-Za-z\u00c0-\u024f]/gu` | `timelineSplitter.isRomanizationCandidate` |
| 西文可连接音节 | `/[\p{Script=Latin}\p{N}'’`-]/u` | `ttmlConversion.WESTERN_JOINABLE_TEXT_REGEX` |
| 字母或数字结尾 | `/[\p{L}\p{N}]$/u` | `cjkSemanticLayout.TRAILING_WORD_CHAR_REGEX` |
| 粘贴式尾标点 | `/^[,.;:!?，。！？、：；）】》」』〉〕］)}\]"'’”’]+$/u` | `cjkSemanticLayout.STICKY_TRAILING_PUNCTUATION_REGEX` |

---

## 6. 句子布局与 CJK 语义布局

### 6.1 布局单元契约（`cjkSemanticLayout.ts:30-45`）

```ts
export interface LyricLayoutUnit {
  text: string;        // 布局规划用文本；可能与原始解析 token 不同
  words: Word[];       // 内含的原始解析词，时序权威
  startTime: number;
  endTime: number;
  isSemantic: boolean; // Intl.Segmenter 把 CJK 词组合成了语义单元
  isSticky?: boolean;  // 标点/缩写碎片已粘附，保证视觉稳定
}
export type SegmentableLine = Pick<Line, 'fullText' | 'words' | 'wordSegments'>;
export interface BuildPostLyricLayoutUnitsOptions { semantic?: boolean; sticky?: boolean; }
```

设计约束（文件头注释原文要点）：本层**不得**改写 `Line` 或全局合并解析词，因为 YRC/QRC/增强 LRC 会故意暴露
极小的定时碎片（例：`words: ["It","’","s","unbelievable"]`）。布局单元只是**显示规划层**：

```
input words:  It | ’ | s | unbelievable
layoutUnits:  It’s(isSticky, words=[It, ’, s]) | unbelievable
input words:  世 | 界 | 。
layoutUnits: 世界。(isSemantic, isSticky, words=[世, 界, 。])
```

**语义 CJK 单元仍返回原始 words**（逐字时序保留）；sticky 非语义单元在实际渲染时合并成一个 `Word`。

### 6.2 关键函数

```ts
export const createSingleWordLayoutUnits = (words: Word[]): LyricLayoutUnit[];

export const buildCjkSemanticLayoutUnits = (line: SegmentableLine): LyricLayoutUnit[] => {
  if (line.words.length === 0) return [];
  const fallbackUnits = createSingleWordLayoutUnits(line.words);
  // 只在「无空格脚本」时 Intl.Segmenter 才比解析词多出信息；用户自定义分词在任何脚本下都是有意为之，故跳过 CJK 门
  if (!hasCjkText(line.fullText) && !hasWordSegmentationOverride(line)) return fallbackUnits;
  const segments = getWordSegments(line);            // segmentLyricWords → {segment, isWordLike}
  if (!segments) return fallbackUnits;
  return mapSegmentsToWords(segments, line.words) ?? fallbackUnits;
};

export const applyStickyPunctuationLayoutUnits = (units: LyricLayoutUnit[]): LyricLayoutUnit[];
export const buildPostLyricLayoutUnits = (line, options = {}): LyricLayoutUnit[] => {
  const rawUnits = options.semantic ? buildCjkSemanticLayoutUnits(line) : createSingleWordLayoutUnits(line.words);
  return options.sticky ? applyStickyPunctuationLayoutUnits(rawUnits) : rawUnits;
};
export const buildDisplayWordsFromLayoutUnits = (units: LyricLayoutUnit[]): Word[] => units.flatMap(unit =>
  (!unit.isSticky || unit.isSemantic) ? unit.words
    : [{ text: unit.text, startTime: unit.startTime, endTime: unit.endTime }]);
```

`mapSegmentsToWords(segments, words)`（对齐规则，**任一无法精确对齐即返回 `null` → 整体回退逐词单元**）：
1. 跳过空/纯空白 segment。
2. 贪心累积 `words[wordIndex].text` 直到 `collectedText.length >= segmentText.length`；
   中途若 `!segmentText.startsWith(collectedText)` → `null`。
3. `collectedText !== segmentText` → `null`；否则该 segment 占 `words.slice(startWordIndex, wordIndex)`。
4. `!segment.isWordLike && units.length > 0` → 并入上一单元（`appendWordsToUnit`，不新建）。
5. 否则新建单元：`isSemantic = Boolean(segment.isWordLike && hasCjkText(segmentText) && segmentWords.length > 1)`。
6. 收尾要求 `wordIndex === words.length && units.length > 0`，否则 `null`。

`applyStickyPunctuationLayoutUnits` 的四条粘附规则（顺序固定）：
1. 当前是**纯撇号**（`/^['’]\s*$/`）且下一单元是**缩写后缀**（`/^(s|t|m|d|ll|re|ve|em)\s*$/i`）
   且上一单元以字母/数字结尾 → 把「撇号 + 后缀」都粘到上一单元，`index += 1`。
2. 当前是**直接缩写**（`/^['’](s|t|m|d|ll|re|ve|em)\s*$/i`）且上一单元以字母/数字结尾 → 粘附。
3. 当前是缩写后缀且上一单元以撇号结尾 → 粘附。
4. 当前是尾随标点集合 → 粘附。
全部走 `appendUnitToStickyUnit`（`target.text += unit.text; target.words.push(...unit.words); target.endTime = unit.endTime; target.isSticky = true`）。
收尾再标 `isSticky`：`hasAttachedTrailingPunctuation(unit)`（words > 1 且末词本身是尾标点）
或 `hasInlineContraction(unit)`（words > 1 && !isSemantic && `/[\p{L}\p{N}]+['’](s|t|m|d|ll|re|ve|em)/iu`）。

### 6.3 `SentenceLayout`（`sentenceLayout.ts`）

`class SentenceLayout implements LyricLayoutUnit`：
字段 `text: string`、`words: {text,startTime,endTime}[] = []`、`startTime = 0`、`endTime = 0`、`isSemantic = true`（**恒 true**）。

```ts
static splitIntoSentences(text: string, targetCount: number, timeSeed?: number): SentenceLayout[]
```

`targetCount` 语义：
- `<= 1 && >= 0` → 直接 `[new SentenceLayout(text)]`（**不切分**，targetCount=1 和 0 同效）。
- `-1` → `maxLevel = 1`；`-2` → 2；`-3` → 3；`-4` → 4；`-5` 及更小/其它 → `5`。
- `> 0` → 表示**目标句数**。

主循环：`level = 1..maxLevel`，只要 `sentences.length >= Math.abs(targetCount) && targetCount > 0` 就 break；
每个当前句依次跑 `splitByLevel(sentence, level)`，把结果展开（**同一 level 全部句子都跑，再进入下一 level**）。

`splitByLevel` 层级表（**顺序即优先级**）：

| level | 方法 | 规则 |
|---|---|---|
| 1 | `splitByPunctuation` | `/[，。；！？、…·\.\,\;\!\?]+/g`；标点**跟前面那段**，并把紧随其后的空白一起带上（`/^\s+/`）；无命中返回 `[text]` |
| 2 | `splitByBracketsQuotes` | 成对符号最外层切分，见下表 |
| 3 | `splitByWesternWords` | 仅含 CJK 时生效；`/[a-zA-Z0-9]+(?:[a-zA-Z0-9'\-]*[a-zA-Z0-9]+)?(?:\s+[a-zA-Z0-9]+(?:[a-zA-Z0-9'\-]*[a-zA-Z0-9]+)?)+[.,;:!?。，；：！？]?\s*/g`；需至少一个「多词块」才切；边界符 `-` 总跳过，`:`/`：`/`/`/`/`/`|`/`｜` 仅在全文出现 ≥ 2 次时跳过（`getGlobalCount`） |
| 4 | `splitCJKBySpace` | 仅含 CJK 时生效；见下 |
| 5 | `splitBySpecialChars` | `/[：:\/／\\|｜~～]+/`；特殊符**跟前面那段**，尾部残留挂到最后一单元 |

成对符号（level 2，`findOutermostPair` 取「最左开符 + 其后的第一个闭符」，平局取闭符更靠右者；
`extractOutermostPairs` 递归处理开符之前与闭符之后）：
`「」 『』 《》 【】 ｛｝ ［］ [] （） () "" ''`（直引号用字符串匹配，其余用正则）。

`splitCJKBySpace` 字符级状态机（level 4）：
```
for char of text:
  isCJK     = CJK_REGEX.test(char)
  isWestern = /[a-zA-Z0-9]/.test(char)
  isSpace   = /\s/.test(char)
  if isCJK      → 追加，inCjkBlock = true
  elif isWestern→ 追加（不切边界）
  elif isSpace:
      isFullWidthSpace = char === '\u3000'
      if (isFullWidthSpace && currentSegment.length > 0) → 追加 + 收段（inCjkBlock = false）
      elif (inCjkBlock && currentSegment.length > 0):
           末字符是 CJK → 追加 + 收段（inCjkBlock = false）；否则追加
      elif (currentSegment.length === 0 && segments.length > 0) → 空白挂到上一段末
      else → 追加
  else:
      currentSegment 为空且有上一段 → 挂到上一段末；否则追加
收尾：currentSegment 若为纯空白且有上一段 → 挂末；否则作为新段
返回 segments.length > 1 ? segments : [text]
```

后续两步（`targetCount > 0` 时）：

```ts
if (targetCount > 0 && result.length < targetCount) result = SentenceLayout.secondarySplit(result, targetCount, timeSeed);
if (result.length > 1 && result.length > targetCount && targetCount > 0) result = SentenceLayout.mergeSentences(result, targetCount);
```

- `secondarySplit`：优先用 `Intl.Segmenter(undefined,{granularity:'word'})` 在**最平衡**的候选句上切
  （候选 = `text.length > 2` 的句；对每句取词位置，选距 `s.text.length / 2` 最近的词缝，
  评分 `balanceScore * 10 + wordPositions.length`，其中 `balanceScore = 1 - |splitPos - midChar| / midChar`；
  取最高分切一刀，循环）。**没有 Segmenter 或没有可用词缝时**退化为
  伪随机中点切：
  ```
  pseudoRandom(seed) = (x => x - Math.floor(x))(Math.sin(seed) * 10000)
  textHash = Σ_i Σ_c charCodeAt(c)
  seed = textHash + sentences.length + (timeSeed ?? 0)
  selectedCandidate = candidates[Math.floor(pseudoRandom(seed) * candidates.length)]
  midPoint = Math.floor(text.length / 2)
  ```
  **文件注释明确说明**：这是全仓唯一一个在 `utils/lyrics/wordSegmentation` 之外调用的分词器，因此用户保存的分词
  到不了这里；它切的是「句子片段」而非整行，保留原样是刻意的。
- `mergeSentences`：反复合并**相邻长度之和最小**的一对，直到句数 ≤ `targetCount`。

**移植注意**：`SentenceLayout` 的 `words/startTime/endTime` 恒为空/0 —— 它只做**文本切分**，
时序由调用方按比例回填。`export { SentenceLayout }; export type { SentenceSplitOptions };`

---

## 7. 匹配与打分

### 7.1 `matchScore.ts`——精确权重与公式

```ts
const SCORE_WEIGHTS = { title: 45, artist: 25, album: 30 } as const;   // 合计 100
const AUTO_MATCH_COMPONENT_MISS_SCORE_CAP = 74;                        // 组件缺失时的封顶

export type MatchScoreDetails = {
  score: number; titleScore: number; artistScore: number; albumScore: number;
  durationScore: number; durationMultiplier: number;
  titleSimilarity: number; artistSimilarity: number; albumSimilarity: number | null;
  titleMatched: boolean; artistMatched: boolean; albumMatched: boolean | null; durationMatched: boolean | null;
};
```

**文本归一化**

```ts
export function normalizeLyricMatchText(value: string): string {
  const romajiValue = wanakana.toRomaji(value);        // 假名 → 罗马字
  const simpValue = t2sConverter(romajiValue);         // OpenCC 繁 → 简（OpenCC.Converter({from:'t',to:'cn'})）
  return simpValue.toLowerCase().replace(/[\p{P}\p{S}]/gu, '').replace(/\s+/g, ' ').trim();
}

function normalizeTitleForMatch(value: string): string {
  const versionMarkerPattern = /(instrumental|inst|off\s*vocal|karaoke|remix|mix|version|ver\.?|cover|live|edit|arrange|伴奏|カラオケ|インスト|リミックス|remaster|remastered)/iu;
  return normalizeLyricMatchText(
    value
      .replace(/[\(\[（【]\s*(feat|featuring|ft)\.?\s+[^\)\]）】]+[\)\]）】]/giu, '')   // 去 (feat. X)
      .replace(/\b(feat|featuring|ft)\.?\s+.+$/iu, '')                                // 去尾部 feat. X
      .replace(/[\(\[（【]([^\)\]）】]+)[\)\]）】]/gu, (match, content: string) =>
        versionMarkerPattern.test(content) ? match : '')                              // 只保留版本标记括号
  );
}
```

**字符相似度（Jaccard + 包含特例）**

```ts
function stringSimilarity(s1, s2, normalizer = normalizeLyricMatchText): number {
  const n1 = normalizer(s1), n2 = normalizer(s2);
  if (!n1 || !n2) return 0;
  if (n1 === n2) return 1.0;
  if (n1.includes(n2) || n2.includes(n1)) return Math.min(n1.length, n2.length) / Math.max(n1.length, n2.length);
  const set1 = new Set(n1), set2 = new Set(n2);
  let intersection = 0;
  for (const char of set1) if (set2.has(char)) intersection++;
  const union = new Set([...set1, ...set2]).size;
  return union > 0 ? intersection / union : 0;
}
```

**歌手相似度**

```ts
function splitArtistsForMatch(artistText: string): string[] {
  return artistText.split(/[,&、\/]|feat\.?|ft\.?|featuring|与/i).map(a => normalizeLyricMatchText(a)).filter(a => a.length > 0);
}

function calculateArtistSimilarity(target: string, search: string): number {
  const tArtists = splitArtistsForMatch(target), sArtists = splitArtistsForMatch(search);
  if (tArtists.length === 0 || sArtists.length === 0) return stringSimilarity(target, search);

  let matchCount = 0;
  for (const a1 of tArtists) for (const a2 of sArtists) {
    if (a1 === a2 || (a1.length >= 3 && a2.includes(a1)) || (a2.length >= 3 && a1.includes(a2))) { matchCount++; break; }
  }
  const tokenSim = matchCount / Math.max(tArtists.length, sArtists.length);
  const isMainArtistMatched = tArtists[0] && sArtists[0] &&
    (tArtists[0] === sArtists[0] || (tArtists[0].length >= 3 && sArtists[0].includes(tArtists[0]))
                              || (sArtists[0].length >= 3 && tArtists[0].includes(sArtists[0])));
  const mainBonus = isMainArtistMatched ? Math.max(tokenSim, 0.7) : tokenSim;
  return Math.max(mainBonus, stringSimilarity(target, search));
}
```

**时长倍率（`calculateDurationScore`）**——`diff = |targetDurationMs - searchDurationMs|`：

| 条件 | multiplier | matched |
|---|---|---|
| `target <= 0 \|\| search <= 0` | `0.9` | `null` |
| `diff <= 1000` | `1` | `true` |
| `diff <= 3000` | `0.95` | `true` |
| `diff <= 5000` | `0.75` | `false` |
| `diff <= 10000` | `0.35` | `false` |
| 其余 | `0.1` | `false` |

**总分（`calculateMatchScoreDetails`）**

```
titleSimilarity = stringSimilarity(song.title, result.name || '', normalizeTitleForMatch)
titleScore      = titleSimilarity * 45

artistSimilarity = song.artist.trim() ? calculateArtistSimilarity(song.artist, searchArtist) : 1   // 空歌手视为 1
artistScore      = artistSimilarity * 25

hasTargetAlbum = Boolean(song.album?.trim())
hasSearchAlbum = Boolean(searchAlbum.trim())
albumSimilarity = (hasTargetAlbum && hasSearchAlbum) ? stringSimilarity(song.album, searchAlbum, normalizeTitleForMatch) : null
albumScore = albumSimilarity === null ? (hasTargetAlbum ? 0 : 30) : albumSimilarity * 30

duration = calculateDurationScore(targetDurationMs, searchDurationMs)
identityScore = titleScore + artistScore + albumScore

titleMatched  = titleSimilarity >= 0.65
artistMatched = !song.artist.trim() || artistSimilarity >= 0.5
albumMatched  = !hasTargetAlbum ? null : (hasSearchAlbum ? (albumSimilarity ?? 0) >= 0.65 : null)

hasReliableIdentityMatch = artistMatched || albumMatched === true
cappedIdentityScore = (!titleMatched || !hasReliableIdentityMatch)
                    ? Math.min(identityScore, 74) : identityScore
finalScore = cappedIdentityScore * duration.multiplier

score = Math.min(100, Math.max(0, Math.round(finalScore)))
```

辅助：
- `getArtistText(result) = createProviderSongMetadata(result).artists.map(a => a.name).join(', ')`。
- `getAlbumText(result)`：`album?.name || ''`，且**精确匹配 `/^unknown album$/i` 的专辑名视为空串**。
- `calculateMatchScore(song, result) = calculateMatchScoreDetails(song, result).score`。
- 时长归一化（`duration.ts`）：`MAX_REASONABLE_SONG_DURATION_MS = 12 * 60 * 60 * 1000`；
  `normalizeLyricMatchDurationMs(d) = (!Number.isFinite(d) || !d || d <= 0) ? 0 : (d > MAX ? d/1000 : d)`。

### 7.2 搜索词构造（`searchQuery.ts`）

```ts
const MAX_ALBUM_QUERY_LENGTH = 48;

normalizeSongTitleForLyricSearch(title, artist):
  // 去掉「歌手 - 歌名」里重复的歌手前缀
  separator = title.match(/^(.+?)\s+-\s+(.+)$/u)
  if (!separator) return title.trim() || ''
  return normalizeArtistIdentity(separator[1]) === normalizeArtistIdentity(artist) ? separator[2].trim() : title

normalizeArtistIdentity(v) = normalizeLyricMatchText(v).replace(/\s+/gu, '')

normalizeAlbumForLyricSearch(album):
  trimmed 空 → null；长度 <= 48 → 原样
  否则去掉 /\s*※.*$/u 与 /\s*(歌|歌唱|アーティスト|Artist)\s*[:：]?\s*.+$/iu 后再判断，仍超长则 slice(0, 48).trim()

buildLyricSearchQuery(title, artist, album) =
  [normalizeSongTitleForLyricSearch(title, artist), artist?.trim(), normalizeAlbumForLyricSearch(album)]
    .map(p => p?.trim()).filter(Boolean).join(' - ')

buildKugouLyricSearchQuery(keyword) = keyword.trim().split(/\s+-\s+/u)[0]?.trim() || keyword.trim()
```

### 7.3 来源顺序（`sourcePriority.ts`）

```ts
export const DEFAULT_PREFERRED_LYRIC_SOURCE: LyricProviderSource = 'qq';
const BASE_LYRIC_SOURCE_ORDER: readonly LyricProviderSource[] = ['netease', 'amll', 'qq', 'kugou'];
export const buildLyricSourceOrder = (preferredSource = DEFAULT_PREFERRED_LYRIC_SOURCE): LyricProviderSource[] =>
  [preferredSource, ...BASE_LYRIC_SOURCE_ORDER.filter(s => s !== preferredSource)];
export const isLyricProviderSource = (v): v is LyricProviderSource =>
  v === 'netease' || v === 'amll' || v === 'qq' || v === 'kugou';
```

### 7.4 `autoMatchBestLyric` 总体算法（`autoMatchBestLyric.ts`）

常量：

```ts
const PROVIDER_SEARCH_TIMEOUT_MS = 3500;
const PROVIDER_LYRIC_TIMEOUT_MS  = 5000;
const AUTO_MATCH_SEARCH_LIMIT    = 10;
const AUTO_MATCH_MIN_SCORE       = 75;
```

入口签名：

```ts
export async function autoMatchBestLyric(
  title: string, artist: string, durationMs: number, options: AutoMatchBestLyricOptions = {}
): Promise<AutoMatchBestLyricResult>;
// AutoMatchBestLyricResult = AutoMatchBestLyricMatch | AutoMatchBestLyricPureMusic | null
```

流程：

1. `searchQuery = buildLyricSearchQuery(title, artist, options.album)`；
   `normalizedDurationMs = normalizeLyricMatchDurationMs(durationMs)`；
   `targetSong = { title, artist, album: options.album, durationMs: normalizedDurationMs }`。
2. `providerCandidate = options.providerCandidate ?? (options.neteaseCandidate ? 转成 {providerId:'netease', song, lyricsResult} : undefined)`
   （`neteaseCandidate` 已 `@deprecated`）。`activeProviderChorusRanges = providerCandidate?.lyricsResult.chorusRanges ?? []`。
3. `searchOrder = (options.exactMatchOnly && options.metadataCandidate) ? [options.metadataCandidate.source] : buildLyricSourceOrder(options.preferredSource)`。
4. **按 `searchOrder` 顺序**遍历（默认 `['qq','netease','amll','kugou']`，因为默认偏好源是 `'qq'`）：
   - **`'netease'`**：`getNeteaseCandidateSongs()`（有 providerCandidate 或 `metadataCandidate.source==='netease'` 时直接用；
     否则 `searchSongs(searchQuery, 10, 0)` + `withTimeout(..., 3500, 'NetEase search', {items:[],hasMore:false,nextOffset:0})`
     + `selectBestCandidate('netease', ...)`）。
     对每个候选：`getNeteaseProcessed(song)`（providerCandidate 复用；否则 `withTimeout(getLyrics(song), 5000, ..., null)`）；
     - `processed.isPureMusic` → **立即** `return { isPureMusic: true, source: 'netease', id: song.id }`（不再查其他源）；
     - 记录 `discoveredNeteaseChorusRanges`；
     - `acceptsExactNonWordByWord = options.exactMatchOnly && isSelectedMetadataCandidate('netease', song, options.metadataCandidate)`；
     - `hasRenderableLyrics(processed.lyrics)` 时构造 `match`；若 `processed.lyrics.isWordByWord || acceptsExactNonWordByWord`
       → **立即返回**；否则记入 `lineByLineFallback ??= match` 并继续找逐字源。
   - **`'amll'`**：
     - 若 `options.metadataCandidate?.source === 'qq'`：先 `getQqBestCandidate()`，命中同一 metadata 候选则 `tryAmllDbCandidate('qq', ...)`；
       逐字则返回，否则 `lineByLineFallback ??=`。
     - 再 `getNeteaseCandidateSongs()`；**为空则 `continue`**（注释：没有可靠网易云候选就跳过 AMLL 自动探测）。
     - 对每个网易云候选 `tryAmllDbCandidate('ncm', song)`；逐字返回，否则 `lineByLineFallback ??=`。
     - 注释：NCM 未命中后结束，**QQ 的 AMLL 探测保留给手动匹配**。
   - **`'qq'`**：`getQqBestCandidate()`（providerCandidate 复用；否则 `searchQQLyrics(searchQuery, 1, 10)` + `withTimeout(...,3500)`；
     `metadataCandidate.source === 'qq'` 时优先精确匹配，`exactMatchOnly` 时找不到即 null；否则 `selectBestCandidate('qq', ...)`）。
     单候选：`getQqProcessed(song)`（复用或 `fetchQQLyrics(song, { chorusRanges: activeProviderChorusRanges.length ? activeProviderChorusRanges : discoveredNeteaseChorusRanges })` + `withTimeout(...,5000)`，
     返回 `{ lyrics, isPureMusic: false }`）；纯音乐立即返回；逐字或 exact 立即返回；否则 `lineByLineFallback ??=`。
   - **`'kugou'`**：同构。`selectBestCandidate('kugou', page.items, targetSong)`；`getKugouProcessed`；
     `id: song.id`、`kgHash: song.kgHash`。
5. 循环结束：`lineByLineFallback` 存在则返回它（**逐字优先，行级兜底**）；否则 `return null`。

`selectBestCandidate(source, songs, target)`（`:95-138`）：

```ts
const isReliableCandidate = (d) => d.titleMatched && (d.artistMatched || d.albumMatched === true);
const scored = songs.slice(0, 10).map(song => ({ song, details: calculateMatchScoreDetails(target, song) }))
                   .sort((a, b) => b.details.score - a.details.score);
const best = scored.find(item => isReliableCandidate(item.details)) ?? scored[0];
if (!best) return null;
if (!isReliableCandidate(best.details)) return null;      // 标题或身份字段不匹配 → 直接放弃
if (best.details.score < 75) return null;
return best.song;
```

即：**先在「标题命中且（歌手命中或专辑命中）」的候选里取最高分；若一个都没有，退化为总分最高者，但随后仍会因不可靠而被拒。**
最后再卡 `score >= 75`。`withTimeout(promise, timeoutMs, label, fallback)` 用 `Promise.race` + `setTimeout`，
超时只 `console.warn` 并 resolve `fallback`（单测里 `import.meta.env.DEV` 控制详细日志）。

`resolveMatchedLyrics(lyrics, sourceResult, sourceProviderId, sourceSong)`：把胜利歌词套回 provider 结果后交给
`resolveProviderLyricsChorus(providerResult, { providerId, songId })`，返回 `resolved.result.lyrics ?? lyrics`
（合唱效果跟随当前 provider）。

`tryAmllDbCandidate(platform, song)`：`musicIds = getAmllDbMusicIds(platform, song)`；
`withTimeout(fetchAmllDbLyrics(platform, musicIds), 5000 * Math.max(1, musicIds.length), ..., null)`（QQ 要试 mid 和数字 ID，两个 ID 各有超时）；
无 TTML → `null`；合唱区间取 `activeProviderChorusRanges` → `discoveredNeteaseChorusRanges` → `getProviderChorusRanges('netease', song)`；
返回 `{ lyrics, source: 'amll', id: song.id, song, matchedLyricsProviderPlatform: platform, ...(platform==='qq' ? {qqMid: song.qqMid} : {}) }`。

### 7.5 `lyricMatchSources.ts`（手动匹配路径）

```ts
export const LYRIC_MATCH_SOURCES: readonly LyricProviderSource[] = ['netease', 'amll', 'qq', 'kugou'];
const AMLL_DB_SEARCH_PAGE_SIZE = 50;
const AMLL_DB_MAX_RESULTS = 20;
```

- `searchLyricsByMatchSource(source, query, target)`：`'netease'`/`'kugou'` → `getOnlineMusicProvider(id).search.searchSongs(query, 50, 0)`
  后 `sortByMatchScore`；`'qq'` → `searchQQLyrics(query)` 后排序；否则 `searchAmllDbLyricCandidates`。
- `sortByMatchScore` = `[...songs].sort((a,b) => calculateMatchScore(target,b) - calculateMatchScore(target,a))`。
- `searchAmllDbLyricCandidates(query, target)`：按 `buildAmllDbSearchQueries(query)` **顺序**尝试；
  `searchAmllDbSongs(params, 50)` 返回 `null`（限流/网络错）→ **立刻返回 `[]`，不再发兜底请求**；
  有候选即 `sortByMatchScore(...).slice(0, 20)`。
- `buildAmllDbSearchQueries(query)`（`amllDbCandidates.ts`）：
  `QUERY_SEPARATOR = /\s+-\s+/u`；`ARTIST_SEPARATOR = /\s*[,，、&]\s*|\s+(?:feat\.?|ft\.?)\s+/iu`；
  `stripTitleSuffix(title) = title.replace(/(?:\s*[(\[（【][^)\]）】]*[)\]）】])+\s*$/u, '').trim() || title`。
  - 无 ` - `（只有歌名/手输关键词）：`[{musicName: parts[0]}, {q: parts[0]}]`。
  - 有：`[{musicName, artistName}]`（有 artistName 时）→ 若 `baseName !== musicName` 再 `[{musicName: baseName, artistName}]`
    → 最后 `[{musicName: baseName}]`。
- `toAmllDbSongResult(item)`：平台 ID 优先 `ncmMusicIds[0]` 否则 `qqMusicIds[0]`，都没有返回 `null`；
  `durationMs: 0`（官方搜索不返回时长，评分时按未知处理，倍率 0.9）；`artists` 由**全部** `artistNames`（多语言别名）构造；
  `qq` 且 id 是字符串时写 `qqMid: id`。
- `toAmllDbSongResults(items)`：任一平台 ID 重复即视为同一首歌，保留靠前的一条。

### 7.6 AMLL 官方 API（`amllApi.ts` / `amllDbProvider.ts`）

```ts
const AMLL_API_BASE_URL = 'https://api.amll.dev';
const AMLL_API_TIMEOUT_MS = 5000;
const PLATFORM_QUERY_KEYS: Record<AmllDbPlatform, string> = { ncm: 'ncmMusicId', qq: 'qqMusicId' };

buildAmllApiLyricsUrl(platform, musicId) = `${BASE}/v1/lyrics/get?${new URLSearchParams({ [KEY]: String(musicId) })}`
buildAmllApiSearchUrl(params, pageSize)  = `${BASE}/v1/lyrics/search?${...params, pageSize: String(pageSize)}`
// 同一平台传多个 ID 时官方按交集匹配，所以一次只查一个 ID

getAmllApiData<T>(url): status === 429 → console.warn 限流；status !== 200 → null；
                        body = JSON.parse(bodyText)；return body.status === 200 && body.data ? body.data : null
// 网络错误/超时/非 JSON 会抛出，由调用方记日志；不重试
```

`getAmllDbMusicIds(platform, song) = normalizeMusicIds(platform === 'qq' ? [song.qqMid, song.id] : [song.id])`
（去空、去重；QQ 的 mid 在前——注释：AMLL 里 QQ 约 2:1 按 mid / 数字 ID 收录）。
`fetchAmllDbLyrics(platform, musicId | ids)`：逐个 ID 查询，返回第一个有歌词的结果；
缓存 `Map<string, Promise<LyricData|null>>`，`AMLL_DB_CACHE_LIMIT = 200`（超限删最旧键）。
`fetchAmllDbLyricsUncached` 要求 `ttml?.trim() && /<tt(?:\s|>)/i.test(ttml)`，否则 `null`，然后 `parseLyricsByFormat('ttml', ttml)`，
并只接受 `parsed?.lines?.length` 非空。
`UA`（仅 Electron 代理路径）：`` `Folia/${__APP_VERSION__}-${__BUILD_COMMIT__ ?? 'dev'} (${__BUILD_REPO__ ?? 'unknown'})` ``。

### 7.7 合唱装饰（`chorusEffects.ts`）

```ts
const CHORUS_EFFECTS: Array<'bars' | 'circles' | 'beams'> = ['bars', 'circles', 'beams'];

applyDetectedChorusEffects(lyrics, mainLrc, random = Math.random):
  chorusLines = detectChorusLines(mainLrc)            // 按文本集合，来自 ../chorusDetector
  每段随机分配一个 effect；命中 fullText.trim() 的行 → { isChorus: true, chorusEffect }

applyNeteaseChorusByTime(lyrics, chorusRanges, random = Math.random):
  每个区间随机分配一个 effect
  行与区间相交判据：lineStart < rangeEnd && lineEnd > rangeStart（左闭右开语义）
  命中 → { isChorus: true, chorusEffect: rangeEffects[matchedRangeIndex] }（取第一个命中的区间）
```

`provider` 侧在 `fetchQQLyrics` / `fetchKugouLyrics` 结尾调用：
有 `options.chorusRanges` → `applyNeteaseChorusByTime`，否则 `applyDetectedChorusEffects`。

---

## 8. 运行时时间模型

### 8.1 时钟

```ts
// src/stores/motionSignals.ts:31-34
export const currentTime = motionValue(0);      // 实际听到的播放位置（秒）
export const lyricCurrentTime = motionValue(0); // 歌词时钟 = currentTime - offset（秒）
```

主循环（`usePlaybackVisualizerBridge.ts:133-146` 等分支，四处同构）：

```
time = audioElement.currentTime                          // 或 stage / playerCap / stageLyrics 的显示时间
currentTime.set(time)
effectiveLyricTime = time - lyricTimelineOffsetMs / 1000
lyricCurrentTime.set(effectiveLyricTime)
if (lyrics) {
  foundIndex = findLatestActiveLineIndex(lyrics.lines, effectiveLyricTime)
  if (foundIndex !== currentLineIndexRef.current) { currentLineIndexRef.current = foundIndex; setCurrentLineIndex(foundIndex) }
}
```

**注意：偏移只作用于歌词时钟，`currentTime` 不变。** 循环重播（`'one'` / `'all'`）时会把歌词时钟归零并重算行号。

### 8.2 播放位置 → 当前行：`findLatestActiveLineIndex`（`appPlaybackHelpers.ts:21-32`）

```ts
export const findLatestActiveLineIndex = (lines: LyricData['lines'], time: number) => {
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (!line || time < line.startTime) continue;                     // 注意：continue 而非 break
    if (time <= (line.renderHints?.renderEndTime ?? line.endTime)) return index;
  }
  return -1;
};
```

- **从后往前扫**，返回第一个 `startTime <= time <= renderEndTime` 的行索引；无 → `-1`（`-1` 是「无活动行」的规范值）。
- 用 `renderHints?.renderEndTime ?? endTime`，即允许活跃行在 `endTime` 之后继续停留（淡出窗口）。
- 复杂度 O(n)；`lines` 已排序，若需 O(log n) 需自建，但**必须保持 `renderEndTime` 上界语义**（`renderEndTime` 可能大于下一行 `startTime`，
  导致同时满足的行不止一个；倒序扫描保证取「最后一行」）。

### 8.3 相邻行助手（`components/visualizer/runtime.ts`）

```ts
export const getRecentCompletedLine = ({ lines, currentLineIndex, currentTime, getLineEndTime = l => l.endTime }): Line | null => {
  if (currentLineIndex !== -1 || lines.length === 0) return null;
  for (let i = lines.length - 1; i >= 0; i--) if (currentTime > getLineEndTime(lines[i])) return lines[i];
  return null;
};
// 仅当没有活动行时才有意义：字幕在行间隙里继续显示上一句的译文

export const getUpcomingLine = (lines, currentLineIndex, currentTime): Line | null => {
  const activeLine = lines[currentLineIndex];
  if (activeLine) return lines[currentLineIndex + 1] ?? null;
  for (const line of lines) if (line.startTime > currentTime) return line;
  return null;
};

export const getUpcomingLines = (lines, currentLineIndex, count = 2): Line[] =>
  currentLineIndex < 0 ? [] : lines.slice(currentLineIndex + 1, currentLineIndex + 1 + count);

export const shouldPreheatLine = (line, currentTime, window: VisualizerPreheatWindow): boolean => {
  if (!line) return false;
  const leadTime = line.startTime - currentTime;
  return leadTime >= window.minLead && leadTime <= window.maxLead;   // 预热窗以「提前秒数」定义
};

export const prepareActiveAndUpcoming = <T>({ activeLine, upcomingLine, prepareLine }): T | null => {
  if (!activeLine) { prepareLine(upcomingLine); return null; }
  const currentState = prepareLine(activeLine); prepareLine(upcomingLine); return currentState;
};

export const useVisualizerRuntime = ({ currentTime, currentLineIndex, lines, getLineEndTime }) => { ... }
// 返回 { currentTimeValue, activeLine, recentCompletedLine, upcomingLine, nextLines }
```

### 8.4 行/词高亮判据（两套实现，移植时择一并统一）

**通用（Monet，`monetLyricsModel.ts:332-359`）**

```ts
export const resolveMonetLineStatus = (line: Line, index: number, activeIndex: number, currentTime: number) => {
  if (index === activeIndex || (activeIndex < 0 && currentTime >= line.startTime && currentTime <= line.endTime)) return 'active';
  if (currentTime > line.endTime || (activeIndex >= 0 && index < activeIndex)) return 'passed';
  return 'waiting';
};

export const resolveMonetWordStatus = (currentTime: number, startTime: number, endTime: number) => {
  if (currentTime < startTime) return 'waiting';
  if (currentTime <= endTime) return 'active';
  return 'passed';
};
```

**节奏感知（Cadenza，`cadenzaEnvelopes.ts:35-62`）**——引入 `wordRevealMode` 提前量与 `renderEndTime`：

```ts
export const getWordStatus = (time: number, lineTiming: ResolvedLineRenderTiming, word: WordType) => {
  const lookahead = lineTiming.wordRevealMode === 'fast' ? 0.045
                  : lineTiming.wordRevealMode === 'instant' ? 0
                  : 0.18;                                     // normal
  const activeEndTime = lineTiming.wordRevealMode === 'instant' ? lineTiming.lineRenderEndTime : word.endTime;
  if (time >= word.startTime - lookahead && time <= activeEndTime) return 'active' as const;
  if (time > activeEndTime) return 'passed' as const;
  return 'waiting' as const;
};

export const getWordProgress = (time: number, wordRevealMode: ResolvedLineRenderTiming['wordRevealMode'], word: WordType) => {
  if (wordRevealMode === 'instant') return time < word.startTime ? 0 : 1;
  const minDuration = wordRevealMode === 'fast' ? 0.045 : 0.01;
  const duration = Math.max(word.endTime - word.startTime, minDuration);
  return clamp((time - word.startTime) / duration, 0, 1);
};

export const resolveLineRenderTiming = (line: Line): ResolvedLineRenderTiming => {
  const renderHints = line.renderHints ?? null;
  const wordRevealMode = renderHints?.wordRevealMode ?? 'normal';
  const lastWord = line.words[line.words.length - 1];
  const rawDuration = renderHints?.rawDuration ?? Math.max(line.endTime - line.startTime, 0);
  const transitionTiming = getLineTransitionTiming(rawDuration, renderHints?.lineTransitionMode ?? 'normal', wordRevealMode);
  return { renderHints, lineRenderEndTime: renderHints?.renderEndTime ?? line.endTime,
           wordRevealMode, lastWordEndTime: lastWord?.endTime ?? line.endTime,
           linePassHold: transitionTiming.linePassHold, transitionTiming };
};
```

**移植建议**：ArkTS 侧把 `findLatestActiveLineIndex` + `resolveMonetLineStatus` / `resolveMonetWordStatus` 作为基线，
再叠加 `renderHints`（`lookahead` / `activeEndTime`）实现逐字高亮；两者都不依赖浏览器 API，可直接搬运。

### 8.5 时间轴偏移（**文件内 `[offset:]` 不存在**）

- 单曲偏移：`lyricOffsetMemory.ts`，storage key **`lyric_timeline_offsets`**，值 `{ [songKey]: offsetMs }`，
  `MAX_ENTRIES = 1000`（LRU 淘汰），`readLyricOffset(songKey)` / `writeLyricOffset(songKey, offsetMs)`（写 0 等于删除）。
- 全局偏移：`useLyricSettingsStore.ts`，key **`global_lyric_timeline_offset_ms`**，
  `GLOBAL_LYRIC_TIMELINE_OFFSET_LIMIT_MS = 2000`，`clampGlobalLyricTimelineOffsetMs(v)` 先判有限再 `Math.round` 并夹到 ±2000。
- 生效值：`App.tsx:512` → `effectiveLyricTimelineOffsetMs = lyricTimelineOffsetMs + globalLyricTimelineOffsetMs`；
  消费处一律 `effectiveLyricTime = time - offsetMs / 1000`（**正值让歌词更晚出现**）。
- 上游**没有**解析 LRC 的 `[offset:]` 标签（`parseMetadataLine` 只认 `[ti:]`/`[ar:]`），也没有把 `offsetMs` 写回歌词时间轴。
  `.fia` 里的 `offsetMs` 明确注释为「只是元数据：时间轴本身没有被平移」。

---

## 9. 移植清单（ArkTS / HarmonyOS）

### 9.1 纯逻辑、可 1:1 直搬（无宿主 API 依赖）

| 模块 | 说明 |
|---|---|
| `types.ts` 全部接口/类型 | ArkTS 用 `interface` / `type`；`role: 'translation' \| 'romanization' \| string` 在 ArkTS 里写成 `string`（ArkTS 不支持 `X \| string` 的收窄联合，改为 `string` + 常量表）。 |
| `formatDetection.ts` | 纯正则，直接搬。**注意** `replace(/^\uFEFF/,'')`、`m` 标志、`\d{2,3}` 均需支持。 |
| `parserCore.ts` 全部 8 个解析器 + `buildTimedWords` / `attachInterludes` / `finalizeParsedLyricLines` / `findTranslationsForSortedStartTimes` / `parseAwlrcTimestamp` / `resolveAlternateTracks` | 纯字符串/数字运算。 |
| `timelineSplitter.ts` | 纯正则。`\S`、`u` 标志需支持。 |
| `embeddedLrcNormalization.ts` | 纯逻辑。 |
| `wordSegmentation.ts`（**除 `Intl.Segmenter` 分支**） | `segmentsFromBoundaries` / `isValidWordSegmentation` / `splitEdgeWhitespace` / `getWordSegmentationKey` 可直搬。 |
| `graphemeTiming.ts`（**除 `Intl.Segmenter`**） | 直搬。 |
| `cjkSemanticLayout.ts` | 纯逻辑；只依赖 `segmentLyricWords`。 |
| `sentenceLayout.ts` | 纯逻辑；`secondarySplit` 的 Segmenter 分支需替换（见 9.3）。 |
| `renderHints.ts` | 纯数值。 |
| `matchScore.ts` | 数值/集合逻辑可搬；`wanakana` / `opencc-js` 需替代（见 9.3）。 |
| `duration.ts` / `searchQuery.ts` / `sourcePriority.ts` / `validity.ts` / `noLyricLines.ts` / `filtering.ts` | 纯逻辑。 |
| `lyricOffsetMemory.ts` | 逻辑可搬，存储换 `@ohos.data.preferences`。 |
| `enhancedLrcSerializer.ts` | 纯逻辑（正则 `[\]\r\n]` 等）。 |
| `foliaLyricDocument.ts` | 纯 `JSON.parse` + 校验。 |
| `awlrcContainer.ts` | 仅 base64 需替换（见 9.2）。 |
| `pureMusic.ts` / `staffCredits.ts` / `staffCreditsPolicy.ts` | 纯正则 + 词表；`LyricStaffPolicy` / `LyricStaffVerdict` / `LyricStaffAbsorbMode` 见 `src/utils/lyrics/types.ts`。 |

### 9.2 依赖浏览器/Node API，需要替换

| 上游 | 用途（文件） | ArkTS 建议 |
|---|---|---|
| `TextDecoder('utf-8' / 'utf-16le' / 'utf-16be' / 'gb18030')` | `lyricFileDecoding.ts:23-37`、`krcDecrypt`、`qrcDecrypt`、`awlrcContainer` | `@ohos.util` → `util.TextDecoder.create('utf-8')` / `'utf-16le'` / `'utf-16be'`；**`gb18030` 需实测**（`util.TextDecoder` 的编码集与 ICU 版本相关）；不可用时内置 GB18030 解码表或走 `@ohos.i18n`。【推断】 |
| `TextEncoder` | `qrcDecrypt`（`QRC_KEY`）、`qqLyricProvider.toBase64` | `util.TextEncoder`；QRC 的 24 字节密钥也可直接写成 `Uint8Array` 字面量（推荐，避免编码差异）。 |
| `atob` / `btoa` / `Buffer.from(x,'base64')` | `parseKRC` 的 `[language:]`、`awlrcContainer`、`fetchKugouLyrics`、`toBase64` | `util.Base64Helper`（`decodeSync` / `encodeSync`，UTF-8）；或 `@ohos.buffer` 的 `Buffer.from(str,'base64').toString('utf8')`。 |
| `DecompressionStream('deflate')` | `krcDecrypt.decompressDeflate`、`qrcDecrypt.decompressDeflate` | `@ohos.zlib`（`zlib.decompress` / `zlib.inflate`，注意二者对 **zlib 头（0x78）** 与 **raw deflate** 的差别；上游用的是 **zlib 包装**）。若 API 不匹配，改用纯 TS 的 `fflate.inflateSync`（无浏览器 API，可靠）。【推断】 |
| `DOMParser`（`@xmldom/xmldom`） | `parseTTML` | ① 直接移植 `@xmldom/xmldom`（纯 JS，无浏览器 API）；② 或 `@ohos.xml` 的 `XmlPullParser` + 手写 `TTMLResult` 构建器（需对齐 `ttmlConversion.ts` 依赖的 `TTMLResult` 字段）。 |
| `Intl.Segmenter`（word / grapheme） | `wordSegmentation.segmentTextWords`、`graphemeTiming.splitLyricGraphemes`、`sentenceLayout.secondarySplit` | ArkTS/ArkUI 无 `Intl.Segmenter`。方案：① 字素：实现 UAX#29 扩展字素簇切分（emoji ZWJ、组合记号、代理对）；② 词：`segmentTextWords` 退化为字素切分（**上游已有该兜底路径，且保留全部码元与行时序**），CJK 词边界改用 `i18n.BreakIterator`（`@ohos.i18n`）或内置词典；③ `sentenceLayout.secondarySplit` 无 Segmenter 时上游已有伪随机中点切兜底，可直接用。 |
| `Intl` / `localStorage` | 全局偏移、单曲偏移、分词记录 | `@ohos.data.preferences`（key-value）。 |
| `Worker`（`workerClient.ts`） | 解析移出主线程 | 解析是纯函数且快；ArkTS 侧直接同步调用即可。若要异步，用 `@ohos.taskpool`。 |
| `fetch` / `AbortSignal.timeout` | QQ/酷狗/AMLL 网络 | `@ohos.net.http` 或 `@ohos.net.http.createHttp()`；`AbortSignal.timeout(5000)` → 手动 `setTimeout` + 请求取消；`withTimeout` 的 `Promise.race` 语义可原样保留。 |
| `URL` / `URLSearchParams` | AMLL URL、酷狗 query、QQ 代理 | ArkTS 有 `@ohos.url.URL` / `URLParams`；或手写 query 拼接（**签名按排序后的 key 拼接，顺序必须一致**）。 |
| `md5`（`blueimp-md5`） | 酷狗 `signParams`、`mid` | `@ohos.security.cryptoFramework` 的 `Md5`，或移植纯 JS md5。 |
| `Math.random` / `Date.now` | 合唱效果随机、QQ `search_id` | 原生可用。 |
| `wanakana.toRomaji` | `matchScore.normalizeLyricMatchText` | 移植假名→罗马字表（wanakana 是纯 JS，可整体移植）。 |
| `opencc-js`（繁→简） | `matchScore` 的 `t2sConverter` | 移植 `opencc-js` 的 `t2s` 字典，或用 `@ohos.i18n` 的 `Transliterator`/`I18NUtil`；**必须实测覆盖度**，否则中文匹配分下降。【推断】 |
| `\p{P}` `\p{S}` `\p{L}` `\p{N}` `\p{Script=Latin}` 等 Unicode 属性转义 | `wordSegmentation`、`cjkSemanticLayout`、`matchScore`、`timelineSplitter` | ArkTS/ArkJS 对 Unicode 属性转义的支持需实测。若不支持，改为显式字符类（如 `[!-/:-@\[-`{-~…]` + 中文标点集合），并在单测里锁定与上游一致的判定结果。 |
| 正则 `s` 标志（`/^(\s*)(.*?)(\s*)$/su`） | `wordSegmentation.EDGE_WHITESPACE` | 不支持时改用 `[\s\S]` 显式写法。 |
| `Buffer`（Node 分支） | `parseKRC`、`awlrcContainer` | 只保留 `TextDecoder` + `atob` 等价路径（HarmonyOS 属浏览器式环境）。 |

### 9.3 明确**不要**做的事

1. **不要**用系统 3DES 替换 `qrcDecrypt` 的 `SBOX`（非标准 S-box），也不要用 `bitnum` 的等价简化实现。
2. **不要**用 `words.length > 0` 推断 `isWordByWord`（LRC/VTT 也有假时轴）。
3. **不要**给 `[al:]` / `[by:]` / `[offset:]` 增加解析——上游行为是丢弃；加了会改变行数（破坏单测与 `findLatestActiveLineIndex` 的时序）。
4. **不要**在 `findTranslationsForSortedStartTimes` 里退回最近邻——那正是上游修掉的缺陷（重复翻译 / 对唱串行）。
5. **不要**把 `Line` 的 `startTime/endTime` 改成毫秒；毫秒只在解析器入口出现。
6. **不要**修改 `_upstream` 目录下任何文件（本次任务约束）。

### 9.4 模块划分建议（ArkTS）

```
entry/src/main/ets/lyrics/
  types.ets                  // Line/Word/LyricSyllable/... （§1）
  formatDetection.ets        // §2
  parserCore.ets             // §3（buildTimedWords / parseLRC / parseEnhancedLRC / parseVTT / parseYRC / parseQRC / parseKRC / parseAwlrc / finalize*）
  timelineSplitter.ets       // §3.13
  embeddedNormalization.ets  // §3.14
  awlrcContainer.ets         // §3.15
  foliaLyricDocument.ets     // §3.18
  renderHints.ets            // §1.5
  wordSegmentation.ets       // §5.1
  graphemeTiming.ets         // §5.2
  layoutUnits.ets            // §6.1-6.2
  sentenceLayout.ets         // §6.3
  enhancedLrcSerializer.ets  // §3.17
  matching/{matchScore,autoMatchBestLyric,lyricMatchSources,searchQuery,sourcePriority}.ets   // §7
  crypto/{krcDecrypt,qrcDecrypt,des3}.ets                // §4
  runtime/{lineTiming,lyricClock,offsetMemory}.ets       // §8
  io/{fileDecoding,base64,zlib,segmenter}.ets            // §9.2 适配层
```

---

## 10. 输入 / 输出样例（可直接做单测基线）

> 以下均为**默认参数**（`options = {}`，`includeInterludes` 未显式关闭）的真实行为推演，单位为秒。

### 例 1：标准 LRC（含末行 5s 规则 + 假逐字时轴）

输入：

```
[ti:Test Song]
[ar:Someone]
[00:01.00]Hello world
```

`parseLRC` 输出（`finalizeParsedLyricLines` 后）：

```jsonc
{
  "isWordByWord": false,
  "lines": [
    {
      "startTime": 1.0,
      "endTime": 6.0,                       // 无下一行 → duration = 5（末行恒 5s）
      "fullText": "Hello world",
      "words": [
        { "text": "Hello", "startTime": 1.0,  "endTime": 3.25 },   // weight 1.75 / 总 3.5 → 2.25s
        { "text": "world", "startTime": 3.25, "endTime": 5.5  }
      ],
      "renderHints": {
        "rawDuration": 5.0, "timingClass": "normal", "lineTransitionMode": "normal", "wordRevealMode": "normal",
        "renderEndTime": 6.0
      }
    }
  ]
  // 注意：没有 title / artist —— parseLRC 不产出 metadata（[ti:]/[ar:] 只被逐行消费掉）
}
```

（`includeInterludes` 默认开，但首行 1.0s ≤ 3s，故**不插前奏行**。）

### 例 2：增强 LRC（`<mm:ss.xx>` 逐字 + 自动前奏间奏行）

输入：

```
[00:10.00]<00:10.00>Hel<00:10.50>lo <00:11.00>world<00:11.50>
```

`parseEnhancedLRC` 输出：

```jsonc
{
  "isWordByWord": true,
  "lines": [
    { "startTime": 0.5, "endTime": 9.5, "fullText": "......",          // attachInterludes：首行 10.0 > 3
      "words": [ {"text":".","startTime":0.5,"endTime":2.0},
                 {"text":".","startTime":2.0,"endTime":3.5},
                 {"text":".","startTime":3.5,"endTime":5.0},
                 {"text":".","startTime":5.0,"endTime":6.5},
                 {"text":".","startTime":6.5,"endTime":8.0},
                 {"text":".","startTime":8.0,"endTime":9.5} ] },        // 6 个 '.'，(9.5-0.5)/6 = 1.5
    { "startTime": 10.0, "endTime": 11.5, "fullText": "Hello world",
      "words": [
        { "text": "Hel",   "startTime": 10.0, "endTime": 10.5 },
        { "text": "lo ",   "startTime": 10.5, "endTime": 11.0 },       // 空白段计入 fullText 也入 words
        { "text": "world", "startTime": 11.0, "endTime": 11.5 }
      ],
      "renderHints": { "rawDuration": 1.5, "timingClass": "normal", "lineTransitionMode": "normal",
                       "wordRevealMode": "normal", "renderEndTime": 11.5 } }
  ]
}
```

（`draft.endTime = 11.5` 来自最后一个词的 `endTime`；尾随文本为空故不追加 word。）

### 例 3：YRC（网易云逐字）

输入：

```
[1000,2000](1000,500,0)你(1500,500,0)好(2000,1000,0)！
```

输出：

```jsonc
{
  "isWordByWord": true,
  "lines": [
    { "startTime": 1.0, "endTime": 3.0, "fullText": "你好！",
      "words": [ {"text":"你","startTime":1.0,"endTime":1.5},
                 {"text":"好","startTime":1.5,"endTime":2.0},
                 {"text":"！","startTime":2.0,"endTime":3.0} ] }
  ]
}
```

### 例 4：QRC（标签在前的文本分块消歧）

输入（`qrcDecrypt` 之后）：

```
[1000,2000](1000,500)你(1500,500)好(2000,1000)！
```

输出：与例 3 **完全相同**（`prefersTrailingText` 分支：`textChunks = ["", "你", "好", "！"]`，
每个 tag 取 **后一个** chunk）。若把文本写成 `你(1000,500)好(1500,500)！(2000,1000)`，
`prefersLeadingText` 为真，则每个 tag 取**前一个** chunk，结果仍是 `你/好/！` 三个词——
**两种排列必须都通过测试**。

### 例 5：KRC（相对行首 offset + `[language:]` 内嵌轨）

输入（`krcDecrypt` 之后，`[language:]` 值此处省略）：

```
[1000,2000]<0,500,0>你<500,500,0>好<1000,1000,0>！
```

输出：

```jsonc
{
  "isWordByWord": true,
  "lines": [
    { "startTime": 1.0, "endTime": 3.0, "fullText": "你好！",
      "words": [ {"text":"你","startTime":1.0,"endTime":1.5},
                 {"text":"好","startTime":1.5,"endTime":2.0},
                 {"text":"！","startTime":2.0,"endTime":3.0} ],
      "translation": "<内嵌轨 type=1 第 0 项，若有>",
      "romanization": "<内嵌轨 type=0 第 0 项，若有>" }
  ]
}
```

（**与 YRC 的关键差别**：KRC 的 `<offset>` 是**相对行首**的毫秒，`wordStartMs = lineStartTimeMs + offsetMs`；
YRC 的 `(start,dur)` 是**绝对**毫秒。用错会整行错位。）

### 例 6：VTT（行级 + 空行分块）

输入：

```
WEBVTT

00:00:05.000 --> 00:00:08.000
Hello world
```

输出：

```jsonc
{
  "isWordByWord": false,
  "lines": [
    { "startTime": 0.5, "endTime": 4.5, "fullText": "......", "words": [ 6 × { "text": ".", 时长 0.6666… } ] },
    { "startTime": 5.0, "endTime": 8.0, "fullText": "Hello world",
      "words": [ {"text":"Hello","startTime":5.0,"endTime":6.35},
                 {"text":"world","startTime":6.35,"endTime":7.7} ] }
  ]
}
```

（`endTime` 直接取 VTT 的 `00:00:08.000`；`buildTimedWords` 只用到 3s 中的 90% = 2.7s，
`timePerWeight = 2.7/3.5`，故 1.35s/词，末词 7.7 未越界 → 不回缩。前奏行来自首行 5.0 > 3。）

### 例 7（期望值，供逆向验证）：KRC / QRC 解密

- `krcDecrypt(bytes)`：`bytes[0..3] === [107,114,99,49]`（`"krc1"`），长度 > 4；
  `bytes[4+i] ^ KRC_KEY[i % 16]`（`KRC_KEY = [64,71,97,119,94,50,116,71,81,54,49,45,206,210,110,105]`）→ zlib inflate → UTF-8。
- `qrcDecrypt(hex)`：`hex` 逐 2 字符 `parseInt(_,16)` → 3DES-DECRYPT（密钥 `!@#)(*$%123ZXC!@!@#)(NHL`，
  **自定义 SBOX 表见 §4.2**）逐 8 字节块（尾部零填充）→ zlib inflate → UTF-8。
- **自检**：对同一份已知明文先做反向流程（3DES-ENCRYPT + deflate + `md5` 无关）无法用系统库生成，
  因此移植后必须用**真实上游样本**做回归（仓库未内置二进制样本；`test/manual/lyrics_benchmark.ts`
  与 `test/manual/netease_lyrics_cli.ts` 提供人工验证入口）。【推断：样本需另行获取】

### 例 8：翻译配对（`findTranslationsForSortedStartTimes`）

```
startTimes = [10.0, 10.2, 20.0]                 // 10.0 与 10.2 是对唱同起点/近似起点
entries    = [{startTime: 10.1, text: 'T1'}, {startTime: 20.0, text: 'T2'}]
```
候选：`(line0,entry0,diff=0.1)`、`(line1,entry0,diff=0.1)`、`(line2,entry1,diff=0)`。
排序（diff, line, entry）：`(2,1,0) → (0,0,0) → (1,0,0)`。
结果：`line2` 取 `T2`；`line0` 取 `T1`；**`line1` 得到 `undefined`**（不借用邻居）。
而 `[10.00][10.00]` 两条同时间戳的译文会按 `entry` 升序依次配给 `line0`、`line1`。

---

## 附：一句话索引（实现时按需回查）

| 我要…… | 看 |
|---|---|
| 字段/单位 | §1 |
| 判断一份文本是什么格式 | §2.1 |
| 造「假逐字」时轴 | §3.2 |
| 插 `......` 间奏 | §3.3 |
| 配翻译/罗马音 | §3.4 |
| 拆「原文+译文同行」 | §3.13 |
| 洛雪容器 | §3.15 |
| KRC/QRC 密钥与 SBOX | §4 |
| 分词 / 字素 | §5 |
| 布局单元 / 句子切分 | §6 |
| 匹配分与自动匹配顺序 | §7 |
| 播放位置 → 高亮行/词 | §8 |
| ArkTS 换什么 API | §9 |
| 单测基线 | §10 |
