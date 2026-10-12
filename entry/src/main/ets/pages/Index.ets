/**
 * Folia HarmonyOS - 应用入口页
 *
 * 页面本身只做两件事：
 *   1. 把全局 UI 状态（窗口尺寸 / 断点 / 安全区）交给 AppShell；
 *   2. 承载最深层的背景色，避免首帧闪白。
 *
 * 真正的窗口适配（横屏锁定、沉浸式、尺寸监听）在 EntryAbility + WindowAdapter 完成。
 */
import { AppShell } from '../views/shell/AppShell';
import { appUiState } from '../state/AppUiState';

@Entry
@ComponentV2
struct Index {
  build() {
    Stack() {
      AppShell({ ui: appUiState })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
