/**
 * Folia HarmonyOS - 全局常量
 *
 * 这里放需要与配置文件保持一致的常量。改动 bundleName / 入口 Ability 名时
 * 必须同步修改 AppScope/app.json5 与 entry/src/main/module.json5。
 */

/** 应用包名，必须与 AppScope/app.json5 的 app.bundleName 一致 */
export const BUNDLE_NAME: string = 'top.izuna.foliamajor.hmos';

/** 入口 UIAbility 名，必须与 entry/src/main/module.json5 的 abilities[0].name 一致 */
export const ENTRY_ABILITY_NAME: string = 'EntryAbility';

/** AVSession 标签；系统用 tag 区分同一应用内的多个会话 */
export const AVSESSION_TAG: string = 'folia_music';

/** 播控中心队列标题 */
export const QUEUE_TITLE: string = 'Folia 播放队列';

/** 歌词时间轴偏移的上下限，毫秒（与上游一致） */
export const MAX_LYRIC_OFFSET_MS: number = 2000;
