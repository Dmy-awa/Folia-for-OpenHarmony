/**
 * Folia HarmonyOS - AbilityStage
 *
 * 应用级最早入口。这里刻意保持**极简**：
 *   - 只做与 UI 无关的轻量初始化与生命周期日志；
 *   - 不做崩溃兜底：`errorManager.on('unhandledRejection')` 是 API 19+，
 *     本工程目标 API 14 不可用；`errorManager.on('error')` 虽可用，但
 *     ErrorObserver 的接口定义不在当前 SDK 声明集内，无法核实签名，
 *     与其猜一个可能编译不过的写法，不如留给后续在真机上验证后再加。
 *
 * 重活（曲库、在线服务、播放器、媒体会话）都放在 EntryAbility 的
 * onWindowStageCreate 之后异步启动，避免拖慢启动页展示。
 */
import { AbilityStage } from '@kit.AbilityKit';
import { Logger } from '../core/Logger';

const TAG: string = 'AppAbilityStage';

export default class AppAbilityStage extends AbilityStage {
  onCreate(): void {
    Logger.info(TAG, 'AbilityStage created');
  }

  onDestroy(): void {
    Logger.info(TAG, 'AbilityStage destroyed');
  }
}
