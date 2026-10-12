/**
 * Folia HarmonyOS - Vorbis Comment / FLAC 图片块解析
 *
 * Vorbis Comment 结构同时被 FLAC（METADATA_BLOCK_VORBIS_COMMENT）、
 * Ogg Vorbis（0x03 "vorbis" 注释头）与 Ogg Opus（"OpusTags"）复用，
 * 因此单独抽成一个文件，供 FlacParser 与 VorbisParser 共同调用。
 *
 * 注意两种字节序：Vorbis Comment 全部是小端，FLAC 图片块全部是大端。
 */
import { util } from '@kit.ArkTS';
import { readUint32LE, readUint32BE, readAsciiString, decodeUtf8 } from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import {
  applyCover, MAX_COVER_BYTES, parseLeadingInt, sanitizeText, sanitizeLyrics,
  splitArtistList, extractYear
} from './MetadataUtils';
import { Logger } from '../../core/Logger';

const TAG: string = 'VorbisTag';

/** 单条注释值长度上限，防止损坏长度触发超大分配 */
const MAX_COMMENT_VALUE_BYTES: number = 64 * 1024;

/** 注释条数上限，防止损坏 count 造成长时间循环 */
const MAX_COMMENT_COUNT: number = 65536;

/** 单个 FLAC 图片块读取上限（含头部余量） */
export const MAX_PICTURE_BLOCK_BYTES: number = MAX_COVER_BYTES + 4096;

/**
 * Base64 解码（FLAC 的 METADATA_BLOCK_PICTURE / COVERART 使用）。
 * 先去空白并补齐 padding；失败返回空数组，不抛异常。
 */
function decodeBase64(value: string): Uint8Array {
  let cleaned = value.replace(/[\s\r\n\t]+/g, '');
  if (cleaned.length === 0) {
    return new Uint8Array(0);
  }
  const remainder = cleaned.length % 4;
  if (remainder === 2) {
    cleaned += '==';
  } else if (remainder === 3) {
    cleaned += '=';
  } else if (remainder === 1) {
    // 非法 base64 长度，直接放弃
    return new Uint8Array(0);
  }
  try {
    const helper = new util.Base64Helper();
    const decoded: Uint8Array = helper.decodeSync(cleaned);
    return decoded;
  } catch (e) {
    Logger.err(TAG, 'decodeBase64', e as Error);
    return new Uint8Array(0);
  }
}

/**
 * 解析 FLAC 图片块（METADATA_BLOCK_PICTURE 解码后的内容，或 FLAC 的 PICTURE 元数据块）。
 * 结构（全大端）：
 *   type(u32) mimeLen(u32) mime descLen(u32) desc width(u32) height(u32) depth(u32) colors(u32)
 *   dataLen(u32) data
 * 第一张图片优先。
 */
export function parseFlacPictureBlock(bytes: Uint8Array, offset: number, end: number, meta: AudioMetadata): void {
  const limit = Math.min(end, bytes.length);
  let pos = Math.max(0, offset);
  if (pos + 8 > limit) {
    return;
  }
  pos += 4; // 图片类型（不做正面封面优先判定）
  const mimeLen = readUint32BE(bytes, pos);
  pos += 4;
  if (mimeLen > limit - pos) {
    return;
  }
  const mime = readAsciiString(bytes, pos, Math.min(mimeLen, 256));
  pos += mimeLen;
  if (pos + 4 > limit) {
    return;
  }
  const descriptionLength = readUint32BE(bytes, pos);
  pos += 4;
  if (descriptionLength > limit - pos) {
    return;
  }
  pos += descriptionLength;
  if (pos + 16 > limit) {
    return; // width/height/depth/colors
  }
  pos += 16;
  if (pos + 4 > limit) {
    return;
  }
  const dataLength = readUint32BE(bytes, pos);
  pos += 4;
  if (dataLength <= 0) {
    return;
  }
  let take = dataLength;
  if (take > limit - pos) {
    take = limit - pos;
  }
  if (take > MAX_COVER_BYTES) {
    take = MAX_COVER_BYTES;
  }
  if (take <= 0) {
    return;
  }
  const data = bytes.slice(pos, pos + take);
  applyCover(meta, mime, data, false);
}

/**
 * 解析 Vorbis Comment 结构（小端），[offset, end) 为有效范围。
 * 结构：vendorLen(u32) vendor commentCount(u32) [valueLen(u32) "KEY=VALUE"]*
 */
