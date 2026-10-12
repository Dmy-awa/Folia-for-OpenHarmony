/**
 * Folia HarmonyOS - M4A / MP4 标签解析
 *
 * 结构：原子的树形嵌套，每个原子 = size(4, 大端) + type(4) [+ 64 位 size 或 full box 头]。
 * 关注：
 *   moov.mvhd           整体时长（timescale + duration）
 *   moov.trak.mdia.mdhd 音轨时长（优先于 mvhd）
 *   moov.udta.meta.ilst 文本项（©nam / ©ART / aART / ©alb / trkn / ©day / ©lyr）与 covr
 *   moov.trak.mdia.minf.stbl.stsd.mp4a  采样率与声道数
 *
 * 32 位与 64 位原子长度都支持；所有子原子边界都会被裁剪到父原子范围内。
 */
import { ByteReader, asciiEquals, readUint16BE, readUint32BE, readUint64BE, decodeUtf8 } from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import {
  MAX_COVER_BYTES, createEmptyMetadata, finalizeMetadata, sanitizeText,
  sanitizeLyrics, extractYear, applyCover
} from './MetadataUtils';
import { Logger } from '../../core/Logger';

const TAG: string = 'Mp4Parser';

/** 递归深度上限，防御构造出的恶意嵌套 */
const MAX_DEPTH: number = 10;

/** 单层原子数量上限 */
const MAX_ATOMS_PER_LEVEL: number = 4096;

/** 文本项读取上限 */
const MAX_TEXT_BYTES: number = 64 * 1024;

/** 原子头解析结果 */
interface Mp4AtomHeader {
  ok: boolean;
  size: number;
  headerSize: number;
  typeBytes: Uint8Array;
}

/** 解析过程中的可变状态 */
class Mp4WalkState {
  mvhdDurationMs: number = 0;
  mdhdDurationMs: number = 0;
}

/** 构造失败结果 */
function invalidHeader(): Mp4AtomHeader {
  const header: Mp4AtomHeader = { ok: false, size: 0, headerSize: 0, typeBytes: new Uint8Array(0) };
  return header;
}

/** 读取 pos 处的原子头（含 64 位长度与 uuid 扩展头） */
function readAtomHeader(reader: ByteReader, pos: number, end: number): Mp4AtomHeader {
  const result = invalidHeader();
  if (pos + 8 > end) {
    return result;
  }
  const head = reader.readRange(pos, 16);
  if (head.length < 8) {
    return result;
  }
  let size = readUint32BE(head, 0);
  let headerSize = 8;
  if (size === 1) {
    if (head.length < 16) {
      return result;
    }
    size = readUint64BE(head, 8);
    headerSize = 16;
  } else if (size === 0) {
    size = end - pos; // 延伸到父容器末尾
  }
  if (size < headerSize) {
    return result;
  }
  const typeBytes = head.slice(4, 8);
  if (asciiEquals(typeBytes, 0, 'uuid')) {
    headerSize += 16; // uuid 原子额外 16 字节用户类型
    if (size < headerSize) {
      return result;
    }
  }
  result.ok = true;
  result.size = size;
  result.headerSize = headerSize;
  result.typeBytes = typeBytes;
  return result;
}

/** 解析 mvhd：版本 0 用 32 位时长，版本 1 用 64 位 */
function parseMvhd(reader: ByteReader, start: number, end: number, state: Mp4WalkState): void {
  const bytes = reader.readRange(start, 32);
  if (bytes.length < 20) {
    return;
  }
  const version = bytes[0];
  let timescale = 0;
  let duration = 0;
  if (version === 1) {
    if (bytes.length < 32) {
      return;
    }
    timescale = readUint32BE(bytes, 20);
    duration = readUint64BE(bytes, 24);
  } else {
    timescale = readUint32BE(bytes, 12);
    duration = readUint32BE(bytes, 16);
  }
  if (timescale > 0 && duration > 0) {
    state.mvhdDurationMs = duration * 1000 / timescale;
  }
}

/** 解析 mdhd（音轨时长，优先使用第一个有效值） */
function parseMdhd(reader: ByteReader, start: number, end: number, state: Mp4WalkState): void {
  const bytes = reader.readRange(start, 32);
  if (bytes.length < 20) {
    return;
  }
  const version = bytes[0];
  let timescale = 0;
  let duration = 0;
  if (version === 1) {
    if (bytes.length < 32) {
      return;
    }
    timescale = readUint32BE(bytes, 20);
    duration = readUint64BE(bytes, 24);
  } else {
    timescale = readUint32BE(bytes, 12);
    duration = readUint32BE(bytes, 16);
  }
  if (timescale > 0 && duration > 0 && state.mdhdDurationMs <= 0) {
    state.mdhdDurationMs = duration * 1000 / timescale;
  }
}

