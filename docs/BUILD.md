# 构建与签名手册

本文说明如何把本工程打包成可安装的 **HAP**。

> **先看这一句，能省你半小时：**
> 能装到**鸿蒙 NEXT 手机**上的 HAP，必须由**华为签发的证书**签名，
> 而该证书只能通过 DevEco Studio 的「自动生成签名」（登录华为开发者账号）获得。
> 这是账号/信任链问题，不是工具链问题——没有账号、没有 DevEco，
> 任何本地方案都产不出手机可装的包。
> 如果你的目标设备是 OpenHarmony 设备或模拟器，则可以完全免账号（见 4.3）。

---

## 1. 前置条件

| 项 | 要求 | 检查方式 |
| --- | --- | --- |
| DevEco Studio | 5.0.2 Release 或更高 | 打开 IDE 看 About |
| HarmonyOS SDK | API 14（`5.0.2(14)`）或更高 | DevEco → SDK Manager |
| Node.js | 18+（DevEco 自带一份可直接用） | `node --version` |
| JDK | 8+（仅手动签名时需要） | `java -version` |
| hdc | DevEco SDK 的 `toolchains` 下 | `hdc -v` |

工程已自带 hvigor 启动脚本（`hvigorw` / `hvigorw.bat` / `hvigor/hvigor-wrapper.js`），
**不需要**额外安装 hvigor 或 ohpm。

### 1.1 配置 SDK 路径（命令行构建必做）

hvigor 需要知道 SDK 在哪，二选一：

**方式 A：工程级配置（推荐）**

```bash
cp local.properties.example local.properties
# 编辑 local.properties，把 sdk.dir 指向你的 SDK 根目录
```

Windows 路径需要转义（`:` → `\:`，`\` → `\\`）：

```properties
sdk.dir=C\:\\Users\\你的用户名\\AppData\\Local\\Huawei\\Sdk
```

**方式 B：环境变量**

```powershell
# Windows PowerShell
$env:DEVECO_SDK_HOME = "C:\Users\你的用户名\AppData\Local\Huawei\Sdk"
```

```bash
# macOS / Linux
export DEVECO_SDK_HOME="$HOME/Library/Huawei/Sdk"
```

`local.properties` 已在 `.gitignore` 中，不会被提交。

---

## 2. 方式一：DevEco Studio 图形界面（最简单，推荐首次使用）

1. **打开工程**：`File → Open`，选择本仓库根目录（含 `build-profile.json5` 的那一层）。
2. **等待 Sync**：右下角进度条走完。首次会从 ohpm 仓库拉取 `@ohos/hypium` 等开发依赖。
3. **配置签名**：`File → Project Structure → Signing Configs`
   - 勾选 **Automatically generate signature**
   - 按提示登录华为开发者账号
   - IDE 会自动生成 `.p12` / `.cer` / `.p7b` 并回填到 `build-profile.json5`
4. **连接设备**：USB 连接手机，或在 Device Manager 启动模拟器。
5. **构建并安装**：点击 ▶ Run，或 `Build → Build Hap(s)/APP(s) → Build Hap(s)`。

产物位置：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

> **提示**：首次在 DevEco 打开后，建议先执行一次 `Build → Clean Project`，
> 排除缓存干扰再编译。

---

## 3. 方式二：命令行一键构建

工程提供了跨平台脚本，封装了 hvigor 的正确调用方式、SDK 探测、产物定位与可选签名。

### Windows

```powershell
# debug 构建
.\scripts\build-hap.ps1

# release 构建 + 清理旧产物
.\scripts\build-hap.ps1 -BuildMode release -Clean

# 构建并用已有材料签名
.\scripts\build-hap.ps1 -Sign `
    -Keystore C:\sign\app.p12 -KeystorePwd 你的口令 `
    -KeyAlias key0 -KeyPwd 你的口令 `
    -AppCert C:\sign\app.cer -Profile C:\sign\profile.p7b
```

