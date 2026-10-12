/**
 * Folia HarmonyOS - 播放页
 *
 * 布局策略（横屏，覆盖手机 / 平板 / PC / 2in1）：
 *   - 背景：封面放大 + 高斯模糊 + 主题色遮罩，营造沉浸感；
 *   - 主体：全屏歌词舞台居中；
 *   - >=840vp（lg）：右侧额外展开队列 / 歌曲信息面板，利用横向空间；
 *   - 上下控制层默认 5 秒后自动隐藏，点击任意位置唤回，避免遮挡歌词。
 */
import { PlaybackStatus, QueueItem, Track } from '../core/Types';
import { LyricStage } from '../components/lyrics/LyricStage';
import { LyricTheme, LYRIC_THEMES, resolveTheme } from '../components/lyrics/LyricTheme';
import { ProgressBar } from '../components/player/ProgressBar';
import { TransportBar } from '../components/player/TransportBar';
import { CoverArt } from '../components/common/CoverArt';
import { playbackController, PlaybackController } from '../services/player/PlaybackController';
import { settingsStore } from '../services/settings/SettingsStore';
import { Breakpoint, supportsSidePanel } from '../utils/Breakpoints';

/** 控制层自动隐藏延迟 */
const CHROME_HIDE_DELAY_MS: number = 5000;

@ComponentV2
export struct PlayerView {
  @Require @Param breakpoint: Breakpoint;
  @Require @Param safeTop: number;
  @Require @Param safeBottom: number;
  /** 可用尺寸，由外层传入 */
  @Require @Param stageWidth: number;
  @Require @Param stageHeight: number;
  @Event onOpenQueue: () => void = () => {};

  @Local private chromeVisible: boolean = true;
  /** 主题 id 本地缓存，切换主题时立即生效 */
  @Local private themeId: string = settingsStore.get().lyricTheme;
  /**
   * 播放控制器持有为 @Local。
   * V2 的 @Monitor 只支持观察 @Local/@Param 上的路径，
   * 因此要监听 controller.queueVersion 就必须让它成为被观察字段。
   */
  @Local private controller: PlaybackController = playbackController;

  private hideTimer: number = -1;

  aboutToAppear(): void {
    this.scheduleHide();
  }

  aboutToDisappear(): void {
    this.clearHideTimer();
  }

