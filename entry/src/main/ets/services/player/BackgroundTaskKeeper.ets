/**
 * Folia HarmonyOS - 后台长时任务
 *
 * 音乐应用进入后台后要持续播放，必须申请「音频播放」类型的长时任务。
 *
 * 官方约束（已核实）：
 *  - 权限：ohos.permission.KEEP_BACKGROUND_RUNNING；
 *    同时 module.json5 的 abilities[] 必须声明 backgroundModes: ["audioPlayback"]，两者缺一不可。
 *  - API 14/15 使用 `backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK`。
 *    ⚠️ `BackgroundTaskMode.MODE_AUDIO_PLAYBACK` 是 API 21+ 的枚举，本工程不可用。
 *  - 单个 UIAbility 同时只能有一个长时任务：暂停时必须取消，恢复播放时重新申请。
 *  - 音频仍在播放却取消长时任务会被系统强制终止进程，因此取消与暂停必须成对。
 *  - STREAM_USAGE_MUSIC 场景必须同时接入 AVSession，否则后台播放会被静音冻结。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../core/Logger';
import { BUNDLE_NAME, ENTRY_ABILITY_NAME } from '../../core/Constants';

const TAG: string = 'BackgroundTaskKeeper';

/** 取消原因；API 15+ 才有 on('continuousTaskCancel') */
export const CANCEL_REASON_USER: number = 1;
export const CANCEL_REASON_SYSTEM: number = 2;

/** WantAgent 的拉起目标 */
interface AbilityTarget {
  bundleName: string;
  abilityName: string;
}

export interface ContinuousTaskObserver {
  /** 长时任务被系统或用户取消，应用应暂停播放 */
  onTaskCancelled(reason: number): void;
}

export class BackgroundTaskKeeper {
  private running: boolean = false;
  private observer: ContinuousTaskObserver | undefined = undefined;
  private cancelListener: ((info: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | undefined = undefined;

  setObserver(observer: ContinuousTaskObserver): void {
    this.observer = observer;
  }

  isRunning(): boolean {
    return this.running;
  }

  /**
   * 申请长时任务。
   * wantAgent 指向自身入口 Ability，系统点击后台任务通知时回到应用。
   */
  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    const info = this.resolveTarget(context);
    const agentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: info.bundleName,
          abilityName: info.abilityName
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    try {
      const agent: WantAgent = await wantAgent.getWantAgent(agentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.running = true;
      this.bindCancelListener();
      Logger.info(TAG, `background running started for ${info.bundleName}/${info.abilityName}`);
    } catch (error) {
      Logger.err(TAG, 'startBackgroundRunning', error as Error);
      this.running = false;
    }
  }

  /**
   * 解析通知要拉起的 Ability。
   * 优先用运行时的 abilityInfo（bundleName 改动后无需改代码），
   * 读取失败时退回 core/Constants 中的常量，保证长时任务仍能申请成功。
   */
  private resolveTarget(context: common.UIAbilityContext): AbilityTarget {
    try {
      const info = context.abilityInfo;
      if (info !== undefined && info.bundleName !== undefined && info.name !== undefined
        && info.bundleName.length > 0 && info.name.length > 0) {
        const target: AbilityTarget = { bundleName: info.bundleName, abilityName: info.name };
        return target;
      }
    } catch (error) {
      Logger.warn(TAG, `abilityInfo unavailable, falling back to constants: ${(error as Error).message}`);
    }
    const fallback: AbilityTarget = {
      bundleName: BUNDLE_NAME,
      abilityName: ENTRY_ABILITY_NAME
    };
    return fallback;
  }

  /** 注册取消监听；该事件 API 15+ 才有，低版本会抛错，此处静默降级 */
  private bindCancelListener(): void {
    if (this.cancelListener !== undefined) {
      return;
    }
    this.cancelListener = (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
      Logger.warn(TAG, `continuous task cancelled, reason=${info.reason}`);
      this.running = false;
      this.observer?.onTaskCancelled(info.reason);
    };
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelListener);
    } catch (error) {
      // API 15 以下不支持该事件，属于预期情况
      Logger.info(TAG, 'continuousTaskCancel not supported on this API level');
      this.cancelListener = undefined;
    }
  }

  private unbindCancelListener(): void {
    if (this.cancelListener === undefined) {
      return;
    }
    try {
      backgroundTaskManager.off('continuousTaskCancel', this.cancelListener);
    } catch (error) {
      Logger.err(TAG, 'off continuousTaskCancel', error as Error);
    }
    this.cancelListener = undefined;
  }

  /**
   * 取消长时任务。
   * 必须在音频暂停之后调用，否则会被系统判定为异常并终止进程。
   */
  async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      Logger.info(TAG, 'background running stopped');
    } catch (error) {
      const err = error as BusinessError;
      Logger.err(TAG, 'stopBackgroundRunning', err as Error);
    }
    this.running = false;
    this.unbindCancelListener();
  }
}

export const backgroundTaskKeeper: BackgroundTaskKeeper = new BackgroundTaskKeeper();
