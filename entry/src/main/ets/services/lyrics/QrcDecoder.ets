/**
 * Folia HarmonyOS - QQ 音乐 QRC 歌词解密（QrcDecoder）
 *
 * 上游对应实现：src/utils/lyrics/providers/qrcDecrypt.ts
 *
 * 算法（三步）：
 *   1. 输入是十六进制字符串（QQ 接口 data.lyric / data.trans / data.roma 都是待解密的十六进制串）
 *      或原始字节；按 **8 字节一块**分组，末尾不足 8 字节的块用 0 补齐；
 *   2. 每块过 **自定义 3DES**（QQ Music 自有变体：S-box 与标准 DES 不同，SBOX[1]、SBOX[3] 里存在
 *      重复值，因此**不能**替换成系统 `cryptoFramework` 的 DES192）。密钥是 UTF-8 的 24 字节
 *      `!@#)(*$%123ZXC!@!@#)(NHL`，按 `tripledes_key_setup(key, 0)`（0 = DECRYPT）编排，
 *      即 key16 解密 -> key8 加密 -> key0 解密；解密后只写回该块的原始长度；
 *   3. 对结果做 **zlib 包装**的 INFLATE（RFC1950；上游用 DecompressionStream('deflate')），
 *      再按 UTF-8 解码，得到 `[time,duration]word...` 形态的明文（可能是 XML/QRC 头 + 逐字行）。
 *      本文件不解析明文，与上游 qrcDecrypt 的返回语义完全一致。
 *
 * ⚠️ 关于 isQrcPayload：本函数判定的是「**加密态**」QRC（十六进制密文）。上游的 detectIsQrc
 *    判定的是「**解密后**」的明文（含 '(' ')' 且形如 [数字,数字]），那个规则单独导出为
 *    isPlainQrcText，语义与上游 qqLyricProvider.detectIsQrc 一致，不要混用。
 *
 * 关于解压 API 的选择（已核对本机 SDK D:\HarmonyOS_Development_API\23\ets\api\@ohos.zlib.d.ts）：
 *   该 SDK 中**不存在**任何同步的 ArrayBuffer 解压函数（任务说明假设的 `zlib.decompressSync`
 *   并不存在）；API 12 起只有 `zlib.createZipSync()` 返回的 `Zip` 对象上的**异步**
 *   `uncompress(dest, source, sourceLen?)`。为保持 decryptQrc 的同步签名，本文件移植了 zlib 自带
 *   示例程序 puff.c（public domain）的 INFLATE 作为纯 ArkTS 实现，只依赖 Uint8Array。
 *   该 INFLATE 与 KrcDecoder.ets 中的实现逐字相同（为满足「每个文件自包含」的要求而各存一份）。
 *
 * 失败一律返回空字符串（调用方以空串表示「无歌词」）并写日志，不向上抛异常。
 */
import { util } from '@kit.ArkTS';
import { Logger } from '../../core/Logger';

const TAG: string = 'QrcDecoder';

/** QRC 的 24 字节 3DES 密钥明文（UTF-8 编码后正好 24 字节 = 三组 8 字节 DES 密钥） */
const QRC_KEY_TEXT: string = '!@#)(*$%123ZXC!@!@#)(NHL';

/** 上游 qqLyricProvider.detectIsQrc 用的明文形态正则（带 g 标志的正则跨调用有状态，故不带 g） */
const PLAIN_QRC_TAG: RegExp = /\[\d+,\d+\]/;

/**
 * 判定一段文本是否是**加密态**的 QRC 负载。
 * QQ 接口返回的是十六进制字符串，这里要求：去空白后是偶数长度、长度 >= 16（至少一个 8 字节块）、
 * 且全部字符都是十六进制数字。明文形态请用 isPlainQrcText。
 */
export function isQrcPayload(text: string): boolean {
  try {
    const hex = text.trim();
    if (hex.length < 16 || hex.length % 2 !== 0) {
      return false;
    }
    return isHexString(hex);
  } catch {
    // 运行时拿到 undefined / null 时按「不是 QRC」处理，不抛异常
    return false;
  }
}

/** 判定一段**解密后**的文本是否是 QRC 明文：含成对括号且含 [数字,数字]。与上游 detectIsQrc 一致 */
export function isPlainQrcText(content: string): boolean {
  return content.includes('(') && content.includes(')') && PLAIN_QRC_TAG.test(content);
}

