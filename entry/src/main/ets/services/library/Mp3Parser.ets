/**
 * Folia HarmonyOS - MP3（ID3v2 / ID3v1）标签解析
 *
 * 流程：
 * 1. ID3v2 头（"ID3"，支持 2.2 / 2.3 / 2.4），sync-safe 长度，全局去同步（unsynchronisation）；
 * 2. 帧遍历：文本帧、TXXX、APIC/PIC、USLT/ULT；
 * 3. ID3v1 兜底（末尾 128 字节 "TAG"）；
 * 4. 时长：优先 Xing/Info（帧数）与 VBRI，否则按第一帧码率做 CBR 估算。
 *
 * 所有步骤都做了边界检查，损坏文件只会导致字段缺失，不会抛异常。
 */
import {
  ByteReader, asciiEquals, indexOfByte, findTerminator, readUint32BE,
  readSyncSafeUint32, decodeLatin1, decodeUtf8, decodeUtf16,
  deUnsynchronize, readAsciiString
} from './ByteReader';
import { AudioMetadata } from './MetadataReader';
import {
  MAX_COVER_BYTES, createEmptyMetadata, finalizeMetadata, sanitizeText,
  sanitizeLyrics, parseLeadingInt, applyCover, extractYear, splitArtistList
} from './MetadataUtils';
import { Logger } from '../../core/Logger';

const TAG: string = 'Mp3Parser';

/** ID3v2 标签体读取上限，防止损坏的 sync-safe 长度触发超大分配 */
const MAX_ID3_BODY_BYTES: number = 8 * 1024 * 1024;

/** MPEG 帧搜索窗口（通常第一帧就在音频起点附近） */
const FRAME_SCAN_BYTES: number = 64 * 1024;

// 码率表（单位 kbps），下标为 bitrateIndex，0 与 15 为非法值
const BITRATE_V1_L1: number[] = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0];
const BITRATE_V1_L2: number[] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0];
const BITRATE_V1_L3: number[] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const BITRATE_V2_L1: number[] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0];
const BITRATE_V2_L23: number[] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];

/** 采样率表：下标为 version（3=MPEG1，2=MPEG2，0=MPEG2.5），内层为 sampleRateIndex */
const SAMPLE_RATE_V1: number[] = [44100, 48000, 32000, 0];
const SAMPLE_RATE_V2: number[] = [22050, 24000, 16000, 0];
const SAMPLE_RATE_V25: number[] = [11025, 12000, 8000, 0];

/** MPEG 帧头解析结果 */
interface Mp3FrameHeader {
  valid: boolean;
  version: number;      // 3=MPEG1、2=MPEG2、0=MPEG2.5
  layer: number;        // 1、2、3
  bitrateKbps: number;
  sampleRate: number;
  channels: number;
  samplesPerFrame: number;
  frameLength: number;
  crc: boolean;
}

/** 标签解析过程中的可变状态 */
class Mp3TagState {
  frontCoverAssigned: boolean = false;
}

/** 构造一个无效帧头，避免到处写对象字面量 */
function invalidFrame(): Mp3FrameHeader {
  const header: Mp3FrameHeader = {
    valid: false,
    version: 0,
    layer: 0,
    bitrateKbps: 0,
    sampleRate: 0,
    channels: 0,
    samplesPerFrame: 0,
    frameLength: 0,
    crc: false
  };
  return header;
}