/** 解析音频采样入口（mp4a/alac）：声道数 @16，采样率 @24（16.16 定点） */
function parseAudioSampleEntry(reader: ByteReader, start: number, end: number, meta: AudioMetadata): void {
  const bytes = reader.readRange(start, 28);
  if (bytes.length < 28) {
    return;
  }
  const channels = readUint16BE(bytes, 16);
  if (channels > 0) {
    meta.channels = channels;
  }
  const sampleRate = readUint32BE(bytes, 24) >>> 16;
  if (sampleRate > 0) {
    meta.sampleRate = sampleRate;
  }
}

/** 解析 ilst 下的一个文本/二进制项 */
function parseIlstItem(reader: ByteReader, itemType: Uint8Array, start: number, end: number, meta: AudioMetadata): void {
  let pos = start;
  let guard = 0;
  while (pos + 8 <= end && guard < 64) {
    guard++;
    const header = readAtomHeader(reader, pos, end);
    if (!header.ok) {
      break;
    }
    let childEnd = pos + header.size;
    if (childEnd > end || childEnd <= pos) {
      childEnd = end;
    }
    if (asciiEquals(header.typeBytes, 0, 'data')) {
      const dataHead = reader.readRange(pos, 16);
      if (dataHead.length >= 16) {
        // data 原子：size(4) 'data'(4) typeIndicator(4) locale(4) payload
        const typeIndicator = readUint32BE(dataHead, 8) & 0x00FFFFFF;
        applyIlstData(reader, itemType, typeIndicator, pos + 16, childEnd, meta);
      }
    }
    if (header.size <= 0) {
      break;
    }
    pos = pos + header.size;
  }
}

/** 把 data 载荷写入对应字段 */
function applyIlstData(reader: ByteReader, itemType: Uint8Array, typeIndicator: number, start: number, end: number, meta: AudioMetadata): void {
  const length = end - start;
  if (length <= 0) {
    return;
  }
  if (asciiEquals(itemType, 0, 'covr')) {
    // 13 = JPEG，14 = PNG，其他按魔数兜底；第一张优先
    let take = length;
    if (take > MAX_COVER_BYTES) {
      take = MAX_COVER_BYTES;
    }
    const data = reader.readRange(start, take);
    if (data.length === 0) {
      return;
    }
    let mime = '';
    if (typeIndicator === 13) {
      mime = 'image/jpeg';
    } else if (typeIndicator === 14) {
      mime = 'image/png';
    }
    applyCover(meta, mime, data, false);
    return;
  }
  if (asciiEquals(itemType, 0, 'trkn')) {
    // 二进制：2 字节保留 + 2 字节曲号 + 2 字节总数 + 2 字节保留
    const bytes = reader.readRange(start, Math.min(length, 8));
    if (bytes.length >= 4 && meta.trackNumber <= 0) {
      meta.trackNumber = readUint16BE(bytes, 2);
    }
    return;
  }
  let take = length;
  if (take > MAX_TEXT_BYTES) {
    take = MAX_TEXT_BYTES;
  }
  const bytes = reader.readRange(start, take);
  if (bytes.length === 0) {
    return;
  }
  const text = sanitizeText(decodeUtf8(bytes, 0, bytes.length));
  if (text.length === 0) {
    return;
  }
  const isCopyRight = itemType.length >= 4 && itemType[0] === 0xA9;
  if (isCopyRight && asciiEquals(itemType, 1, 'nam')) {
    if (meta.title.length === 0) {
      meta.title = text;
    }
    return;
  }
  if (isCopyRight && asciiEquals(itemType, 1, 'ART')) {
    if (meta.artist.length === 0) {
      meta.artist = text;
    }
    return;
  }
  if (asciiEquals(itemType, 0, 'aART')) {
    if (meta.albumArtist.length === 0) {
      meta.albumArtist = text;
    }
    return;
  }
  if (isCopyRight && asciiEquals(itemType, 1, 'alb')) {
    if (meta.album.length === 0) {
      meta.album = text;
    }
    return;
  }
  if (isCopyRight && asciiEquals(itemType, 1, 'day')) {
    if (meta.year.length === 0) {
      meta.year = extractYear(text);
    }
    return;
  }
  if (isCopyRight && asciiEquals(itemType, 1, 'lyr')) {
    if (meta.lyrics === undefined) {
      const lyrics = sanitizeLyrics(text);
      if (lyrics.length > 0) {
        meta.lyrics = lyrics;
      }
    }
    return;
  }
}

