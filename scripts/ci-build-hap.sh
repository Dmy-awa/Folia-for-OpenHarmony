#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CI 专用构建入口：在无图形界面的环境里拉取 SDK、构建并签名 HAP。
#
# 支持两种 SDK：
#   --sdk-type harmonyos     使用 DevEco Studio 的 HarmonyOS SDK（runner 上需预装）
#                            产物可安装到鸿蒙 NEXT 手机 —— 需要华为账号签名材料
#   --sdk-type openharmony   从华为云公开镜像下载 OpenHarmony SDK（免账号）
#                            产物只能安装到 OpenHarmony 设备/模拟器
#
# 用法：
#   ./scripts/ci-build-hap.sh --sdk-type harmonyos --build-mode release
#   ./scripts/ci-build-hap.sh --sdk-type openharmony --sdk-version 5.0.2-Release --build-mode debug
#
# 签名材料通过环境变量提供（CI 里放 secrets）：
#   SIGN_KEYSTORE  SIGN_KEYSTORE_PWD  SIGN_KEY_ALIAS  SIGN_KEY_PWD
#   SIGN_APP_CERT  SIGN_PROFILE
# 未提供时只产出未签名包。
# ---------------------------------------------------------------------------
set -euo pipefail

SDK_TYPE="harmonyos"
SDK_VERSION="5.0.2-Release"
BUILD_MODE="debug"
PRODUCT="default"
MODULE="entry"
WORK_DIR="${WORK_DIR:-$PWD}"
SKIP_SIGN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sdk-type) SDK_TYPE="$2"; shift 2 ;;
        --sdk-version) SDK_VERSION="$2"; shift 2 ;;
        --build-mode) BUILD_MODE="$2"; shift 2 ;;
        --product) PRODUCT="$2"; shift 2 ;;
        --module) MODULE="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --skip-sign) SKIP_SIGN=1; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

step() { echo ""; echo "==> $1"; }
ok()   { echo "    $1"; }
warn() { echo "    $1"; }
err()  { echo "    $1" >&2; }
group_end() { echo ""; }

MIRROR="${OHOS_MIRROR:-https://repo.huaweicloud.com/openharmony/os}"