### macOS / Linux

```bash
chmod +x scripts/*.sh
./scripts/build-hap.sh                      # debug
./scripts/build-hap.sh -m release -c        # release + 清理
./scripts/build-hap.sh -s \
    --keystore /sign/app.p12 --keystore-pwd 口令 \
    --key-alias key0 --key-pwd 口令 \
    --app-cert /sign/app.cer --profile /sign/profile.p7b
```

### 它实际执行的命令

如果你想知道脚本背后做了什么（或想自己手动执行）：

```bash
./hvigorw \
    --mode module \
    -p product=default \
    -p module=entry@default \
    -p buildMode=debug \
    assembleHap --no-daemon
```

产物在 `entry/build/default/outputs/default/` 下：

| 文件名 | 含义 |
| --- | --- |
| `entry-default-unsigned.hap` | 未签名，**不能安装** |
| `entry-default-signed.hap` | 已签名，可安装 |

---

## 4. 签名详解

### 4.1 方式 A：DevEco 自动签名（唯一能出「手机可装」包的路径）

见第 2 节第 3 步。IDE 会把材料生成到：

```
<用户目录>/.ohos/config/
├── default_<工程名>_<哈希>.p12     # 密钥库
├── default_<工程名>_<哈希>.cer     # 应用证书
└── default_<工程名>_<哈希>.p7b     # provisioning profile（按设备 UDID 签发）
```

并在 `build-profile.json5` 里写入：

```json5
"signingConfigs": [
  {
    "name": "default",
    "type": "HarmonyOS",
    "material": {
      "certpath": "...cer",
      "storePassword": "...",   // DevEco 加密后的口令
      "keyAlias": "...",
      "keyPassword": "...",
      "profile": "...p7b",
      "signAlg": "SHA256withECDSA",
      "storeFile": "...p12"
    }
  }
]
```

配置好后，**命令行构建也会自动签名**，产物直接是 `*-signed.hap`。

> ⚠️ `storePassword` / `keyPassword` 是 DevEco 加密过的密文，不能用明文替换，
> 也不能直接拿这段配置到别的机器上用——换机器必须重新生成签名。

### 4.2 方式 B：命令行手动签名（用已有的 .p12 / .cer / .p7b）

当签名材料已经有了（例如从 CI secrets 注入），但 `build-profile.json5` 里没配：

```bash
# 1) 先构建出未签名包
./scripts/build-hap.sh

# 2) 再签名
./scripts/sign-hap.sh \
    --input  entry/build/default/outputs/default/entry-default-unsigned.hap \
    --output out/folia-signed.hap \
    --keystore /sign/app.p12 --keystore-pwd 口令 \
    --key-alias key0 --key-pwd 口令 \
    --app-cert /sign/app.cer --profile /sign/profile.p7b
```

底层调用的是华为官方签名工具：

```bash
java -jar hap-sign-tool.jar sign-app \
    -keyAlias   "key0" \
    -signAlg    "SHA256withECDSA" \
    -mode       "localSign" \
    -appCertFile "app.cer" \
    -profileFile "profile.p7b" \
    -inFile      "entry-default-unsigned.hap" \
    -keystoreFile "app.p12" \
    -outFile     "folia-signed.hap" \
    -keyPwd      "口令" \
    -keystorePwd "口令"
```

`hap-sign-tool.jar` 的位置：

- DevEco：`<SDK>/.../toolchains/lib/hap-sign-tool.jar`
- 独立的 HAP 安装工具：`C:\Program Files (x86)\HAPInstallTool\tools\hap-sign-tool.jar`

脚本会自动探测这两处，也可以用 `--sign-tool-jar` / `-SignToolJar` 显式指定。

### 4.3 方式 C：OpenHarmony 调试签名（免账号，仅 OpenHarmony 设备可用）

华为云公开的 OpenHarmony SDK 自带一整套调试签名材料，位于
`<SDK>/.../toolchains/lib/`：

