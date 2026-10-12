/**
 * Folia HarmonyOS - FLAC 标签解析
 *
 * 结构：fLaC 标记 -> METADATA_BLOCK 链（每块 4 字节头：last 标志 + 类型 + 24 位大端长度）。
 * 关注：STREAMINFO(0) 采样率/声道/总样本数，VORBIS_COMMENT(4) 文本标签，
 *       PICTURE(6) 内嵌封面；METADATA_BLOCK_PICTURE 由 VorbisTag 处理。
 *
 * 损坏块只会导致后续块被跳过（长度不可信），不会抛异常。
 */
import { ByteReader, asciiEquals, readUint32BE } from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import { createEmptyMetadata, finalizeMetadata } from './MetadataUtils';
import { parseVorbisComment, parseFlacPictureBlock, MAX_PICTURE_BLOCK_BYTES } from './VorbisTag';
import { Logger } from '../../core/Logger';

const TAG: string = 'FlacParser';

/** VORBIS_COMMENT 块读取上限 */
const MAX_COMMENT_BLOCK_BYTES: number = 4 * 1024 * 1024;

/** 元数据块数量上限，防御性上限（防止长度字段全 0 造成死循环） */
const MAX_BLOCK_COUNT: number = 4096;

/** 解析 STREAMINFO（固定 34 字节有效内容） */
function parseStreamInfo(reader: ByteReader, blockStart: number, blockLength: number, fileSize: number, meta: AudioMetadata): void {
  if (blockLength < 34) {
    return;
  }
  const bytes = reader.readRange(blockStart, 34);
  if (bytes.length < 34) {
    return;
  }
  // 偏移 10 起 8 字节打包：sampleRate(20) channels-1(3) bitsPerSample-1(5) totalSamples(36)
  const b10 = bytes[10];
  const b11 = bytes[11];
  const b12 = bytes[12];
  const b13 = bytes[13];
  const sampleRate = (b10 << 12) | (b11 << 4) | (b12 >> 4);
  const channels = ((b12 >> 1) & 0x07) + 1;
  const bitsPerSample = (((b12 & 0x01) << 4) | (b13 >> 4)) + 1;
  const totalSamplesHigh = b13 & 0x0F;
  const totalSamples = totalSamplesHigh * 4294967296 + readUint32BE(bytes, 14);

  meta.sampleRate = sampleRate;
  meta.channels = channels;
  // bitsPerSample 当前不需要单独对外暴露，仅用于 STREAMINFO 完整性校验
  if (bitsPerSample <= 0) {
    return;
  }
  if (sampleRate > 0 && totalSamples > 0) {
    meta.durationMs = totalSamples * 1000 / sampleRate;
    // FLAC 是 VBR：这里给出平均码率（kbps），供库列表展示
    if (meta.durationMs > 0) {
      meta.bitrate = fileSize * 8 / meta.durationMs;
    }
  }
}

/**
 * 遍历 METADATA_BLOCK 链。
 */
function parseBlocks(reader: ByteReader, fileSize: number, meta: AudioMetadata): void {
  let pos = 4; // 跳过 fLaC
  let guard = 0;
  let last = false;
  while (!last && guard < MAX_BLOCK_COUNT) {
    guard++;
    if (pos + 4 > fileSize) {
      return;
    }
    const header = reader.readRange(pos, 4);
    if (header.length < 4) {
      return;
    }
    const blockType = header[0] & 0x7F;
    last = (header[0] & 0x80) !== 0;
    const blockLength = (header[1] << 16) | (header[2] << 8) | header[3];
    const blockStart = pos + 4;
    if (blockType === 0) {
      parseStreamInfo(reader, blockStart, blockLength, fileSize, meta);
    } else if (blockType === 4) {
      let take = blockLength;
      if (take > MAX_COMMENT_BLOCK_BYTES) {
        take = MAX_COMMENT_BLOCK_BYTES;
      }
      const block = reader.readRange(blockStart, take);
      if (block.length > 0) {
        parseVorbisComment(block, 0, block.length, meta);
      }
    } else if (blockType === 6) {
      let take = blockLength;
      if (take > MAX_PICTURE_BLOCK_BYTES) {
        take = MAX_PICTURE_BLOCK_BYTES;
      }
      const block = reader.readRange(blockStart, take);
      if (block.length > 0) {
        parseFlacPictureBlock(block, 0, block.length, meta);
      }
    } else if (blockType === 127) {
      return; // 非法块类型，停止
    }
    // 无论长度是否可信都至少前进 4 字节，保证循环收敛
    pos = blockStart + blockLength;
  }
}

/** FLAC 入口 */
export function parseFlac(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  try {
    const marker = reader.readRange(0, 4);
    if (marker.length < 4 || !asciiEquals(marker, 0, 'fLaC')) {
      return meta;
    }
    parseBlocks(reader, fileSize, meta);
  } catch (e) {
    Logger.err(TAG, 'parseFlac', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}
