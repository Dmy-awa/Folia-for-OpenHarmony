/**
 * Folia HarmonyOS - 酷狗 KRC 歌词解密（KrcDecoder）
 *
 * 上游对应实现：src/utils/lyrics/providers/krcDecrypt.ts
 *
 * 算法（三步，缺一不可）：
 *   1. 头部判定：前 4 字节必须是 ASCII "krc1"（107,114,99,49），与上游 hasKrcHeader 逐字一致；
 *   2. 丢掉前 4 字节，剩余字节与 16 字节静态密钥 KRC_KEY 做**循环 XOR**（key[i % 16]）；
 *   3. 对 XOR 结果做 **zlib 包装**的 INFLATE（RFC1950；上游用浏览器 DecompressionStream('deflate')，
 *      是 zlib 包装而非 raw deflate），再按 UTF-8 解码成明文。
 *      KRC **没有** base64 环节：酷狗接口 content 字段的 base64 由 fetchKugouLyrics 在调用前用
 *      atob 转成字节，本文件只接受字节。
 *   解密结果是明文原样串（形如 `[start,duration]字<start,duration>...`），本文件**不解析**，
 *   与上游 krcDecrypt 的返回语义完全一致，由上层歌词解析器负责解释。
 *
 * 关于解压 API 的选择（已核对本机 SDK D:\HarmonyOS_Development_API\23\ets\api\@ohos.zlib.d.ts）：
 *   任务说明假设存在 `zlib.decompressSync(input: Uint8Array): Uint8Array`，但该 SDK 中**不存在**任何
 *   同步的 ArrayBuffer 解压函数：API 12 起提供的是 `zlib.createZipSync()` 返回的 `Zip` 对象上的
 *   **异步** `uncompress(dest, source, sourceLen?): Promise<ZipOutputInfo>`（另有异步 Zip.uncompress2）。
 *   为保持 decryptKrc 的同步签名，本文件不走 zlib kit，而是逐行移植 zlib 自带示例程序 puff.c 的
 *   INFLATE 算法（public domain）作为纯 ArkTS 实现，只依赖 Uint8Array，不依赖任何平台 API。
 *
 * 失败一律返回空字符串（调用方以空串表示「无歌词」）并写日志，不向上抛异常。
 */
import { util } from '@kit.ArkTS';
import { Logger } from '../../core/Logger';

const TAG: string = 'KrcDecoder';

/** KRC 的 16 字节循环 XOR 密钥，逐字节照抄上游 krcDecrypt.ts 的 KRC_KEY（长度必须为 16） */
const KRC_KEY: Uint8Array = new Uint8Array([
  64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105
]);

/** KRC 头部 "krc1" 的四个字节（ASCII k=107, r=114, c=99, 1=49） */
const KRC_HEADER: number[] = [107, 114, 99, 49];

/**
 * 判定一段字节是否是加密的 KRC 负载。
 * 判定规则与上游 kugouLyricProvider.hasKrcHeader 完全一致：长度 >= 4 且前 4 字节为 "krc1"。
 */
export function isKrcPayload(data: Uint8Array): boolean {
  try {
    if (data.length < 4) {
      return false;
    }
    for (let i = 0; i < KRC_HEADER.length; i++) {
      if (data[i] !== KRC_HEADER[i]) {
        return false;
      }
    }
    return true;
  } catch {
    // 运行时拿到 undefined / null 时按「不是 KRC」处理，不抛异常
    return false;
  }
}

/**
 * 解密酷狗 KRC 字节流：跳过 "krc1" 头 -> 16 字节循环 XOR -> zlib inflate -> UTF-8。
 * 任意一步失败都返回空字符串。
 */
export function decryptKrc(data: Uint8Array): string {
  try {
    if (data.length <= 4) {
      // 与上游 `Invalid KRC data: too short` 对应，这里不抛异常，只记日志
      Logger.warn(TAG, 'KRC 数据过短（<= 4 字节），放弃解密');
      return '';
    }

    // 跳过前 4 字节头部 "krc1"
    const body = data.subarray(4);
    const decrypted = new Uint8Array(body.length);
    for (let i = 0; i < body.length; i++) {
      decrypted[i] = body[i] ^ KRC_KEY[i % KRC_KEY.length];
    }

    const inflated = inflateZlib(decrypted);
    if (inflated.partial) {
      // 与上游「读循环抛错但已收到数据时只告警并返回已有数据」一致
      Logger.warn(TAG, 'zlib 流中途出错，改用已解出的部分数据：' + inflated.reason);
    }
    if (inflated.data.length === 0) {
      Logger.error(TAG, 'KRC 解压结果为空，解密失败：' + inflated.reason);
      return '';
    }
    return decodeUtf8(inflated.data);
  } catch (error) {
    Logger.err(TAG, 'decryptKrc', error as Error);
    return '';
  }
}

