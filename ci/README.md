# CI 配置说明

> **放置位置**：本目录下的文件是**模板**，不会自动生效。按需复制到对应位置：
>
> | 模板 | 复制到 |
> | --- | --- |
> | `github-actions-selfhosted.yml` | `.github/workflows/build-hap-selfhosted.yml` |
> | `github-actions-openharmony-sdk.yml` | `.github/workflows/build-hap-openharmony.yml` |
> | `gitee-go-build-hap.yml` | `.workflow/build-hap.yml` |
>
> 之所以不直接放进 `.github/workflows/`，是因为两个 GitHub 方案**互斥**——
> 同时启用会在每次 push 时各跑一遍（其中一个还要下载 4 GB SDK、或在没有
> 自托管 Runner 时白白排队）。请按实际情况二选一。

本目录提供三套流水线配置。**它们解决的不是同一个问题**，选之前先看清楚：

| 配置 | 能否产出「手机可安装的 HAP」 | 需要什么 | 主要价值 |
| --- | --- | --- | --- |
| `github-actions-selfhosted.yml` | ✅ **能** | 一台装了 DevEco Studio 的自托管 Runner + 华为账号签名材料 | 直接产出可分发/可安装的安装包 |
| `github-actions-openharmony-sdk.yml` | ❌ 不能（只能装 OpenHarmony 设备/模拟器） | 无，ubuntu-latest 即可 | **持续验证代码能否编译通过** |
| `gitee-go-build-hap.yml` | ❌ 同上（除非 Runner 预装 DevEco） | Gitee 仓库 + 公共构建机 | 国内网络下的编译验证 |

## 为什么「手机可安装」这么麻烦

鸿蒙 NEXT 手机安装 HAP 时会校验**签名信任链**：

```
HAP 签名  ←  应用证书(.cer)  ←  华为根证书
                          ↑
      Provisioning Profile(.p7b) 由华为按设备 UDID 签发
```

也就是说，手机只认**华为签发**的证书与 profile。获取途径只有一条：在 DevEco Studio 里
登录华为开发者账号，使用「自动生成签名」。这是账号体系问题，不是工具链问题——
任何本地方案、任何公开 SDK 都绕不过去。

而 OpenHarmony 公开 SDK 自带的是 **OpenHarmony 自己的**调试签名材料
（`OpenHarmony.p12` / `OpenHarmonyApplication.pem`），只被 OpenHarmony 设备信任。

## 复用的构建逻辑

三套配置都只是壳，真正的逻辑在：

- `scripts/build-hap.ps1` / `scripts/build-hap.sh` —— 本机一键构建（+ 可选签名）
- `scripts/sign-hap.sh` / `scripts/sign-hap.ps1` —— 用 `hap-sign-tool.jar` 签名
- `scripts/ci-build-hap.sh` —— CI 专用：拉 SDK、切 runtimeOS、构建、签名、收集产物

任何其他 CI（Jenkins / GitLab CI / 阿里云效 / 腾讯 CODING）都只需要三步：

```bash
# 1. 准备 SDK 与 Node 18+
export DEVECO_SDK_HOME=/path/to/sdk

# 2. 构建（并按需签名）
./scripts/ci-build-hap.sh --sdk-type harmonyos --build-mode release

# 3. 收集 entry/build/**/*.hap 作为产物
```

## 关于 `ci-build-hap.sh` 的两种 SDK 模式

### `--sdk-type harmonyos`

用 Runner 上预装的 DevEco Studio SDK。**不改动** `build-profile.json5`，
保留 `runtimeOS: "HarmonyOS"` 与 `compatibleSdkVersion: "5.0.2(14)"`。
签名材料通过 `SIGN_KEYSTORE` / `SIGN_APP_CERT` / `SIGN_PROFILE` 等环境变量传入。

### `--sdk-type openharmony`

从 `https://repo.huaweicloud.com/openharmony/os/` 下载公开 SDK（约 4 GB），
并**临时**把 `build-profile.json5` 改成：

```json5
"compatibleSdkVersion": 14,
"targetSdkVersion": 14,
"runtimeOS": "OpenHarmony"
```

构建结束后脚本会把备份还原回去。脚本还会检查 SDK 是否带 `ets/kits` 目录——
如果缺失，说明该 SDK 不支持 `@kit.*` 形式的 import，本工程**全部**使用这种导入，
脚本会直接报错退出而不是给出一个误导性的编译失败。

## 缓存建议

OpenHarmony SDK 有 4 GB，CI 上务必缓存：

- GitHub Actions：见 `github-actions-openharmony-sdk.yml` 里的 `actions/cache` 步骤
- 其他 CI：缓存 `.ohos-sdk-cache/` 目录，key 用 SDK 版本号

## 敏感信息

**绝对不要把 `.p12` / `.cer` / `.p7b` / 密码提交到仓库。**
`.gitignore` 已经排除了这些扩展名。CI 中一律通过 secrets 注入，
GitHub Actions 的方案里还会在流水线结束时清理临时解密出来的材料。

## 相关文档

- [`../docs/BUILD.md`](../docs/BUILD.md) —— 完整的构建与签名手册，含签名材料获取步骤与报错排查
- [`../README.md`](../README.md) —— 工程总览