/** 是否全部为十六进制字符 */
function isHexString(hex: string): boolean {
  for (let i = 0; i < hex.length; i++) {
    const c = hex.charCodeAt(i);
    const isDigit = c >= 48 && c <= 57; // 0-9
    const isUpper = c >= 65 && c <= 70; // A-F
    const isLower = c >= 97 && c <= 102; // a-f
    if (!isDigit && !isUpper && !isLower) {
      return false;
    }
  }
  return hex.length > 0;
}

/**
 * 十六进制字符串 -> 字节。
 * 等价于上游的 `new Uint8Array(hex.match(/.{1,2}/g)!.map(b => parseInt(b, 16)))`：
 * 每组取 2 个字符，最后一组不足 2 个字符时只按 1 个字符解析。
 */
export function qrcHexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(Math.ceil(hex.length / 2));
  for (let i = 0; i < out.length; i++) {
    const part = hex.substring(i * 2, i * 2 + 2);
    const value = parseInt(part, 16);
    // 解析失败（非十六进制）时按 0 处理：上游 parseInt 得到 NaN，写入 Uint8Array 同样是 0
    out[i] = Number.isNaN(value) ? 0 : value & 0xff;
  }
  return out;
}

/**
 * 解密十六进制形态的 QRC。空串 / 非法十六进制 / 解密失败都返回空字符串。
 */
export function decryptQrc(text: string): string {
  try {
    const hex = text.trim();
    if (hex.length === 0) {
      Logger.warn(TAG, 'QRC 密文为空，放弃解密');
      return '';
    }
    if (!isHexString(hex)) {
      Logger.warn(TAG, 'QRC 密文不是合法的十六进制字符串，放弃解密');
      return '';
    }
    return decryptQrcBytes(qrcHexToBytes(hex));
  } catch (error) {
    Logger.err(TAG, 'decryptQrc', error as Error);
    return '';
  }
}

/**
 * 解密字节形态的 QRC（上游 qrcDecrypt 同时接受 string | Uint8Array）。
 * 8 字节一块做自定义 3DES 解密，末尾不足 8 字节用 0 补齐、解密后只写回原长度，再 zlib inflate。
 */
export function decryptQrcBytes(bytes: Uint8Array): string {
  try {
    if (bytes.length === 0) {
      Logger.warn(TAG, 'QRC 字节为空，放弃解密');
      return '';
    }

    const qrcKey = new util.TextEncoder().encodeInto(QRC_KEY_TEXT);
    if (qrcKey.length !== 24) {
      Logger.error(TAG, 'QRC 密钥编码后长度不是 24 字节，实际为 ' + qrcKey.length);
      return '';
    }
    const schedule = tripledesKeySetup(qrcKey, 0); // 0 = DECRYPT

    const decryptedBytes = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i += 8) {
      const blockLen = Math.min(8, bytes.length - i);
      const padded = new Uint8Array(8); // 不足 8 字节的部分保持 0
      for (let j = 0; j < blockLen; j++) {
        padded[j] = bytes[i + j];
      }
      const decryptedBlock = tripledesCrypt(padded, schedule);
      for (let j = 0; j < blockLen; j++) {
        decryptedBytes[i + j] = decryptedBlock[j]; // 只写回原始长度
      }
    }

    const inflated = inflateZlib(decryptedBytes);
    if (inflated.partial) {
      // 与上游「读循环抛错但已收到数据时只告警并返回已有数据」一致
      Logger.warn(TAG, 'zlib 流中途出错，改用已解出的部分数据：' + inflated.reason);
    }
    if (inflated.data.length === 0) {
      Logger.error(TAG, 'QRC 解压结果为空，解密失败：' + inflated.reason);
      return '';
    }
    return decodeUtf8(inflated.data);
  } catch (error) {
    Logger.err(TAG, 'decryptQrcBytes', error as Error);
    return '';
  }
}

/** UTF-8 解码，并去掉可能存在的 BOM */
function decodeUtf8(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes).replace(/^\uFEFF/, '');
}

/* =====================================================================================
 * 自定义 3DES（QQ Music 变体）—— 逐常量照抄上游 qrcDecrypt.ts，禁止「优化」或替换为标准 DES
 * ===================================================================================== */

/** 8 组 × 64 项 S-box。**非标准 DES**：SBOX[1]（下标 21 处）与 SBOX[3]（下标 41 处）存在重复值 */
const SBOX: number[][] = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
    3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11
  ]
];

/** 密钥编排常量：16 轮的循环左移位数 */
const KEY_RND_SHIFT: number[] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

/** 密钥编排常量：PC-1 的左半（C）取位表 */
const KEY_PERM_C: number[] = [
  56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
  58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35
];

