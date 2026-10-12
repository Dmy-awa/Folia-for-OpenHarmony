#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 一键构建 Folia for HarmonyOS 的 HAP 安装包（macOS / Linux）
#
# 用法：
#   ./scripts/build-hap.sh                       # debug 构建
#   ./scripts/build-hap.sh -m release -c         # release 构建并清理
#   ./scripts/build-hap.sh -s \
#       --keystore /path/app.p12 --keystore-pwd 123456 \
#       --key-alias key0 --key-pwd 123456 \
#       --app-cert /path/app.cer --profile /path/profile.p7b
#
# 前置条件：
#   1. 已安装 DevEco Studio（提供 hvigor / ohpm / SDK）；
#   2. 已设置 SDK 路径：工程下的 local.properties（见 local.properties.example）
#      或环境变量 DEVECO_SDK_HOME；
#   3. 需要签名时已准备好 .p12 / .cer / .p7b（见 docs/BUILD.md 第 4 节）。
# ---------------------------------------------------------------------------
set -euo pipefail

BUILD_MODE="debug"
PRODUCT="default"
MODULE="entry"
CLEAN=0
SIGN=0
KEYSTORE=""; KEYSTORE_PWD=""; KEY_ALIAS="key0"; KEY_PWD=""
APP_CERT=""; PROFILE=""; SIGN_ALG="SHA256withECDSA"; SIGN_TOOL_JAR=""

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

选项：
  -m, --mode <debug|release>   构建模式（默认 debug）
  -p, --product <name>         产品名（默认 default）
  -M, --module <name>          模块名（默认 entry）
  -c, --clean                  构建前清理
  -s, --sign                   构建后签名
      --keystore <file>        .p12 密钥库
      --keystore-pwd <pwd>     密钥库口令
      --key-alias <alias>      密钥别名（默认 key0）
      --key-pwd <pwd>          密钥口令
      --app-cert <file>        应用证书 .cer
      --profile <file>         Provisioning Profile .p7b
      --sign-alg <alg>         签名算法（默认 SHA256withECDSA）
      --sign-tool-jar <file>   显式指定 hap-sign-tool.jar
  -h, --help                   显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode) BUILD_MODE="$2"; shift 2 ;;
        -p|--product) PRODUCT="$2"; shift 2 ;;
        -M|--module) MODULE="$2"; shift 2 ;;
        -c|--clean) CLEAN=1; shift ;;
        -s|--sign) SIGN=1; shift ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --keystore-pwd) KEYSTORE_PWD="$2"; shift 2 ;;
        --key-alias) KEY_ALIAS="$2"; shift 2 ;;
        --key-pwd) KEY_PWD="$2"; shift 2 ;;
        --app-cert) APP_CERT="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --sign-alg) SIGN_ALG="$2"; shift 2 ;;
        --sign-tool-jar) SIGN_TOOL_JAR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1"; usage; exit 1 ;;
    esac
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

step()  { echo ""; echo "==> $1"; }
ok()    { echo "    $1"; }
warn()  { echo "    $1"; }
err()   { echo "    $1" >&2; }

# ---------------------------------------------------------------------------
# 1. 前置检查
# ---------------------------------------------------------------------------
step "检查构建环境"

[[ -f "$PROJECT_ROOT/hvigorw" ]] || { err "找不到 hvigorw，请确认工程完整。"; exit 1; }
chmod +x "$PROJECT_ROOT/hvigorw" 2>/dev/null || true
ok "hvigorw 就绪"

command -v node >/dev/null 2>&1 || { err "PATH 中找不到 node。"; exit 1; }
ok "node $(node --version)"

SDK_DIR=""
if [[ -f "$PROJECT_ROOT/local.properties" ]]; then
    SDK_DIR="$(grep -E '^\s*sdk\.dir\s*=' "$PROJECT_ROOT/local.properties" | head -1 | sed -E 's/^\s*sdk\.dir\s*=\s*//' | tr -d '\r')"
    # 还原 properties 转义
    SDK_DIR="${SDK_DIR//\\\\//}"
    SDK_DIR="${SDK_DIR//\\:/:}"
fi
[[ -z "$SDK_DIR" ]] && SDK_DIR="${DEVECO_SDK_HOME:-}"