/** 解析 offset 处的 MPEG 音频帧头；非法返回 valid=false */
function parseFrameHeader(bytes: Uint8Array, offset: number): Mp3FrameHeader {
  const header = invalidFrame();
  if (offset < 0 || offset + 4 > bytes.length) {
    return header;
  }
  const b0 = bytes[offset];
  const b1 = bytes[offset + 1];
  const b2 = bytes[offset + 2];
  const b3 = bytes[offset + 3];
  if (b0 !== 0xFF || (b1 & 0xE0) !== 0xE0) {
    return header;
  }
  const version = (b1 >> 3) & 0x03;
  if (version === 1) {
    return header; // 保留值
  }
  const layerBits = (b1 >> 1) & 0x03;
  if (layerBits === 0) {
    return header; // 保留值
  }
  const layer = 4 - layerBits; // 3=Layer1、2=Layer2、1=Layer3
  const bitrateIndex = (b2 >> 4) & 0x0F;
  const sampleRateIndex = (b2 >> 2) & 0x03;
  const padding = (b2 >> 1) & 0x01;
  if (bitrateIndex === 0 || bitrateIndex === 15 || sampleRateIndex === 3) {
    return header;
  }
  const isMpeg1 = version === 3;
  let bitrateKbps = 0;
  if (layer === 1) {
    bitrateKbps = isMpeg1 ? BITRATE_V1_L1[bitrateIndex] : BITRATE_V2_L1[bitrateIndex];
  } else if (layer === 2) {
    bitrateKbps = isMpeg1 ? BITRATE_V1_L2[bitrateIndex] : BITRATE_V2_L23[bitrateIndex];
  } else {
    bitrateKbps = isMpeg1 ? BITRATE_V1_L3[bitrateIndex] : BITRATE_V2_L23[bitrateIndex];
  }
  if (bitrateKbps <= 0) {
    return header;
  }
  let sampleRate = 0;
  if (version === 3) {
    sampleRate = SAMPLE_RATE_V1[sampleRateIndex];
  } else if (version === 2) {
    sampleRate = SAMPLE_RATE_V2[sampleRateIndex];
  } else {
    sampleRate = SAMPLE_RATE_V25[sampleRateIndex];
  }
  if (sampleRate <= 0) {
    return header;
  }
  let samplesPerFrame = 1152;
  if (layer === 1) {
    samplesPerFrame = 384;
  } else if (layer === 3 && !isMpeg1) {
    samplesPerFrame = 576;
  }
  let coefficient = 144;
  if (layer === 1) {
    coefficient = 12;
  } else if (layer === 3 && !isMpeg1) {
    coefficient = 72;
  }
  let frameLength = 0;
  if (layer === 1) {
    frameLength = (Math.floor(coefficient * bitrateKbps * 1000 / sampleRate) + padding) * 4;
  } else {
    frameLength = Math.floor(coefficient * bitrateKbps * 1000 / sampleRate) + padding;
  }
  if (frameLength <= 0) {
    return header;
  }
  const channelMode = (b3 >> 6) & 0x03;
  header.valid = true;
  header.version = version;
  header.layer = layer;
  header.bitrateKbps = bitrateKbps;
  header.sampleRate = sampleRate;
  header.channels = channelMode === 3 ? 1 : 2;
  header.samplesPerFrame = samplesPerFrame;
  header.frameLength = frameLength;
  header.crc = (b1 & 0x01) === 0;
  return header;
}

/**
 * 尝试读取 Xing/Info 或 VBRI 头得到精确时长（毫秒）。
 * 返回 0 表示没有 VBR 头，需要由调用方按 CBR 估算。
 */
function readVbrDuration(bytes: Uint8Array, frameOffset: number, header: Mp3FrameHeader): number {
  if (header.layer !== 3 || header.sampleRate <= 0 || header.samplesPerFrame <= 0) {
    return 0;
  }
  const isMpeg1 = header.version === 3;
  let sideInfo = isMpeg1 ? 32 : 17;
  if (header.channels === 1) {
    sideInfo = isMpeg1 ? 17 : 9;
  }
  const xingOffset = frameOffset + 4 + (header.crc ? 2 : 0) + sideInfo;
  if (asciiEquals(bytes, xingOffset, 'Xing') || asciiEquals(bytes, xingOffset, 'Info')) {
    const flags = readUint32BE(bytes, xingOffset + 4);
    if ((flags & 0x01) !== 0) {
      const frames = readUint32BE(bytes, xingOffset + 8);
      if (frames > 0) {
        return frames * header.samplesPerFrame * 1000 / header.sampleRate;
      }
    }
    return 0;
  }
  // VBRI（Fraunhofer）：固定在帧头之后 32 字节处，即 frameOffset + 36
  const vbriOffset = frameOffset + 36;
  if (asciiEquals(bytes, vbriOffset, 'VBRI')) {
    const frames = readUint32BE(bytes, vbriOffset + 14);
    if (frames > 0) {
      return frames * header.samplesPerFrame * 1000 / header.sampleRate;
    }
  }
  return 0;
}

/** 按 ID3 编码字节解码文本 */
function decodeEncodedText(bytes: Uint8Array, start: number, end: number, encoding: number): string {
  if (end <= start) {
    return '';
  }
  if (encoding === 1) {
    return decodeUtf16(bytes, start, end, false);
  }
  if (encoding === 2) {
    return decodeUtf16(bytes, start, end, true);
  }
  if (encoding === 3) {
    return decodeUtf8(bytes, start, end);
  }
  return decodeLatin1(bytes, start, end);
}

