/**
 * Folia HarmonyOS - Ogg（Vorbis / Opus）标签解析
 *
 * 结构：Ogg Page（'OggS' + 版本 + 类型 + granule(8) + serial(4) + seq(4) + crc(4)
 *       + 段数(1) + 段表(n) + 载荷）。一个逻辑包可以跨多个页，这里把头部若干页的
 *       载荷顺序拼接后再解析：识别头（0x01 "vorbis" / "OpusHead"）与注释头
 *       （0x03 "vorbis" / "OpusTags"）。
 *
 * 时长：best-effort —— 读取文件尾部窗口，取最后一个 granule 有效的页。
 *       取不到时 durationMs 保持 0（例如只写入了部分文件、页被截断）。
 *
 * 不支持：Ogg FLAC / Theora 等非 Vorbis/Opus 流。
 */
import { ByteReader, asciiEquals, indexOfAscii, readUint16LE, readUint32LE } from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import { createEmptyMetadata, finalizeMetadata } from './MetadataUtils';
import { parseVorbisComment } from './VorbisTag';
import { Logger } from '../../core/Logger';

const TAG: string = 'VorbisParser';

/** 头部窗口：用于收集识别头与注释头（含内嵌封面），超出部分不再解析 */
const MAX_HEADER_WINDOW: number = 256 * 1024;

/** 头部最多遍历的页数 */
const MAX_HEADER_PAGES: number = 64;

/** 尾部窗口：用于查找最后一页的 granule position */
const TAIL_WINDOW: number = 64 * 1024;

/** Opus 解码采样率固定 48kHz，granule 也以 48kHz 计 */
const OPUS_SAMPLE_RATE: number = 48000;

/**
 * 顺序拼接头部若干页的载荷。
 * 只做单趟有界遍历：段表或载荷越界立即停止。
 */
function collectHeaderPayloads(window: Uint8Array): Uint8Array {
  const parts: Uint8Array[] = [];
  let total = 0;
  let pos = 0;
  let pages = 0;
  while (pos + 27 <= window.length && pages < MAX_HEADER_PAGES && total < MAX_HEADER_WINDOW) {
    if (!asciiEquals(window, pos, 'OggS')) {
      break;
    }
    const segmentCount = window[pos + 26];
    if (pos + 27 + segmentCount > window.length) {
      break;
    }
    let payloadLength = 0;
    for (let i = 0; i < segmentCount; i++) {
      payloadLength += window[pos + 27 + i];
    }
    const payloadStart = pos + 27 + segmentCount;
    if (payloadStart + payloadLength > window.length) {
      break;
    }
    if (payloadLength > 0) {
      parts.push(window.slice(payloadStart, payloadStart + payloadLength));
      total += payloadLength;
    }
    pos = payloadStart + payloadLength;
    pages++;
  }
  const concat = new Uint8Array(total);
  let write = 0;
  for (let i = 0; i < parts.length; i++) {
    concat.set(parts[i], write);
    write += parts[i].length;
  }
  return concat;
}

/** 在拼接后的载荷里找 0x03 "vorbis" 注释头，返回注释数据起始偏移；找不到返回 -1 */
function findVorbisCommentStart(data: Uint8Array, from: number): number {
  let index = from;
  let guard = 0;
  while (guard < 4096) {
    guard++;
    index = indexOfAscii(data, 'vorbis', index);
    if (index < 0) {
      return -1;
    }
    if (index >= 1 && data[index - 1] === 0x03) {
      return index + 6;
    }
    index += 1;
  }
  return -1;
}

/**
 * 读取最后一页的 granule position（以采样数为单位）。
 * 尾部窗口内向前扫描所有 'OggS'，只接受页结构完整且 granule 不是 -1 的页，取最大值。
 */
