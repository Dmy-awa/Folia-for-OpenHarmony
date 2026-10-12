/**
 * Folia HarmonyOS - 设置页
 *
 * 设置项与上游对齐，但只保留在鸿蒙端有意义的条目：
 *   - 在线音质、歌词主题、歌词时间轴偏移；
 *   - 播控中心歌词开关（对应 AVMetadata.lyric）；
 *   - 后台播放开关（对应长时任务）；
 *   - 在线服务地址与关于信息。
 *
 * 实现说明：卡片外壳没有抽成接受闭包的公共 Builder（ArkTS 的 @Builder 不支持
 * 把 builder 当普通函数参数传递），改为统一使用 cardShell 样式 + cardHeader builder。
 */
import { settingsStore } from '../services/settings/SettingsStore';
import { playbackController } from '../services/player/PlaybackController';
import { LYRIC_THEMES, LyricTheme } from '../components/lyrics/LyricTheme';
import { onlineSettings } from '../services/online/OnlineSettings';

/** 音质选项 */
interface QualityOption {
  id: string;
  label: string;
  hint: string;
}

const QUALITIES: QualityOption[] = [
  { id: 'standard', label: '标准', hint: '128kbps，省流量' },
  { id: 'higher', label: '较高', hint: '192kbps' },
  { id: 'exhigh', label: '极高', hint: '320kbps' },
  { id: 'lossless', label: '无损', hint: 'FLAC，需要会员或自建库支持' }
];

@ComponentV2
export struct SettingsView {
  @Require @Param safeTop: number;
  @Require @Param safeBottom: number;
  @Require @Param width: number;

  @Local private quality: string = settingsStore.get().quality;
  @Local private themeId: string = settingsStore.get().lyricTheme;
  @Local private offsetMs: number = settingsStore.get().lyricOffset;
  @Local private ccLyric: boolean = settingsStore.get().showLyricInControlCenter;
  @Local private backgroundPlayback: boolean = settingsStore.get().backgroundPlayback;
  @Local private wordByWord: boolean = settingsStore.get().wordByWordLyric;
  @Local private navidromeServer: string = onlineSettings.getNavidrome().serverUrl;
  @Local private neteaseServer: string = onlineSettings.getNetease().baseUrl;