/** 密钥编排常量：PC-1 的右半（D）取位表 */
const KEY_PERM_D: number[] = [
  62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
  60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3
];

/** 密钥编排常量：PC-2 压缩置换表（48 位） */
const KEY_COMPRESSION: number[] = [
  13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1,
  40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31
];

/** 从字节数组里按位取值（b 为位序号，按大端位序解释），结果左移 c 位 */
function bitnum(a: Uint8Array, b: number, c: number): number {
  const index = Math.floor(b / 32) * 4 + 3 - Math.floor((b % 32) / 8);
  const shift = 7 - (b % 8);
  return ((a[index] >> shift) & 1) << c;
}

/** 从 32 位整数里取第 b 位（最高位为 0），结果左移 c 位 */
function bitnumIntr(a: number, b: number, c: number): number {
  return ((a >>> (31 - b)) & 1) << c;
}

/** 把 32 位整数的第 b 位挪到第 c 位（左移越界后按无符号右移） */
function bitnumIntl(a: number, b: number, c: number): number {
  return (((a << b) & 0x80000000) >>> c);
}

/** S-box 输入的位重排 */
function sboxBit(a: number): number {
  return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);
}

/** initial_permutation 的返回值（ArkTS 不支持元组解构，用类代替） */
class PermState {
  s0: number = 0;
  s1: number = 0;
}

/** 初始置换 IP，输出两个 32 位状态 */
function initialPermutation(inputData: Uint8Array): PermState {
  const state = new PermState();
  state.s0 = (
    bitnum(inputData, 57, 31) | bitnum(inputData, 49, 30) | bitnum(inputData, 41, 29) | bitnum(inputData, 33, 28) |
    bitnum(inputData, 25, 27) | bitnum(inputData, 17, 26) | bitnum(inputData, 9, 25) | bitnum(inputData, 1, 24) |
    bitnum(inputData, 59, 23) | bitnum(inputData, 51, 22) | bitnum(inputData, 43, 21) | bitnum(inputData, 35, 20) |
    bitnum(inputData, 27, 19) | bitnum(inputData, 19, 18) | bitnum(inputData, 11, 17) | bitnum(inputData, 3, 16) |
    bitnum(inputData, 61, 15) | bitnum(inputData, 53, 14) | bitnum(inputData, 45, 13) | bitnum(inputData, 37, 12) |
    bitnum(inputData, 29, 11) | bitnum(inputData, 21, 10) | bitnum(inputData, 13, 9) | bitnum(inputData, 5, 8) |
    bitnum(inputData, 63, 7) | bitnum(inputData, 55, 6) | bitnum(inputData, 47, 5) | bitnum(inputData, 39, 4) |
    bitnum(inputData, 31, 3) | bitnum(inputData, 23, 2) | bitnum(inputData, 15, 1) | bitnum(inputData, 7, 0)
  ) >>> 0;

  state.s1 = (
    bitnum(inputData, 56, 31) | bitnum(inputData, 48, 30) | bitnum(inputData, 40, 29) | bitnum(inputData, 32, 28) |
    bitnum(inputData, 24, 27) | bitnum(inputData, 16, 26) | bitnum(inputData, 8, 25) | bitnum(inputData, 0, 24) |
    bitnum(inputData, 58, 23) | bitnum(inputData, 50, 22) | bitnum(inputData, 42, 21) | bitnum(inputData, 34, 20) |
    bitnum(inputData, 26, 19) | bitnum(inputData, 18, 18) | bitnum(inputData, 10, 17) | bitnum(inputData, 2, 16) |
    bitnum(inputData, 60, 15) | bitnum(inputData, 52, 14) | bitnum(inputData, 44, 13) | bitnum(inputData, 36, 12) |
    bitnum(inputData, 28, 11) | bitnum(inputData, 20, 10) | bitnum(inputData, 12, 9) | bitnum(inputData, 4, 8) |
    bitnum(inputData, 62, 7) | bitnum(inputData, 54, 6) | bitnum(inputData, 46, 5) | bitnum(inputData, 38, 4) |
    bitnum(inputData, 30, 3) | bitnum(inputData, 22, 2) | bitnum(inputData, 14, 1) | bitnum(inputData, 6, 0)
  ) >>> 0;

  return state;
}

