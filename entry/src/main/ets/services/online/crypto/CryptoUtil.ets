/**
 * Folia HarmonyOS - 加密 / 编码工具
 *
 * 只实现在线 provider 真正需要的最小集合，全部基于系统能力：
 *   - MD5        : @kit.CryptoArchitectureKit 的 cryptoFramework.createMd('MD5')
 *   - 随机字节    : cryptoFramework.createRandom().generateRandomSync(n)
 *   - UTF-8 编解码: @kit.ArkTS 的 util.TextEncoder / util.TextDecoder
 *   - Base64     : @kit.ArkTS 的 util.Base64Helper
 *   - hex 编解码  : 手写（比引 buffer polyfill 更稳，也避免额外依赖）
 *
 * ⚠️ 这里的函数是同步的：酷狗签名需要「连续同步计算 MD5 再拼串」，
 *    若改成 async 会让整条签名链变成 Promise 地狱。
 *
 * ⚠️ 本文件不实现任何 AES / RSA（网易云的 weapi/eapi 常量不在上游仓库里，
 *    见移植规范 §3.1.5 与附录 B，禁止臆造）。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../../../core/Logger';

const TAG: string = 'CryptoUtil';

/** 复用同一个 TextEncoder（无状态，可安全共享） */
const TEXT_ENCODER: util.TextEncoder = new util.TextEncoder();

/** UTF-8 字符串 → 字节数组 */
export function utf8Encode(text: string): Uint8Array {
  return TEXT_ENCODER.encodeInto(text);
}

/** 字节数组 → UTF-8 字符串；解码失败时返回空串（调用方按「无内容」处理） */
export function utf8Decode(bytes: Uint8Array): string {
  try {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(bytes);
  } catch (error) {
    Logger.err(TAG, 'utf8Decode', error as Error);
    return '';
  }
}

/** 字节数组 → 小写 hex 字符串 */
export function bytesToHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let index = 0; index < bytes.length; index++) {
    const value: number = bytes[index];
    out += value < 16 ? `0${value.toString(16)}` : value.toString(16);
  }
  return out;
}

/** 小写 hex 字符串 → 字节数组；非法字符按 0 处理 */
export function hexToBytes(hex: string): Uint8Array {
  const length: number = Math.floor(hex.length / 2);
  const bytes: Uint8Array = new Uint8Array(length);
  for (let index = 0; index < length; index++) {
    const parsed: number = Number.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
    bytes[index] = Number.isNaN(parsed) ? 0 : parsed;
  }
  return bytes;
}

/**
 * MD5 十六进制小写。
 * 这是 Subsonic token 与酷狗签名的基础原语，**必须保持十六进制小写**。
 */
export function md5Hex(text: string): string {
  const md: cryptoFramework.Md = cryptoFramework.createMd('MD5');
  md.updateSync({ data: utf8Encode(text) });
  const digest: cryptoFramework.DataBlob = md.digestSync();
  return bytesToHex(digest.data);
}

/**
 * 生成 `byteLength` 字节的随机数并转成小写 hex（salt / 设备随机串用）。
 * ⚠️ 未确认：加密安全随机数不可用时的降级路径（仅用于 salt 与设备标识，不用于密钥材料）；
 *    真机上 createRandom() 正常可用，降级分支只是避免整个在线层因为随机源异常而不可用。
 */
export function randomHex(byteLength: number): string {
  const safeLength: number = byteLength < 1 ? 1 : Math.floor(byteLength);
  try {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = random.generateRandomSync(safeLength);
    return bytesToHex(blob.data);
  } catch (error) {
    Logger.err(TAG, 'randomHex', error as Error);
    let fallback: string = '';
    for (let index = 0; index < safeLength; index++) {
      const value: number = Math.floor(Math.random() * 256);
      fallback += value < 16 ? `0${value.toString(16)}` : value.toString(16);
    }
    return fallback;
  }
}

/** 字符串 → Base64（UTF-8） */
export function base64EncodeText(text: string): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(utf8Encode(text));
}

/** Base64 → UTF-8 字符串 */
export function base64DecodeToText(base64: string): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return utf8Decode(helper.decodeSync(base64));
}

/** 字节数组 → Base64 */
export function base64EncodeBytes(bytes: Uint8Array): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

/** Base64 → 字节数组 */
export function base64DecodeToBytes(base64: string): Uint8Array {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.decodeSync(base64);
}

/** 生成不带连字符的大写 32 位 hex（对应 Node 的 crypto.randomUUID().replace(/-/g,'').toUpperCase()） */
export function randomUpperHexUuid(): string {
  try {
    return util.generateRandomUUID(true).replace(/-/g, '').toUpperCase();
  } catch (error) {
    Logger.err(TAG, 'randomUpperHexUuid', error as Error);
    return randomHex(16).toUpperCase();
  }
}

/**
 * 十六进制字符串 → 十进制字符串（大数），用于酷狗 lite 设备 cookie 的
 * `KUGOU_API_MID = BigInt('0x'+md5(guid)).toString(10)` 这类换算。
 * ArkTS 的 BigInt 支持情况需实测（移植规范 §3.2.6），因此这里手写十进制大数乘法。
 */
export function hexToDecimalString(hex: string): string {
  const normalized: string = hex.replace(/^0x/i, '').toLowerCase();
  let digits: number[] = [0];
  for (let index = 0; index < normalized.length; index++) {
    const value: number = Number.parseInt(normalized.charAt(index), 16);
    if (Number.isNaN(value)) {
      continue;
    }
    let carry: number = value;
    for (let digitIndex = 0; digitIndex < digits.length; digitIndex++) {
      const current: number = digits[digitIndex] * 16 + carry;
      digits[digitIndex] = current % 10;
      carry = Math.floor(current / 10);
    }
    while (carry > 0) {
      digits.push(carry % 10);
      carry = Math.floor(carry / 10);
    }
  }
  let out: string = '';
  for (let index = digits.length - 1; index >= 0; index--) {
    out += digits[index].toString(10);
  }
  // 去掉前导零
  let start: number = 0;
  while (start < out.length - 1 && out.charAt(start) === '0') {
    start++;
  }
  return out.substring(start);
}
