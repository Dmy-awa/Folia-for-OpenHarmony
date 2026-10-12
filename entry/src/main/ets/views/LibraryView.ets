/**
 * Folia HarmonyOS - 本地曲库
 *
 * 横屏自适应：
 *   - md（600~840vp）：单列紧凑列表；
 *   - lg（>=840vp）：左侧曲目列表 + 右侧「正在播放」信息栏的双栏布局；
 *   - 顶部提供导入入口与本地过滤输入框。
 */
import { ProviderId, Track, TrackOrigin } from '../core/Types';
import { Breakpoint, supportsSidePanel } from '../utils/Breakpoints';
import { localLibraryService } from '../services/library/LocalLibraryService';
import { playbackController } from '../services/player/PlaybackController';
import { QueueAddBehavior } from '../services/player/PlaybackQueue';
import { CoverArt } from '../components/common/CoverArt';
import { Logger } from '../core/Logger';

const TAG: string = 'LibraryView';

@ComponentV2
export struct LibraryView {
  @Require @Param breakpoint: Breakpoint;
  @Require @Param safeTop: number;
  @Require @Param safeBottom: number;
  @Require @Param width: number;
  @Require @Param height: number;

  @Local private tracks: Track[] = [];
  @Local private keyword: string = '';
  @Local private importing: boolean = false;
  @Local private message: string = '';

  private controller = playbackController;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.tracks = localLibraryService.getAll();
  }

  /** 触发系统文件选择器导入，并按需刷新列表 */
  private async importFiles(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    this.message = '';
    try {
      const count = await localLibraryService.importFromPicker();
      this.refresh();
      this.message = count > 0 ? `已导入 ${count} 首` : '未选择任何文件';
    } catch (error) {
      Logger.err(TAG, 'import', error as Error);
      this.message = `导入失败：${(error as Error).message}`;
    } finally {
      this.importing = false;
    }
  }

  private visibleTracks(): Track[] {
    if (this.keyword.trim().length === 0) {
      return this.tracks;
    }
    const lower = this.keyword.trim().toLowerCase();
    return this.tracks.filter((t: Track) => {
      return t.title.toLowerCase().includes(lower)
        || t.artist.toLowerCase().includes(lower)
        || t.album.toLowerCase().includes(lower);
    });
  }

  private coverUri(track: Track): string {
    if (track.cover === undefined) {
      return '';
    }
    return track.cover.uri ?? '';
  }

  /** 从当前列表播放，把整个列表作为队列 */
  private playAt(index: number): void {
    const list = this.visibleTracks();
    if (index < 0 || index >= list.length) {
      return;
    }
    this.controller.playTracks(list, index);
  }

  build() {
    Column() {
      this.header()

      if (this.tracks.length === 0) {
        this.emptyState()
      } else if (supportsSidePanel(this.breakpoint)) {
        // 双栏：列表 + 当前播放信息
        Row() {
          this.trackList().layoutWeight(1)
          Divider()
            .vertical(true)
            .color('#1AF2F4F8')
          this.infoPane()
            .width(Math.max(240, Math.min(this.width * 0.26, 340)))
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        this.trackList()
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

      Row({ space: 14 }) {
        Column({ space: 2 }) {
          Text('本地曲库')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFF2F4F8')
          Text(`${this.tracks.length} 首 · 音频文件仅保存在本机`)
            .fontSize(12)
            .fontColor('#80F2F4F8')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.message.length > 0) {
          Text(this.message)
            .fontSize(12)
            .fontColor('#99F2F4F8')
            .maxLines(1)
        }

        // 导入按钮
        Row({ space: 6 }) {
          if (this.importing) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color('#FF0B0D12')
          } else {
            Image($r('app.media.ic_add'))
              .width(16)
              .height(16)
              .fillColor('#FF0B0D12')
          }
          Text(this.importing ? '导入中…' : '导入音乐')
            .fontSize(13)
            .fontColor('#FF0B0D12')
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: 14, right: 16, top: 9, bottom: 9 })
        .backgroundColor('#FF7DB8FF')
        .borderRadius(20)
        .onClick(() => {
          this.importFiles();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 本地过滤
      Row({ space: 8 }) {
        Image($r('app.media.ic_search'))
          .width(16)
          .height(16)
          .fillColor('#80F2F4F8')
        TextInput({ text: this.keyword, placeholder: '在本地曲库中过滤' })
          .placeholderColor('#59F2F4F8')
          .fontColor('#FFF2F4F8')
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.keyword = value;
          })
      }
      .width('100%')
      .height(38)
      .padding({ left: 14, right: 14 })
      .backgroundColor('#14FFFFFF')
      .borderRadius(19)
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 14 })
  }

  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Image($r('app.media.ic_library'))
        .width(48)
        .height(48)
        .fillColor('#4DF2F4F8')
      Text('曲库里还没有音乐')
        .fontSize(16)
        .fontColor('#CCF2F4F8')
      Text('点击「导入音乐」选择本机音频文件，支持 MP3 / FLAC / M4A / OGG / WAV 等格式')
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
  trackList() {
    List({ space: 2 }) {
      ForEach(this.visibleTracks(), (track: Track, index: number) => {
        ListItem() {
          this.trackRow(track, index)
        }
      }, (track: Track) => track.id)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .contentEndOffset(this.safeBottom + 12)
  }

  @Builder
  trackRow(track: Track, index: number) {
    Row({ space: 14 }) {
      CoverArt({ uri: this.coverUri(track), size: 44, borderRadius: 9, shadow: false })

      Column({ space: 3 }) {
        Text(track.title)
          .fontSize(14)
          .fontColor('#FFF2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(track.album.length > 0 ? `${track.artist} · ${track.album}` : track.artist)
          .fontSize(11)
          .fontColor('#80F2F4F8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.formatDuration(track.duration))
        .fontSize(11)
        .fontColor('#66F2F4F8')

      Image($r('app.media.ic_add'))
        .width(16)
        .height(16)
        .fillColor('#80F2F4F8')
        .padding(6)
        .onClick(() => {
          this.controller.addToQueue([track], QueueAddBehavior.NEXT);
        })
    }
    .width('100%')
    .height(60)
    .padding({ left: 10, right: 10 })
    .borderRadius(10)
    .backgroundColor(this.isCurrent(track) ? '#1A7DB8FF' : Color.Transparent)
    .onClick(() => {
      this.playAt(index);
    })
  }

  private isCurrent(track: Track): boolean {
    const current = this.controller.currentTrack;
    return current !== undefined && current.id === track.id;
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

  @Builder
  infoPane() {
    Column({ space: 14 }) {
      Blank().height(8)
      CoverArt({
        uri: this.coverUri(this.controller.currentTrack ?? this.placeholderTrack()),
        size: 180,
        borderRadius: 16
      })
      Text(this.controller.currentTrack?.title ?? '未在播放')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFF2F4F8')
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.controller.currentTrack?.artist ?? '选择左侧任意曲目开始播放')
        .fontSize(12)
        .fontColor('#99F2F4F8')
        .textAlign(TextAlign.Center)
        .maxLines(1)
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 占位曲目，仅用于让封面组件安全处理 undefined */
  private placeholderTrack(): Track {
    const track: Track = {
      id: 'placeholder',
      title: '',
      artist: '',
      artists: [],
      album: '',
      duration: 0,
      origin: TrackOrigin.LOCAL,
      providerId: ProviderId.LOCAL,
      songId: ''
    };
    return track;
  }
}