/** 逆初始置换 IP^-1，输出 8 字节（注意 data[3]…data[4] 的书写顺序与上游一致） */
function inversePermutation(s0: number, s1: number): Uint8Array {
  const data = new Uint8Array(8);

  data[3] = bitnumIntr(s1, 7, 7) | bitnumIntr(s0, 7, 6) | bitnumIntr(s1, 15, 5) |
    bitnumIntr(s0, 15, 4) | bitnumIntr(s1, 23, 3) | bitnumIntr(s0, 23, 2) |
    bitnumIntr(s1, 31, 1) | bitnumIntr(s0, 31, 0);

  data[2] = bitnumIntr(s1, 6, 7) | bitnumIntr(s0, 6, 6) | bitnumIntr(s1, 14, 5) |
    bitnumIntr(s0, 14, 4) | bitnumIntr(s1, 22, 3) | bitnumIntr(s0, 22, 2) |
    bitnumIntr(s1, 30, 1) | bitnumIntr(s0, 30, 0);

  data[1] = bitnumIntr(s1, 5, 7) | bitnumIntr(s0, 5, 6) | bitnumIntr(s1, 13, 5) |
    bitnumIntr(s0, 13, 4) | bitnumIntr(s1, 21, 3) | bitnumIntr(s0, 21, 2) |
    bitnumIntr(s1, 29, 1) | bitnumIntr(s0, 29, 0);

  data[0] = bitnumIntr(s1, 4, 7) | bitnumIntr(s0, 4, 6) | bitnumIntr(s1, 12, 5) |
    bitnumIntr(s0, 12, 4) | bitnumIntr(s1, 20, 3) | bitnumIntr(s0, 20, 2) |
    bitnumIntr(s1, 28, 1) | bitnumIntr(s0, 28, 0);

  data[7] = bitnumIntr(s1, 3, 7) | bitnumIntr(s0, 3, 6) | bitnumIntr(s1, 11, 5) |
    bitnumIntr(s0, 11, 4) | bitnumIntr(s1, 19, 3) | bitnumIntr(s0, 19, 2) |
    bitnumIntr(s1, 27, 1) | bitnumIntr(s0, 27, 0);

  data[6] = bitnumIntr(s1, 2, 7) | bitnumIntr(s0, 2, 6) | bitnumIntr(s1, 10, 5) |
    bitnumIntr(s0, 10, 4) | bitnumIntr(s1, 18, 3) | bitnumIntr(s0, 18, 2) |
    bitnumIntr(s1, 26, 1) | bitnumIntr(s0, 26, 0);

  data[5] = bitnumIntr(s1, 1, 7) | bitnumIntr(s0, 1, 6) | bitnumIntr(s1, 9, 5) |
    bitnumIntr(s0, 9, 4) | bitnumIntr(s1, 17, 3) | bitnumIntr(s0, 17, 2) |
    bitnumIntr(s1, 25, 1) | bitnumIntr(s0, 25, 0);

  data[4] = bitnumIntr(s1, 0, 7) | bitnumIntr(s0, 0, 6) | bitnumIntr(s1, 8, 5) |
    bitnumIntr(s0, 8, 4) | bitnumIntr(s1, 16, 3) | bitnumIntr(s0, 16, 2) |
    bitnumIntr(s1, 24, 1) | bitnumIntr(s0, 24, 0);

  return data;
}