# ---------------------------------------------------------------------------
# 1. node
# ---------------------------------------------------------------------------
step "检查 Node.js"
command -v node >/dev/null 2>&1 || { err "找不到 node"; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
ok "node $(node --version)"
if [[ "$NODE_MAJOR" -lt 18 ]]; then
    err "hvigor 需要 Node.js 18+，当前 $NODE_MAJOR"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. 准备 SDK
# ---------------------------------------------------------------------------
if [[ "$SDK_TYPE" == "openharmony" ]]; then
    step "下载 OpenHarmony SDK $SDK_VERSION（公开镜像，免账号）"
    SDK_ROOT="${WORK_DIR}/ohos-sdk"
    SDK_TARBALL="ohos-sdk-windows_linux-public.tar.gz"
    SDK_URL="${MIRROR}/${SDK_VERSION}/${SDK_TARBALL}"

    if [[ -d "$SDK_ROOT/ets" ]]; then
        ok "已有缓存：$SDK_ROOT"
    else
        mkdir -p "$SDK_ROOT"
        # 4 GB 左右，CI 上务必配合 actions/cache 使用
        if [[ ! -f "${WORK_DIR}/${SDK_TARBALL}" ]]; then
            ok "下载 $SDK_URL"
            curl -fL --retry 3 --retry-delay 5 -o "${WORK_DIR}/${SDK_TARBALL}" "$SDK_URL"
        fi
        ok "解压…"
        tar -xzf "${WORK_DIR}/${SDK_TARBALL}" -C "$SDK_ROOT"
        # 官方包解压后是 linux/ 与 windows/ 两个子目录
        if [[ -d "$SDK_ROOT/linux" ]]; then
            SDK_ROOT="$SDK_ROOT/linux"
        fi
        # 里面还有一层版本目录，统一压平成 <sdk>/ets
        if [[ ! -d "$SDK_ROOT/ets" ]]; then
            inner="$(find "$SDK_ROOT" -maxdepth 2 -type d -name ets | head -1)"
            [[ -n "$inner" ]] && SDK_ROOT="$(dirname "$inner")"
        fi
        ok "SDK 根目录：$SDK_ROOT"
    fi

    [[ -d "$SDK_ROOT/ets" ]] || { err "SDK 解压结果不符合预期，未找到 ets 目录"; exit 1; }

    if [[ ! -d "$SDK_ROOT/ets/kits" ]]; then
        warn "⚠️ 该 SDK 没有 ets/kits 目录，说明它不支持 @kit.* 形式的 import。"
        warn "   本工程全部使用 @kit.* 导入，必须使用带 kits 的 SDK（OpenHarmony 5.0+ 或 HarmonyOS SDK）。"
        err "放弃构建。"
        exit 1
    fi

    # 公开 SDK 只能在 OpenHarmony 运行时下构建，需要把 runtimeOS 改成 OpenHarmony
    # 且 compatibleSdkVersion / targetSdkVersion 用数字形式
    step "把 build-profile.json5 切换为 OpenHarmony 运行时（仅 CI 临时改动）"
    cp build-profile.json5 build-profile.json5.ci-backup
    sed -i \
        -e 's/"compatibleSdkVersion": *"[^"]*"/"compatibleSdkVersion": 14/' \
        -e 's/"targetSdkVersion": *"[^"]*"/"targetSdkVersion": 14/' \
        -e 's/"runtimeOS": *"HarmonyOS"/"runtimeOS": "OpenHarmony"/' \
        build-profile.json5
    ok "已切换（备份在 build-profile.json5.ci-backup）"
    grep -E 'compatibleSdkVersion|targetSdkVersion|runtimeOS' build-profile.json5 | sed 's/^/    /'
else
    step "使用 runner 上预装的 HarmonyOS SDK"
    SDK_ROOT="${DEVECO_SDK_HOME:-}"
    if [[ -z "$SDK_ROOT" || ! -d "$SDK_ROOT" ]]; then
        err "未设置 DEVECO_SDK_HOME，或该路径不存在。"
        err "自托管 runner 需要预装 DevEco Studio 并导出 DEVECO_SDK_HOME。"
        exit 1
    fi
    ok "SDK: $SDK_ROOT"
fi

export DEVECO_SDK_HOME="$SDK_ROOT"

# 工程里也写一份 local.properties，hvigor 两种方式都会读
mkdir -p "$(dirname "$PROJECT_ROOT/local.properties")"
{
    echo "# 由 scripts/ci-build-hap.sh 生成（CI 环境）"
    echo "sdk.dir=$(printf '%s' "$SDK_ROOT" | sed 's/\\/\\\\/g; s/:/\\:/g')"
} > "$PROJECT_ROOT/local.properties"
ok "已写入 local.properties"

# ---------------------------------------------------------------------------
# 3. 安装依赖
# ---------------------------------------------------------------------------
step "解析工程依赖"
if command -v ohpm >/dev/null 2>&1; then
    ohpm install --all || warn "ohpm install 失败，继续尝试构建"
elif [[ -x "$SDK_ROOT/../tools/ohpm/bin/ohpm" ]]; then
    "$SDK_ROOT/../tools/ohpm/bin/ohpm" install --all || true
else
    warn "未找到 ohpm；若工程没有第三方依赖，hvigor 可以继续。"
fi

# ---------------------------------------------------------------------------
# 4. 构建
# ---------------------------------------------------------------------------
step "构建 HAP（mode=$BUILD_MODE, product=$PRODUCT, module=$MODULE）"
chmod +x "$PROJECT_ROOT/hvigorw" 2>/dev/null || true
set +e
"$PROJECT_ROOT/hvigorw" \
    --mode module \
    -p "product=$PRODUCT" \
    -p "module=$MODULE@default" \
    -p "buildMode=$BUILD_MODE" \
    assembleHap --no-daemon
EXIT_CODE=$?
set -e

# 恢复 CI 临时改动的配置
if [[ -f build-profile.json5.ci-backup ]]; then
    mv build-profile.json5.ci-backup build-profile.json5
    ok "已恢复 build-profile.json5"
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    err "构建失败（exit=$EXIT_CODE）"
    exit $EXIT_CODE
fi

# ---------------------------------------------------------------------------
# 5. 定位产物
# ---------------------------------------------------------------------------
step "定位产物"
OUT_ROOT="$PROJECT_ROOT/$MODULE/build"
UNSIGNED=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "    $f  ($(du -h "$f" | cut -f1))"
    if [[ "$f" == *unsigned*.hap && -z "$UNSIGNED" ]]; then UNSIGNED="$f"; fi
done < <(find "$OUT_ROOT" -type f -name '*.hap' 2>/dev/null | sort)

if [[ -z "$UNSIGNED" ]]; then
    warn "未找到未签名 HAP（可能已在 build-profile.json5 中配置签名，产出了已签名包）"
fi

# ---------------------------------------------------------------------------
# 6. 签名
# ---------------------------------------------------------------------------
if [[ "$SKIP_SIGN" == "1" ]]; then
    step "按要求跳过签名"
elif [[ -n "${SIGN_KEYSTORE:-}" && -n "${SIGN_APP_CERT:-}" && -n "${SIGN_PROFILE:-}" && -n "$UNSIGNED" ]]; then
    step "使用 CI secrets 中的签名材料签名"
    OUT_DIR="$(dirname "$UNSIGNED")"
    BASE="$(basename "$UNSIGNED" .hap)"; BASE="${BASE%-unsigned}"
    "$PROJECT_ROOT/scripts/sign-hap.sh" \
        --input "$UNSIGNED" --output "$OUT_DIR/$BASE-signed.hap" --force \
        --keystore "$SIGN_KEYSTORE" \
        --keystore-pwd "${SIGN_KEYSTORE_PWD:-}" \
        --key-alias "${SIGN_KEY_ALIAS:-key0}" \
        --key-pwd "${SIGN_KEY_PWD:-}" \
        --app-cert "$SIGN_APP_CERT" \
        --profile "$SIGN_PROFILE" \
        --sign-tool-jar "$(find "$SDK_ROOT" -name 'hap-sign-tool.jar' -type f 2>/dev/null | head -1)"
elif [[ "$SDK_TYPE" == "openharmony" && -n "$UNSIGNED" ]]; then
    step "使用 OpenHarmony 调试签名材料签名（免账号）"
    OUT_DIR="$(dirname "$UNSIGNED")"
    BASE="$(basename "$UNSIGNED" .hap)"; BASE="${BASE%-unsigned}"
    "$PROJECT_ROOT/scripts/sign-hap.sh" \
        --input "$UNSIGNED" --output "$OUT_DIR/$BASE-signed.hap" --force \
        --oh-debug \
        --sign-tool-jar "$(find "$SDK_ROOT" -name 'hap-sign-tool.jar' -type f 2>/dev/null | head -1)" || {
            warn "OpenHarmony 调试签名失败（通常是没有 profile.p7b，需要先用模板生成）。"
            warn "未签名包仍然可以下载，见 docs/BUILD.md 第 4.3 节。"
        }
else
    step "未提供签名材料，跳过签名"
    warn "产物为未签名包。要产出可安装的 HAP，请配置 SIGN_* 环境变量或 secrets。"
fi

group_end
echo "CI 构建流程结束。"