function readLastGranule(reader: ByteReader, fileSize: number): number {
  if (fileSize < 27) {
    return 0;
  }
  let tailSize = fileSize;
  if (tailSize > TAIL_WINDOW) {
    tailSize = TAIL_WINDOW;
  }
  const tail = reader.readTail(tailSize);
  if (tail.length < 27) {
    return 0;
  }
  let best = 0;
  for (let i = 0; i + 27 <= tail.length; i++) {
    if (!asciiEquals(tail, i, 'OggS')) {
      continue;
    }
    const low = readUint32LE(tail, i + 6);
    const high = readUint32LE(tail, i + 10);
    if (low === 0xFFFFFFFF && high === 0xFFFFFFFF) {
      continue; // granule = -1，表示该页没有完成的包
    }
    if (high >= 0x200000) {
      continue; // 超出安全整数范围，视为噪声
    }
    const segmentCount = tail[i + 26];
    if (i + 27 + segmentCount > tail.length) {
      continue;
    }
    let payloadLength = 0;
    for (let k = 0; k < segmentCount; k++) {
      payloadLength += tail[i + 27 + k];
    }
    if (i + 27 + segmentCount + payloadLength > tail.length) {
      continue; // 页不完整（被窗口起点截断），丢弃
    }
    const granule = high * 4294967296 + low;
    if (granule > best) {
      best = granule;
    }
  }
  return best;
}

/** Ogg 入口（Vorbis / Opus） */
export function parseOgg(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  try {
    if (fileSize < 27) {
      return meta;
    }
    let windowSize = fileSize;
    if (windowSize > MAX_HEADER_WINDOW) {
      windowSize = MAX_HEADER_WINDOW;
    }
    const window = reader.readRange(0, windowSize);
    if (window.length < 27 || !asciiEquals(window, 0, 'OggS')) {
      return meta;
    }
    const concat = collectHeaderPayloads(window);
    if (concat.length < 8) {
      return meta;
    }

    let sampleRate = 0;
    let preSkip = 0;
    let isOpus = false;

    if (asciiEquals(concat, 0, '\u0001vorbis') && concat.length >= 30) {
      // Vorbis 识别头（共 30 字节）：channels@11，sampleRate@12(u32 LE)，nominalBitrate@20(u32 LE)
      meta.channels = concat[11];
      sampleRate = readUint32LE(concat, 12);
      const nominalBitrate = readUint32LE(concat, 20);
      meta.sampleRate = sampleRate;
      if (nominalBitrate > 0 && nominalBitrate < 1000000000) {
        meta.bitrate = nominalBitrate / 1000;
      }
      const commentStart = findVorbisCommentStart(concat, 7);
      if (commentStart >= 0) {
        parseVorbisComment(concat, commentStart, concat.length, meta);
      }
    } else if (asciiEquals(concat, 0, 'OpusHead') && concat.length >= 19) {
      // Opus 识别头：version@8，channels@9，preSkip@10(u16 LE)，inputSampleRate@12(u32 LE)
      isOpus = true;
      meta.channels = concat[9];
      preSkip = readUint16LE(concat, 10);
      sampleRate = OPUS_SAMPLE_RATE;
      meta.sampleRate = sampleRate;
      const tagsIndex = indexOfAscii(concat, 'OpusTags', 0);
      if (tagsIndex >= 0) {
        parseVorbisComment(concat, tagsIndex + 8, concat.length, meta);
      }
    } else {
      // 既不是 Vorbis 也不是 Opus（例如 Ogg FLAC / Theora），本解析器不支持
      Logger.warn(TAG, '不支持的 Ogg 编码');
      return meta;
    }

    if (sampleRate > 0) {
      const granule = readLastGranule(reader, fileSize);
      let samples = granule;
      if (isOpus && preSkip > 0 && samples > preSkip) {
        samples -= preSkip;
      }
      if (samples > 0) {
        meta.durationMs = samples * 1000 / sampleRate;
      }
    }
  } catch (e) {
    Logger.err(TAG, 'parseOgg', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}
