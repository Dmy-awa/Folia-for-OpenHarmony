/**
 * Folia HarmonyOS - 音频标签解析底层字节工具
 *
 * 本文件只做两件事：
 * 1. ByteReader：基于已打开的 fd 做“有界读取”，任何越界都会被裁剪，任何 IO 异常都会被吞掉并返回空数组；
 * 2. 一组自由函数：大小端整数、ASCII/文本解码、终止符查找、ID3 去同步（unsynchronisation）。
 *
 * 设计约束：所有函数都不向外抛异常，越界一律返回 0 / 空数组 / 空字符串，
 * 由上层解析器按“字段缺失”处理，这样损坏文件不会中断整库扫描。
 */
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../../core/Logger';

const TAG: string = 'ByteReader';

/** 空结果常量，失败路径复用，避免反复分配 */
const EMPTY_BYTES: Uint8Array = new Uint8Array(0);

// ---------------------------------------------------------------------------
// 整数读取（大端 / 小端），越界返回 0
// ---------------------------------------------------------------------------

/** 大端 16 位无符号整数 */
export function readUint16BE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 2 > bytes.length) {
    return 0;
  }
  return ((bytes[offset] << 8) | bytes[offset + 1]) & 0xFFFF;
}

/** 小端 16 位无符号整数 */
export function readUint16LE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 2 > bytes.length) {
    return 0;
  }
  return (bytes[offset] | (bytes[offset + 1] << 8)) & 0xFFFF;
}

/** 大端 24 位无符号整数（FLAC 块长度、ID3v2.2 帧长度使用） */
export function readUint24BE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 3 > bytes.length) {
    return 0;
  }
  return ((bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2]) & 0xFFFFFF;
}

/** 大端 32 位无符号整数 */
export function readUint32BE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > bytes.length) {
    return 0;
  }
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16)
    | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

/** 小端 32 位无符号整数 */
export function readUint32LE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > bytes.length) {
    return 0;
  }
  return (bytes[offset] | (bytes[offset + 1] << 8)
    | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

/**
 * 大端 64 位整数。
 * 超出 JS 安全整数范围时饱和到 MAX_SAFE_INTEGER，调用方一律用它做长度比较，
 * 饱和值必然大于真实文件长度，因此会被正常裁剪掉。
 */
export function readUint64BE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 8 > bytes.length) {
    return 0;
  }
  const high = readUint32BE(bytes, offset);
  const low = readUint32BE(bytes, offset + 4);
  if (high >= 0x200000) {
    return Number.MAX_SAFE_INTEGER;
  }
  return high * 4294967296 + low;
}

/** 小端 64 位整数，语义同 readUint64BE */
export function readUint64LE(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 8 > bytes.length) {
    return 0;
  }
  const low = readUint32LE(bytes, offset);
  const high = readUint32LE(bytes, offset + 4);
  if (high >= 0x200000) {
    return Number.MAX_SAFE_INTEGER;
  }
  return high * 4294967296 + low;
}

/** ID3v2 的 sync-safe 32 位整数（每字节只用低 7 位） */
export function readSyncSafeUint32(bytes: Uint8Array, offset: number): number {
  if (offset < 0 || offset + 4 > bytes.length) {
    return 0;
  }
  return ((bytes[offset] & 0x7F) << 21) | ((bytes[offset + 1] & 0x7F) << 14)
    | ((bytes[offset + 2] & 0x7F) << 7) | (bytes[offset + 3] & 0x7F);
}

// ---------------------------------------------------------------------------
// ASCII 查找 / 读取
// ---------------------------------------------------------------------------