/** 分发单个原子 */
function handleAtom(reader: ByteReader, header: Mp4AtomHeader, dataStart: number, atomEnd: number,
  depth: number, meta: AudioMetadata, state: Mp4WalkState): void {
  const type = header.typeBytes;
  if (asciiEquals(type, 0, 'moov') || asciiEquals(type, 0, 'trak') || asciiEquals(type, 0, 'mdia')
    || asciiEquals(type, 0, 'minf') || asciiEquals(type, 0, 'stbl') || asciiEquals(type, 0, 'udta')
    || asciiEquals(type, 0, 'ilst')) {
    walkAtoms(reader, dataStart, atomEnd, depth + 1, meta, state);
    return;
  }
  if (asciiEquals(type, 0, 'meta')) {
    // meta 是 full box：version(1) + flags(3)；个别 QuickTime 文件省略这 4 字节
    let childStart = dataStart;
    const probe = reader.readRange(dataStart, 4);
    if (probe.length === 4 && readUint32BE(probe, 0) === 0) {
      childStart = dataStart + 4;
    }
    walkAtoms(reader, childStart, atomEnd, depth + 1, meta, state);
    return;
  }
  if (asciiEquals(type, 0, 'stsd')) {
    // full box：version+flags(4) + entryCount(4)，之后是 sample entry 原子
    walkAtoms(reader, dataStart + 8, atomEnd, depth + 1, meta, state);
    return;
  }
  if (asciiEquals(type, 0, 'mvhd')) {
    parseMvhd(reader, dataStart, atomEnd, state);
    return;
  }
  if (asciiEquals(type, 0, 'mdhd')) {
    parseMdhd(reader, dataStart, atomEnd, state);
    return;
  }
  if (asciiEquals(type, 0, 'mp4a') || asciiEquals(type, 0, 'alac')) {
    parseAudioSampleEntry(reader, dataStart, atomEnd, meta);
    return;
  }
  const isCopyRightItem = type.length >= 4 && type[0] === 0xA9;
  // aART / covr / trkn / disk 不带 © 前缀，需要单独识别
  const isPlainItem = asciiEquals(type, 0, 'covr') || asciiEquals(type, 0, 'trkn')
    || asciiEquals(type, 0, 'aART') || asciiEquals(type, 0, 'disk');
  if (isCopyRightItem || isPlainItem) {
    parseIlstItem(reader, type, dataStart, atomEnd, meta);
  }
}

/** 在 [start, end) 内顺序遍历同一层的原子 */
function walkAtoms(reader: ByteReader, start: number, end: number, depth: number,
  meta: AudioMetadata, state: Mp4WalkState): void {
  if (depth > MAX_DEPTH || start < 0 || end <= start) {
    return;
  }
  let pos = start;
  let guard = 0;
  while (pos + 8 <= end && guard < MAX_ATOMS_PER_LEVEL) {
    guard++;
    const header = readAtomHeader(reader, pos, end);
    if (!header.ok) {
      break; // 损坏：停止当前层
    }
    let atomEnd = pos + header.size;
    if (atomEnd > end || atomEnd <= pos) {
      atomEnd = end; // 长度越界时裁剪到父容器末尾
    }
    handleAtom(reader, header, pos + header.headerSize, atomEnd, depth, meta, state);
    if (header.size <= 0) {
      break;
    }
    pos = pos + header.size;
  }
}

/** M4A/MP4 入口 */
export function parseMp4(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  const state = new Mp4WalkState();
  try {
    const head = reader.readRange(4, 4);
    if (head.length < 4 || !asciiEquals(head, 0, 'ftyp')) {
      return meta;
    }
    walkAtoms(reader, 0, fileSize, 0, meta, state);
    if (state.mdhdDurationMs > 0) {
      meta.durationMs = state.mdhdDurationMs;
    } else if (state.mvhdDurationMs > 0) {
      meta.durationMs = state.mvhdDurationMs;
    }
    // 平均码率（kbps）：m4a 通常为 AAC，码率需要按文件大小估算
    if (meta.durationMs > 0 && meta.bitrate <= 0) {
      meta.bitrate = fileSize * 8 / meta.durationMs;
    }
  } catch (e) {
    Logger.err(TAG, 'parseMp4', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}
