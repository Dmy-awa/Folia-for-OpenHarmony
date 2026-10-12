/**
 * Folia HarmonyOS - 响应式断点
 *
 * 断点区间与 HarmonyOS 官方 GridRow / Navigation 的默认约定保持一致（按窗口宽度，单位 vp）：
 *   xs : [0, 320)
 *   sm : [320, 600)
 *   md : [600, 840)
 *   lg : [840, +∞)
 *
 * 本应用全局横屏，因此实际会落到的档位是：
 *   手机横屏  -> md / lg
 *   平板横屏  -> lg
 *   PC / 2in1 -> lg（自由窗口可能缩到 md）
 */

export enum Breakpoint {
  XS = 'xs',
  SM = 'sm',
  MD = 'md',
  LG = 'lg'
}

export function resolveBreakpoint(widthVp: number): Breakpoint {
  if (widthVp < 320) {
    return Breakpoint.XS;
  }
  if (widthVp < 600) {
    return Breakpoint.SM;
  }
  if (widthVp < 840) {
    return Breakpoint.MD;
  }
  return Breakpoint.LG;
}

/** 是否为紧凑宽度（需要收起侧栏、使用堆叠导航） */
export function isCompact(breakpoint: Breakpoint): boolean {
  return breakpoint === Breakpoint.XS || breakpoint === Breakpoint.SM;
}

/** 是否宽到可以并排显示「导航栏 + 内容区」——与 Navigation Split 的 600vp 阈值一致 */
export function supportsSplit(breakpoint: Breakpoint): boolean {
  return breakpoint === Breakpoint.MD || breakpoint === Breakpoint.LG;
}

/** 是否宽到可以并排显示「歌词舞台 + 侧边队列/信息栏」 */
export function supportsSidePanel(breakpoint: Breakpoint): boolean {
  return breakpoint === Breakpoint.LG;
}

/** 根据窗口宽度给出歌词字号，横屏大屏用更大的字以保证可读性 */
export function lyricFontSizeFor(widthVp: number, heightVp: number): number {
  const base = Math.min(widthVp * 0.045, heightVp * 0.11);
  return Math.max(20, Math.min(base, 56));
}
