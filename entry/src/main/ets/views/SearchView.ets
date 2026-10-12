/**
 * Folia HarmonyOS - 在线搜索
 *
 * 通过 OmniRouter 搜索并播放。
 *
 * 分层约束（与上游一致）：UI 只能调用 OmniRouter，绝不直接触碰任何 provider。
 * 直链在点击播放时才解析——在线直链普遍带过期时间，提前解析会立刻失效。
 */
import { ProviderError, ProviderId, SearchSongItem, SearchResult, Track } from '../core/Types';
import { Breakpoint } from '../utils/Breakpoints';
import { omniRouter } from '../services/online/OmniRouter';
import { playbackController } from '../services/player/PlaybackController';
import { QueueAddBehavior } from '../services/player/PlaybackQueue';
import { CoverArt } from '../components/common/CoverArt';
import { Logger } from '../core/Logger';

const TAG: string = 'SearchView';
const PAGE_SIZE: number = 30;

@ComponentV2
export struct SearchView {
  @Require @Param breakpoint: Breakpoint;
  @Require @Param safeTop: number;
  @Require @Param safeBottom: number;
  @Require @Param width: number;
  @Require @Param height: number;

  @Local private keyword: string = '';
  /** 已提交的搜索词，避免输入过程中反复请求 */
  @Local private submittedKeyword: string = '';
  @Local private results: SearchSongItem[] = [];
  @Local private searching: boolean = false;
  @Local private errorText: string = '';
  @Local private hasSearched: boolean = false;
  @Local private providerLabel: string = '';
  /** 正在解析直链的歌曲 id，用于按钮 loading 态 */
  @Local private resolvingId: string = '';

  private controller = playbackController;

  aboutToAppear(): void {
    this.providerLabel = this.describeProvider(omniRouter.getActiveProvider());
  }

  private describeProvider(providerId: ProviderId): string {
    switch (providerId) {
      case ProviderId.NAVIDROME:
        return 'Navidrome 自建库';
      case ProviderId.NETEASE:
        return '网易云（自建 API）';
      case ProviderId.KUGOU:
        return '酷狗（匿名通道）';
      default:
        return '本地';
    }
  }

  /** 执行搜索；失败时展示可读的中文错误而不是抛栈 */
  private async doSearch(): Promise<void> {
    const keyword = this.keyword.trim();
    if (keyword.length === 0 || this.searching) {
      return;
    }
    this.searching = true;
    this.errorText = '';
    this.submittedKeyword = keyword;
    try {
      const result: SearchResult = await omniRouter.search(keyword, 1, PAGE_SIZE);
      this.results = result.songs;
      this.hasSearched = true;
      if (result.songs.length === 0) {
        this.errorText = '没有找到匹配的歌曲，换个关键词试试';
      }
    } catch (error) {
      this.results = [];
      this.hasSearched = true;
      this.errorText = this.readableError(error as Object);
      Logger.err(TAG, 'search', error as Error);
    } finally {
      this.searching = false;
    }
  }

  /** 点击结果：构造 Track -> 作为单曲队列播放 */
  private async playItem(item: SearchSongItem): Promise<void> {
    if (this.resolvingId.length > 0) {
      return;
    }
    this.resolvingId = item.id;
    this.errorText = '';
    try {
      const track = omniRouter.buildTrackFromSearch(item, omniRouter.getActiveProvider());
      await this.controller.playTrack(track);
    } catch (error) {
      this.errorText = this.readableError(error as Object);
      Logger.err(TAG, 'play search result', error as Error);
    } finally {
      this.resolvingId = '';
    }
  }

  /** 把 ProviderError 转成用户能看懂的中文提示 */
  private readableError(error: Object): string {
    if (error instanceof ProviderError) {
      return error.message;
    }
    const e = error as Error;
    return e.message ?? '操作失败，请稍后重试';
  }

  private addToQueue(item: SearchSongItem): void {
    try {
      const track: Track = omniRouter.buildTrackFromSearch(item, omniRouter.getActiveProvider());
      this.controller.addToQueue([track], QueueAddBehavior.NEXT);
    } catch (error) {
      this.errorText = this.readableError(error as Object);
    }
  }