/** 是否为合法帧 ID（3 或 4 位大写字母/数字） */
function isValidFrameId(id: string): boolean {
  if (id.length !== 3 && id.length !== 4) {
    return false;
  }
  for (let i = 0; i < id.length; i++) {
    const code = id.charCodeAt(i);
    const isDigit = code >= 0x30 && code <= 0x39;
    const isUpper = code >= 0x41 && code <= 0x5A;
    if (!isDigit && !isUpper) {
      return false;
    }
  }
  return true;
}

/** 把 ID3v2.2 的 3 字符帧 ID 归一化成 v2.3/v2.4 的 4 字符 ID */
function normalizeFrameId(id: string, version: number): string {
  if (version !== 2) {
    return id;
  }
  if (id === 'TT2') {
    return 'TIT2';
  }
  if (id === 'TP1') {
    return 'TPE1';
  }
  if (id === 'TP2') {
    return 'TPE2';
  }
  if (id === 'TAL') {
    return 'TALB';
  }
  if (id === 'TRK') {
    return 'TRCK';
  }
  if (id === 'TYE') {
    return 'TYER';
  }
  if (id === 'TDR') {
    return 'TDRC';
  }
  if (id === 'TXT') {
    return 'TXXX';
  }
  return id;
}

/** 文本帧写入对应字段 */
function applyTextFrame(id: string, value: string, meta: AudioMetadata): void {
  const text = sanitizeText(value);
  if (text.length === 0) {
    return;
  }
  if (id === 'TIT2') {
    if (meta.title.length === 0) {
      meta.title = text;
    }
    return;
  }
  if (id === 'TPE1') {
    if (meta.artist.length === 0) {
      meta.artist = text;
    }
    // 立即拆分出逐个歌手，避免后续 TXXX/ARTISTS 覆盖掉 TPE1 的拆分结果
    const names = splitArtistList(text);
    for (let i = 0; i < names.length; i++) {
      meta.artists.push(names[i]);
    }
    return;
  }
  if (id === 'TPE2') {
    if (meta.albumArtist.length === 0) {
      meta.albumArtist = text;
    }
    return;
  }
  if (id === 'TALB') {
    if (meta.album.length === 0) {
      meta.album = text;
    }
    return;
  }
  if (id === 'TRCK') {
    if (meta.trackNumber <= 0) {
      meta.trackNumber = parseLeadingInt(text);
    }
    return;
  }
  if (id === 'TYER' || id === 'TDRC' || id === 'TDOR') {
    if (meta.year.length === 0) {
      meta.year = extractYear(text);
    }
    return;
  }
}

/** TXXX：描述符 + 值，取 ARTISTS / ALBUMARTIST / LYRICS 等常用自定义键 */
function handleTxxxFrame(body: Uint8Array, start: number, end: number, meta: AudioMetadata): void {
  if (start >= end) {
    return;
  }
  const encoding = body[start];
  const wide = encoding === 1 || encoding === 2;
  const descEnd = findTerminator(body, start + 1, end, wide);
  if (descEnd < 0) {
    return;
  }
  const description = decodeEncodedText(body, start + 1, descEnd, encoding).trim().toLowerCase();
  const valueStart = descEnd + (wide ? 2 : 1);
  if (valueStart >= end) {
    return;
  }
  const value = decodeEncodedText(body, valueStart, end, encoding);
  if (description === 'artists' || description === 'artist') {
    // MusicBrainz 的 ARTISTS 用 NUL 分隔多个歌手；TPE1 已经给出歌手时忽略
    if (meta.artists.length > 0) {
      return;
    }
    const parts = value.split('\u0000');
    for (let i = 0; i < parts.length; i++) {
      const names = parts[i].split(';');
      for (let k = 0; k < names.length; k++) {
        const name = sanitizeText(names[k]);
        if (name.length > 0) {
          meta.artists.push(name);
        }
      }
    }
    return;
  }
  if (description === 'albumartist' || description === 'album artist') {
    if (meta.albumArtist.length === 0) {
      meta.albumArtist = sanitizeText(value);
    }
    return;
  }
  if (description === 'lyrics' || description === 'unsyncedlyrics' || description === 'unsynced lyrics') {
    if (meta.lyrics === undefined) {
      const lyrics = sanitizeLyrics(value);
      if (lyrics.length > 0) {
        meta.lyrics = lyrics;
      }
    }
    return;
  }
}

