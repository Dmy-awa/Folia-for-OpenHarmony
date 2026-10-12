# 验证情况

本文记录本工程在**没有 ArkTS 编译器**的条件下做过的全部校验，以及这些校验
**能证明什么、不能证明什么**。目的有两个：让使用者知道当前可信到什么程度，
以及让后续维护者可以一键复跑。

---

## 1. 先说结论

| 项 | 状态 |
| --- | --- |
| ArkTS 编译 | ❌ **从未执行过**。编写环境没有 DevEco Studio，也没有 ArkTS 编译器 |
| 鸿蒙 API 符号 | ✅ 185 个符号对照 SDK 声明文件逐一核对通过 |
| 静态结构 | ✅ 50 个 `.ets` 文件，0 错误 0 警告 |
| 构建脚本 | ✅ PowerShell 官方 Parser + `bash -n` 全部通过 |
| CI 流水线 | ✅ 3 个文件结构校验通过 |
| Markdown 链接 | ✅ 13 个文件 / 101 个链接全部可解析（含锚点） |
| 歌词解密 | ✅ 与上游实现逐值对拍，1318 项断言全绿 |
| 音频标签解析 | ✅ 124 项断言 + 模糊测试通过 |
| 在线 provider 层 | ✅ 用真实 `tsc --strict` 整包检查 0 error |
| 运行时行为 | ❌ 未在真机 / 模拟器上验证过 |

**一句话**：代码的「结构正确性」和「API 名字正确性」有较强证据，
但「能不能编译过」与「跑起来什么表现」**仍然未知**。

---

## 2. 复跑方式

```bash
# verify_hos_api.py 需要一个 HarmonyOS SDK 的声明目录
$env:HOS_API_DIR = "C:\Program Files\Huawei\DevEco Studio\sdk\...\ets\api"   # Windows
export HOS_API_DIR="/path/to/sdk/ets/api"                                    # macOS / Linux

python tools/verify_hos_api.py     # API 符号核对
python tools/validate_arkts.py     # ArkTS 静态检查
python tools/validate_ci.py        # CI 流水线结构检查
python tools/check_links.py        # Markdown 相对链接与锚点检查
python tools/fix_imports.py        # 修正相对导入层级（写错时用）
python tools/make_icons.py         # 重新生成应用图标（需要 Pillow）
```

最后一项 `check_links.py` 会遍历全部 `.md`，验证相对链接与 `#锚点` 都能解析
（会自动跳过代码块与行内代码，避免把正则误判成链接）。

> 注：静态检查脚本会以 UTF-8 输出并容忍 Windows 中文控制台，
> 但 `validate_arkts.py` 的告警文本含中文，若你的终端是 GBK 代码页仍可能乱码，
> 建议 `chcp 65001` 后再跑。

---

## 3. 逐项说明

### 3.1 鸿蒙 API 符号核对（`tools/verify_hos_api.py`）

对 **15 个 SDK 声明文件、185 个 API 符号**逐一比对是否存在。覆盖范围：

| 声明文件 | 核对内容举例 |
| --- | --- |
| `@ohos.multimedia.avsession` | 元数据全字段、播放状态枚举、队列、12 个命令、`setAVMetadata` 等 |
| `@ohos.multimedia.media` | AVPlayer 状态机、`fdSrc`、`PlaybackStrategy`、全部回调名 |
| `@ohos.multimedia.audio` | 焦点中断枚举、`StreamUsage`、设备变化、`getSessionManager` |
| `@ohos.window` | 横屏、沉浸式、安全区、尺寸监听、`SystemBarProperties` |
| `@ohos.resourceschedule.backgroundTaskManager` | `BackgroundMode`、`AUDIO_PLAYBACK`、`startBackgroundRunning` |
| `@ohos.data.preferences` / `@ohos.file.fs` / `@ohos.file.picker` | `getPreferencesSync`、`OpenMode`、`DocumentViewPicker` |
| `@ohos.util` / `@ohos.display` / `@ohos.app.ability.wantAgent` | `Base64Helper`、`densityPixels`、`WantAgentFlags` |
| `@ohos.app.ability.UIAbility` / `AbilityStage` | 生命周期方法、`OnContinueResult` |

**它抓出的真实问题：**

- `backgroundTaskManager.startBackgroundTask` / `BackgroundTaskMode` 在该 SDK 声明中**不存在**
  → 确认应使用 `startBackgroundRunning` + `BackgroundMode.AUDIO_PLAYBACK`（API 14/15 的正确形态）；
- `errorManager.on('unhandledRejection')` 实为 **API 19+** → 目标 API 14 不可用，已移除；
- `abilityStage.context.currentHapModuleInfo` 查无此符号 → 已从日志里去掉。

> **局限**：这个校验只能证明「符号名存在」，不能证明「调用签名匹配」。
> 另外本机 SDK 是**裁剪过的声明集**（只有 `ets/api`，没有 `api/application/**` 子树），
> 因此 `Context.filesDir`、`UIAbilityContext.abilityInfo` 这类符号查不到，
> 它们是**额外对照 OpenHarmony 文档**确认的。`BackgroundTaskKeeper.resolveTarget()`
> 还为此加了常量兜底。

### 3.2 ArkTS 静态检查（`tools/validate_arkts.py`）

检查项：

1. 每个相对导入都能解析到真实文件；
2. 无 ArkTS 禁用的构造：`require()`、`any`、`Object.assign`、对象展开、
   `console.*`、DOM 全局、`localStorage`、`ESObject`；
