/**
 * Folia HarmonyOS - 全屏歌词舞台
 *
 * 这是移植版的核心视觉组件：
 *   - 沉浸式居中滚动，当前行放大高亮，其余行按「已唱 / 未唱」两种状态着色；
 *   - 支持逐字扫光（仅当歌词带真实逐字时轴且主题开启时）；
 *   - 间奏行渲染为进度呼吸点，而不是文字。
 *
 * ⚠️ 实现上刻意使用 List + ForEach（而不是 LazyForEach）：
 *    逐字扫光要求「当前行」随 positionMs 每帧重绘，而 LazyForEach 的项按 key 缓存，
 *    positionMs 变化不会让未变更的项重新构建，扫光就会卡住。
 *    歌词行数通常在数百行量级，ForEach 的开销可以接受；
 *    positionMs 由播放控制器按 ~120ms 节流上报，重绘频率是可控的。
 *
 * 时间单位：本组件接收**毫秒**的播放位置，换算集中在 LyricTimeline.toLyricTime，
 * 组件内部不重复做单位推导。
 */
import { LyricDocument, LyricLine, LyricWord } from '../../core/Types';
import { INTERLUDE_FULL_TEXT } from '../../services/lyrics/LyricCore';
import { resolveWordStatus, toLyricTime, WordStatus, wordProgress } from '../../services/lyrics/LyricTimeline';
import { canHighlightWords, LyricTheme, themeFontSize } from './LyricTheme';

@ComponentV2
export struct LyricStage {
  @Require @Param doc: LyricDocument | undefined;
  @Require @Param currentIndex: number;
  /** 播放位置，毫秒 */
  @Require @Param positionMs: number;
  @Require @Param theme: LyricTheme;
  /** 歌词偏移，毫秒 */
  @Param lyricOffsetMs: number = 0;
  /** 舞台高度，vp；用于换算字号 */
  @Param stageHeight: number = 360;
  /** 点击某行跳转播放位置 */
  @Event onSeek: (positionMs: number) => void = () => {};

  private scroller: Scroller = new Scroller();
  /** 上一次滚动到的行，避免同一行重复触发滚动动画 */
  private lastScrolledIndex: number = -2;

  aboutToAppear(): void {
    this.scrollToActive(false);
  }

  /** 当前行变化时平滑滚动到视觉中心 */
  @Monitor('currentIndex')
  onIndexChanged(): void {
    this.scrollToActive(true);
  }

  private scrollToActive(smooth: boolean): void {
    const index = this.currentIndex;
    if (index < 0 || index === this.lastScrolledIndex) {
      return;
    }
    this.lastScrolledIndex = index;
    try {
      this.scroller.scrollToIndex(index, smooth, ScrollAlign.CENTER);
    } catch (error) {
      // 列表尚未完成首帧布局时忽略，下一帧会重试
    }
  }

  private lines(): LyricLine[] {
    return this.doc === undefined ? [] : this.doc.lines;
  }

  private lyricSeconds(): number {
    return toLyricTime(this.positionMs, this.lyricOffsetMs);
  }

  private fontSize(): number {
    return themeFontSize(this.theme, this.stageHeight);
  }

  /** 行文字颜色：当前行 / 已唱 / 未唱 */
  private lineColor(index: number): string {
    if (index === this.currentIndex) {
      return this.theme.activeColor;
    }
    if (index < this.currentIndex) {
      return this.theme.sungColor;
    }
    return this.theme.unsungColor;
  }

  /** 非当前行按主题整体压暗，突出当前行 */
  private lineOpacity(index: number): number {
    return index === this.currentIndex ? 1 : this.theme.inactiveOpacity + 0.28;
  }

  /** 逐字颜色：已唱高亮、正在唱按进度切换、未唱用未唱色 */
  private wordColor(word: LyricWord, seconds: number): string {
    const status = resolveWordStatus(word, seconds, 0.045);
    if (status === WordStatus.WAITING) {
      return this.theme.unsungColor;
    }
    if (status === WordStatus.PASSED) {
      return this.theme.highlightColor;
    }
    const progress = wordProgress(word, seconds, 0.045);
    return progress > 0.5 ? this.theme.highlightColor : this.theme.activeColor;
  }