/** USLT/ULT：编码 + 语言(3) + 描述 + 歌词正文 */
function handleLyricsFrame(body: Uint8Array, start: number, end: number, meta: AudioMetadata): void {
  if (start + 4 > end) {
    return;
  }
  const encoding = body[start];
  const wide = encoding === 1 || encoding === 2;
  let pos = start + 1 + 3; // 跳过语言代码
  const descEnd = findTerminator(body, pos, end, wide);
  if (descEnd >= 0) {
    pos = descEnd + (wide ? 2 : 1);
  }
  if (pos >= end) {
    return;
  }
  if (meta.lyrics !== undefined) {
    return;
  }
  const lyrics = sanitizeLyrics(decodeEncodedText(body, pos, end, encoding));
  if (lyrics.length > 0) {
    meta.lyrics = lyrics;
  }
}

/** APIC（v2.3/v2.4）：编码 + MIME + 图片类型 + 描述 + 数据 */
function handleApicFrame(body: Uint8Array, start: number, end: number, meta: AudioMetadata, state: Mp3TagState): void {
  if (start + 4 > end) {
    return;
  }
  const encoding = body[start];
  const wide = encoding === 1 || encoding === 2;
  const mimeEnd = indexOfByte(body, start + 1, end, 0x00);
  if (mimeEnd < 0) {
    return;
  }
  const mime = readAsciiString(body, start + 1, mimeEnd - (start + 1));
  let pos = mimeEnd + 1;
  if (pos >= end) {
    return;
  }
  const pictureType = body[pos];
  pos++;
  const descEnd = findTerminator(body, pos, end, wide);
  if (descEnd >= 0) {
    pos = descEnd + (wide ? 2 : 1);
  } else {
    pos = end;
  }
  if (pos >= end) {
    return;
  }
  let take = end - pos;
  if (take > MAX_COVER_BYTES) {
    take = MAX_COVER_BYTES;
  }
  const data = body.slice(pos, pos + take);
  const isFront = pictureType === 3 && !state.frontCoverAssigned;
  applyCover(meta, mime, data, isFront);
  if (pictureType === 3) {
    state.frontCoverAssigned = true;
  }
}

/** PIC（v2.2）：编码 + 3 字节格式(JPG/PNG) + 图片类型 + 描述 + 数据 */
function handlePicFrame(body: Uint8Array, start: number, end: number, meta: AudioMetadata, state: Mp3TagState): void {
  if (start + 5 > end) {
    return;
  }
  const encoding = body[start];
  const wide = encoding === 1 || encoding === 2;
  const format = readAsciiString(body, start + 1, 3).toUpperCase();
  let pos = start + 4;
  const pictureType = body[pos];
  pos++;
  const descEnd = findTerminator(body, pos, end, wide);
  if (descEnd >= 0) {
    pos = descEnd + (wide ? 2 : 1);
  } else {
    pos = end;
  }
  if (pos >= end) {
    return;
  }
  let mime = '';
  if (format === 'PNG') {
    mime = 'image/png';
  } else if (format === 'JPG') {
    mime = 'image/jpeg';
  }
  let take = end - pos;
  if (take > MAX_COVER_BYTES) {
    take = MAX_COVER_BYTES;
  }
  const data = body.slice(pos, pos + take);
  const isFront = pictureType === 3 && !state.frontCoverAssigned;
  applyCover(meta, mime, data, isFront);
  if (pictureType === 3) {
    state.frontCoverAssigned = true;
  }
}

/** 分发单个 ID3v2 帧 */
function handleId3Frame(id: string, body: Uint8Array, start: number, end: number, meta: AudioMetadata, state: Mp3TagState): void {
  if (end <= start) {
    return;
  }
  if (id === 'APIC') {
    handleApicFrame(body, start, end, meta, state);
    return;
  }
  if (id === 'PIC') {
    handlePicFrame(body, start, end, meta, state);
    return;
  }
  if (id === 'USLT' || id === 'ULT') {
    handleLyricsFrame(body, start, end, meta);
    return;
  }
  if (id === 'TXXX' || id === 'TXX') {
    handleTxxxFrame(body, start, end, meta);
    return;
  }
  if (id.charAt(0) !== 'T') {
    return;
  }
  const encoding = body[start];
  const text = decodeEncodedText(body, start + 1, end, encoding);
  applyTextFrame(id, text, meta);
}

/**
 * 遍历 ID3v2 帧。body 已按需去同步。
 * version：2 / 3 / 4；tagFlags：标签头第 6 字节。
 */