  private scheduleHide(): void {
    this.clearHideTimer();
    this.hideTimer = setTimeout(() => {
      this.chromeVisible = false;
    }, CHROME_HIDE_DELAY_MS);
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private wakeChrome(): void {
    this.chromeVisible = true;
    this.scheduleHide();
  }

  private theme(): LyricTheme {
    return resolveTheme(this.themeId);
  }

  /** 在三种主题之间轮换并持久化 */
  private cycleTheme(): void {
    let index = 0;
    for (let i = 0; i < LYRIC_THEMES.length; i += 1) {
      if (LYRIC_THEMES[i].id === this.themeId) {
        index = i;
        break;
      }
    }
    const next = LYRIC_THEMES[(index + 1) % LYRIC_THEMES.length];
    this.themeId = next.id;
    settingsStore.setLyricTheme(next.id);
  }

  private coverUri(track: Track | undefined): string {
    if (track === undefined || track.cover === undefined) {
      return '';
    }
    const cover = track.cover;
    if (cover.uri !== undefined && cover.uri.length > 0) {
      return cover.uri;
    }
    if (cover.url !== undefined) {
      return cover.url;
    }
    return '';
  }

  private sideWidth(): number {
    return Math.max(260, Math.min(this.stageWidth * 0.28, 380));
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 背景 ----------
      this.backdrop()

      // ---------- 主体 ----------
      Row() {
        Column() {
          // 顶部预留，避免歌词顶到状态栏
          Blank().height(this.safeTop + 8)
          LyricStage({
            doc: this.controller.lyricDoc,
            currentIndex: this.controller.currentLineIndex,
            positionMs: this.controller.positionMs,
            theme: this.theme(),
            lyricOffsetMs: this.controller.lyricOffsetMs,
            stageHeight: this.stageHeight,
            onSeek: (positionMs: number) => {
              this.wakeChrome();
              this.controller.seek(positionMs);
            }
          })
            .layoutWeight(1)
        }
        .layoutWeight(1)
        .height('100%')

        // 宽屏才展示侧栏，横屏手机上保持纯歌词沉浸
        if (supportsSidePanel(this.breakpoint)) {
          this.sidePanel()
            .width(this.sideWidth())
            .height('100%')
        }
      }
      .width('100%')
      .height('100%')

      // ---------- 悬浮控制层 ----------
      if (this.chromeVisible) {
        this.topBar()
        this.bottomLayer()
      } else {
        // 隐藏状态下点击任意位置唤回控制层
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => this.wakeChrome())
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  backdrop() {
    Stack() {
      if (this.coverUri(this.controller.currentTrack).length > 0) {
        Image(this.coverUri(this.controller.currentTrack))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(64)
          .interpolation(ImageInterpolation.Low)
          .draggable(false)
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme().background)
        .opacity(this.theme().backdropOpacity)
      // 上下渐变，保证浅色封面上控制层文字也能看清
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#B3000000', 0.0], ['#00000000', 0.28], ['#00000000', 0.72], ['#B3000000', 1.0]]
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  topBar() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.controller.currentTrack?.title ?? '未在播放')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFF7FAFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.controller.currentTrack?.artist ?? '从曲库或搜索中选择一首歌')
          .fontSize(13)
          .fontColor('#B3F2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      this.chromeIcon($r('app.media.ic_more'), () => {
        this.cycleTheme();
        this.wakeChrome();
      })
      this.chromeIcon($r('app.media.ic_queue'), () => {
        this.wakeChrome();
        this.onOpenQueue();
      })
      this.chromeIcon($r('app.media.ic_close'), () => {
        this.chromeVisible = false;
        this.clearHideTimer();
      })
    }
    .width('100%')
    .padding({
      left: 24,
      right: 24,
      top: this.safeTop + 14,
      bottom: 14
    })
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: 0 })
  }

  /** 控制层下半部分：用整屏 Column 贴底，避免依赖固定高度做绝对定位 */
  @Builder
  bottomLayer() {
    Column() {
      Blank().layoutWeight(1)
      Column({ space: 8 }) {
        ProgressBar({
          positionMs: this.controller.positionMs,
          durationMs: this.controller.durationMs,
          bufferedMs: this.controller.bufferedMs,
          accentColor: this.theme().highlightColor,
          textColor: '#B3F2F4F8',
          onSeek: (positionMs: number) => {
            this.wakeChrome();
            this.controller.seek(positionMs);
          }
        })
        TransportBar({
          isPlaying: this.controller.status === PlaybackStatus.PLAYING,
          repeatMode: this.controller.repeatMode,
          isFavorite: this.controller.isFavorite,
          hasTrack: this.controller.currentTrack !== undefined,
          accentColor: this.theme().highlightColor,
          iconColor: '#FFF2F4F8',
          onToggle: () => {
            this.wakeChrome();
            this.controller.togglePlay();
          },
          onNext: () => {
            this.wakeChrome();
            this.controller.next(true);
          },
          onPrevious: () => {
            this.wakeChrome();
            this.controller.previous();
          },
          onCycleRepeat: () => {
            this.wakeChrome();
            this.controller.cycleRepeatMode();
          },
          onShuffle: () => {
            this.wakeChrome();
            this.controller.shuffleQueue();
          },
          onToggleFavorite: () => {
            this.wakeChrome();
            const track = this.controller.currentTrack;
            if (track !== undefined) {
              this.controller.toggleFavorite(track.id);
            }
          }
        })
      }
      .width('100%')
      .padding({ left: 32, right: 32, bottom: this.safeBottom + 16 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  sidePanel() {
    Column({ space: 14 }) {
      Blank().height(this.safeTop + 64)

      Column({ space: 12 }) {
        CoverArt({
          uri: this.coverUri(this.controller.currentTrack),
          size: Math.min(this.sideWidth() - 72, 190),
          borderRadius: 18
        })
        Text(this.controller.currentTrack?.title ?? '未在播放')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFF7FAFF')
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.controller.currentTrack?.album ?? '')
          .fontSize(12)
          .fontColor('#99F2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Divider().color('#1AF2F4F8')

      Text(`播放队列 · 共 ${this.controller.getQueue().length} 首`)
        .fontSize(12)
        .fontColor('#99F2F4F8')
        .width('100%')

      List() {
        ForEach(this.controller.getQueue(), (item: QueueItem, index: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(`${index + 1}`)
                .fontSize(11)
                .fontColor(index === this.controller.getQueueIndex()
                  ? this.theme().highlightColor : '#66F2F4F8')
                .width(20)
              Column({ space: 2 }) {
                Text(item.track.title)
                  .fontSize(13)
                  .fontColor(index === this.controller.getQueueIndex()
                    ? this.theme().highlightColor : '#E6F2F4F8')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.track.artist)
                  .fontSize(11)
                  .fontColor('#80F2F4F8')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 7, bottom: 7, left: 4, right: 4 })
            .borderRadius(8)
            .backgroundColor(index === this.controller.getQueueIndex() ? '#14FFFFFF' : Color.Transparent)
            .onClick(() => {
              this.controller.onRemoteSkipToQueueItem(index);
            })
          }
        }, (item: QueueItem, index: number) => `${item.queueId}-${index}`)
      }
      // 读取 queueVersion 以建立观察依赖：队列增删时驱动侧栏刷新
      .id(`queue-${this.controller.queueVersion}`)
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .padding({ left: 18, right: 18 })
    .backgroundColor('#4D000000')
    .backdropBlur(24)
  }

  @Builder
  chromeIcon(icon: Resource, action: () => void) {
    Image(icon)
      .width(22)
      .height(22)
      .fillColor('#E6F2F4F8')
      .padding(9)
      .borderRadius(20)
      .backgroundColor('#26FFFFFF')
      .onClick(action)
  }
}
