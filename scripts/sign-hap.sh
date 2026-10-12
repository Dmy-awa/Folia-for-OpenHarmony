#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 用华为官方 hap-sign-tool.jar 对未签名的 HAP 签名（macOS / Linux）。
#
# 用法：
#   ./scripts/sign-hap.sh \
#       --input  entry/build/default/outputs/default/entry-default-unsigned.hap \
#       --output out/folia-signed.hap \
#       --keystore /path/app.p12 --keystore-pwd 123456 \
#       --key-alias key0 --key-pwd 123456 \
#       --app-cert /path/app.cer --profile /path/profile.p7b
#
#   # OpenHarmony 调试签名（免华为账号，仅 OpenHarmony 设备可用）
#   ./scripts/sign-hap.sh --input <unsigned.hap> --output <signed.hap> --oh-debug
#
# 签名材料怎么来，见 docs/BUILD.md 第 4 节。
# ---------------------------------------------------------------------------
set -euo pipefail

INPUT=""; OUTPUT=""
KEYSTORE=""; KEYSTORE_PWD=""; KEY_ALIAS="key0"; KEY_PWD=""
APP_CERT=""; PROFILE=""; SIGN_ALG="SHA256withECDSA"
SIGN_TOOL_JAR=""; JAVA_EXE=""
OH_DEBUG=0; FORCE=0

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

选项：
      --input <file>           未签名的 .hap（必填）
      --output <file>          输出的已签名 .hap（默认同目录 *-signed.hap）
      --keystore <file>        .p12 密钥库
      --keystore-pwd <pwd>     密钥库口令
      --key-alias <alias>      密钥别名（默认 key0）
      --key-pwd <pwd>          密钥口令
      --app-cert <file>        应用证书 .cer
      --profile <file>         Provisioning Profile .p7b
      --sign-alg <alg>         签名算法（默认 SHA256withECDSA）
      --sign-tool-jar <file>   显式指定 hap-sign-tool.jar
      --java <file>            显式指定 java
      --oh-debug               使用 SDK 自带的 OpenHarmony 调试签名材料
      --force                  覆盖已存在的输出文件
  -h, --help                   显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --keystore-pwd) KEYSTORE_PWD="$2"; shift 2 ;;
        --key-alias) KEY_ALIAS="$2"; shift 2 ;;
        --key-pwd) KEY_PWD="$2"; shift 2 ;;
        --app-cert) APP_CERT="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --sign-alg) SIGN_ALG="$2"; shift 2 ;;
        --sign-tool-jar) SIGN_TOOL_JAR="$2"; shift 2 ;;
        --java) JAVA_EXE="$2"; shift 2 ;;
        --oh-debug) OH_DEBUG=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1"; usage; exit 1 ;;
    esac
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

step() { echo ""; echo "==> $1"; }
ok()   { echo "    $1"; }
warn() { echo "    $1"; }
err()  { echo "    $1" >&2; }

# ---------------------------------------------------------------------------
# 1. 校验输入
# ---------------------------------------------------------------------------
[[ -n "$INPUT" ]] || { err "--input 必填"; usage; exit 1; }
[[ -f "$INPUT" ]] || { err "找不到输入 HAP：$INPUT"; exit 1; }
INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"

if [[ -z "$OUTPUT" ]]; then
    d="$(dirname "$INPUT")"
    b="$(basename "$INPUT" .hap)"; b="${b%-unsigned}"
    OUTPUT="$d/$b-signed.hap"
fi
if [[ -e "$OUTPUT" ]]; then
    if [[ "$FORCE" != "1" ]]; then err "输出文件已存在：$OUTPUT（加 --force 覆盖）"; exit 1; fi
    rm -f "$OUTPUT"
fi
mkdir -p "$(dirname "$OUTPUT")"

step "输入参数"
ok "输入 HAP : $INPUT"
ok "输出 HAP : $OUTPUT"

# ---------------------------------------------------------------------------
# 2. 探测 java
# ---------------------------------------------------------------------------
step "探测 JDK"
JAVA=""
if [[ -n "$JAVA_EXE" && -x "$JAVA_EXE" ]]; then
    JAVA="$JAVA_EXE"
elif command -v java >/dev/null 2>&1; then
    JAVA="$(command -v java)"
else
    for p in \
        "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java" \
        "$HOME/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java" \
        /opt/deveco/jbr/bin/java; do
        [[ -x "$p" ]] && { JAVA="$p"; break; }
    done
fi
[[ -n "$JAVA" ]] || { err "找不到 java。请安装 JDK 或指定 --java。"; exit 1; }
ok "java: $JAVA"

# ---------------------------------------------------------------------------
# 3. 探测 hap-sign-tool.jar
# ---------------------------------------------------------------------------
step "探测 hap-sign-tool.jar"
SDK_DIR=""
if [[ -f "$PROJECT_ROOT/local.properties" ]]; then
    SDK_DIR="$(grep -E '^\s*sdk\.dir\s*=' "$PROJECT_ROOT/local.properties" | head -1 | sed -E 's/^\s*sdk\.dir\s*=\s*//' | tr -d '\r')"
    SDK_DIR="${SDK_DIR//\\\\//}"; SDK_DIR="${SDK_DIR//\\:/:}"