export function parseVorbisComment(bytes: Uint8Array, offset: number, end: number, meta: AudioMetadata): void {
  const limit = Math.min(end, bytes.length);
  let pos = Math.max(0, offset);
  if (pos + 4 > limit) {
    return;
  }
  const vendorLength = readUint32LE(bytes, pos);
  pos += 4;
  if (vendorLength > limit - pos) {
    // vendor 长度损坏，无法继续定位注释区
    return;
  }
  pos += vendorLength;
  if (pos + 4 > limit) {
    return;
  }
  let commentCount = readUint32LE(bytes, pos);
  pos += 4;
  if (commentCount > MAX_COMMENT_COUNT) {
    commentCount = MAX_COMMENT_COUNT;
  }
  for (let i = 0; i < commentCount; i++) {
    if (pos + 4 > limit) {
      return;
    }
    let valueLength = readUint32LE(bytes, pos);
    pos += 4;
    if (valueLength <= 0) {
      return;
    }
    if (valueLength > limit - pos) {
      valueLength = limit - pos;
    }
    if (valueLength > MAX_COMMENT_VALUE_BYTES) {
      valueLength = MAX_COMMENT_VALUE_BYTES;
    }
    const text = decodeUtf8(bytes, pos, pos + valueLength);
    pos += valueLength;
    applyVorbisComment(text, meta);
  }
}

/** 处理单条 "KEY=VALUE" 注释 */
function applyVorbisComment(rawText: string, meta: AudioMetadata): void {
  const equals = rawText.indexOf('=');
  if (equals <= 0) {
    return;
  }
  const key = rawText.substring(0, equals).trim().toUpperCase();
  const value = rawText.substring(equals + 1);
  if (key.length === 0 || value.length === 0) {
    return;
  }
  if (key === 'TITLE') {
    if (meta.title.length === 0) {
      meta.title = value;
    }
    return;
  }
  if (key === 'ALBUM') {
    if (meta.album.length === 0) {
      meta.album = value;
    }
    return;
  }
  if (key === 'ARTIST') {
    // ARTIST 可重复出现，全部收集为多个歌手
    if (meta.artist.length === 0) {
      meta.artist = sanitizeText(value);
    }
    const names = splitArtistList(value);
    for (let i = 0; i < names.length; i++) {
      meta.artists.push(names[i]);
    }
    return;
  }
  if (key === 'ALBUMARTIST' || key === 'ALBUM ARTIST' || key === 'ALBUM_ARTIST' || key === 'ENSEMBLE') {
    if (meta.albumArtist.length === 0) {
      meta.albumArtist = value;
    }
    return;
  }
  if (key === 'TRACKNUMBER') {
    if (meta.trackNumber <= 0) {
      meta.trackNumber = parseLeadingInt(value);
    }
    return;
  }
  if (key === 'DATE' || key === 'YEAR' || key === 'ORIGINALDATE') {
    if (meta.year.length === 0) {
      meta.year = extractYear(value);
    }
    return;
  }
  if (key === 'LYRICS' || key === 'UNSYNCEDLYRICS' || key === 'UNSYNCHRONISEDLYRICS' || key === 'SYNCEDLYRICS') {
    if (meta.lyrics === undefined) {
      const lyrics = sanitizeLyrics(value);
      if (lyrics.length > 0) {
        meta.lyrics = lyrics;
      }
    }
    return;
  }
  if (key === 'METADATA_BLOCK_PICTURE') {
    if (meta.cover === undefined) {
      const block = decodeBase64(value);
      if (block.length > 0) {
        parseFlacPictureBlock(block, 0, block.length, meta);
      }
    }
    return;
  }
  if (key === 'COVERART') {
    // 旧式 base64 原始图片（无 MIME 字段），按魔数兜底
    if (meta.cover === undefined) {
      const data = decodeBase64(value);
      if (data.length > 0) {
        applyCover(meta, '', data, false);
      }
    }
    return;
  }
  if (key === 'COVERARTMIME') {
    // COVERARTMIME 可能出现在 COVERART 之后，这里做一次 MIME 修正
    if (meta.cover !== undefined) {
      const mimeType = sanitizeText(value);
      if (mimeType.indexOf('/') > 0) {
        meta.cover.mimeType = mimeType;
      }
    }
    return;
  }
}