| 文件 | 用途 | 默认口令 |
| --- | --- | --- |
| `OpenHarmony.p12` | 密钥库 | `123456` |
| `OpenHarmonyApplication.pem` | 应用证书链 | — |
| `UnsgnedDebugProfileTemplate.json` | profile 模板 | — |

```bash
./scripts/sign-hap.sh --input <unsigned.hap> --output <signed.hap> --oh-debug
```

> ⚠️ **该模式产出的 HAP 安装了鸿蒙 NEXT 手机会被拒绝**（签名信任链不匹配），
> 只能装到 OpenHarmony 设备 / 模拟器。
> 另外 `UnsgnedDebugProfileTemplate.json` 需要先用 `hap-sign-tool.jar sign-profile`
> 转成 `.p7b` 才能用，具体参数请对照华为官方《hap-sign-tool 使用指导》——
> 该步骤的命令行参数随版本有差异，本文不提供未经验证的写法以免误导。

### 4.4 方式 D：自己生成证书链

`hap-sign-tool.jar` 提供 `generate-keypair` / `generate-csr` / `generate-app-cert` /
`generate-profile-cert` / `sign-profile` 等子命令，可以自建一条证书链。
但生成的证书**仍然不被鸿蒙 NEXT 手机信任**（因为根不是华为的），
只适合 OpenHarmony 设备测试。

如果你确实需要这条路，请以华为官方《hapsigner 使用指导》为准——
各子命令的参数在不同版本间有调整，照抄博客容易踩坑。

---

## 5. 安装到设备

```bash
# 确认设备已连接
hdc list targets

# 安装（-r 表示覆盖安装）
hdc install -r out/folia-signed.hap

# 卸载
hdc uninstall top.izuna.foliamajor.hmos

# 查看应用日志（域名 0xF0A1 是本应用的 hilog 标签）
hdc shell hilog | Select-String Folia     # Windows
hdc shell hilog | grep Folia              # macOS / Linux
```

`hdc` 位置：

- DevEco：`<SDK>/.../toolchains/hdc.exe`
- 独立 HAP 安装工具：`C:\Program Files (x86)\HAPInstallTool\tools\hdc.exe`

### 安装失败的常见原因

| 报错 | 原因 | 处理 |
| --- | --- | --- |
| `failed to install, error: 9568289` | 签名校验失败 | 确认用的是华为签发材料，而非 OpenHarmony 的 |
| `error: 9568259` | profile 里没有这台设备的 UDID | 在 DevEco 里重新生成签名（会自动登记当前设备） |
| `compatibleSdkVersion ... do not match` | 设备 API 版本低于工程 `compatibleSdkVersion` | 降低 `compatibleSdkVersion`，或换更高版本设备 |
| `device type not supported` | 设备形态不在 `deviceTypes` 里 | 检查 `module.json5` 的 `deviceTypes` |

---

## 6. CI

三套流水线配置在 [`ci/`](../ci/) 目录，选型与原理见 [`ci/README.md`](../ci/README.md)。
速览：

| 配置 | 手机可装 | 需要什么 |
| --- | --- | --- |
| `ci/github-actions-selfhosted.yml` | ✅ | 自托管 Runner + DevEco + 签名 secrets |
| `ci/github-actions-openharmony-sdk.yml` | ❌ | 无（ubuntu-latest 即可，主要验证编译） |
| `ci/gitee-go-build-hap.yml` | ❌ | Gitee 仓库 + 公共构建机 |

任何 CI 都只需调用同一个入口：

```bash
./scripts/ci-build-hap.sh --sdk-type harmonyos --build-mode release
```

---

## 7. 报错排查

