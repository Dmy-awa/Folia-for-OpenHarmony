/**
 * Folia HarmonyOS - 窗口与设备适配
 *
 * 职责：
 *  1. 进入页面时锁定横屏（手机 / 平板生效）。
 *  2. 打开沉浸式全屏布局，隐藏状态栏与导航栏。
 *  3. 监听窗口尺寸变化，把窗口宽度换算成 vp 后更新全局断点状态。
 *  4. 处理安全区（挖孔屏 / 刘海）。
 *
 * 重要差异（PC / 2in1）：
 *  - 2in1 默认是自由窗口，`setPreferredOrientation` 调用不报错但**不生效**，
 *    因此 PC 上不要依赖方向锁，布局必须能接受任意宽高比。
 *  - `getWindowAvoidArea` 在 PC / 2in1 自由窗口下返回**空避让区**，
 *    代码必须容忍空值，不能假设一定拿到刘海高度。
 */
import { window } from '@kit.ArkUI';
import { display } from '@kit.ScreenManager';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Logger } from '../core/Logger';
import { Breakpoint, resolveBreakpoint } from './Breakpoints';
import { AppUiState } from '../state/AppUiState';

const TAG: string = 'WindowAdapter';

/** 设备形态，用于布局策略分支 */
export enum DeviceForm {
  PHONE = 'phone',
  TABLET = 'tablet',
  PC = 'pc',
  UNKNOWN = 'unknown'
}

export class WindowAdapter {
  private mainWindow: window.Window | undefined = undefined;
  private density: number = 1;
  private sizeListener: ((size: window.Size) => void) | undefined = undefined;

  /** 当前设备形态；主屏宽度 >= 840vp 且设备类型为 2in1 时判定为 PC */
  private deviceForm: DeviceForm = DeviceForm.UNKNOWN;

  getDeviceForm(): DeviceForm {
    return this.deviceForm;
  }

  /** 是否运行在 PC / 2in1 上；决定是否跳过横屏锁定与沉浸式 */
  isDesktop(): boolean {
    return this.deviceForm === DeviceForm.PC;
  }

  /**
   * 在 EntryAbility.onWindowStageCreate 中调用。
   * 完成方向、沉浸式、尺寸监听的初始化。
   */
  async attach(windowStage: window.WindowStage, uiState: AppUiState): Promise<void> {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (error) {
      Logger.err(TAG, 'getMainWindowSync', error as Error);
      return;
    }

    this.resolveDeviceForm();
    this.resolveDensity();

    await this.lockLandscape();
    await this.enableImmersive();

    // 首次同步一次尺寸，避免首帧布局抖动
    this.syncSize(this.mainWindow.getWindowProperties().windowRect.width,
      this.mainWindow.getWindowProperties().windowRect.height, uiState);

    this.bindSizeChange(uiState);
    Logger.info(TAG, `attached, deviceForm=${this.deviceForm}, density=${this.density}`);
  }

  /** 设备形态判定：2in1 即 PC / 鸿蒙电脑 */
  private resolveDeviceForm(): void {
    const type = deviceInfo.deviceType;
    if (type === '2in1') {
      this.deviceForm = DeviceForm.PC;
    } else if (type === 'tablet') {
      this.deviceForm = DeviceForm.TABLET;
    } else if (type === 'phone') {
      this.deviceForm = DeviceForm.PHONE;
    } else {
      this.deviceForm = DeviceForm.UNKNOWN;
    }
    Logger.info(TAG, `deviceType=${type}`);
  }