/** DES 轮函数 f（key 为 6 字节轮密钥） */
function fFeistel(state: number, key: number[]): number {
  const t1 = (
    bitnumIntl(state, 31, 0) |
    ((state & 0xf0000000) >>> 1) |
    bitnumIntl(state, 4, 5) |
    bitnumIntl(state, 3, 6) |
    ((state & 0x0f000000) >>> 3) |
    bitnumIntl(state, 8, 11) |
    bitnumIntl(state, 7, 12) |
    ((state & 0x00f00000) >>> 5) |
    bitnumIntl(state, 12, 17) |
    bitnumIntl(state, 11, 18) |
    ((state & 0x000f0000) >>> 7) |
    bitnumIntl(state, 16, 23)
  ) >>> 0;

  const t2 = (
    bitnumIntl(state, 15, 0) |
    ((state & 0x0000f000) << 15) |
    bitnumIntl(state, 20, 5) |
    bitnumIntl(state, 19, 6) |
    ((state & 0x00000f00) << 13) |
    bitnumIntl(state, 24, 11) |
    bitnumIntl(state, 23, 12) |
    ((state & 0x000000f0) << 11) |
    bitnumIntl(state, 28, 17) |
    bitnumIntl(state, 27, 18) |
    ((state & 0x0000000f) << 9) |
    bitnumIntl(state, 0, 23)
  ) >>> 0;

  // lrgstate / xorState 用定长数组 + for 循环（ArkTS 下避免 map 回调类型推断问题）
  const lrgstate: number[] = [
    (t1 >>> 24) & 0xff,
    (t1 >>> 16) & 0xff,
    (t1 >>> 8) & 0xff,
    (t2 >>> 24) & 0xff,
    (t2 >>> 16) & 0xff,
    (t2 >>> 8) & 0xff
  ];
  const xorState: number[] = [];
  for (let idx = 0; idx < lrgstate.length; idx++) {
    xorState.push(lrgstate[idx] ^ key[idx]);
  }

  const outputState = (
    (SBOX[0][sboxBit(xorState[0] >>> 2)] << 28) |
    (SBOX[1][sboxBit(((xorState[0] & 0x03) << 4) | (xorState[1] >>> 4))] << 24) |
    (SBOX[2][sboxBit(((xorState[1] & 0x0f) << 2) | (xorState[2] >>> 6))] << 20) |
    (SBOX[3][sboxBit(xorState[2] & 0x3f)] << 16) |
    (SBOX[4][sboxBit(xorState[3] >>> 2)] << 12) |
    (SBOX[5][sboxBit(((xorState[3] & 0x03) << 4) | (xorState[4] >>> 4))] << 8) |
    (SBOX[6][sboxBit(((xorState[4] & 0x0f) << 2) | (xorState[5] >>> 6))] << 4) |
    SBOX[7][sboxBit(xorState[5] & 0x3f)]
  ) >>> 0;

  return (
    bitnumIntl(outputState, 15, 0) | bitnumIntl(outputState, 6, 1) | bitnumIntl(outputState, 19, 2) |
    bitnumIntl(outputState, 20, 3) | bitnumIntl(outputState, 28, 4) | bitnumIntl(outputState, 11, 5) |
    bitnumIntl(outputState, 27, 6) | bitnumIntl(outputState, 16, 7) | bitnumIntl(outputState, 0, 8) |
    bitnumIntl(outputState, 14, 9) | bitnumIntl(outputState, 22, 10) | bitnumIntl(outputState, 25, 11) |
    bitnumIntl(outputState, 4, 12) | bitnumIntl(outputState, 17, 13) | bitnumIntl(outputState, 30, 14) |
    bitnumIntl(outputState, 9, 15) | bitnumIntl(outputState, 1, 16) | bitnumIntl(outputState, 7, 17) |
    bitnumIntl(outputState, 23, 18) | bitnumIntl(outputState, 13, 19) | bitnumIntl(outputState, 31, 20) |
    bitnumIntl(outputState, 26, 21) | bitnumIntl(outputState, 2, 22) | bitnumIntl(outputState, 8, 23) |
    bitnumIntl(outputState, 18, 24) | bitnumIntl(outputState, 12, 25) | bitnumIntl(outputState, 29, 26) |
    bitnumIntl(outputState, 5, 27) | bitnumIntl(outputState, 21, 28) | bitnumIntl(outputState, 10, 29) |
    bitnumIntl(outputState, 3, 30) | bitnumIntl(outputState, 24, 31)
  ) >>> 0;
}

/**
 * 单个 8 字节块的 DES：16 轮 Feistel，**最后一轮不交换左右**。
 * 传入 key_schedule(key, 0) 即为解密。
 */
function crypt(inputData: Uint8Array, key: number[][]): Uint8Array {
  const ip = initialPermutation(inputData);
  let s0 = ip.s0;
  let s1 = ip.s1;

  for (let idx = 0; idx < 15; idx++) {
    const previousS1 = s1;
    s1 = (fFeistel(s1, key[idx]) ^ s0) >>> 0;
    s0 = previousS1;
  }
  s0 = (fFeistel(s1, key[15]) ^ s0) >>> 0;

  return inversePermutation(s0, s1);
}

/**
 * 密钥编排：由 8 字节密钥生成 16 组 6 字节轮密钥。
 * mode === 0 时按解密顺序（15 - i）写入，否则按加密顺序（i）写入。
 */
