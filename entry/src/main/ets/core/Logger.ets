/**
 * Folia HarmonyOS - 全局日志
 *
 * 统一通过 hilog 输出，域名固定为 0xF0A1（Folia）。
 * release 构建下 DEBUG 级别会被系统过滤，因此业务日志请优先使用 info 及以上。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xF0A1;
const PREFIX: string = 'Folia';

export class Logger {
  static debug(tag: string, message: string): void {
    hilog.debug(DOMAIN, PREFIX, '[%{public}s] %{public}s', tag, message);
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, PREFIX, '[%{public}s] %{public}s', tag, message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, PREFIX, '[%{public}s] %{public}s', tag, message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, PREFIX, '[%{public}s] %{public}s', tag, message);
  }

  /** 记录异常对象，附带错误码，避免各处重复拼接 */
  static err(tag: string, scene: string, error: Error): void {
    const e = error as Error & { code?: number };
    const code: string = e.code === undefined ? '-' : String(e.code);
    hilog.error(DOMAIN, PREFIX, '[%{public}s] %{public}s failed, code=%{public}s, message=%{public}s',
      tag, scene, code, e.message ?? 'unknown');
  }
}
