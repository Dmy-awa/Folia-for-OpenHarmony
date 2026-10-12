/**
 * Folia HarmonyOS - WAV（RIFF/WAVE）与 AAC（ADTS）解析
 *
 * WAV：RIFF 头 + 若干 chunk（fmt / data / LIST-INFO），chunk 为小端、按偶数字节对齐。
 *      时长由 data chunk 长度与 byteRate 计算，因此是精确值。
 * AAC：ADTS 头给出采样率索引与声道配置，首个帧长可用于估算平均码率；
 *      精确时长需要遍历全部帧，这里按 best-effort 保持 durationMs = 0。
 */
import { ByteReader, asciiEquals, readUint16LE, readUint32LE, decodeUtf8 } from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import { createEmptyMetadata, finalizeMetadata, sanitizeText, parseLeadingInt, extractYear } from './MetadataUtils';
import { Logger } from '../../core/Logger';

const TAG: string = 'WavParser';

/** chunk 数量上限 */
const MAX_CHUNK_COUNT: number = 4096;

/** LIST-INFO 单个值读取上限 */
const MAX_INFO_VALUE_BYTES: number = 64 * 1024;

/** ADTS 采样率表（按 samplingFrequencyIndex） */
const ADTS_SAMPLE_RATES: number[] = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
  16000, 12000, 11025, 8000, 7350, 0, 0, 0
];

/** 读取 LIST/INFO 子块中的字符串值（NUL 结尾） */
function readInfoValue(reader: ByteReader, start: number, end: number): string {
  if (end <= start) {
    return '';
  }
  let take = end - start;
  if (take > MAX_INFO_VALUE_BYTES) {
    take = MAX_INFO_VALUE_BYTES;
  }
  const bytes = reader.readRange(start, take);
  if (bytes.length === 0) {
    return '';
  }
  // INFO 值通常是 Latin-1 或 UTF-8，这里按 UTF-8 解码并裁到第一个 NUL
  let cut = bytes.length;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] === 0x00) {
      cut = i;
      break;
    }
  }
  return sanitizeText(decodeUtf8(bytes, 0, cut));
}

/** 解析 LIST 块中的 INFO 子块：INAM/IART/IPRD/ICRD/ITRK */
function parseInfoList(reader: ByteReader, start: number, end: number, meta: AudioMetadata): void {
  const listHead = reader.readRange(start, 4);
  if (listHead.length < 4 || !asciiEquals(listHead, 0, 'INFO')) {
    return;
  }
  let pos = start + 4;
  let guard = 0;
  while (pos + 8 <= end && guard < MAX_CHUNK_COUNT) {
    guard++;
    const head = reader.readRange(pos, 8);
    if (head.length < 8) {
      return;
    }
    const id = head.slice(0, 4);
    const size = readUint32LE(head, 4);
    const bodyStart = pos + 8;
    if (bodyStart + size > end) {
      return;
    }
    const text = readInfoValue(reader, bodyStart, bodyStart + size);
    if (text.length > 0) {
      if (asciiEquals(id, 0, 'INAM')) {
        if (meta.title.length === 0) {
          meta.title = text;
        }
      } else if (asciiEquals(id, 0, 'IART')) {
        if (meta.artist.length === 0) {
          meta.artist = text;
        }
      } else if (asciiEquals(id, 0, 'IPRD') || asciiEquals(id, 0, 'IALB')) {
        if (meta.album.length === 0) {
          meta.album = text;
        }
      } else if (asciiEquals(id, 0, 'ICRD')) {
        if (meta.year.length === 0) {
          meta.year = extractYear(text);
        }
      } else if (asciiEquals(id, 0, 'ITRK')) {
        if (meta.trackNumber <= 0) {
          meta.trackNumber = parseLeadingInt(text);
        }
      }
    }
    pos = bodyStart + size + (size % 2); // chunk 按偶数字节对齐
  }
}

/** WAV 入口 */
export function parseWav(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  try {
    const head = reader.readRange(0, 12);
    if (head.length < 12 || !asciiEquals(head, 0, 'RIFF') || !asciiEquals(head, 8, 'WAVE')) {
      return meta;
    }
    let pos = 12;
    let guard = 0;
    let dataSize = -1;
    let byteRate = 0;
    let blockAlign = 0;

    while (pos + 8 <= fileSize && guard < MAX_CHUNK_COUNT) {
      guard++;
      const chunkHead = reader.readRange(pos, 8);
      if (chunkHead.length < 8) {
        break;
      }
      const id = chunkHead.slice(0, 4);
      // chunk 长度是不可信输入，先按剩余文件长度裁剪
      const declaredSize = readUint32LE(chunkHead, 4);
      const bodyStart = pos + 8;
      const remain = fileSize - bodyStart;
      let chunkSize = declaredSize;
      if (chunkSize > remain) {
        chunkSize = remain > 0 ? remain : 0;
      }
      if (asciiEquals(id, 0, 'fmt ')) {
        const fmt = reader.readRange(bodyStart, Math.min(chunkSize, 40));
        if (fmt.length >= 16) {
          const channels = readUint16LE(fmt, 2);
          const sampleRate = readUint32LE(fmt, 4);
          byteRate = readUint32LE(fmt, 8);
          blockAlign = readUint16LE(fmt, 12);
          if (channels > 0) {
            meta.channels = channels;
          }
          if (sampleRate > 0) {
            meta.sampleRate = sampleRate;
          }
        }
      } else if (asciiEquals(id, 0, 'data')) {
        dataSize = chunkSize;
      } else if (asciiEquals(id, 0, 'LIST')) {
        parseInfoList(reader, bodyStart, bodyStart + chunkSize, meta);
      }
      if (chunkSize <= 0 && declaredSize <= 0) {
        break; // 长度为 0 的非 data chunk，防止死循环
      }
      pos = bodyStart + chunkSize + (chunkSize % 2);
    }

    if (byteRate <= 0 && blockAlign > 0 && meta.sampleRate > 0) {
      byteRate = blockAlign * meta.sampleRate;
    }
    if (byteRate > 0) {
      meta.bitrate = byteRate * 8 / 1000;
      if (dataSize > 0) {
        meta.durationMs = dataSize * 1000 / byteRate;
      }
    }
  } catch (e) {
    Logger.err(TAG, 'parseWav', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}

/** AAC（ADTS）入口；时长无法在不遍历全部帧的前提下得出，保持 0 */
export function parseAac(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  try {
    const head = reader.readRange(0, 7);
    if (head.length < 7) {
      return meta;
    }
    // ADTS 同步字 12 位：0xFFF
    if (head[0] !== 0xFF || (head[1] & 0xF0) !== 0xF0) {
      return meta;
    }
    const sampleRateIndex = (head[2] >> 2) & 0x0F;
    const channelConfig = ((head[2] & 0x01) << 2) | ((head[3] >> 6) & 0x03);
    const sampleRate = ADTS_SAMPLE_RATES[sampleRateIndex];
    meta.sampleRate = sampleRate;
    meta.channels = channelConfig;
    // frame_length 为 13 位；用第一帧长度估算平均码率（每帧 1024 个样本）
    const frameLength = ((head[3] & 0x03) << 11) | (head[4] << 3) | (head[5] >> 5);
    if (frameLength > 0 && sampleRate > 0) {
      meta.bitrate = frameLength * 8 * sampleRate / 1024 / 1000;
    }
    // durationMs 保持 0：ADTS 无全局时长字段，逐帧累计成本过高（见文件头注释）
  } catch (e) {
    Logger.err(TAG, 'parseAac', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}