function keySchedule(key: Uint8Array, mode: number): number[][] {
  const schedule: number[][] = [];
  for (let i = 0; i < 16; i++) {
    schedule.push([0, 0, 0, 0, 0, 0]);
  }

  let c = 0;
  for (let i = 0; i < 28; i++) {
    c |= bitnum(key, KEY_PERM_C[i], 31 - i);
  }
  c = c >>> 0;

  let d = 0;
  for (let i = 0; i < 28; i++) {
    d |= bitnum(key, KEY_PERM_D[i], 31 - i);
  }
  d = d >>> 0;

  for (let i = 0; i < 16; i++) {
    c = (((c << KEY_RND_SHIFT[i]) | (c >>> (28 - KEY_RND_SHIFT[i]))) & 0xfffffff0) >>> 0;
    d = (((d << KEY_RND_SHIFT[i]) | (d >>> (28 - KEY_RND_SHIFT[i]))) & 0xfffffff0) >>> 0;

    const togen = mode === 0 ? 15 - i : i;

    for (let j = 0; j < 6; j++) {
      schedule[togen][j] = 0;
    }
    for (let j = 0; j < 24; j++) {
      schedule[togen][Math.floor(j / 8)] |= bitnumIntr(c, KEY_COMPRESSION[j], 7 - (j % 8));
    }
    for (let j = 24; j < 48; j++) {
      schedule[togen][Math.floor(j / 8)] |= bitnumIntr(d, KEY_COMPRESSION[j] - 27, 7 - (j % 8));
    }
  }

  return schedule;
}

/**
 * 3DES 密钥编排：24 字节密钥切成 3 组 8 字节。
 * mode === 1（ENCRYPT）：key0 加密 -> key8 解密 -> key16 加密；
 * 否则（DECRYPT，QRC 走这条）：key16 解密 -> key8 加密 -> key0 解密。
 */
function tripledesKeySetup(key: Uint8Array, mode: number): number[][][] {
  const key0 = key.subarray(0, 8);
  const key8 = key.subarray(8, 16);
  const key16 = key.subarray(16, 24);

  if (mode === 1) {
    return [keySchedule(key0, 1), keySchedule(key8, 0), keySchedule(key16, 1)];
  }
  return [keySchedule(key16, 0), keySchedule(key8, 1), keySchedule(key0, 0)];
}

/** 依次用 3 组轮密钥做 3 次单块 DES */
function tripledesCrypt(data: Uint8Array, keySchedule3: number[][][]): Uint8Array {
  let temp = data;
  for (let i = 0; i < 3; i++) {
    temp = crypt(temp, keySchedule3[i]);
  }
  return temp;
}

/* =====================================================================================
 * 纯 ArkTS 的 INFLATE（DEFLATE / zlib 解压）
 *
 * 与 KrcDecoder.ets 中的实现逐字相同（每个文件自包含，不跨文件依赖）。
 * 算法来源：zlib 自带示例程序 puff.c（public domain）；上游用的是浏览器
 * DecompressionStream('deflate')，即 RFC1950 的 zlib 包装，故入口先跳过 2 字节头，
 * 尾部 4 字节 Adler-32 不校验（与 puff.c 的 inf() 一致）。
 * ===================================================================================== */

const MAXBITS: number = 15;
const MAXLCODES: number = 286;
const MAXDCODES: number = 30;
const MAXCODES: number = MAXLCODES + MAXDCODES;
const FIXLCODES: number = 288;
const MIN_OUT_CAPACITY: number = 1024;

/** 长度码 257..285 的基值 */
const LENGTH_BASE: number[] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];

/** 长度码的附加位数 */
const LENGTH_EXTRA: number[] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];

/** 距离码 0..29 的基值 */
const DIST_BASE: number[] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];

/** 距离码的附加位数 */
const DIST_EXTRA: number[] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];

/** 动态块里「码长码」的出现顺序（puff.c 的 order） */
const CODE_LENGTH_ORDER: number[] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/** 生成 n 个 0 的 number[] */
function zeros(n: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    out.push(0);
  }
  return out;
}

/** 霍夫曼表：count[len] = 该码长的码字个数，symbol[] = 按码字升序排列的符号 */
class Huffman {
  count: number[] = zeros(MAXBITS + 1);
  symbol: number[] = zeros(MAXCODES);
}

/** 由码长数组构造霍夫曼表（puff.c construct），码长溢出时抛错 */
function construct(h: Huffman, length: number[], n: number): void {
  for (let len = 0; len <= MAXBITS; len++) {
    h.count[len] = 0;
  }
  for (let symbol = 0; symbol < n; symbol++) {
    h.count[length[symbol]] = h.count[length[symbol]] + 1;
  }
  if (h.count[0] === n) {
    return;
  }

  let left = 1;
  for (let len = 1; len <= MAXBITS; len++) {
    left <<= 1;
    left -= h.count[len];
    if (left < 0) {
      throw new Error('inflate: 霍夫曼码长溢出（over-subscribed）');
    }
  }

  const offs: number[] = zeros(MAXBITS + 1);
  for (let len = 1; len < MAXBITS; len++) {
    offs[len + 1] = offs[len] + h.count[len];
  }
  for (let symbol = 0; symbol < n; symbol++) {
    if (length[symbol] !== 0) {
      h.symbol[offs[length[symbol]]] = symbol;
      offs[length[symbol]] = offs[length[symbol]] + 1;
    }
  }
}