/** 判断 [offset, offset+text.length) 是否等于给定 ASCII 文本 */
export function asciiEquals(bytes: Uint8Array, offset: number, text: string): boolean {
  if (offset < 0 || offset + text.length > bytes.length) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    if (bytes[offset + i] !== text.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/** 读取可打印 ASCII 字符串；不可打印字节会被跳过（容器标记本身都是 ASCII） */
export function readAsciiString(bytes: Uint8Array, offset: number, length: number): string {
  let text = '';
  const end = Math.min(offset + length, bytes.length);
  for (let i = Math.max(0, offset); i < end; i++) {
    const value = bytes[i];
    if (value >= 0x20 && value <= 0x7E) {
      text += String.fromCharCode(value);
    }
  }
  return text;
}

/** 在 [from, bytes.length) 中查找 ASCII 文本，返回下标；找不到返回 -1 */
export function indexOfAscii(bytes: Uint8Array, text: string, from: number): number {
  if (text.length === 0) {
    return -1;
  }
  const start = from < 0 ? 0 : from;
  const limit = bytes.length - text.length;
  for (let i = start; i <= limit; i++) {
    if (asciiEquals(bytes, i, text)) {
      return i;
    }
  }
  return -1;
}

/** 在 [start, end) 中查找单字节值，返回下标；找不到返回 -1 */
export function indexOfByte(bytes: Uint8Array, start: number, end: number, value: number): number {
  const limit = Math.min(end, bytes.length);
  for (let i = Math.max(0, start); i < limit; i++) {
    if (bytes[i] === value) {
      return i;
    }
  }
  return -1;
}

/**
 * 查找字符串终止符（0x00）。
 * wide 为 true 时按 UTF-16 处理，要求连续两个 0x00 且从 start 起两字节对齐。
 */
export function findTerminator(bytes: Uint8Array, start: number, end: number, wide: boolean): number {
  const limit = Math.min(end, bytes.length);
  if (!wide) {
    return indexOfByte(bytes, start, limit, 0x00);
  }
  let i = Math.max(0, start);
  while (i + 1 < limit) {
    if (bytes[i] === 0x00 && bytes[i + 1] === 0x00) {
      return i;
    }
    i += 2;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// 文本解码（手写实现，不依赖 TextDecoder；非法序列替换为 U+FFFD）
// ---------------------------------------------------------------------------

/** ISO-8859-1（逐字节映射码点），ID3 编码 0x00 与 ID3v1 使用 */
export function decodeLatin1(bytes: Uint8Array, start: number, end: number): string {
  let text = '';
  const limit = Math.min(end, bytes.length);
  for (let i = Math.max(0, start); i < limit; i++) {
    text += String.fromCharCode(bytes[i]);
  }
  return text;
}

/** UTF-8 解码；非法字节序列输出 U+FFFD，不会抛异常 */
export function decodeUtf8(bytes: Uint8Array, start: number, end: number): string {
  let text = '';
  const limit = Math.min(end, bytes.length);
  let i = Math.max(0, start);
  while (i < limit) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      text += String.fromCharCode(b0);
      i++;
      continue;
    }
    let needed = 0;
    let code = 0;
    if ((b0 & 0xE0) === 0xC0) {
      needed = 1;
      code = b0 & 0x1F;
    } else if ((b0 & 0xF0) === 0xE0) {
      needed = 2;
      code = b0 & 0x0F;
    } else if ((b0 & 0xF8) === 0xF0) {
      needed = 3;
      code = b0 & 0x07;
    } else {
      text += '\uFFFD';
      i++;
      continue;
    }
    // 续字节必须全部存在
    if (i + needed >= limit) {
      text += '\uFFFD';
      break;
    }
    let valid = true;
    for (let k = 1; k <= needed; k++) {
      const bk = bytes[i + k];
      if ((bk & 0xC0) !== 0x80) {
        valid = false;
        break;
      }
      code = (code << 6) | (bk & 0x3F);
    }
    if (!valid) {
      text += '\uFFFD';
      i++;
      continue;
    }
    if (code > 0xFFFF) {
      const value = code - 0x10000;
      text += String.fromCharCode(0xD800 + (value >> 10));
      text += String.fromCharCode(0xDC00 + (value & 0x3FF));
    } else {
      text += String.fromCharCode(code);
    }
    i += needed + 1;
  }
  return text;
}

/**
 * UTF-16 解码。bigEndian 为默认字节序；存在 BOM 时以 BOM 为准并跳过它。
 * 代理对由 String.fromCharCode 按码元透传，无需额外处理。
 */
export function decodeUtf16(bytes: Uint8Array, start: number, end: number, bigEndian: boolean): string {
  const limit = Math.min(end, bytes.length);
  let i = Math.max(0, start);
  let big = bigEndian;
  if (i + 1 < limit) {
    if (bytes[i] === 0xFF && bytes[i + 1] === 0xFE) {
      big = false;
      i += 2;
    } else if (bytes[i] === 0xFE && bytes[i + 1] === 0xFF) {
      big = true;
      i += 2;
    }
  }
  let text = '';
  while (i + 1 < limit) {
    const unit = big ? ((bytes[i] << 8) | bytes[i + 1]) : ((bytes[i + 1] << 8) | bytes[i]);
    text += String.fromCharCode(unit);
    i += 2;
  }
  return text;
}

// ---------------------------------------------------------------------------
// ID3 unsynchronisation
// ---------------------------------------------------------------------------

/**
 * 去同步：把 0xFF 00 还原成 0xFF。
 * 分两趟处理（先计长度再填充），避免构造临时 number[] 数组。
 */
export function deUnsynchronize(bytes: Uint8Array): Uint8Array {
  let outLength = 0;
  for (let i = 0; i < bytes.length; i++) {
    outLength++;
    if (bytes[i] === 0xFF && i + 1 < bytes.length && bytes[i + 1] === 0x00) {
      i++;
    }
  }
  const out = new Uint8Array(outLength);
  let write = 0;
  for (let i = 0; i < bytes.length; i++) {
    out[write] = bytes[i];
    write++;
    if (bytes[i] === 0xFF && i + 1 < bytes.length && bytes[i + 1] === 0x00) {
      i++;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 基于 fd 的有界读取器
// ---------------------------------------------------------------------------

/**
 * ByteReader：把 fd + 文件长度包成“永远不会越界”的读取器。
 * 读取器不负责关闭 fd，由调用方（MetadataReader）统一管理。
 */
export class ByteReader {
  private fd: number = -1;
  private fileSize: number = 0;
  private usable: boolean = false;

  constructor(fd: number, fileSize: number) {
    this.fd = fd;
    this.fileSize = fileSize > 0 ? Math.floor(fileSize) : 0;
    this.usable = fd >= 0 && this.fileSize > 0;
  }

  /** 文件总长度（构造时传入） */
  getSize(): number {
    return this.fileSize;
  }

  /** fd 与长度是否可用于读取 */
  isUsable(): boolean {
    return this.usable;
  }

  /**
   * 读取 [position, position + length)，自动裁剪到文件范围内。
   * IO 失败或参数非法时返回长度为 0 的数组，不抛异常。
   */
  readRange(position: number, length: number): Uint8Array {
    if (!this.usable || length <= 0) {
      return EMPTY_BYTES;
    }
    const start = Math.floor(position);
    if (start < 0 || start >= this.fileSize) {
      return EMPTY_BYTES;
    }
    let count = Math.floor(length);
    const remain = this.fileSize - start;
    if (count > remain) {
      count = remain;
    }
    if (count <= 0) {
      return EMPTY_BYTES;
    }
    try {
      const buffer = new ArrayBuffer(count);
      const options: fileIo.ReadOptions = { offset: start, length: count };
      const readCount = fileIo.readSync(this.fd, buffer, options);
      const view = new Uint8Array(buffer);
      if (readCount >= count) {
        return view;
      }
      if (readCount <= 0) {
        return EMPTY_BYTES;
      }
      return view.slice(0, readCount);
    } catch (e) {
      Logger.err(TAG, 'ByteReader.readRange', e as Error);
      return EMPTY_BYTES;
    }
  }

  /** 从文件尾部读取至多 length 字节（ID3v1、Ogg 尾页用） */
  readTail(length: number): Uint8Array {
    if (!this.usable || length <= 0) {
      return EMPTY_BYTES;
    }
    let count = Math.floor(length);
    if (count > this.fileSize) {
      count = this.fileSize;
    }
    return this.readRange(this.fileSize - count, count);
  }
}