### 构建阶段

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `ERROR: Couldn't find hvigor/hvigor-wrapper.js` | 工程文件缺失 | 确认 `hvigor/hvigor-wrapper.js` 存在（本仓库自带） |
| `SDK component missing` / `sdk.dir not found` | SDK 路径没配对 | 按 1.1 配置 `local.properties` 或 `DEVECO_SDK_HOME` |
| `Cannot find module '@ohos/hypium'` | 依赖没装 | 在 DevEco 里 Sync 一次，或 `ohpm install --all` |
| `UseNormalizedOHMUrl can be true only when Compatible SDK Version is 5.0.0 (12) or later` | `compatibleSdkVersion` 太低 | 保持 `5.0.2(14)` 或更高 |
| `ArkTS:ERROR ... is not assignable` | 类型不兼容 | 本工程未经编译器验证，首次编译可能需要微调；请对照 SDK 声明修改 |
| `Cannot find name 'xxx'` / 找不到 `@kit.*` | SDK 版本过低或不是 HarmonyOS SDK | 确认 SDK 含 `ets/kits` 目录 |
| 构建很慢 / OOM | hvigor 默认堆偏小 | 已在 `hvigor/hvigor-config.json5` 设 `maxOldSpaceSize: 8192`，可按机器调整 |

### 签名阶段

| 报错码 | 含义 | 处理 |
| --- | --- | --- |
| `0x1000` / `0x1001` | 口令错误 | 核对 keystore 口令与 key 口令（两者可以不同） |
| `0x1002` | profile 与证书不匹配 | profile 必须由签发该证书的同一账号生成 |
| `0x1003` | 签名算法与密钥类型不符 | ECC 密钥用 `SHA256withECDSA`，RSA 用 `SHA256withRSA` |
| `0x1004` | 输入 HAP 已签名 | 只能对 `*-unsigned.hap` 签名 |

### 运行阶段

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 一退到后台就停 | 长时任务没起来 | 确认 `module.json5` 同时有 `KEEP_BACKGROUND_RUNNING` 权限与 `backgroundModes: ["audioPlayback"]` |
| 播控中心没有卡片 | AVSession 没激活 | 顺序必须是 元数据 → 播放状态 → 注册命令 → `activate()` |
| 播控中心按钮置灰 | 对应命令没注册 | 在 `MediaSessionService.registerCommands()` 中补齐 |
| 酷狗搜索失败 | 明文流量被拦 | 本工程默认已改走 https；若仍失败见 `KugouProvider.ets` 顶部注释 |
| 本地导入的歌没歌词 | 侧车文件命名不匹配 | 歌词需与音频**同目录同名**（`.lrc/.vtt/.ttml/.qrc/.yrc/.krc`） |

---

## 8. 产物说明

一个 HAP 内部结构（可用 `7z l xxx.hap` 查看）：

```
entry-default-signed.hap
├── ets/
│   ├── modules.abc          # ArkTS 编译后的字节码
│   ├── resources.index      # 资源索引
│   └── sourceMaps.map       # 仅 debug 包
├── libs/                    # 原生库（本工程为空）
├── resources/               # 编译后的资源
├── module.json              # 由 module.json5 生成
├── pack.info
└── (签名块)
```

| 项 | 值 |
| --- | --- |
| bundleName | `top.izuna.foliamajor.hmos` |
| 版本 | `1.0.0`（versionCode `1000000`） |
| 支持设备 | `phone` / `tablet` / `2in1` / `default` |
| 目标 API | 14（`5.0.2`） |

> 改 `bundleName` 时别忘了同步改 `entry/src/main/ets/core/Constants.ets`
> 里的 `BUNDLE_NAME`（长时任务通知回跳用它做兜底）。

---

## 9. 相关文档

- [`../ci/README.md`](../ci/README.md) —— CI 选型与原理
- [`../README.md`](../README.md) —— 工程总览、鸿蒙适配要点
- [`PORTING.md`](PORTING.md) —— 上游到鸿蒙的模块映射与踩坑清单
- [`hos-api/avsession.md`](hos-api/avsession.md) —— AVSession（播控中心）核实结果
- [`hos-api/audio-playback.md`](hos-api/audio-playback.md) —— AVPlayer 与后台长时任务核实结果