  private controller = playbackController;

  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: 16 }) {
          this.sectionQuality()
          this.sectionLyric()
          this.sectionPlayback()
          this.sectionOnline()
          this.sectionAbout()
          Blank().height(this.safeBottom + 24)
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }

  @Builder
  header() {
    Column({ space: 2 }) {
      Blank().height(this.safeTop)
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFF2F4F8')
        .width('100%')
      Text('所有设置都会立即生效并自动保存')
        .fontSize(12)
        .fontColor('#80F2F4F8')
        .width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 卡片标题区，各 section 复用 */
  @Builder
  cardHeader(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFF2F4F8')
        .width('100%')
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(11)
          .fontColor('#80F2F4F8')
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionQuality() {
    Column({ space: 14 }) {
      this.cardHeader('在线音质', '影响在线歌曲的直链请求参数，本地文件不受影响')
      Column({ space: 8 }) {
        ForEach(QUALITIES, (option: QualityOption) => {
          Row({ space: 10 }) {
            Radio({ value: option.id, group: 'quality' })
              .checked(this.quality === option.id)
              .radioStyle({ checkedBackgroundColor: '#FF7DB8FF' })
              .onChange((checked: boolean) => {
                if (checked) {
                  this.quality = option.id;
                  settingsStore.setQuality(option.id);
                  onlineSettings.setQuality(option.id);
                }
              })
            Column({ space: 2 }) {
              Text(option.label)
                .fontSize(14)
                .fontColor('#FFF2F4F8')
              Text(option.hint)
                .fontSize(11)
                .fontColor('#80F2F4F8')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (option: QualityOption) => option.id)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FF14171F')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionLyric() {
    Column({ space: 16 }) {
      this.cardHeader('歌词', '歌词主题与时间轴偏移会立即应用到播放页')

      // 主题选择
      Column({ space: 8 }) {
        Text('歌词主题')
          .fontSize(13)
          .fontColor('#B3F2F4F8')
          .width('100%')
        Row({ space: 10 }) {
          ForEach(LYRIC_THEMES, (theme: LyricTheme) => {
            Text(theme.name)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themeId === theme.id ? '#FF0B0D12' : '#E6F2F4F8')
              .padding({ left: 18, right: 18, top: 8, bottom: 8 })
              .backgroundColor(this.themeId === theme.id ? '#FF7DB8FF' : '#1AFFFFFF')
              .borderRadius(16)
              .onClick(() => {
                this.themeId = theme.id;
                settingsStore.setLyricTheme(theme.id);
              })
          }, (theme: LyricTheme) => theme.id)
        }
        .width('100%')
      }
      .width('100%')

      // 偏移
      Column({ space: 6 }) {
        Row() {
          Text('时间轴偏移')
            .fontSize(13)
            .fontColor('#B3F2F4F8')
            .layoutWeight(1)
          Text(`${this.offsetMs > 0 ? '+' : ''}${this.offsetMs} ms`)
            .fontSize(13)
            .fontColor('#FF7DB8FF')
        }
        .width('100%')

        Slider({
          value: this.offsetMs,
          min: -2000,
          max: 2000,
          step: 50,
          style: SliderStyle.OutSet
        })
          .width('100%')
          .selectedColor('#FF7DB8FF')
          .trackColor('#26FFFFFF')
          .blockColor('#FFF2F4F8')
          .onChange((value: number, mode: SliderChangeMode) => {
            this.offsetMs = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              settingsStore.setLyricOffset(this.offsetMs);
              this.controller.setLyricOffset(this.offsetMs);
            }
          })

        Text('正值表示歌词比音频提前显示；范围 ±2000ms')
          .fontSize(11)
          .fontColor('#66F2F4F8')
          .width('100%')
      }
      .width('100%')

      this.toggleRow('优先使用逐字歌词', '关闭后只展示整行歌词，可降低渲染开销',
        this.wordByWord, (checked: boolean) => {
          this.wordByWord = checked;
          settingsStore.setWordByWordLyric(checked);
        })

      this.toggleRow('在播控中心显示歌词', '通过 AVMetadata.lyric 提供给系统播控中心与锁屏卡片',
        this.ccLyric, (checked: boolean) => {
          this.ccLyric = checked;
          settingsStore.setShowLyricInControlCenter(checked);
        })
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FF14171F')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionPlayback() {
    Column({ space: 12 }) {
      this.cardHeader('播放', '后台播放依赖系统长时任务与媒体会话')
      this.toggleRow('允许后台播放', '退到后台后继续播放，并在播控中心显示歌曲信息',
        this.backgroundPlayback, (checked: boolean) => {
          this.backgroundPlayback = checked;
          settingsStore.setBackgroundPlayback(checked);
        })
      Text('提示：鸿蒙要求音乐类应用在后台持续播放时必须接入媒体会话（AVSession）'
        + '并申请「音频播放」长时任务，本应用已默认满足该要求。')
        .fontSize(11)
        .fontColor('#66F2F4F8')
        .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FF14171F')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionOnline() {
    Column({ space: 14 }) {
      this.cardHeader('在线音乐服务', '留空则使用内置的酷狗匿名通道（搜索 / 试听 / 歌词）')
      this.inputRow('Navidrome 服务器', 'https://music.example.com',
        this.navidromeServer, (value: string) => {
          this.navidromeServer = value;
          // 服务器地址单独修改时保留已保存的账号密码
          const current = onlineSettings.getNavidrome();
          onlineSettings.setNavidrome(value, current.username, current.password);
        })
      this.inputRow('网易云 API 地址', 'http://192.168.1.10:3000',
        this.neteaseServer, (value: string) => {
          this.neteaseServer = value;
          onlineSettings.setNeteaseBaseUrl(value);
        })
      Text('网易云官方接口需要签名与 RSA 加密，客户端无法直接实现；'
        + '请自行部署 NeteaseCloudMusicApi 并把地址填在这里。')
        .fontSize(11)
        .fontColor('#66F2F4F8')
        .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FF14171F')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sectionAbout() {
    Column({ space: 10 }) {
      this.cardHeader('关于', '')
      this.infoRow('应用', 'Folia for HarmonyOS')
      this.infoRow('上游项目', 'chthollyphile/folia-major')
      this.infoRow('开源许可', 'AGPL-3.0')
      this.infoRow('目标平台', 'HarmonyOS NEXT API 14 · 手机 / 平板 / PC / 2in1')
      Text('本项目是 Folia 桌面版的鸿蒙移植版本，遵循上游的 AGPL-3.0 许可。'
        + '播放与歌词解析逻辑移植自上游，UI 使用 ArkUI 重写。')
        .fontSize(11)
        .fontColor('#66F2F4F8')
        .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FF14171F')
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  toggleRow(title: string, hint: string, checked: boolean, onChange: (checked: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontColor('#FFF2F4F8')
        Text(hint)
          .fontSize(11)
          .fontColor('#80F2F4F8')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: checked })
        .selectedColor('#FF7DB8FF')
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontColor('#B3F2F4F8')
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .placeholderColor('#59F2F4F8')
        .fontColor('#FFF2F4F8')
        .fontSize(13)
        .backgroundColor('#1AFFFFFF')
        .borderRadius(10)
        .height(40)
        .width('100%')
        .onChange(onChange)
    }
    .width('100%')
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#80F2F4F8')
        .width(90)
      Text(value)
        .fontSize(12)
        .fontColor('#E6F2F4F8')
        .layoutWeight(1)
    }
    .width('100%')
  }
}