function parseId3Frames(body: Uint8Array, version: number, tagFlags: number, meta: AudioMetadata): void {
  if (body.length === 0) {
    return;
  }
  const state = new Mp3TagState();
  const headerLength = version === 2 ? 6 : 10;
  let pos = 0;
  // 扩展头
  if (version === 3 && (tagFlags & 0x40) !== 0) {
    const extSize = readUint32BE(body, 0);
    let skip = 4 + extSize;
    if (skip <= 0 || skip > body.length) {
      skip = body.length;
    }
    pos = skip;
  } else if (version === 4 && (tagFlags & 0x40) !== 0) {
    // v2.4 的扩展头长度包含自身
    const extSize = readSyncSafeUint32(body, 0);
    let skip = extSize;
    if (skip <= 0 || skip > body.length) {
      skip = body.length;
    }
    pos = skip;
  }

  let guard = 0;
  while (pos + headerLength <= body.length && guard < 4096) {
    guard++;
    if (body[pos] === 0x00) {
      break; // padding
    }
    const idLength = version === 2 ? 3 : 4;
    const id = readAsciiString(body, pos, idLength);
    if (!isValidFrameId(id)) {
      break;
    }
    let size = 0;
    if (version === 2) {
      size = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5];
    } else if (version === 3) {
      size = readUint32BE(body, pos + 4);
    } else {
      size = readSyncSafeUint32(body, pos + 4);
    }
    if (size <= 0) {
      break;
    }
    const dataStart = pos + headerLength;
    if (dataStart + size > body.length) {
      break; // 损坏（长度超出标签体）
    }
    let effectiveStart = dataStart;
    let usable = true;
    let frameNeedsUnsync = false;
    if (version >= 3) {
      const formatFlags = body[pos + 9];
      if (version === 3) {
        if ((formatFlags & 0x80) !== 0 || (formatFlags & 0x40) !== 0) {
          usable = false; // 压缩 / 加密帧跳过
        }
        if ((formatFlags & 0x20) !== 0) {
          effectiveStart += 1; // 分组标识字节
        }
      } else {
        if ((formatFlags & 0x08) !== 0 || (formatFlags & 0x04) !== 0) {
          usable = false;
        }
        if ((formatFlags & 0x40) !== 0) {
          effectiveStart += 1;
        }
        if ((formatFlags & 0x01) !== 0) {
          effectiveStart += 4; // 数据长度指示符
        }
        if ((formatFlags & 0x02) !== 0) {
          frameNeedsUnsync = true;
        }
      }
      if (effectiveStart > dataStart + size) {
        usable = false;
      }
    }
    if (usable) {
      let frameBody = body;
      let frameStart = effectiveStart;
      let frameEnd = dataStart + size;
      if (frameNeedsUnsync) {
        frameBody = deUnsynchronize(body.slice(effectiveStart, dataStart + size));
        frameStart = 0;
        frameEnd = frameBody.length;
      }
      handleId3Frame(normalizeFrameId(id, version), frameBody, frameStart, frameEnd, meta, state);
    }
    pos = dataStart + size;
  }
}

/**
 * 解析 ID3v2 标签头，返回音频数据起始偏移（无标签返回 0）。
 */
function parseId3v2(reader: ByteReader, fileSize: number, meta: AudioMetadata): number {
  const head = reader.readRange(0, 10);
  if (head.length < 10 || !asciiEquals(head, 0, 'ID3')) {
    return 0;
  }
  const version = head[3];
  const tagFlags = head[5];
  if (version < 2 || version > 4) {
    return 0; // 未知版本，放弃标签
  }
  const tagSize = readSyncSafeUint32(head, 6);
  if (tagSize <= 0) {
    return 10;
  }
  const hasFooter = version === 4 && (tagFlags & 0x10) !== 0;
  let audioStart = 10 + tagSize + (hasFooter ? 10 : 0);
  if (audioStart >= fileSize - 4) {
    // 标签长度不可信（比文件还大），退回从文件头扫描音频帧
    audioStart = 0;
  }
  let bodyLength = tagSize;
  const available = fileSize - 10;
  if (bodyLength > available) {
    bodyLength = available;
  }
  if (bodyLength > MAX_ID3_BODY_BYTES) {
    bodyLength = MAX_ID3_BODY_BYTES;
  }
  if (bodyLength <= 0) {
    return audioStart;
  }
  let body = reader.readRange(10, bodyLength);
  if (body.length === 0) {
    return audioStart;
  }
  if ((tagFlags & 0x80) !== 0) {
    body = deUnsynchronize(body);
  }
  parseId3Frames(body, version, tagFlags, meta);
  return audioStart;
}

