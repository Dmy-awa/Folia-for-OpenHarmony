/**
 * Folia HarmonyOS - 封面组件
 *
 * 本地封面走沙箱文件路径，在线封面走 URL；两者都失败时回退到内置的音符占位图。
 * 位图尺寸由调用方指定，组件本身不做缓存（Image 组件自带内存缓存）。
 */
@ComponentV2
export struct CoverArt {
  @Param uri: string = '';
  @Param size: number = 200;
  @Param borderRadius: number = 16;
  @Param shadow: boolean = true;

  private hasSource(): boolean {
    return this.uri.length > 0;
  }

  build() {
    // build() 需要唯一根容器，因此有无封面两种情况都放在同一个 Stack 里分支渲染
    Stack() {
      if (this.hasSource()) {
        Image(this.uri)
          .width(this.size)
          .height(this.size)
          .borderRadius(this.borderRadius)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .draggable(false)
          .shadow(this.shadow
            ? {
              radius: this.size * 0.14,
              color: '#66000000',
              offsetX: 0,
              offsetY: this.size * 0.04
            }
            : undefined)
          .alt($r('app.media.ic_play_circle'))
      } else {
        Column() {
          Image($r('app.media.ic_play_circle'))
            .width(this.size * 0.34)
            .height(this.size * 0.34)
            .fillColor('#66F2F4F8')
        }
        .width(this.size)
        .height(this.size)
        .borderRadius(this.borderRadius)
        .backgroundColor('#1AFFFFFF')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width(this.size)
    .height(this.size)
  }
}