/** UTF-8 解码，并去掉可能存在的 BOM（与上游 new TextDecoder('utf-8') + 去 BOM 的写法一致） */
function decodeUtf8(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes).replace(/^\uFEFF/, '');
}

/* =====================================================================================
 * 纯 ArkTS 的 INFLATE（DEFLATE / zlib 解压）
 *
 * 算法来源：zlib 自带示例程序 puff.c（public domain）的 inflate 实现，逐行移植：
 *   - 比特流 LSB 优先；
 *   - 三种块类型：0=stored、1=fixed Huffman、2=dynamic Huffman；
 *   - 霍夫曼表用 puff 的 count/symbol 规范解码法（decode/construct）；
 *   - 长度/距离基值与附加位表与 puff.c 相同。
 * 入口 inflateZlib 会先校验 RFC1950 的 zlib 头；尾部 4 字节 Adler-32 不校验
 * （与 puff.c 的 inf() 一致：最后一块读完后自然停止，尾部字节不再读取）。
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

/** 生成 n 个 0 的 number[]（ArkTS 下不用 Array.from / fill，避免回调类型推断问题） */
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

/**
 * 由码长数组构造霍夫曼表（puff.c construct）。
 * 码长全 0 视为空表（合法）；码长溢出（over-subscribed）抛错。
 */
function construct(h: Huffman, length: number[], n: number): void {
  for (let len = 0; len <= MAXBITS; len++) {
    h.count[len] = 0;
  }
  for (let symbol = 0; symbol < n; symbol++) {
    h.count[length[symbol]] = h.count[length[symbol]] + 1;
  }
  if (h.count[0] === n) {
    return; // 整表为空（例如没有距离码时）
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

/** 单个 deflate 流的解压状态机（对应 puff.c 的 state + huffman 表） */
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

  /** 块类型 0：非压缩存储块（puff.c stored） */
  private stored(): void {
    this.bitBuf = 0;
    this.bitCnt = 0; // 丢弃当前字节的剩余位，对齐到字节边界
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

  /** 块类型 1：固定霍夫曼表（puff.c fixed） */
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

  /** 块类型 2：动态霍夫曼表（puff.c dynamic） */
  private dynamic(): void {
    const lengths: number[] = zeros(MAXCODES);
    const nlen = this.bits(5) + 257;
    const ndist = this.bits(5) + 1;
    const ncode = this.bits(4) + 4;
    if (nlen > MAXLCODES || ndist > MAXDCODES) {
      throw new Error('inflate: 动态块码字数非法');
    }

    // 先读「码长码」的码长（3 位一组，按 CODE_LENGTH_ORDER 排列）
    for (let index = 0; index < ncode; index++) {
      lengths[CODE_LENGTH_ORDER[index]] = this.bits(3);
    }
    for (let index = ncode; index < CODE_LENGTH_ORDER.length; index++) {
      lengths[CODE_LENGTH_ORDER[index]] = 0;
    }
    construct(this.lencode, lengths, 19);

    // 再用「码长码」解出所有 literal/length 与 distance 的码长（16/17/18 为重复码）
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

  /** 解 literal / length + distance 序列，直到遇到块结束码 256（puff.c codes） */
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
          // 允许重叠拷贝（LZ77），因此必须逐字节复制
          this.out[this.outLen] = this.out[from];
          this.outLen++;
          from++;
        }
      } else {
        return; // 256 = 块结束
      }
    }
  }

  /** 解压全部 deflate 块；中途失败时抛错，已产出的数据由 inflateZlib 决定是否保留 */
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
 * 解压 RFC1950 zlib 包装的数据（上游 DecompressionStream('deflate') 的等价物）。
 * - 头校验失败 / 关键错误且无任何产出：data 为空、partial 为 false；
 * - 流中途出错但已有产出：partial 为 true（上游此时只告警并用已有数据）；
 * 不抛异常。
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

  // 从第 3 个字节开始就是 raw deflate 数据；尾部 4 字节 Adler-32 不读取也不校验
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