3. 没有混用状态管理 V1 装饰器（`@State/@Prop/@Link/@ObjectLink`）；
4. 每个具名导入都真的被目标模块导出；
5. 类字段有初始化（或在构造函数中赋值）；
6. **`build()` 有唯一根容器**（ArkUI 硬约束）；
7. 必需配置文件齐全；
8. `main_pages.json` 指向的页面存在；
9. `$r('app.media.*')` 与 `module.json5` / `app.json5` 里的 `$string:` / `$color:` /
   `$media:` / `$profile:` 引用都存在。

**它抓出的真实问题：**

- **7 个文件的相对导入层级少了一级**（`../core/Types` 应为 `../../core/Types`）；
- `CoverArt` 与 `AppShell` 的 `build()` 以 `if` 开头，违反「唯一根容器」约束；
- `AVSession.on/off` 是一组重载，传动态事件名无法完成重载解析 → 改为字面量逐个注册。

> **局限**：这是正则 + 括号配平级别的检查，**不是类型检查**。
> 类型不兼容、ArkUI 组件属性名写错、API 版本可用性都必须靠编译器。

### 3.3 构建脚本与 CI

| 检查 | 方式 | 结果 |
| --- | --- | --- |
| `scripts/*.ps1` | PowerShell 官方 `Parser::ParseFile` | ✅ 2/2 |
| `scripts/*.sh` | `bash -n` | ✅ 3/3 |
| `ci/*.yml` | YAML 解析 + 结构校验（`tools/validate_ci.py`） | ✅ 3/3 |

`validate_ci.py` 会检查：触发块 / jobs / steps 是否存在、
每个 step 必须有且只有一个 `uses` 或 `run`、构建任务必须上传产物、
**`secrets.*` 不得用于 `if:`**、`env.RUNNER_TEMP` 应写成 `runner.temp`、
以及 workflow 里引用的 `scripts/*` 是否真实存在。

**它抓出的真实问题**：`env.RUNNER_TEMP` 用错、`secrets` 出现在 `if:` 里——
这两个都是「只有跑起来才会报错」的问题。

### 3.4 与上游的逐值对拍

两个子模块在 Node 24 下**直接执行 `.ets` 的真实逻辑**（stub 掉 `@kit.*` 声明），
与上游 TypeScript 实现做对拍：

**KRC / QRC 解密 — 1318 项断言全绿**

- SBOX 8×64 = 512 项与上游 `JSON.stringify` 完全相等；
  并额外验证了 `SBOX[1]` 中 15 出现 5 次、`SBOX[3]` 中 10 出现 5 次
  （其余 6 组是标准 DES 的每值 4 次）——**证明它是 QQ 变体，不能用系统 DES192 替代**；
- INFLATE 与 `node:zlib` 在 4 个压缩级别 × 5 种策略 × 多种输入规模下全对拍；
- `key_schedule` / `crypt` / `f` / `initial_permutation` / `inverse_permutation` /
  `tripledes_*` 在数百组随机输入上逐值相等；
- QRC 端到端：用上游自己的 `tripledes_key_setup(key, 1)` 反向加密构造密文再解回。

**音频标签解析 — 124/124 断言通过**

- 9 类真实容器文件（MP3 各 ID3 版本 / FLAC / Ogg / M4A / WAV / ADTS）；
- 模糊测试：每种容器的**全部截断长度** + 300 次随机字节破坏 + 首 64 字节逐个置 `0xFF`，
  无异常抛出、无 `NaN`/`Infinity`、无越界；
- 过程中查出并修掉 2 个真实 bug（MP3 `TPE1` 未拆分 artists、MP4 `aART` 未识别）。

**在线 provider 层 — `tsc --strict` 0 error**

把 8 个 provider 文件与 `core/Types.ets`、`core/Logger.ets` 镜像成 `.ts`，
为 7 个 `@kit.*` 模块写桩声明，用真实 tsc 5.4 `--strict` 整包检查；
另加一个复刻 `AppBootstrap` / `SearchView` 调用点的集成探针，同样 0 error。

> **局限**：对拍只能证明**这两个模块的算法与上游一致**，
> 不能证明它们在 ArkTS 下能编译，也不能证明运行时的 IO 行为正确。

---

## 4. 已知的未验证面

按风险从高到低：

| # | 未验证项 | 说明 |
| --- | --- | --- |
| 1 | **ArkTS 编译** | 类型兼容性、ArkUI 组件属性合法性、API 版本可用性全部未过编译器 |
| 2 | **AVSession 实际表现** | 播控中心卡片、锁屏卡片、实况胶囊在真机上的行为 |
| 3 | **后台长时任务** | 系统是否会因为取消时机不当而终止进程 |
| 4 | **酷狗匿名通道** | 上游规范用 http 明文，工程已默认改 https，但**未在真机验证过** |
| 5 | **音频焦点时序** | 来电 / 其他应用抢占时的暂停-恢复行为 |
| 6 | **本地库大文件导入** | 数 GB 音乐库下的内存与耗时表现 |
| 7 | **`@ohos.zlib` 缺失同步接口**的替代实现 | 自移植的 puff.c INFLATE 虽已与 `node:zlib` 对拍，但未在设备上跑过 |

---

## 5. 这些校验**不能**替代什么

- 不能证明工程能编译通过；
- 不能证明运行时行为正确；
- 不能证明 ArkUI 布局在真机上如预期（断点、安全区、模糊背景性能等）；
- 不能证明第三方依赖版本兼容。

首次在 DevEco Studio 中打开时，建议先 `Build → Clean Project` 再编译，
并把编译错误按模块逐个收敛。欢迎把编译日志提到 issues。