/** 读取 ID3v1 的定长字段（ISO-8859-1，去 NUL 与空白） */
function readId3v1Field(tail: Uint8Array, offset: number, length: number): string {
  const end = Math.min(offset + length, tail.length);
  const raw = decodeLatin1(tail, offset, end);
  return sanitizeText(raw);
}

/** ID3v1（末尾 128 字节）兜底；只填补 ID3v2 未提供的字段 */
function applyId3v1(reader: ByteReader, fileSize: number, meta: AudioMetadata): void {
  if (fileSize < 128) {
    return;
  }
  const tail = reader.readTail(128);
  if (tail.length < 128 || !asciiEquals(tail, 0, 'TAG')) {
    return;
  }
  if (meta.title.length === 0) {
    meta.title = readId3v1Field(tail, 3, 30);
  }
  if (meta.artist.length === 0) {
    meta.artist = readId3v1Field(tail, 33, 30);
  }
  if (meta.album.length === 0) {
    meta.album = readId3v1Field(tail, 63, 30);
  }
  if (meta.year.length === 0) {
    meta.year = readId3v1Field(tail, 93, 4);
  }
  // ID3v1.1：注释第 28 字节为 0 时，第 29 字节是曲号
  if (meta.trackNumber <= 0 && tail[125] === 0x00 && tail[126] > 0) {
    meta.trackNumber = tail[126];
  }
}

/**
 * 从音频起点扫描第一个合法 MPEG 帧，填充采样率/声道/码率，并计算时长。
 */
function readMpegInfo(reader: ByteReader, fileSize: number, audioStart: number, meta: AudioMetadata): void {
  if (fileSize <= 4) {
    return;
  }
  let scanStart = audioStart;
  if (scanStart < 0 || scanStart >= fileSize - 4) {
    scanStart = 0;
  }
  let window = fileSize - scanStart;
  if (window > FRAME_SCAN_BYTES) {
    window = FRAME_SCAN_BYTES;
  }
  if (window < 4) {
    return;
  }
  const bytes = reader.readRange(scanStart, window);
  if (bytes.length < 4) {
    return;
  }
  let frameOffset = -1;
  let frameHeader = invalidFrame();
  for (let i = 0; i + 4 <= bytes.length; i++) {
    const candidate = parseFrameHeader(bytes, i);
    if (!candidate.valid) {
      continue;
    }
    // 二次校验：下一帧位置也应当是合法帧头（缓冲区不足时跳过校验）
    const nextOffset = i + candidate.frameLength;
    if (nextOffset + 4 <= bytes.length) {
      const next = parseFrameHeader(bytes, nextOffset);
      if (!next.valid) {
        continue;
      }
    }
    frameOffset = i;
    frameHeader = candidate;
    break;
  }
  if (frameOffset < 0) {
    return;
  }
  meta.sampleRate = frameHeader.sampleRate;
  meta.channels = frameHeader.channels;
  meta.bitrate = frameHeader.bitrateKbps;

  // Xing/Info/VBRI 需要帧头附近最多约 200 字节，单独精确读取一次
  const vbrWindow = reader.readRange(scanStart + frameOffset, 200);
  let durationMs = 0;
  if (vbrWindow.length >= 4) {
    durationMs = readVbrDuration(vbrWindow, 0, frameHeader);
  }
  if (durationMs <= 0) {
    // 无 VBR 头：按第一帧码率做 CBR 估算（VBR 文件会不准确）
    const audioBytes = fileSize - (scanStart + frameOffset);
    if (audioBytes > 0) {
      durationMs = audioBytes * 8 / frameHeader.bitrateKbps;
    }
  }
  if (durationMs > 0) {
    meta.durationMs = durationMs;
  }
}

/** MP3 入口 */
export function parseMp3(reader: ByteReader, fileSize: number): AudioMetadata {
  const meta = createEmptyMetadata();
  let audioStart = 0;
  try {
    audioStart = parseId3v2(reader, fileSize, meta);
  } catch (e) {
    Logger.err(TAG, 'parseId3v2', e as Error);
  }
  try {
    applyId3v1(reader, fileSize, meta);
  } catch (e) {
    Logger.err(TAG, 'applyId3v1', e as Error);
  }
  try {
    readMpegInfo(reader, fileSize, audioStart, meta);
  } catch (e) {
    Logger.err(TAG, 'readMpegInfo', e as Error);
  }
  finalizeMetadata(meta);
  return meta;
}