  private resolveDensity(): void {
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.density = defaultDisplay.densityPixels > 0 ? defaultDisplay.densityPixels : 1;
    } catch (error) {
      Logger.err(TAG, 'getDefaultDisplaySync', error as Error);
      this.density = 1;
    }
  }

  /**
   * 锁定横屏。
   * PC / 2in1 为自由窗口，方向锁不生效，直接跳过以免产生误导性日志。
   */
  private async lockLandscape(): Promise<void> {
    const win = this.mainWindow;
    if (win === undefined) {
      return;
    }
    if (this.isDesktop()) {
      Logger.info(TAG, 'desktop device, skip orientation lock');
      return;
    }
    try {
      await win.setPreferredOrientation(window.Orientation.LANDSCAPE);
      Logger.info(TAG, 'landscape locked');
    } catch (error) {
      // 部分设备/窗口模式不支持方向锁，此处降级为「尽力而为」
      Logger.err(TAG, 'setPreferredOrientation', error as Error);
    }
  }

  /** 沉浸式全屏：内容延伸到状态栏与导航栏区域 */
  private async enableImmersive(): Promise<void> {
    const win = this.mainWindow;
    if (win === undefined) {
      return;
    }
    try {
      await win.setWindowLayoutFullScreen(true);
    } catch (error) {
      Logger.err(TAG, 'setWindowLayoutFullScreen', error as Error);
    }
    try {
      // PC 上系统栏概念不同，空数组不会报错但也不一定有意义
      await win.setWindowSystemBarEnable([]);
    } catch (error) {
      Logger.err(TAG, 'setWindowSystemBarEnable', error as Error);
    }
    try {
      const barProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      };
      await win.setWindowSystemBarProperties(barProps);
    } catch (error) {
      Logger.err(TAG, 'setWindowSystemBarProperties', error as Error);
    }
  }

  /** 安全区：PC / 2in1 返回空值，属于预期行为 */
  private readSafeArea(): window.AvoidArea | undefined {
    const win = this.mainWindow;
    if (win === undefined) {
      return undefined;
    }
    try {
      return win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    } catch (error) {
      Logger.err(TAG, 'getWindowAvoidArea', error as Error);
      return undefined;
    }
  }

  private bindSizeChange(uiState: AppUiState): void {
    const win = this.mainWindow;
    if (win === undefined) {
      return;
    }
    this.sizeListener = (size: window.Size) => {
      this.syncSize(size.width, size.height, uiState);
    };
    try {
      win.on('windowSizeChange', this.sizeListener);
    } catch (error) {
      Logger.err(TAG, 'on windowSizeChange', error as Error);
    }
  }

  /** windowSizeChange 回调返回的单位是 px，这里换算成 vp 后再驱动布局 */
  private syncSize(widthPx: number, heightPx: number, uiState: AppUiState): void {
    const widthVp = widthPx / this.density;
    const heightVp = heightPx / this.density;
    uiState.updateSize(widthVp, heightVp, resolveBreakpoint(widthVp));

    const avoid = this.readSafeArea();
    if (avoid !== undefined) {
      uiState.updateSafeArea(
        avoid.topRect.height / this.density,
        avoid.bottomRect.height / this.density,
        avoid.leftRect.width / this.density,
        avoid.rightRect.width / this.density
      );
    } else {
      uiState.updateSafeArea(0, 0, 0, 0);
    }
  }

  /** 保持屏幕常亮；仅播放页调用，离开时务必关闭 */
  async setKeepScreenOn(on: boolean): Promise<void> {
    const win = this.mainWindow;
    if (win === undefined) {
      return;
    }
    try {
      await win.setWindowKeepScreenOn(on);
    } catch (error) {
      Logger.err(TAG, 'setWindowKeepScreenOn', error as Error);
    }
  }

  /** 退出播放页时复位屏幕常亮 */
  async releaseKeepScreenOn(): Promise<void> {
    await this.setKeepScreenOn(false);
  }

  detach(): void {
    const win = this.mainWindow;
    if (win !== undefined && this.sizeListener !== undefined) {
      try {
        win.off('windowSizeChange', this.sizeListener);
      } catch (error) {
        Logger.err(TAG, 'off windowSizeChange', error as Error);
      }
    }
    this.sizeListener = undefined;
    this.mainWindow = undefined;
  }

  getMainWindow(): window.Window | undefined {
    return this.mainWindow;
  }
}

export const windowAdapter: WindowAdapter = new WindowAdapter();

/** 供 UI 层直接使用的断点标签 */
export function breakpointLabel(breakpoint: Breakpoint): string {
  return breakpoint as string;
}
