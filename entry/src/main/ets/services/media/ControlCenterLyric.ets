/**
 * Folia HarmonyOS - 播控中心歌词载荷
 *
 * 系统媒体播控中心通过 `AVMetadata.lyric` 显示歌词，格式要求是
 * **简单版 LRC（Simple LRC）**，且字符串长度必须小于 40960 字节。
 *
 * 因此这里不能直接把解析后的行结构塞过去，而是重新序列化一份「干净」的 LRC：
 *  - 只保留行时间 + 文本，不带逐字尖括号（系统不识别，反而会当成正文显示）；
 *  - 跳过间奏行（`......`）与元信息行，它们在系统卡片上没有意义；
 *  - 全局时间偏移必须在这里抵消，否则播控中心歌词会与音频不同步；
 *  - 按字节数截断，优先保留前半部分，保证不触发系统的 40960 字节上限。
 */
import { util } from '@kit.ArkTS';
import { LyricDocument, LyricLine } from '../../core/Types';
import { INTERLUDE_FULL_TEXT } from '../lyrics/LyricCore';
import { Logger } from '../../core/Logger';

const TAG: string = 'ControlCenterLyric';

/** 系统上限，留出安全余量 */
const MAX_BYTES: number = 40000;

/** 把秒格式化成 `[mm:ss.xx]` */
function formatTimestamp(seconds: number): string {
  const safe = Math.max(0, seconds);
  const totalCentis = Math.round(safe * 100);
  const minutes = Math.floor(totalCentis / 6000);
  const secs = Math.floor((totalCentis % 6000) / 100);
  const centis = totalCentis % 100;
  const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
  const ss = secs < 10 ? `0${secs}` : `${secs}`;
  const cc = centis < 10 ? `0${centis}` : `${centis}`;
  return `[${mm}:${ss}.${cc}]`;
}

/** 单行文本里混入的换行会破坏 LRC 结构，需压平成空格 */
function flatten(text: string): string {
  return text.replace(/[\r\n]+/g, ' ').trim();
}

/**
 * 生成播控中心可用的 LRC 文本。
 *
 * @param doc 解析后的歌词文档
 * @param offsetMs 当前生效的歌词偏移（毫秒）。正值表示 App 内歌词提前显示，
 *                 播控中心没有偏移概念，因此序列化时要反向补偿。
 * @returns LRC 文本；无可用歌词时返回空串（调用方应据此不设置 lyric 字段）
 */
export function buildControlCenterLrc(doc: LyricDocument | undefined, offsetMs: number): string {
  if (doc === undefined || doc.lines.length === 0) {
    return '';
  }
  const offsetSeconds = Math.max(-2, Math.min(2, offsetMs / 1000));
  const parts: string[] = [];
  let approximateBytes = 0;

  for (const line of doc.lines) {
    if (shouldSkip(line)) {
      continue;
    }
    // 反向补偿：App 内用的是 (position - offset)，播控中心用原始 position
    const displayTime = line.startTime + offsetSeconds;
    const text = flatten(line.fullText);
    if (text.length === 0) {
      continue;
    }
    const entry = `${formatTimestamp(displayTime)}${text}\n`;
    const entryBytes = utf8Length(entry);
    if (approximateBytes + entryBytes > MAX_BYTES) {
      Logger.warn(TAG, `lyric truncated at ${parts.length} lines`);
      break;
    }
    parts.push(entry);
    approximateBytes += entryBytes;
  }

  if (parts.length === 0) {
    return '';
  }
  return parts.join('');
}

function shouldSkip(line: LyricLine): boolean {
  if (line.isInterlude === true) {
    return true;
  }
  if (line.fullText === INTERLUDE_FULL_TEXT) {
    return true;
  }
  if (line.isCredit === true) {
    return true;
  }
  return line.fullText.trim().length === 0;
}

/** UTF-8 字节数；直接用编码器测量，避免中文按字符数低估 */
function utf8Length(text: string): number {
  try {
    return util.TextEncoder.create('utf-8').encodeInto(text).byteLength;
  } catch (error) {
    // 编码器不可用时退化为保守估计：中文按 3 字节
    let bytes = 0;
    for (let i = 0; i < text.length; i += 1) {
      bytes += text.charCodeAt(i) > 0x7F ? 3 : 1;
    }
    return bytes;
  }
}