/** 单个 deflate 流的解压状态机 */
class Inflater {
  private readonly input: Uint8Array;
  private readonly inLen: number;
  private incnt: number = 0;
  private bitBuf: number = 0;
  private bitCnt: number = 0;
  private out: Uint8Array = new Uint8Array(MIN_OUT_CAPACITY);
  private outLen: number = 0;
  private readonly lencode: Huffman = new Huffman();
  private readonly distcode: Huffman = new Huffman();

  constructor(input: Uint8Array) {
    this.input = input;
    this.inLen = input.length;
  }

  /** 已解出的字节数 */
  getOutLen(): number {
    return this.outLen;
  }

  /** 取已解出的数据（视图，不额外拷贝） */
  takeOutput(): Uint8Array {
    return this.out.subarray(0, this.outLen);
  }

  /** 扩容到至少 outLen + extra 字节 */
  private ensure(extra: number): void {
    const need = this.outLen + extra;
    if (need <= this.out.length) {
      return;
    }
    let cap = this.out.length > 0 ? this.out.length : MIN_OUT_CAPACITY;
    while (cap < need) {
      cap = cap * 2;
    }
    const next = new Uint8Array(cap);
    next.set(this.out.subarray(0, this.outLen));
    this.out = next;
  }

  /** 读 need 位（LSB 优先），位数不足抛错 */
  private bits(need: number): number {
    let val = this.bitBuf;
    while (this.bitCnt < need) {
      if (this.incnt >= this.inLen) {
        throw new Error('inflate: 输入流提前结束');
      }
      val |= this.input[this.incnt] << this.bitCnt;
      this.incnt++;
      this.bitCnt += 8;
    }
    this.bitBuf = val >>> need;
    this.bitCnt -= need;
    return val & ((1 << need) - 1);
  }