  /** 间奏点亮度：仅当前间奏行按进度点亮 */
  private dotOpacity(word: LyricWord, isActive: boolean, seconds: number): number {
    if (!isActive) {
      return 0.16;
    }
    return 0.16 + wordProgress(word, seconds, 0) * 0.84;
  }

  build() {
    Column() {
      if (this.lines().length === 0) {
        this.emptyState()
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.lines(), (line: LyricLine, index: number) => {
            ListItem() {
              this.lineContent(line, index, this.lyricSeconds())
            }
            .width('100%')
          }, (line: LyricLine, index: number) => `${index}-${line.startTime}-${line.fullText}`)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(6)
        // 上下留白，保证首行与末行也能滚动到视觉中心
        .contentStartOffset(this.stageHeight * 0.42)
        .contentEndOffset(this.stageHeight * 0.42)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  emptyState() {
    Column() {
      Text('暂无歌词')
        .fontSize(this.fontSize())
        .fontColor(this.theme.unsungColor)
        .fontWeight(FontWeight.Medium)
      Text('可在设置中确认音源，或换一首有歌词的歌曲')
        .fontSize(13)
        .fontColor(this.theme.translationColor)
        .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 一行的完整渲染。
   * seconds 作为参数显式传入（而不是在函数里再读 this.positionMs），
   * 保证 ForEach 重建时拿到的是同一帧的时间基准，整屏文字不会出现撕裂。
   */
  @Builder
  lineContent(line: LyricLine, index: number, seconds: number) {
    Column() {
      if (line.fullText === INTERLUDE_FULL_TEXT || line.isInterlude === true) {
        // 间奏：6 个按进度点亮的点
        Row({ space: 10 }) {
          ForEach(line.words, (word: LyricWord, dotIndex: number) => {
            Circle()
              .width(8)
              .height(8)
              .fill(this.theme.highlightColor)
              .opacity(this.dotOpacity(word, index === this.currentIndex, seconds))
          }, (word: LyricWord, dotIndex: number) => `dot-${dotIndex}-${word.startTime}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 当前行且带真实逐字时轴时，按词着色实现扫光
        if (index === this.currentIndex && canHighlightWords(this.theme, line)) {
          Text() {
            ForEach(line.words, (word: LyricWord, wordIndex: number) => {
              Span(word.text)
                .fontColor(this.wordColor(word, seconds))
            }, (word: LyricWord, wordIndex: number) => `w-${wordIndex}-${word.startTime}`)
          }
          .fontSize(this.fontSize())
          .fontWeight(FontWeight.Bold)
          .textAlign(this.theme.align)
          .width('100%')
        } else {
          Text(line.fullText)
            .fontSize(this.fontSize())
            .fontColor(this.lineColor(index))
            .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Medium)
            .textAlign(this.theme.align)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        // 译文
        if (this.theme.showTranslation && line.translation !== undefined
          && line.translation.length > 0) {
          Text(line.translation)
            .fontSize(this.fontSize() * 0.58)
            .fontColor(this.theme.translationColor)
            .textAlign(this.theme.align)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })
        }
        // 罗马音
        if (this.theme.showTranslation && line.romanization !== undefined
          && line.romanization.length > 0) {
          Text(line.romanization)
            .fontSize(this.fontSize() * 0.5)
            .fontColor(this.theme.translationColor)
            .opacity(0.8)
            .textAlign(this.theme.align)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
        }
      }
    }
    .width('100%')
    .padding({
      top: this.fontSize() * (this.theme.lineGapRatio - 1) * 0.5,
      bottom: this.fontSize() * (this.theme.lineGapRatio - 1) * 0.5
    })
    .scale({
      x: index === this.currentIndex ? this.theme.activeScale : 1,
      y: index === this.currentIndex ? this.theme.activeScale : 1
    })
    .animation({ duration: 240, curve: Curve.EaseOut })
    .onClick(() => {
      this.onSeek(Math.round(line.startTime * 1000));
    })
  }
}
