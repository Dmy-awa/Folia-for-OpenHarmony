/**
 * Folia HarmonyOS - 应用外壳
 *
 * 横屏自适应布局：
 *   - 左侧固定宽度的导航栏（56~72vp），在大屏上展开为带文字的宽栏；
 *   - 右侧为内容区，由当前 tab 决定渲染哪个视图；
 *   - 底部常驻「正在播放」迷你条，点击回到播放页。
 *
 * 全局横屏下，手机横屏（约 640~900vp）走紧凑栏，平板 / PC（>=840vp）走展开栏。
 */
import { PlaybackStatus } from '../../core/Types';
import { AppUiState } from '../../state/AppUiState';
import { Breakpoint } from '../../utils/Breakpoints';
import { PlayerView } from '../PlayerView';
import { LibraryView } from '../LibraryView';
import { SearchView } from '../SearchView';
import { SettingsView } from '../SettingsView';
import { playbackController } from '../../services/player/PlaybackController';
import { settingsStore } from '../../services/settings/SettingsStore';
import { resolveTheme } from '../../components/lyrics/LyricTheme';

/** 导航项 */
export enum ShellTab {
  PLAYER = 0,
  LIBRARY = 1,
  SEARCH = 2,
  SETTINGS = 3
}

@ComponentV2
export struct AppShell {
  @Require @Param ui: AppUiState;

  @Local private tab: ShellTab = ShellTab.PLAYER;

  private controller = playbackController;

  /** 大屏展开导航栏并显示文字 */
  private expanded(): boolean {
    return this.ui.breakpoint === Breakpoint.LG;
  }

  private railWidth(): number {
    return this.expanded() ? 168 : 68;
  }

  private contentWidth(): number {
    return Math.max(0, this.ui.widthVp - this.railWidth());
  }

  build() {
    // build() 必须有唯一根容器，因此三种状态都放在同一个 Stack 里分支渲染
    Stack() {
      if (!this.ui.ready) {
        this.loadingState()
      } else if (this.ui.bootError.length > 0) {
        this.errorState()
      } else {
        Column() {
          Row() {
            this.navRail()
              .width(this.railWidth())
              .height('100%')

            Column() {
              Stack({ alignContent: Alignment.TopStart }) {
                if (this.tab === ShellTab.PLAYER) {
                  PlayerView({
                    breakpoint: this.ui.breakpoint,
                    safeTop: this.ui.safeTop,
                    safeBottom: this.ui.safeBottom,
                    stageWidth: this.contentWidth(),
                    stageHeight: Math.max(120, this.ui.heightVp - this.ui.safeTop - this.ui.safeBottom),
                    onOpenQueue: () => {
                      // 队列已在播放页右侧面板中展示，这里仅作为扩展点
                    }
                  })
                } else if (this.tab === ShellTab.LIBRARY) {
                  LibraryView({
                    breakpoint: this.ui.breakpoint,
                    safeTop: this.ui.safeTop,
                    safeBottom: this.ui.safeBottom,
                    width: this.contentWidth(),
                    height: this.ui.heightVp
                  })
                } else if (this.tab === ShellTab.SEARCH) {
                  SearchView({
                    breakpoint: this.ui.breakpoint,
                    safeTop: this.ui.safeTop,
                    safeBottom: this.ui.safeBottom,
                    width: this.contentWidth(),
                    height: this.ui.heightVp
                  })
                } else {
                  SettingsView({
                    safeTop: this.ui.safeTop,
                    safeBottom: this.ui.safeBottom,
                    width: this.contentWidth()
                  })
                }
              }
              .width('100%')
              .layoutWeight(1)

              // 迷你播放条：只在非播放页出现，避免与全屏播放页重复
              if (this.tab !== ShellTab.PLAYER) {
                this.miniBar()
              }
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .height('100%')
          // 底部安全区
          .padding({ bottom: this.ui.safeBottom })
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.app_background'))
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  loadingState() {
    Column({ space: 16 }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color('#FF7DB8FF')
      Text('正在准备曲库与播放服务…')
        .fontSize(14)
        .fontColor('#99F2F4F8')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
  }

  @Builder
  errorState() {
    Column({ space: 12 }) {
      Text('初始化失败')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFF2F4F8')
      Text(this.ui.bootError)
        .fontSize(13)
        .fontColor('#99F2F4F8')
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
  }

  @Builder
  navRail() {
    Column({ space: 6 }) {
      Blank().height(this.ui.safeTop + 12)

      // 品牌区
      Row({ space: 10 }) {
        Image($r('app.media.ic_play_circle'))
          .width(26)
          .height(26)
          .fillColor('#FF7DB8FF')
        if (this.expanded()) {
          Text('Folia')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFF7FAFF')
        }
      }
      .width('100%')
      .height(46)
      .padding({ left: this.expanded() ? 18 : 0 })
      .justifyContent(this.expanded() ? FlexAlign.Start : FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Blank().height(8)

      this.navItem(ShellTab.PLAYER, $r('app.media.ic_play_circle'), '正在播放')
      this.navItem(ShellTab.LIBRARY, $r('app.media.ic_library'), '本地曲库')
      this.navItem(ShellTab.SEARCH, $r('app.media.ic_search'), '在线搜索')
      this.navItem(ShellTab.SETTINGS, $r('app.media.ic_settings'), '设置')

      Blank().layoutWeight(1)

      // 底部歌词主题提示
      if (this.expanded()) {
        Text(`歌词主题 · ${resolveTheme(settingsStore.get().lyricTheme).name}`)
          .fontSize(11)
          .fontColor('#66F2F4F8')
          .padding({ left: 18, bottom: 14 })
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FF101319')
  }

  @Builder
  navItem(tab: ShellTab, icon: Resource, label: string) {
    Row({ space: 12 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor(this.tab === tab ? '#FF7DB8FF' : '#99F2F4F8')
      if (this.expanded()) {
        Text(label)
          .fontSize(14)
          .fontColor(this.tab === tab ? '#FFF7FAFF' : '#99F2F4F8')
          .fontWeight(this.tab === tab ? FontWeight.Medium : FontWeight.Normal)
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: this.expanded() ? 18 : 0 })
    .justifyContent(this.expanded() ? FlexAlign.Start : FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.tab === tab ? '#1A7DB8FF' : Color.Transparent)
    .borderRadius(12)
    .margin({ left: 8, right: 8 })
    .onClick(() => {
      this.tab = tab;
    })
  }

  @Builder
  miniBar() {
    Row({ space: 14 }) {
      Image($r('app.media.ic_play_circle'))
        .width(34)
        .height(34)
        .fillColor('#66F2F4F8')

      Column({ space: 2 }) {
        Text(this.controller.currentTrack?.title ?? '未在播放')
          .fontSize(13)
          .fontColor('#FFF2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.controller.currentTrack?.artist ?? '点击曲库导入本地音乐')
          .fontSize(11)
          .fontColor('#80F2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Image(this.controller.status === PlaybackStatus.PLAYING
        ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
        .width(20)
        .height(20)
        .fillColor('#FFF2F4F8')
        .padding(6)
        .onClick(() => {
          this.controller.togglePlay();
        })

      Image($r('app.media.ic_next'))
        .width(20)
        .height(20)
        .fillColor('#FFF2F4F8')
        .padding(6)
        .onClick(() => {
          this.controller.next(true);
        })
    }
    .width('100%')
    .height(58)
    .padding({ left: 18, right: 18 })
    .backgroundColor('#FF14171F')
    .border({ width: { top: 1 }, color: '#1AF2F4F8' })
    .onClick(() => {
      this.tab = ShellTab.PLAYER;
    })
  }
}