if [[ -n "$SDK_DIR" && -d "$SDK_DIR" ]]; then
    ok "SDK: $SDK_DIR"
else
    warn "未检测到有效的 SDK 路径。"
    warn "请二选一："
    warn "  1) 复制 local.properties.example 为 local.properties 并填写 sdk.dir"
    warn "  2) 设置环境变量 DEVECO_SDK_HOME"
    warn "继续尝试构建…"
fi

# ---------------------------------------------------------------------------
# 2. 清理
# ---------------------------------------------------------------------------
if [[ "$CLEAN" == "1" ]]; then
    step "清理旧构建产物"
    for p in "$MODULE/build" "build" ".hvigor/cache"; do
        if [[ -e "$PROJECT_ROOT/$p" ]]; then
            rm -rf "$PROJECT_ROOT/$p"
            ok "已删除 $p"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 3. 构建
# ---------------------------------------------------------------------------
step "构建 HAP（mode=$BUILD_MODE, product=$PRODUCT, module=$MODULE）"
set +e
"$PROJECT_ROOT/hvigorw" \
    --mode module \
    -p "product=$PRODUCT" \
    -p "module=$MODULE@default" \
    -p "buildMode=$BUILD_MODE" \
    assembleHap --no-daemon
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
    err "构建失败（exit=$EXIT_CODE）。常见原因见 docs/BUILD.md 第 7 节。"
    exit $EXIT_CODE
fi

# ---------------------------------------------------------------------------
# 4. 定位产物
# ---------------------------------------------------------------------------
step "定位构建产物"
OUT_ROOT="$PROJECT_ROOT/$MODULE/build"
UNSIGNED=""
SIGNED=""
if [[ -d "$OUT_ROOT" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        size="$(du -h "$f" | cut -f1)"
        echo "    $f  ($size)"
        if [[ "$f" == *unsigned*.hap ]]; then
            [[ -z "$UNSIGNED" ]] && UNSIGNED="$f"
        else
            [[ -z "$SIGNED" ]] && SIGNED="$f"
        fi
    done < <(find "$OUT_ROOT" -type f -name '*.hap' 2>/dev/null | sort)
fi

if [[ -n "$SIGNED" ]]; then
    ok "可安装产物：$SIGNED"
elif [[ -n "$UNSIGNED" ]]; then
    warn "只产出了未签名包：$UNSIGNED"
    warn "在 DevEco 中配置签名后重新构建，或加 -s 参数用 hap-sign-tool 手动签名。"
else
    warn "未找到 .hap，请检查构建日志。"
fi

# ---------------------------------------------------------------------------
# 5. 可选签名
# ---------------------------------------------------------------------------
if [[ "$SIGN" == "1" ]]; then
    step "对未签名产物签名"
    if [[ -z "$UNSIGNED" ]]; then
        warn "没有找到 *unsigned.hap，跳过签名。"
    elif [[ -z "$KEYSTORE" || -z "$APP_CERT" || -z "$PROFILE" ]]; then
        err "签名需要同时提供 --keystore、--app-cert、--profile。详见 docs/BUILD.md 第 4 节。"
        exit 1
    else
        OUT_DIR="$(dirname "$UNSIGNED")"
        BASE="$(basename "$UNSIGNED" .hap)"
        BASE="${BASE%-unsigned}"
        OUT_FILE="$OUT_DIR/$BASE-signed.hap"
        SIGN_ARGS=(
            --input "$UNSIGNED" --output "$OUT_FILE"
            --keystore "$KEYSTORE" --keystore-pwd "$KEYSTORE_PWD"
            --key-alias "$KEY_ALIAS" --key-pwd "$KEY_PWD"
            --app-cert "$APP_CERT" --profile "$PROFILE"
            --sign-alg "$SIGN_ALG"
        )
        [[ -n "$SIGN_TOOL_JAR" ]] && SIGN_ARGS+=(--sign-tool-jar "$SIGN_TOOL_JAR")
        "$PROJECT_ROOT/scripts/sign-hap.sh" "${SIGN_ARGS[@]}"
    fi
fi

echo ""
echo "完成。安装到设备："
echo "    hdc install -r <上面输出的 .hap 路径>"
