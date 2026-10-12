/**
 * Folia HarmonyOS - 入口 Ability
 *
 * 启动流程：
 *   1. onWindowStageCreate 先完成窗口适配（锁定横屏 + 沉浸式），再 loadContent。
 *      方向必须在页面加载前设置，否则首帧会以竖屏布局渲染后立刻旋转，出现明显跳变。
 *   2. loadContent 完成后异步启动业务初始化（曲库 / 在线 / 播放器 / 媒体会话），
 *      不阻塞首帧。
 */
import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../core/Logger';
import { windowAdapter } from '../utils/WindowAdapter';
import { appUiState } from '../state/AppUiState';
import { bootApp, appBootstrap } from '../app/AppBootstrap';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, `onCreate, reason=${launchParam.launchReason}`);
  }

  onDestroy(): void {
    Logger.info(TAG, 'onDestroy');
    appBootstrap.shutdown();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 1) 先适配窗口：横屏锁 + 沉浸式 + 尺寸监听
    windowAdapter.attach(windowStage, appUiState)
      .then(() => {
        Logger.info(TAG, 'window adapted');
      })
      .catch((error: Error) => {
        Logger.err(TAG, 'windowAdapter.attach', error);
      });

    // 2) 再加载页面
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(TAG, `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(TAG, 'content loaded');
      // 3) 页面就绪后启动业务初始化
      bootApp(this.context).catch((error: Error) => {
        Logger.err(TAG, 'bootApp', error);
      });
    });
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG, 'onWindowStageDestroy');
    windowAdapter.detach();
  }

  onForeground(): void {
    Logger.info(TAG, 'onForeground');
  }

  onBackground(): void {
    // 播放相关的后台处理由播放控制器负责，这里不暂停播放
    Logger.info(TAG, 'onBackground');
  }

  /**
   * 跨端迁移。当前只在同一设备上同意迁移，不做数据搬迁，
   * 播放状态由 AVSession 与长时任务在源端负责收尾。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    Logger.info(TAG, 'onContinue');
    return AbilityConstant.OnContinueResult.AGREE;
  }
}
