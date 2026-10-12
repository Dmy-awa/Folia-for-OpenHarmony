/**
 * Folia HarmonyOS - 在线服务 HTTP 传输层
 *
 * 对 `@kit.NetworkKit`（`http.createHttp()` / `http.HttpRequestOptions` / `http.RequestMethod`）
 * 做一层薄封装，供三个 provider 共用。职责边界（移植规范 §2.2）：
 *   - 只负责「发请求 + 拿文本 + 统一错误 + 重试退避」，不做任何签名或业务归一化；
 *   - 签名逻辑属于各 provider 自己的 transport 部分，不在这层。
 *
 * 硬性要求：
 *   1. 每次请求都 `destroy()`（放在 finally 里，异常路径也不泄漏）。
 *   2. 网络类错误最多重试 2 次（指数退避 + 抖动）；HTTP 状态错误只有 5xx/429 才重试。
 *   3. 任何异常出口都是 `HttpError`，由 `toProviderError()` 转成 ProviderError，
 *      绝不允许把系统 raw error 抛给上层。
 *   4. **不打印完整 URL**（可能带 t/token/signature/cookie 等凭据）。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import { ProviderError, ProviderId } from '../../core/Types';
import { utf8Decode } from './crypto/CryptoUtil';
import { ProviderCodes } from './OnlineProvider';

const TAG: string = 'HttpTransport';

/** 默认连接超时：10s（对齐上游 DEFAULT_OPERATION_TIMEOUT_MS） */
const DEFAULT_CONNECT_TIMEOUT_MS: number = 10000;
/** 默认读取超时：15s */
const DEFAULT_READ_TIMEOUT_MS: number = 15000;
/** 网络类错误的额外重试次数（不含首次请求） */
const DEFAULT_RETRY_COUNT: number = 2;
/** 退避基数：第 n 次重试等待 base * 2^n + 抖动 */
const RETRY_BASE_DELAY_MS: number = 300;
/** 退避抖动上限 */
const RETRY_JITTER_MS: number = 120;

/** 单个 query 参数：用数组而不是 Record，保证顺序可控，也不会出现 undefined 值 */
export interface HttpParam {
  key: string;
  value: string;
}

/** 统一响应形状 */
export interface HttpResponse {
  status: number;
  body: string;
  headers: Record<string, string>;
}

/** 请求方法（只用到 GET/POST） */
export enum HttpMethod {
  GET = 'GET',
  POST = 'POST'
}

/** HTTP 层错误分类 */
export enum HttpErrorKind {
  /** DNS 失败 / 连接被拒 / 连接被重置 */
  NETWORK = 'network',
  /** 连接或读取超时 */
  TIMEOUT = 'timeout',
  /** 拿到了响应但状态码非 200（allowNonOk 为 false 时） */
  STATUS = 'status',
  /** 响应体无法解码 */
  PARSE = 'parse'
}

/** 传输层统一错误 */
export class HttpError extends Error {
  readonly kind: HttpErrorKind;
  readonly status: number;
  readonly retryable: boolean;

  constructor(kind: HttpErrorKind, message: string, status: number = 0, retryable: boolean = false) {
    super(message);
    this.kind = kind;
    this.status = status;
    this.retryable = retryable;
  }
}

/** 请求描述 */
export interface HttpRequestSpec {
  url: string;
  method: HttpMethod;
  params?: HttpParam[];
  headers?: Record<string, string>;
  /** POST 原始请求体（字符串） */
  body?: string;
  connectTimeoutMs?: number;
  readTimeoutMs?: number;
  /** 额外重试次数，默认 2；传 0 表示不重试 */
  retryCount?: number;
  /**
   * 是否容忍非 200 状态码。
   * 网易云本地 API「不看 HTTP 状态，只看 body 的 code」（移植规范 §3.1.4），
   * 该 provider 必须打开这个开关，否则非 200 时拿不到 body。
   */
  allowNonOk?: boolean;
}

/** 追加一个 query 参数 */
export function addParam(list: HttpParam[], key: string, value: string): void {
  list.push({ key: key, value: value });
}

/** 把 source 的全部参数追加到 target */
export function mergeParams(target: HttpParam[], source: HttpParam[]): void {
  for (let index = 0; index < source.length; index++) {
    target.push(source[index]);
  }
}

