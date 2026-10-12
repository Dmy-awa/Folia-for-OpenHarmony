/**
 * Folia HarmonyOS - 播放进度条
 *
 * 交互要点：
 *  - 拖动过程中显示「手指位置」而不是播放器回吐的时间，避免进度条跳动；
 *  - 松手后才真正 seek，避免高频 seek 打满媒体框架；
 *  - 单独展示已缓冲区间，弱化显示。
 */
@ComponentV2
export struct ProgressBar {
  /** 当前位置，毫秒 */
  @Require @Param positionMs: number;
  /** 总时长，毫秒；<=0 表示未知 */
  @Require @Param durationMs: number;
  /** 已缓冲，毫秒 */
  @Param bufferedMs: number = 0;
  @Param accentColor: string = '#FF7DB8FF';
  @Param trackColor: string = '#33FFFFFF';
  @Param textColor: string = '#99F2F4F8';
  @Param compact: boolean = false;
  @Event onSeek: (positionMs: number) => void = () => {};

  @Local private dragging: boolean = false;
  @Local private dragValue: number = 0;

  private displayValue(): number {
    return this.dragging ? this.dragValue : this.positionMs;
  }

  private maxValue(): number {
    return this.durationMs > 0 ? this.durationMs : 1;
  }

  /** 毫秒 -> mm:ss */
  private format(ms: number): string {
    if (ms <= 0 || !Number.isFinite(ms)) {
      return '--:--';
    }
    const totalSeconds = Math.floor(ms / 1000);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
    const ss = seconds < 10 ? `0${seconds}` : `${seconds}`;
    return `${mm}:${ss}`;
  }

  build() {
    Row({ space: 10 }) {
      Text(this.format(this.displayValue()))
        .fontSize(this.compact ? 11 : 12)
        .fontColor(this.textColor)
        .width(this.compact ? 38 : 44)
        .textAlign(TextAlign.End)

      Stack({ alignContent: Alignment.Start }) {
        // 底轨
        Divider()
          .strokeWidth(3)
          .color(this.trackColor)
          .width('100%')
        // 缓冲轨
        Divider()
          .strokeWidth(3)
          .color('#26FFFFFF')
          .width(`${this.bufferedRatio() * 100}%`)
        // 播放轨
        Divider()
          .strokeWidth(3)
          .color(this.accentColor)
          .width(`${this.playedRatio() * 100}%`)
      }
      .layoutWeight(1)
      .height(20)

      // 透明 Slider 叠加在上方承接手势
      Slider({
        value: this.displayValue(),
        min: 0,
        max: this.maxValue(),
        step: 1,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .height(20)
        .blockColor(Color.Transparent)
        .trackColor(Color.Transparent)
        .selectedColor(Color.Transparent)
        .trackThickness(20)
        .position({ x: 0, y: 0 })
        .layoutWeight(1)
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin) {
            this.dragging = true;
            this.dragValue = value;
          } else if (mode === SliderChangeMode.Moving) {
            this.dragValue = value;
          } else {
            this.dragValue = value;
            this.dragging = false;
            this.onSeek(Math.round(value));
          }
        })

      Text(this.format(this.durationMs))
        .fontSize(this.compact ? 11 : 12)
        .fontColor(this.textColor)
        .width(this.compact ? 38 : 44)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .height(this.compact ? 24 : 32)
  }

  private playedRatio(): number {
    const max = this.maxValue();
    return Math.max(0, Math.min(1, this.displayValue() / max));
  }

  private bufferedRatio(): number {
    const max = this.maxValue();
    return Math.max(0, Math.min(1, this.bufferedMs / max));
  }
}
