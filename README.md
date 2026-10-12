<div align="center">
  <img src="AppScope/resources/base/media/app_icon.png" width="104" alt="Folia for HarmonyOS">
  <h1>Folia for HarmonyOS</h1>
  <p><b>辞曲新境</b> · 鸿蒙原生沉浸式歌词音乐播放器</p>
  <p>该项目移植还未结束，如果您有什么好的想法或建议欢迎提交Issues</p>
  <p><a href="https://github.com/chthollyphile/folia-major">Folia</a> 桌面版的 HarmonyOS NEXT 移植</p>
</div>

<div align="center">

![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20NEXT-0A59F7)
![API](https://img.shields.io/badge/API-14%20%285.0.2%29-4CAF50)
![Language](https://img.shields.io/badge/ArkTS-ArkUI%20V2-9C27B0)
![License](https://img.shields.io/badge/License-AGPL--3.0-blue)
![Build](https://img.shields.io/badge/build-not%20yet%20compiled-orange)

</div>

---
> 详细的可信度说明见 **[docs/VERIFICATION.md](docs/VERIFICATION.md)**。
> 如果你编译时遇到错误，欢迎提 issue 附上日志。

---

## 目录

- [这是什么](#这是什么)
- [关于「控制栏 / 灵动岛」](#关于控制栏--灵动岛)
- [功能特性](#功能特性)
- [鸿蒙适配要点](#鸿蒙适配要点)
- [模块状态](#模块状态)
- [快速开始](#快速开始)
- [项目结构](#项目结构)- [已知限制](#已知限制)
- [文档](#文档)
- [衍生作品声明](#衍生作品声明)
- [许可与免责](#许可与免责)

---

## 这是什么

**Folia** 是一个以「全屏沉浸式歌词」为核心的在线音乐播放器，上游是
[chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)——一个基于 Electron + React 的桌面应用
（`src/` 约 27.9 万行 TypeScript）。

本项目把它的**播放语义与歌词内核**移植到 **HarmonyOS NEXT**，UI 用
**ArkTS / ArkUI（状态管理 V2）** 全部重写。因为两边的技术栈没有重叠：

| 上游 | 鸿蒙 | 处理方式 |
| --- | --- | --- |
| React + zustand + Tailwind | ArkUI + `@ObservedV2` | UI 全量重写 |
| Web Audio（双 deck + EQ + 9 个效果） | **无对等能力** | 本期未移植，见 [架构说明](docs/ARCHITECTURE.md#10-为什么音效链没做) |
| `<audio>` 元素 | AVPlayer | 重写，状态机与回调完全不同 |
| Dexie / IndexedDB | preferences + 文件 | 重写持久化层 |
| Node 主进程（crypto / npm provider 包） | `@kit.NetworkKit` / `@kit.CryptoArchitectureKit` | 重写网络与签名 |
| `music-metadata`（npm） | — | **自行实现** 6 种容器的标签解析 |

**它是**：一份完整的、结构上自洽的鸿蒙工程源码，播放 / 歌词 / 本地库 / 在线源四条链路都已实现。
**它不是**：可以直接 `Run` 就跑起来的成品应用——见上面的状态声明。

---

## 关于「控制栏 / 灵动岛」

这是本项目研究得最深、也最容易踩坑的一块。

「在控制栏、灵动岛可以快捷操作以及显示歌曲信息」在鸿蒙上的**唯一正解是
[AVSession](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/avsession-overview)（媒体会话）**，
**不是**调用实况窗（LiveViewKit）API：

| 能力 | 官方 API | 三方音乐 App 可否使用 | 本项目 |
| --- | --- | --- | --- |
| 播控中心（控制栏）播控卡片 | `avSession` | ✅ | ✅ 已实现 |
| 锁屏播控卡片 | `avSession` | ✅ 系统自动发送，**零 UI 代码** | ✅ 已实现 |
| 状态栏实况胶囊 / 锁屏沉浸播放态（俗称「灵动岛」） | 系统播控服务基于 AVSession 数据渲染 | ✅ 间接可用 | ✅ 已实现（只需喂数据） |
| 播控中心显示歌词 | `AVMetadata.lyric` | ✅ | ✅ 已实现 |
| 蓝牙 / 有线耳机按键 | `avSession` 的 `handleKeyEvent` | ✅ | ✅ 已实现 |
| 实况窗 `liveViewManager.startLiveView` | `@kit.LiveViewKit` | ❌ **音乐场景不可用** | ❌ 有意未实现 |

**结论**：接入 AVSession 后，系统会据此自动渲染控制栏卡片、锁屏卡片与实况胶囊——
零审批、零 UI 代码。这正是主流音乐平台（华为音乐、酷狗、QQ 音乐）的做法。
完整证据链见 [`docs/hos-api/liveview.md`](docs/hos-api/liveview.md)。

---

## 功能特性

**播放**
- AVPlayer 封装：完整状态机、`url` / `fdSrc` 双源、播放速率、缓冲上报
- 音频焦点中断处理（`INTERRUPT_FORCE` / `INTERRUPT_SHARE`、DUCK / UNDUCK）
- 拔出耳机自动暂停并取消长时任务
- 后台播放（长时任务 + `KEEP_BACKGROUND_RUNNING`）
- 播放队列：追加 / 下一首播放（**两种行为都先去重再重插**）、随机重排、四种循环模式

**鸿蒙媒体播控**
- AVSession 元数据 / 播放状态 / 播放队列上报
- 12 个播控命令回调（play / pause / next / previous / seek / setLoopMode /
  toggleFavorite / skipToQueueItem / handleKeyEvent / fastForward / rewind …）
- 播控中心歌词（`AVMetadata.lyric`，按 UTF-8 字节数安全截断）

**歌词**
- 格式：LRC · 增强 LRC · VTT · YRC · QRC · KRC · AWLRC
- **KRC / QRC 解密**：含自定义 S-box 的 3DES（不能用系统 DES192 替代）与自移植的 INFLATE
- 逐字扫光、翻译 / 罗马音配对、间奏呼吸点、运行时时间轴偏移（±2000ms）
- 3 套歌词主题：**浮名** / **流光** / **心象**
- 时间轴与上游一致使用**秒**，全应用仅一处 ms↔s 换算

**本地音乐库**
- 系统文件选择器导入 → 沙箱存储 → 标签解析 → 封面抽取
- 自行实现的容器解析：ID3v2.2/2.3/2.4 + ID3v1 · FLAC · Ogg Vorbis/Opus · MP4/M4A · WAV · ADTS
- 侧车歌词探测（`.lrc → .vtt → .ttml → .qrc → .yrc → .krc`）与内嵌歌词
- 面对损坏文件**绝不抛异常**，最多返回空字段

**在线音乐**（三层结构：Transport → Provider → OmniRouter）
- **Navidrome / Subsonic**：完全端侧实现，只需 MD5
- **酷狗匿名通道**：搜索 / 直链 / 歌词，含官方签名算法，免登录
- **网易云**：可配置 API 基址的 HTTP 客户端（加密在 npm 包里，端侧无法复刻）

---

## 鸿蒙适配要点

- **全局横屏**：`module.json5` 的 `orientation: landscape` +
  `preferMultiWindowOrientation: landscape` + 运行时 `setPreferredOrientation`。
  ⚠️ **PC / 2in1 上方向锁不生效**（自由窗口模型），代码会主动跳过并要求布局能接受任意宽高比。
- **四形态适配**：`deviceTypes: ["phone", "tablet", "2in1", "default"]`；
  断点 `xs/sm/md/lg` 驱动布局，`lg` 下播放页展开右侧队列面板、曲库变双栏。
- **AVSession 激活顺序是硬约束**：
  `createAVSession → setAVMetadata → setAVPlaybackState → 注册命令 → activate()`。
- **单位陷阱**：`seek` 回调是**毫秒**，`fastForward` / `rewind` 是**秒**。
- `AVMetadata.assetId` **必填**，空值直接返回 `6600101`；切歌必须换 `assetId`。
- 后台播放三条铁律：一个 UIAbility 只能有一个长时任务 / 取消必须与暂停成对 /
  `STREAM_USAGE_MUSIC` 必须同时接入 AVSession。

更多细节见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**，其中「必须遵守的清单」一节的
22 条硬约束全部经过官方文档核实。

---

## 模块状态

| 模块 | 状态 |
| --- | --- |
| 工程骨架（AppScope / entry / hvigor / build-profile） | ✅ 完整 |
| 四形态适配 + 全局横屏 | ✅ 完整 |
| 音频引擎（AVPlayer）+ 音频焦点 + 设备切换 | ✅ 完整 |
| 后台播放（长时任务） | ✅ 完整 |
| 媒体播控（AVSession + 播控中心歌词） | ✅ 完整 |
| 歌词内核（7 种格式 + KRC/QRC 解密 + 时间轴） | ✅ 完整 |
| 本地音乐库（导入 + 标签解析 + 封面 + 侧车歌词） | ✅ 完整 |
| 在线音乐（Navidrome / 酷狗匿名） | ✅ 完整 |
| 在线音乐（网易云） | ⚠️ 需自建 API 服务 |
| UI（播放页 / 歌词舞台 / 曲库 / 搜索 / 设置） | ✅ 完整 |
| 音效链（EQ + 9 个效果） | ❌ 未移植（无 Web Audio） |
| Automix 无级过渡 | ❌ 未移植（规划层可移植，DSP 部分需重写） |
| 壁纸模式 / OBS / Discord RPC / 远程遥控窗 / 转码 / 模组系统 | ❌ 有意舍弃（桌面端专属） |

---

## 快速开始

### 环境要求

| 项 | 版本 |
| --- | --- |
| DevEco Studio | 5.0.2 Release 或更高 |
| HarmonyOS SDK | API 14（`5.0.2(14)`）或更高 |
| Node.js | 18+（DevEco 自带一份） |
| 目标设备 | HarmonyOS NEXT 手机 / 平板 / 鸿蒙电脑（2in1） |

### 方式一：DevEco Studio

```text
1. File → Open，选择本仓库根目录（含 build-profile.json5 的那一层）
2. 等待 hvigor Sync 完成
3. File → Project Structure → Signing Configs
   → 勾选 Automatically generate signature（需登录华为开发者账号）
4. 连接设备或启动模拟器 → 点击 ▶ Run
```

### 方式二：命令行

工程自带 hvigor 启动脚本与跨平台构建封装：

```powershell
# Windows
.\scripts\build-hap.ps1                    # debug
.\scripts\build-hap.ps1 -BuildMode release -Clean
```

```bash
# macOS / Linux
./scripts/build-hap.sh                     # debug
./scripts/build-hap.sh -m release -c
```

产物在 `entry/build/default/outputs/default/`：
`entry-default-unsigned.hap`（未签名，不能装）与 `entry-default-signed.hap`（可安装）。

> 📖 **签名、安装、CI 与报错排查见 [docs/BUILD.md](docs/BUILD.md)**。
> 一句话版本：**能装到鸿蒙 NEXT 手机上的 HAP 必须由华为签发的证书签名**，
> 而该证书只能通过 DevEco 的「自动生成签名」（登录华为账号）获得——
> 这是账号/信任链问题，本地任何方案都绕不过去。

### 方式三：CI 自动构建

`ci/` 下提供三套流水线模板，**需要复制到对应位置才会生效**：

| 模板 | 放到哪里 | 产物能否装手机 |
| --- | --- | --- |
| `ci/github-actions-selfhosted.yml` | `.github/workflows/build-hap-selfhosted.yml` | ✅ 能（需自托管 Runner + 签名 secrets） |
| `ci/github-actions-openharmony-sdk.yml` | `.github/workflows/build-hap-openharmony.yml` | ❌ 只能装 OpenHarmony 设备 |
| `ci/gitee-go-build-hap.yml` | `.workflow/build-hap.yml` | ❌ 同上 |

> 两个 GitHub 方案**互斥，请按需二选一**——同时启用会让每次 push 多跑一遍，
> 其中一个还要下载 4 GB SDK。选型说明见 [`ci/README.md`](ci/README.md)。

### 首次使用

1. 进入**本地曲库** → 点击「导入音乐」选择本机音频文件；
2. 选一首播放 → 进入**正在播放**页看全屏歌词；
3. 屏幕顶部下拉打开**控制中心** → 可见播控卡片与歌词；
4. 按 Home 退到后台 → 音乐继续播放，锁屏出现播控卡片；
5. 在**设置**里配置 Navidrome / 网易云 API 地址以启用在线曲库。

---

## 项目结构

```
folia-harmonyos/
├── AppScope/                     # 应用级配置与图标
├── entry/src/main/
│   ├── module.json5              # 四形态设备 + 权限 + 长时任务 + 横屏
│   ├── ets/
│   │   ├── entryability/         # 窗口适配 → loadContent → 业务启动
│   │   ├── app/AppBootstrap.ets  # 依赖注入与装配
│   │   ├── core/                 # 领域模型 Types · Logger · Constants
│   │   ├── state/ utils/         # 全局布局状态 · 断点 · 窗口适配
│   │   ├── services/
│   │   │   ├── player/           # AudioEngine · PlaybackQueue · PlaybackController · BackgroundTaskKeeper
│   │   │   ├── media/            # MediaSessionService(AVSession) · ControlCenterLyric
│   │   │   ├── lyrics/           # LyricCore · LyricParsers · KrcDecoder · QrcDecoder · LyricTimeline
│   │   │   ├── library/          # LocalLibraryService · MetadataReader · 6 种容器解析器
│   │   │   ├── online/           # HttpTransport · CryptoUtil · OmniRouter · 3 个 Provider
│   │   │   └── settings/         # SettingsStore
│   │   ├── components/           # LyricStage · LyricTheme · TransportBar · ProgressBar · CoverArt
│   │   └── views/                # AppShell · PlayerView · LibraryView · SearchView · SettingsView
│   └── resources/                # 颜色 / 字符串 / SVG 图标 / 启动图
├── ci/                           # GitHub Actions ×2 + Gitee Go
├── scripts/                      # 构建 / 签名 / CI 入口脚本
├── tools/                        # 自检脚本（API 核对 · 静态检查 · CI 校验）
├── docs/                         # 构建手册 · 架构 · 验证 · 移植 · API 核实
└── README.md
```

---

## 已知限制

1. **未经过 ArkTS 编译器验证**——见开头的状态声明与 [docs/VERIFICATION.md](docs/VERIFICATION.md)。
2. **实况窗（LiveViewKit）不可用**——音乐场景不在其 `event` 枚举内，原因见上文。
3. **网易云需要自建服务**——加密逻辑在下游 npm 包里，上游仓库源码中不含任何密钥。
4. **PC / 2in1 上方向锁不生效**——系统行为，布局已能接受任意宽高比，但无法强制横屏窗口。
5. **TTML 暂按增强 LRC 解析**——需要 XML 解析器，ArkTS 侧可接 `@ohos.xml`。
6. **`@ohos.zlib` 没有同步解压接口**——KRC/QRC 用的 INFLATE 是自移植的 `puff.c`。
7. **音频标签解析的部分场景受限**——ID3v2.2 只映射常用帧；无 Xing 头的 VBR MP3 用首帧码率估算；
   ADTS AAC 得不出时长；老式 GBK 编码标签可能乱码。
8. **曲库索引是 JSON 文件**——上万首规模时建议换成关系型数据库。
9. **UI 文案为中文硬编码**——接入 `@ohos.intl` + 资源限定词即可多语言化。

---

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/BUILD.md](docs/BUILD.md) | **构建与签名手册**：两种构建方式、四种签名方案、安装与报错排查 |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | **验证情况**：做过哪些校验、能证明什么、不能证明什么 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | **架构与鸿蒙适配**：横屏、AVSession、后台、歌词内核、在线源 |
| [docs/PORTING.md](docs/PORTING.md) | **移植说明**：上游文件 → ArkTS 模块映射、语义对齐、22 条踩坑清单 |
| [ci/README.md](ci/README.md) | CI 选型说明与「手机可装 HAP」的信任链原理 |
| [docs/hos-api/](docs/hos-api/) | 鸿蒙 API 核实结果：AVSession · AVPlayer · 窗口 · 实况窗 |
| [docs/porting/](docs/porting/) | 上游分析：播放架构 · 歌词规范（140KB） · 在线源规范（85KB） |

---

## 衍生作品声明

依据 **AGPL-3.0 第 5 条**，在此明确声明本仓库是上游项目的修改版本：

- **来源**：[chthollyphile/folia-major](https://github.com/chthollyphile/folia-major)，作者 chthollyphile 及[全部贡献者](https://github.com/chthollyphile/folia-major/blob/main/CONTRIBUTORS.md)。
- **修改内容**：将运行平台从 Electron + React（Windows / macOS / Linux）改为 HarmonyOS NEXT；
  UI 层用 ArkTS / ArkUI 全部重写；播放、播控、窗口、存储、网络、音频标签解析为鸿蒙侧重新实现；
  歌词解析、播放队列语义、歌词主题设计移植自上游。
- **修改日期**：2025 年（详见 Git 提交历史）。
- **移除的内容**：壁纸模式、OBS 浏览器源、Discord RPC、远程遥控窗、转码兜底、
  Folium 模组系统、视频导出、ONNX 推理等桌面端专属能力。

**衍生自上游的部分**：歌词解析算法（`src/utils/lyrics/*`）、播放队列语义
（`src/utils/queueAddBehavior.ts`）、歌词主题设计、在线 provider 的接口契约与端点。
**鸿蒙侧重新编写**：`services/player/`、`services/media/`、`services/library/`、
`services/online/`（网络与签名）、`utils/`、`components/`、`views/`。

美术资源方面：应用图标为本项目自行绘制，**未使用上游的任何美术资源**。

---

## 许可与免责

### 许可

本项目沿用上游的 **[AGPL-3.0](LICENSE)** 许可。你可以自由使用、修改、分发，
但分发修改版本时必须同样以 AGPL-3.0 开源并提供完整源码。

### 免责声明

- 本项目是**非官方的第三方移植**，与上游作者、华为技术有限公司**均无隶属关系**，
  未获得任何一方的背书或支持。
- 项目中的在线音乐接口（网易云 / 酷狗 / Navidrome）均为**非官方接口**，
  其可用性、稳定性与合法性由使用者自行判断并承担相应责任。
  请仅将本项目用于**个人学习与研究**，并遵守所在地区的法律法规与各平台的服务条款。
- 本项目不内置、不分发任何音乐内容或解密密钥。
- 软件按「原样」提供，不附带任何形式的担保。使用本软件产生的任何后果由使用者自行承担。

### 贡献

欢迎提交 issue 与 PR。当前最有价值的贡献是：

1. **编译日志**——让工程真正过一遍 ArkTS 编译器并修掉类型错误；
2. **真机验证结果**——尤其是 AVSession 播控卡片、后台长时任务、酷狗匿名通道；
3. **界面截图**——本项目暂无截图，欢迎补充。
