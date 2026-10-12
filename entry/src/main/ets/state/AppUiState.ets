/**
 * Folia HarmonyOS - 全局 UI 状态
 *
 * 使用状态管理 V2（@ObservedV2 / @Trace）。
 * 这里只放「影响布局」的状态，播放与曲库状态在各自的 ViewModel 中。
 */
import { Breakpoint } from '../utils/Breakpoints';

@ObservedV2
export class AppUiState {
  /** 窗口宽度，vp */
  @Trace widthVp: number = 0;
  /** 窗口高度，vp */
  @Trace heightVp: number = 0;
  /** 当前断点 */
  @Trace breakpoint: Breakpoint = Breakpoint.MD;

  /** 安全区，vp；PC / 2in1 下恒为 0 */
  @Trace safeTop: number = 0;
  @Trace safeBottom: number = 0;
  @Trace safeLeft: number = 0;
  @Trace safeRight: number = 0;

  /** 应用是否已完成初始化（曲库、设置、播放会话就绪） */
  @Trace ready: boolean = false;
  /** 初始化过程中的错误信息，非空时首页展示错误态 */
  @Trace bootError: string = '';

  updateSize(widthVp: number, heightVp: number, breakpoint: Breakpoint): void {
    this.widthVp = widthVp;
    this.heightVp = heightVp;
    this.breakpoint = breakpoint;
  }

  updateSafeArea(top: number, bottom: number, left: number, right: number): void {
    // PC 自由窗口会返回空避让区，此时全部为 0 是正确行为
    this.safeTop = Number.isFinite(top) ? top : 0;
    this.safeBottom = Number.isFinite(bottom) ? bottom : 0;
    this.safeLeft = Number.isFinite(left) ? left : 0;
    this.safeRight = Number.isFinite(right) ? right : 0;
  }

  markReady(): void {
    this.ready = true;
    this.bootError = '';
  }

  markFailed(message: string): void {
    this.ready = true;
    this.bootError = message;
  }

  /** 横屏下左右留白的推荐值：手机窄一点，平板/PC 宽一点 */
  get horizontalPadding(): number {
    if (this.breakpoint === Breakpoint.LG) {
      return 32;
    }
    if (this.breakpoint === Breakpoint.MD) {
      return 24;
    }
    return 16;
  }
}

/** 进程内单例，供 Ability 与页面共享 */
export const appUiState: AppUiState = new AppUiState();