/** 拼接 query 串；key/value 都做 URL 编码 */
export function buildQueryString(params: HttpParam[]): string {
  const parts: string[] = [];
  for (let index = 0; index < params.length; index++) {
    const param: HttpParam = params[index];
    parts.push(`${encodeURIComponent(param.key)}=${encodeURIComponent(param.value)}`);
  }
  return parts.join('&');
}

/** 把 query 串接到 URL 上（自动判断 ? / &） */
export function appendQuery(url: string, query: string): string {
  if (query.length === 0) {
    return url;
  }
  return url.indexOf('?') >= 0 ? `${url}&${query}` : `${url}?${query}`;
}

/** 去掉 URL 末尾的 `/`，便于统一拼 `/rest/...` */
export function trimTrailingSlash(url: string): string {
  let result: string = url;
  while (result.length > 0 && result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/** HTTP 客户端 */
export class HttpTransport {
  /**
   * 发起请求（含重试）。
   * @throws HttpError 所有失败路径都以 HttpError 抛出
   */
  static async request(spec: HttpRequestSpec): Promise<HttpResponse> {
    const retryCount: number = spec.retryCount === undefined ? DEFAULT_RETRY_COUNT : spec.retryCount;
    const maxAttempts: number = (retryCount < 0 ? 0 : retryCount) + 1;
    let lastError: HttpError = new HttpError(HttpErrorKind.NETWORK, '网络请求失败', 0, true);

    for (let attemptIndex = 0; attemptIndex < maxAttempts; attemptIndex++) {
      try {
        return await HttpTransport.attempt(spec);
      } catch (error) {
        const httpError: HttpError = HttpTransport.toHttpError(error as Error);
        lastError = httpError;
        const isLastAttempt: boolean = attemptIndex === maxAttempts - 1;
        if (!httpError.retryable || isLastAttempt) {
          throw httpError;
        }
        const delayMs: number =
          RETRY_BASE_DELAY_MS * Math.pow(2, attemptIndex) + Math.floor(Math.random() * RETRY_JITTER_MS);
        // 日志里只出现错误分类，不出现 URL（URL 可能带 token / signature / cookie）
        Logger.warn(TAG, `请求失败（${httpError.kind}），${delayMs}ms 后重试 ${attemptIndex + 1}/${retryCount}`);
        await HttpTransport.sleep(delayMs);
      }
    }
    throw lastError;
  }

  /** GET 便捷入口 */
  static get(url: string, params: HttpParam[], headers?: Record<string, string>): Promise<HttpResponse> {
    const spec: HttpRequestSpec = {
      url: url,
      method: HttpMethod.GET,
      params: params,
      headers: headers
    };
    return HttpTransport.request(spec);
  }

  /** POST JSON 便捷入口 */
  static postJson(
    url: string,
    body: string,
    headers?: Record<string, string>,
    params?: HttpParam[]
  ): Promise<HttpResponse> {
    const mergedHeaders: Record<string, string> = { 'Content-Type': 'application/json' };
    if (headers !== undefined) {
      const keys: string[] = Object.keys(headers);
      for (let index = 0; index < keys.length; index++) {
        mergedHeaders[keys[index]] = headers[keys[index]];
      }
    }
    const spec: HttpRequestSpec = {
      url: url,
      method: HttpMethod.POST,
      params: params,
      headers: mergedHeaders,
      body: body
    };
    return HttpTransport.request(spec);
  }

  /** 单次请求（无重试），每次都保证 destroy() */
  private static async attempt(spec: HttpRequestSpec): Promise<HttpResponse> {
    const request: http.HttpRequest = http.createHttp();
    try {
      let params: HttpParam[] = [];
      if (spec.params !== undefined) {
        params = spec.params;
      }
      let headers: Record<string, string> = {};
      if (spec.headers !== undefined) {
        headers = spec.headers;
      }
      const url: string = appendQuery(spec.url, buildQueryString(params));
      const options: http.HttpRequestOptions = {
        method: spec.method === HttpMethod.POST ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        connectTimeout: spec.connectTimeoutMs === undefined ? DEFAULT_CONNECT_TIMEOUT_MS : spec.connectTimeoutMs,
        readTimeout: spec.readTimeoutMs === undefined ? DEFAULT_READ_TIMEOUT_MS : spec.readTimeoutMs,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        extraData: spec.body
      };

      const response: http.HttpResponse = await request.request(url, options);
      const status: number = response.responseCode;
      const body: string = HttpTransport.bodyToString(response.result);
      const responseHeaders: Record<string, string> = HttpTransport.collectHeaders(response.header);

      if (status !== 200 && spec.allowNonOk !== true) {
        const retryable: boolean = status >= 500 || status === 429;
        throw new HttpError(HttpErrorKind.STATUS, `服务器返回 HTTP ${status}`, status, retryable);
      }
      if (status !== 200) {
        // allowNonOk：状态码交给上层按业务码判断，这里只留一行可观测日志（不含 URL）
        Logger.warn(TAG, `HTTP ${status}，但调用方要求忽略状态码`);
      }
      const result: HttpResponse = { status: status, body: body, headers: responseHeaders };
      return result;
    } finally {
      request.destroy();
    }
  }

  /** 把任意异常收敛成 HttpError */
  static toHttpError(error: Error): HttpError {
    if (error instanceof HttpError) {
      return error;
    }
    const businessError: BusinessError = error as BusinessError;
    // 2300028 = 连接/读取超时；2300006/2300007/2300008 = DNS 失败 / 连接失败 / 网络不可用
    const code: number = businessError.code === undefined ? 0 : businessError.code;
    const isTimeout: boolean = code === 2300028;
    const detail: string = error.message === undefined ? '未知原因' : error.message;
    const kind: HttpErrorKind = isTimeout ? HttpErrorKind.TIMEOUT : HttpErrorKind.NETWORK;
    const message: string = isTimeout ? `网络请求超时（${detail}）` : `网络请求失败（错误码 ${code}：${detail}）`;
    return new HttpError(kind, message, 0, true);
  }

  /** 响应体 → 字符串（expectDataType 已是 STRING，这里只做兜底） */
  private static bodyToString(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return utf8Decode(new Uint8Array(result));
    }
    return JSON.stringify(result);
  }

  /**
   * 响应头 → Record<string,string>。
   * `http.HttpResponse.header` 的静态类型是 Object，只能先收窄成 Record 再遍历；个别平台
   * 会混入非字符串值，所以逐项 try 掉，收集失败不影响主流程。
   */
  private static collectHeaders(raw: Object | undefined): Record<string, string> {
    const out: Record<string, string> = {};
    if (raw === undefined || raw === null) {
      return out;
    }
    try {
      const record: Record<string, Object> = raw as Record<string, Object>;
      const keys: string[] = Object.keys(record);
      for (let index = 0; index < keys.length; index++) {
        const key: string = keys[index];
        const value: Object = record[key];
        if (value === undefined || value === null) {
          continue;
        }
        out[key] = `${value}`;
      }
    } catch (error) {
      Logger.warn(TAG, '响应头解析失败，已忽略');
    }
    return out;
  }

  /** 退避等待 */
  private static sleep(ms: number): Promise<void> {
    // 与官方文档一致：executor 形参不写类型，交由 ArkTS 上下文推断
    return new Promise<void>((resolve, reject) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

/**
 * HTTP 层异常 → ProviderError。
 * 所有 provider 的错误出口都走这里，保证：
 *   - 消息是中文、面向用户；
 *   - `retryable` 标记正确；
 *   - 不把系统 raw error 泄漏出去。
 */
export function toProviderError(providerId: ProviderId, scene: string, error: Error): ProviderError {
  if (error instanceof ProviderError) {
    return error;
  }
  const httpError: HttpError = HttpTransport.toHttpError(error);
  let code: string = ProviderCodes.NETWORK;
  let retryable: boolean = httpError.retryable;
  if (httpError.kind === HttpErrorKind.PARSE) {
    code = ProviderCodes.INVALID_RESPONSE;
    retryable = false;
  } else if (httpError.kind === HttpErrorKind.STATUS) {
    if (httpError.status === 401 || httpError.status === 403) {
      code = ProviderCodes.AUTH_REQUIRED;
      retryable = false;
    } else if (httpError.status === 404) {
      code = ProviderCodes.NOT_FOUND;
      retryable = false;
    } else {
      code = ProviderCodes.NETWORK;
      retryable = httpError.status >= 500 || httpError.status === 429;
    }
  }
  return new ProviderError(providerId, code, `${scene}失败：${httpError.message}`, retryable);
}