fi
[[ -z "$SDK_DIR" ]] && SDK_DIR="${DEVECO_SDK_HOME:-}"

SIGN_JAR=""
if [[ -n "$SIGN_TOOL_JAR" && -f "$SIGN_TOOL_JAR" ]]; then
    SIGN_JAR="$SIGN_TOOL_JAR"
elif [[ -n "$SDK_DIR" && -d "$SDK_DIR" ]]; then
    SIGN_JAR="$(find "$SDK_DIR" -name 'hap-sign-tool.jar' -type f 2>/dev/null | head -1)"
fi
if [[ -z "$SIGN_JAR" ]]; then
    for p in \
        "/Applications/DevEco-Studio.app/Contents/sdk" \
        "$HOME/Library/Huawei/Sdk" \
        "$HOME/Huawei/Sdk"; do
        [[ -d "$p" ]] && SIGN_JAR="$(find "$p" -name 'hap-sign-tool.jar' -type f 2>/dev/null | head -1)"
        [[ -n "$SIGN_JAR" ]] && break
    done
fi
[[ -n "$SIGN_JAR" ]] || { err "找不到 hap-sign-tool.jar。请指定 --sign-tool-jar。"; exit 1; }
ok "hap-sign-tool: $SIGN_JAR"

# ---------------------------------------------------------------------------
# 4. OpenHarmony 调试签名材料
# ---------------------------------------------------------------------------
if [[ "$OH_DEBUG" == "1" ]]; then
    step "使用 SDK 自带的 OpenHarmony 调试签名材料"
    [[ -n "$SDK_DIR" && -d "$SDK_DIR" ]] || { err "该模式需要 SDK 路径。"; exit 1; }
    LIB_DIR="$(find "$SDK_DIR" -type d -name lib -exec test -f '{}/OpenHarmony.p12' \; -print 2>/dev/null | head -1)"
    [[ -n "$LIB_DIR" ]] || { err "未在 SDK 中找到 OpenHarmony.p12（通常在 <sdk>/.../toolchains/lib）。"; exit 1; }
    KEYSTORE="$LIB_DIR/OpenHarmony.p12"
    KEYSTORE_PWD="123456"
    KEY_ALIAS="OpenHarmony Application Release"
    KEY_PWD="123456"
    APP_CERT="$LIB_DIR/OpenHarmonyApplication.pem"
    [[ -z "$PROFILE" && -f "$LIB_DIR/profile.p7b" ]] && PROFILE="$LIB_DIR/profile.p7b"
    warn "keystore : $KEYSTORE"
    warn "appCert  : $APP_CERT"
    warn "⚠️ 该模式产出的 HAP 只能安装到 OpenHarmony 设备/模拟器，不能装到鸿蒙 NEXT 手机。"
    warn "   还需要一个已签名的 profile（.p7b）；模板：$LIB_DIR/UnsgnedDebugProfileTemplate.json"
fi

if [[ -z "$KEYSTORE" || -z "$APP_CERT" || -z "$PROFILE" ]]; then
    err "缺少签名材料。需要同时提供 --keystore、--app-cert、--profile"
    err "详细获取方式见 docs/BUILD.md 第 4 节。"
    exit 1
fi
for f in "$KEYSTORE" "$APP_CERT" "$PROFILE"; do
    [[ -f "$f" ]] || { err "找不到签名材料文件：$f"; exit 1; }
done

step "签名参数"
ok "keystore : $KEYSTORE"
ok "keyAlias : $KEY_ALIAS"
ok "appCert  : $APP_CERT"
ok "profile  : $PROFILE"
ok "signAlg  : $SIGN_ALG"

# ---------------------------------------------------------------------------
# 5. 执行签名
# ---------------------------------------------------------------------------
step "执行签名"
set +e
"$JAVA" -jar "$SIGN_JAR" sign-app \
    -keyAlias "$KEY_ALIAS" \
    -signAlg "$SIGN_ALG" \
    -mode localSign \
    -appCertFile "$APP_CERT" \
    -profileFile "$PROFILE" \
    -inFile "$INPUT" \
    -keystoreFile "$KEYSTORE" \
    -outFile "$OUTPUT" \
    -keyPwd "$KEY_PWD" \
    -keystorePwd "$KEYSTORE_PWD"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 || ! -f "$OUTPUT" ]]; then
    err "签名失败（exit=$EXIT_CODE）"
    err "常见原因：密码错误（0x1000/0x1001）、profile 与证书不匹配（0x1002）、signAlg 与密钥类型不符。"
    exit 1
fi

echo ""
ok "签名成功：$OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo ""
echo "安装到设备："
echo "    hdc install -r \"$OUTPUT\""