  private formatDuration(ms: number): string {
    if (ms <= 0) {
      return '--:--';
    }
    const total = Math.floor(ms / 1000);
    const mm = Math.floor(total / 60);
    const ss = total % 60;
    return `${mm}:${ss < 10 ? '0' : ''}${ss}`;
  }

  build() {
    Column() {
      this.header()

      if (this.searching) {
        this.loadingState()
      } else if (this.results.length === 0) {
        this.emptyState()
      } else {
        this.resultList()
          .layoutWeight(1)
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }

  @Builder
  header() {
    Column({ space: 12 }) {
      Blank().height(this.safeTop)

      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('在线搜索')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFF2F4F8')
          Text(`当前音源 · ${this.providerLabel}`)
            .fontSize(12)
            .fontColor('#80F2F4F8')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 搜索框
      Row({ space: 10 }) {
        Image($r('app.media.ic_search'))
          .width(17)
          .height(17)
          .fillColor('#80F2F4F8')

        TextInput({ text: this.keyword, placeholder: '搜索歌曲、歌手或专辑' })
          .placeholderColor('#59F2F4F8')
          .fontColor('#FFF2F4F8')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.doSearch();
          })

        if (this.keyword.length > 0) {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor('#66F2F4F8')
            .onClick(() => {
              this.keyword = '';
            })
        }

        Text('搜索')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FF0B0D12')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#FF7DB8FF')
          .borderRadius(16)
          .onClick(() => {
            this.doSearch();
          })
      }
      .width('100%')
      .height(42)
      .padding({ left: 14, right: 6 })
      .backgroundColor('#14FFFFFF')
      .borderRadius(21)

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(12)
          .fontColor('#E8A0A0')
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  loadingState() {
    Column({ space: 14 }) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color('#FF7DB8FF')
      Text(`正在搜索「${this.submittedKeyword}」…`)
        .fontSize(13)
        .fontColor('#99F2F4F8')
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyState() {
    Column({ space: 12 }) {
      Image($r('app.media.ic_search'))
        .width(44)
        .height(44)
        .fillColor('#4DF2F4F8')
      Text(this.hasSearched ? '没有结果' : '搜索在线音乐')
        .fontSize(16)
        .fontColor('#CCF2F4F8')
      Text(this.hasSearched
        ? '换个关键词，或在设置中切换到别的音源'
        : '默认使用酷狗匿名通道，无需登录即可搜索与试听；也可在设置中配置 Navidrome 自建库')
        .fontSize(12)
        .fontColor('#80F2F4F8')
        .textAlign(TextAlign.Center)
        .padding({ left: 60, right: 60 })
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  resultList() {
    List({ space: 2 }) {
      ForEach(this.results, (item: SearchSongItem, index: number) => {
        ListItem() {
          this.resultRow(item, index)
        }
      }, (item: SearchSongItem) => item.id)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .contentEndOffset(this.safeBottom + 12)
  }

  @Builder
  resultRow(item: SearchSongItem, index: number) {
    Row({ space: 14 }) {
      Stack() {
        CoverArt({ uri: item.coverUrl ?? '', size: 44, borderRadius: 9, shadow: false })
        if (this.resolvingId === item.id) {
          Column()
            .width(44)
            .height(44)
            .borderRadius(9)
            .backgroundColor('#B3000000')
          LoadingProgress()
            .width(20)
            .height(20)
            .color('#FF7DB8FF')
        }
      }
      .width(44)
      .height(44)

      Column({ space: 3 }) {
        Text(item.title)
          .fontSize(14)
          .fontColor('#FFF2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.album.length > 0 ? `${item.artist} · ${item.album}` : item.artist)
          .fontSize(11)
          .fontColor('#80F2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.formatDuration(item.duration))
        .fontSize(11)
        .fontColor('#66F2F4F8')

      // 「下一首播放」
      Image($r('app.media.ic_add'))
        .width(16)
        .height(16)
        .fillColor('#80F2F4F8')
        .padding(6)
        .onClick(() => {
          this.addToQueue(item);
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .onClick(() => {
      this.playItem(item);
    })
  }
}
