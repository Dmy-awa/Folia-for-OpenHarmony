/**
 * Folia HarmonyOS - 播放控制条
 *
 * 只负责「展示 + 抛事件」，不直接调用播放控制器，
 * 便于在播放页、悬浮条、队列面板中复用同一套控件。
 */
import { RepeatMode } from '../../core/Types';

@ComponentV2
export struct TransportBar {
  @Require @Param isPlaying: boolean;
  @Require @Param repeatMode: RepeatMode;
  @Require @Param isFavorite: boolean;
  @Param hasTrack: boolean = true;
  @Param accentColor: string = '#FF7DB8FF';
  @Param iconColor: string = '#FFF2F4F8';
  @Param compact: boolean = false;
  @Param showShuffle: boolean = true;

  @Event onToggle: () => void = () => {};
  @Event onNext: () => void = () => {};
  @Event onPrevious: () => void = () => {};
  @Event onCycleRepeat: () => void = () => {};
  @Event onShuffle: () => void = () => {};
  @Event onToggleFavorite: () => void = () => {};

  private mainSize(): number {
    return this.compact ? 40 : 56;
  }

  private sideSize(): number {
    return this.compact ? 30 : 38;
  }

  private repeatIcon(): Resource {
    if (this.repeatMode === RepeatMode.ONE) {
      return $r('app.media.ic_repeat_one');
    }
    if (this.repeatMode === RepeatMode.SHUFFLE) {
      return $r('app.media.ic_shuffle');
    }
    return $r('app.media.ic_repeat');
  }

  /** 循环模式处于「顺序播放」时弱化按钮，提示当前未开启循环 */
  private repeatOpacity(): number {
    return this.repeatMode === RepeatMode.OFF ? 0.5 : 1;
  }

  private repeatLabel(): string {
    switch (this.repeatMode) {
      case RepeatMode.ONE:
        return '单曲循环';
      case RepeatMode.ALL:
        return '列表循环';
      case RepeatMode.SHUFFLE:
        return '随机播放';
      default:
        return '顺序播放';
    }
  }

  build() {
    Row({ space: this.compact ? 14 : 22 }) {
      // 收藏
      this.iconButton(
        this.isFavorite ? $r('app.media.ic_heart') : $r('app.media.ic_heart_outline'),
        this.sideSize(),
        this.isFavorite ? this.accentColor : this.iconColor,
        this.isFavorite ? 1 : 0.72,
        () => this.onToggleFavorite()
      )

      // 循环模式
      this.iconButton(this.repeatIcon(), this.sideSize(), this.iconColor,
        this.repeatOpacity(), () => this.onCycleRepeat())

      // 上一首
      this.iconButton($r('app.media.ic_prev'), this.sideSize() * 1.3, this.iconColor, 1,
        () => this.onPrevious())

      // 播放 / 暂停（主按钮）
      Stack() {
        Circle()
          .width(this.mainSize())
          .height(this.mainSize())
          .fill(this.accentColor)
        Image(this.isPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
          .width(this.mainSize() * 0.44)
          .height(this.mainSize() * 0.44)
          .fillColor('#FF0B0D12')
          .margin({ left: this.isPlaying ? 0 : this.mainSize() * 0.05 })
      }
      .width(this.mainSize())
      .height(this.mainSize())
      .onClick(() => {
        if (this.hasTrack) {
          this.onToggle();
        }
      })
      .opacity(this.hasTrack ? 1 : 0.4)

      // 下一首
      this.iconButton($r('app.media.ic_next'), this.sideSize() * 1.3, this.iconColor, 1,
        () => this.onNext())

      // 随机播放
      if (this.showShuffle) {
        this.iconButton($r('app.media.ic_shuffle'), this.sideSize(), this.iconColor, 0.72,
          () => this.onShuffle())
      }
    }
    .height(this.mainSize())
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  iconButton(icon: Resource, size: number, color: string, opacity: number, action: () => void) {
    Image(icon)
      .width(size)
      .height(size)
      .fillColor(color)
      .opacity(opacity)
      .padding(this.compact ? 3 : 5)
      .onClick(action)
  }
}
