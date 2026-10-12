/**
 * Folia HarmonyOS - 音频元数据 / 标签读取器（对外入口）
 *
 * 纯逻辑实现，不依赖 Node 的 music-metadata：直接按容器格式解析文件头。
 * 支持容器：MP3(ID3v2/ID3v1)、FLAC、Ogg(Vorbis/Opus)、M4A/MP4、WAV、AAC(ADTS)。
 *
 * 健壮性约定：
 * - 任何解析步骤都被边界检查包裹，readMetadata 永不抛异常；
 * - 损坏文件会返回“已解析到的部分字段”，最坏情况是全空字段；
 * - 所有长度字段都按剩余文件长度裁剪，内嵌封面最多读取 8MB（见 MetadataUtils.MAX_COVER_BYTES）。
 *
 * 文件 IO 与 Base64 使用的系统 API：
 * - @kit.CoreFileKit 的 fileIo：openSync / statSync / readSync / closeSync；
 * - @kit.ArkTS 的 util.Base64Helper：FLAC METADATA_BLOCK_PICTURE 解码（在 VorbisTag.ets 中）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../../core/Logger';
import { ByteReader, asciiEquals } from './ByteReader';
import { createEmptyMetadata } from './MetadataUtils';
import { parseMp3 } from './Mp3Parser';
import { parseFlac } from './FlacParser';
import { parseOgg } from './VorbisParser';
import { parseMp4 } from './Mp4Parser';
import { parseWav, parseAac } from './WavParser';

const TAG: string = 'MetadataReader';

/** 容器嗅探读取的字节数 */
const SNIFF_BYTES: number = 16;

/** 内嵌封面 */
export interface EmbeddedCover {
  /** image/jpeg、image/png 等 */
  mimeType: string;
  data: Uint8Array;
}

/** 支持的容器 */
export type AudioContainer = 'mp3' | 'flac' | 'ogg' | 'm4a' | 'wav' | 'aac' | 'unknown';

/** 读取结果；任何字段都可能缺失 */
export interface AudioMetadata {
  title: string;
  artist: string;
  artists: string[];
  album: string;
  albumArtist: string;
  trackNumber: number;
  year: string;
  durationMs: number;
  sampleRate: number;
  bitrate: number;
  channels: number;
  /** 内嵌封面；undefined 表示没有 */
  cover?: EmbeddedCover;
  /** 内嵌歌词文本（USLT / LYRICS / ©lyr） */
  lyrics?: string;
}

/**
 * 只根据文件头判断容器，供库扫描时过滤非音频文件。
 * header 至少应包含开头若干字节（16 字节足够），不足时按现有内容判断。
 */
export function detectContainer(header: Uint8Array): AudioContainer {
  if (header.length >= 3 && asciiEquals(header, 0, 'ID3')) {
    return 'mp3';
  }
  if (header.length >= 4 && asciiEquals(header, 0, 'fLaC')) {
    return 'flac';
  }
  if (header.length >= 4 && asciiEquals(header, 0, 'OggS')) {
    return 'ogg';
  }
  if (header.length >= 12 && asciiEquals(header, 0, 'RIFF') && asciiEquals(header, 8, 'WAVE')) {
    return 'wav';
  }
  if (header.length >= 8 && asciiEquals(header, 4, 'ftyp')) {
    return 'm4a';
  }
  // ADTS：12 位同步字 0xFFF + 固定为 00 的 layer 位
  if (header.length >= 2 && header[0] === 0xFF && (header[1] & 0xF6) === 0xF0) {
    return 'aac';
  }
  // MPEG 帧同步（无 ID3 头的 MP3）；排除保留的 version / layer 组合
  if (header.length >= 2 && header[0] === 0xFF && (header[1] & 0xE0) === 0xE0) {
    const versionBits = (header[1] >> 3) & 0x03;
    const layerBits = (header[1] >> 1) & 0x03;
    if (versionBits !== 1 && layerBits !== 0) {
      return 'mp3';
    }
  }
  return 'unknown';
}

/**
 * 从已打开的 fd 读取元数据；读取器不负责关闭 fd。
 * container 传 'unknown' 时会自行嗅探文件头。
 */
export function readMetadata(fd: number, fileSize: number, container: AudioContainer): AudioMetadata {
  try {
    const reader = new ByteReader(fd, fileSize);
    if (!reader.isUsable()) {
      return createEmptyMetadata();
    }
    let target: AudioContainer = container;
    if (target === 'unknown') {
      target = detectContainer(reader.readRange(0, SNIFF_BYTES));
    }
    if (target === 'mp3') {
      return parseMp3(reader, reader.getSize());
    }
    if (target === 'flac') {
      return parseFlac(reader, reader.getSize());
    }
    if (target === 'ogg') {
      return parseOgg(reader, reader.getSize());
    }
    if (target === 'm4a') {
      return parseMp4(reader, reader.getSize());
    }
    if (target === 'wav') {
      return parseWav(reader, reader.getSize());
    }
    if (target === 'aac') {
      return parseAac(reader, reader.getSize());
    }
    return createEmptyMetadata();
  } catch (e) {
    Logger.err(TAG, 'readMetadata', e as Error);
    return createEmptyMetadata();
  }
}

/** 便捷入口：内部负责打开与关闭文件 */
export function readMetadataFromPath(path: string): AudioMetadata {
  let fd = -1;
  try {
    fd = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const stat = fileIo.statSync(path);
    const fileSize = stat.size;
    if (fileSize <= 0) {
      return createEmptyMetadata();
    }
    // 先嗅探容器，再交给 readMetadata 复用同一个 fd
    let header: Uint8Array = new Uint8Array(0);
    try {
      const buffer = new ArrayBuffer(SNIFF_BYTES);
      const options: fileIo.ReadOptions = { offset: 0, length: SNIFF_BYTES };
      const readCount = fileIo.readSync(fd, buffer, options);
      const view = new Uint8Array(buffer);
      if (readCount >= SNIFF_BYTES) {
        header = view;
      } else if (readCount > 0) {
        header = view.slice(0, readCount);
      }
    } catch (e) {
      Logger.err(TAG, 'readMetadataFromPath.sniff', e as Error);
    }
    const container = detectContainer(header);
    return readMetadata(fd, fileSize, container);
  } catch (e) {
    Logger.err(TAG, 'readMetadataFromPath', e as Error);
    return createEmptyMetadata();
  } finally {
    if (fd >= 0) {
      try {
        fileIo.closeSync(fd);
      } catch (e) {
        // 关闭失败不影响读取结果，忽略
      }
    }
  }
}
