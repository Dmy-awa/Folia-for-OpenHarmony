/**
 * Folia HarmonyOS - 元数据解析公共工具
 *
 * 各容器解析器（MP3/FLAC/Ogg/MP4/WAV/AAC）共用的取值、清理、封面与歌手拆分逻辑。
 * 这里只依赖 ByteReader 与公开类型，不依赖任何具体容器解析器，避免循环依赖。
 */
import { AudioMetadata, EmbeddedCover } from './MetadataReader';

/** 内嵌封面字节上限（8MB），防止损坏的标签长度触发超大分配 */
export const MAX_COVER_BYTES: number = 8 * 1024 * 1024;

/** 创建一个全部字段为空的元数据结果；解析器在其上逐字段覆盖 */
export function createEmptyMetadata(): AudioMetadata {
  const artists: string[] = [];
  const result: AudioMetadata = {
    title: '',
    artist: '',
    artists: artists,
    album: '',
    albumArtist: '',
    trackNumber: 0,
    year: '',
    durationMs: 0,
    sampleRate: 0,
    bitrate: 0,
    channels: 0,
    cover: undefined,
    lyrics: undefined
  };
  return result;
}

/** 单行字段清理：去掉 NUL、把换行折叠成空格并 trim */
export function sanitizeText(value: string): string {
  if (value.length === 0) {
    return '';
  }
  let text = '';
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code === 0) {
      continue;
    }
    if (code === 0x0A || code === 0x0D) {
      text += ' ';
      continue;
    }
    text += value.charAt(i);
  }
  return text.trim();
}

/** 歌词清理：去掉 NUL、统一换行为 \n 并 trim */
export function sanitizeLyrics(value: string): string {
  if (value.length === 0) {
    return '';
  }
  let text = '';
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code === 0) {
      continue;
    }
    if (code === 0x0D) {
      text += '\n';
      continue;
    }
    text += value.charAt(i);
  }
  return text.trim();
}

/** 取字符串中的第一个连续数字串，如 "3/12" -> 3；无数字返回 0 */
export function parseLeadingInt(value: string): number {
  const text = sanitizeText(value);
  let digits = '';
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code >= 0x30 && code <= 0x39) {
      digits += text.charAt(i);
    } else {
      break;
    }
  }
  if (digits.length === 0) {
    return 0;
  }
  const parsed = Number.parseInt(digits, 10);
  return parsed > 0 ? parsed : 0;
}

/** 从 "1975-03-01"、"1975"、"03/1975" 等取年份；找不到 4 位数字时返回原文 */
export function extractYear(value: string): string {
  const text = sanitizeText(value);
  if (text.length === 0) {
    return '';
  }
  for (let i = 0; i + 4 <= text.length; i++) {
    let allDigits = true;
    for (let k = 0; k < 4; k++) {
      const code = text.charCodeAt(i + k);
      if (code < 0x30 || code > 0x39) {
        allDigits = false;
        break;
      }
    }
    if (!allDigits) {
      continue;
    }
    // 前后不能再紧邻数字，避免从 "12345" 中截出 "1234"
    const before = i > 0 ? text.charCodeAt(i - 1) : 0;
    const after = i + 4 < text.length ? text.charCodeAt(i + 4) : 0;
    const beforeIsDigit = before >= 0x30 && before <= 0x39;
    const afterIsDigit = after >= 0x30 && after <= 0x39;
    if (!beforeIsDigit && !afterIsDigit) {
      return text.substring(i, i + 4);
    }
  }
  return text;
}

/** 按单个分隔词切分（大小写不敏感），保留原文片段 */
function splitOnWord(value: string, word: string): string[] {
  const parts: string[] = [];
  const lower = value.toLowerCase();
  let from = 0;
  while (from <= value.length) {
    const index = lower.indexOf(word, from);
    if (index < 0) {
      parts.push(value.substring(from));
      break;
    }
    parts.push(value.substring(from, index));
    from = index + word.length;
  }
  return parts;
}

/**
 * 把标签里的艺术家字符串拆成逐个歌手。
 * 分隔符：; ； 、 ／ （始终拆分），以及带空格的 " feat. " / " ft. " / " & " / " with "。
 * 不含无空格的 "/"，避免把 "AC/DC" 拆开。
 */