  /** 按霍夫曼表解出一个符号（puff.c decode） */
  private decode(h: Huffman): number {
    let code = 0;
    let first = 0;
    let index = 0;
    for (let len = 1; len <= MAXBITS; len++) {
      code |= this.bits(1);
      const count = h.count[len];
      if (code - count < first) {
        return h.symbol[index + (code - first)];
      }
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw new Error('inflate: 非法的霍夫曼码');
  }

  /** 块类型 0：非压缩存储块 */
  private stored(): void {
    this.bitBuf = 0;
    this.bitCnt = 0;
    if (this.incnt + 4 > this.inLen) {
      throw new Error('inflate: stored 块长度字段越界');
    }
    const len = this.input[this.incnt] | (this.input[this.incnt + 1] << 8);
    const nlen = this.input[this.incnt + 2] | (this.input[this.incnt + 3] << 8);
    this.incnt += 4;
    if (len !== ((~nlen) & 0xffff)) {
      throw new Error('inflate: stored 块长度与反码不一致');
    }
    if (this.incnt + len > this.inLen) {
      throw new Error('inflate: stored 块数据越界');
    }
    this.ensure(len);
    for (let i = 0; i < len; i++) {
      this.out[this.outLen] = this.input[this.incnt];
      this.outLen++;
      this.incnt++;
    }
  }

  /** 块类型 1：固定霍夫曼表 */
  private fixed(): void {
    const lengths: number[] = zeros(MAXCODES);
    for (let symbol = 0; symbol < 144; symbol++) {
      lengths[symbol] = 8;
    }
    for (let symbol = 144; symbol < 256; symbol++) {
      lengths[symbol] = 9;
    }
    for (let symbol = 256; symbol < 280; symbol++) {
      lengths[symbol] = 7;
    }
    for (let symbol = 280; symbol < FIXLCODES; symbol++) {
      lengths[symbol] = 8;
    }
    construct(this.lencode, lengths, FIXLCODES);

    for (let symbol = 0; symbol < MAXDCODES; symbol++) {
      lengths[symbol] = 5;
    }
    construct(this.distcode, lengths, MAXDCODES);
  }

  /** 块类型 2：动态霍夫曼表 */
  private dynamic(): void {
    const lengths: number[] = zeros(MAXCODES);
    const nlen = this.bits(5) + 257;
    const ndist = this.bits(5) + 1;
    const ncode = this.bits(4) + 4;
    if (nlen > MAXLCODES || ndist > MAXDCODES) {
      throw new Error('inflate: 动态块码字数非法');
    }

    for (let index = 0; index < ncode; index++) {
      lengths[CODE_LENGTH_ORDER[index]] = this.bits(3);
    }
    for (let index = ncode; index < CODE_LENGTH_ORDER.length; index++) {
      lengths[CODE_LENGTH_ORDER[index]] = 0;
    }
    construct(this.lencode, lengths, 19);

    let index = 0;
    while (index < nlen + ndist) {
      let symbol = this.decode(this.lencode);
      if (symbol < 16) {
        lengths[index] = symbol;
        index++;
      } else {
        let len = 0;
        if (symbol === 16) {
          if (index === 0) {
            throw new Error('inflate: 重复码长前没有可用码长');
          }
          len = lengths[index - 1];
          symbol = 3 + this.bits(2);
        } else if (symbol === 17) {
          symbol = 3 + this.bits(3);
        } else {
          symbol = 11 + this.bits(7);
        }
        if (index + symbol > nlen + ndist) {
          throw new Error('inflate: 重复码长次数越界');
        }
        while (symbol > 0) {
          lengths[index] = len;
          index++;
          symbol--;
        }
      }
    }

    construct(this.lencode, lengths, nlen);
    construct(this.distcode, lengths.slice(nlen, nlen + ndist), ndist);
  }

  /** 解 literal / length + distance 序列，直到遇到块结束码 256 */
  private codes(): void {
    while (true) {
      let symbol = this.decode(this.lencode);
      if (symbol < 256) {
        this.ensure(1);
        this.out[this.outLen] = symbol;
        this.outLen++;
      } else if (symbol > 256) {
        symbol -= 257;
        if (symbol >= 29) {
          throw new Error('inflate: 非法长度码');
        }
        const len = LENGTH_BASE[symbol] + this.bits(LENGTH_EXTRA[symbol]);

        symbol = this.decode(this.distcode);
        if (symbol >= MAXDCODES) {
          throw new Error('inflate: 非法距离码');
        }
        const dist = DIST_BASE[symbol] + this.bits(DIST_EXTRA[symbol]);
        if (dist > this.outLen) {
          throw new Error('inflate: 距离超出已解出数据长度');
        }

        this.ensure(len);
        let from = this.outLen - dist;
        for (let i = 0; i < len; i++) {
          // 允许重叠拷贝（LZ77），必须逐字节复制
          this.out[this.outLen] = this.out[from];
          this.outLen++;
          from++;
        }
      } else {
        return;
      }
    }
  }

  /** 解压全部 deflate 块；中途失败抛错，已产出的数据由 inflateZlib 决定是否保留 */
  inflate(): void {
    let last = 0;
    do {
      last = this.bits(1);
      const type = this.bits(2);
      if (type === 0) {
        this.stored();
      } else if (type === 1) {
        this.fixed();
        this.codes();
      } else if (type === 2) {
        this.dynamic();
        this.codes();
      } else {
        throw new Error('inflate: 非法块类型 3');
      }
    } while (last === 0);
  }
}

/** zlib 解压结果；partial 为 true 表示流中途出错，data 是已解出的部分数据 */
export class InflateResult {
  data: Uint8Array = new Uint8Array(0);
  partial: boolean = false;
  reason: string = '';
}

/**
 * 解压 RFC1950 zlib 包装的数据。不抛异常；头校验失败且无产出时 data 为空。
 */
export function inflateZlib(bytes: Uint8Array): InflateResult {
  const result = new InflateResult();
  if (bytes.length < 2) {
    result.reason = '数据不足 2 字节，没有 zlib 头';
    return result;
  }
  const cmf = bytes[0];
  const flg = bytes[1];
  if ((cmf & 0x0f) !== 8) {
    result.reason = 'zlib CM 不是 8（deflate）';
    return result;
  }
  if ((((cmf << 8) | flg) % 31) !== 0) {
    result.reason = 'zlib 头校验（FCHECK）失败';
    return result;
  }
  if ((flg & 0x20) !== 0) {
    result.reason = '不支持带预置字典（FDICT）的 zlib 流';
    return result;
  }

  const inflater = new Inflater(bytes.subarray(2));
  try {
    inflater.inflate();
  } catch (error) {
    const e = error as Error;
    if (inflater.getOutLen() === 0) {
      result.reason = e.message;
      return result;
    }
    result.partial = true;
    result.reason = e.message;
  }
  result.data = inflater.takeOutput();
  return result;
}