export function splitArtistList(value: string): string[] {
  const result: string[] = [];
  const text = sanitizeText(value);
  if (text.length === 0) {
    return result;
  }
  const hardSeparators: string[] = [';', '；', '、', '／'];
  let parts: string[] = [text];
  for (let s = 0; s < hardSeparators.length; s++) {
    const separator = hardSeparators[s];
    const next: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const pieces = splitOnWord(parts[i], separator);
      for (let k = 0; k < pieces.length; k++) {
        next.push(pieces[k]);
      }
    }
    parts = next;
  }
  const softSeparators: string[] = [' feat. ', ' feat ', ' ft. ', ' ft ', ' & ', ' with '];
  for (let s = 0; s < softSeparators.length; s++) {
    const separator = softSeparators[s];
    const next: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const pieces = splitOnWord(parts[i], separator);
      for (let k = 0; k < pieces.length; k++) {
        next.push(pieces[k]);
      }
    }
    parts = next;
  }
  for (let i = 0; i < parts.length; i++) {
    const name = sanitizeText(parts[i]);
    if (name.length > 0 && result.indexOf(name) < 0) {
      result.push(name);
    }
  }
  return result;
}

/** 根据魔数猜封面 MIME 类型；无法识别时按 JPEG 处理（多数场景兜底可渲染） */
export function guessImageMime(data: Uint8Array): string {
  if (data.length >= 3 && data[0] === 0xFF && data[1] === 0xD8 && data[2] === 0xFF) {
    return 'image/jpeg';
  }
  if (data.length >= 8 && data[0] === 0x89 && data[1] === 0x50 && data[2] === 0x4E && data[3] === 0x47) {
    return 'image/png';
  }
  if (data.length >= 6 && data[0] === 0x47 && data[1] === 0x49 && data[2] === 0x46) {
    return 'image/gif';
  }
  if (data.length >= 2 && data[0] === 0x42 && data[1] === 0x4D) {
    return 'image/bmp';
  }
  if (data.length >= 12 && data[8] === 0x57 && data[9] === 0x45 && data[10] === 0x42 && data[11] === 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

/**
 * 写入封面。
 * force 为 true 时覆盖已有封面（MP3 用于让 APIC 的“正面封面”类型 3 优先），否则第一张优先。
 */
export function applyCover(meta: AudioMetadata, mime: string, data: Uint8Array, force: boolean): void {
  if (data.length === 0) {
    return;
  }
  if (meta.cover !== undefined && !force) {
    return;
  }
  let take = data.length;
  if (take > MAX_COVER_BYTES) {
    take = MAX_COVER_BYTES;
  }
  const bytes: Uint8Array = take === data.length ? data : data.slice(0, take);
  let mimeType = sanitizeText(mime);
  if (mimeType.length === 0 || mimeType.indexOf('/') <= 0 || mimeType === '-->') {
    // MIME 缺失、非法或是内嵌 URL（FLAC 允许 "-->http://..."），按魔数兜底
    mimeType = guessImageMime(bytes);
  }
  const cover: EmbeddedCover = { mimeType: mimeType, data: bytes };
  meta.cover = cover;
}

/**
 * 收尾：清理字符串、补齐 artists、取整数值。
 * albumArtist 缺失时不做回落（不臆造专辑艺术家），由上层决定策略。
 */
export function finalizeMetadata(meta: AudioMetadata): void {
  meta.title = sanitizeText(meta.title);
  meta.artist = sanitizeText(meta.artist);
  meta.album = sanitizeText(meta.album);
  meta.albumArtist = sanitizeText(meta.albumArtist);
  meta.year = sanitizeText(meta.year);

  const artists: string[] = [];
  for (let i = 0; i < meta.artists.length; i++) {
    const name = sanitizeText(meta.artists[i]);
    if (name.length > 0 && artists.indexOf(name) < 0) {
      artists.push(name);
    }
  }
  if (artists.length === 0 && meta.artist.length > 0) {
    const split = splitArtistList(meta.artist);
    for (let i = 0; i < split.length; i++) {
      artists.push(split[i]);
    }
  }
  meta.artists = artists;
  if (meta.artist.length === 0 && artists.length > 0) {
    meta.artist = artists[0];
  }

  if (meta.lyrics !== undefined) {
    const lyrics = sanitizeLyrics(meta.lyrics);
    meta.lyrics = lyrics.length > 0 ? lyrics : undefined;
  }

  meta.trackNumber = meta.trackNumber > 0 ? Math.floor(meta.trackNumber) : 0;
  meta.durationMs = meta.durationMs > 0 ? Math.round(meta.durationMs) : 0;
  meta.sampleRate = meta.sampleRate > 0 ? Math.round(meta.sampleRate) : 0;
  meta.bitrate = meta.bitrate > 0 ? Math.round(meta.bitrate) : 0;
  meta.channels = meta.channels > 0 ? Math.floor(meta.channels) : 0;
}
