<#
.SYNOPSIS
    一键构建 Folia for HarmonyOS 的 HAP 安装包（Windows / PowerShell）。

.DESCRIPTION
    封装了 hvigor 的正确调用方式、SDK 路径探测、产物定位与可选的签名步骤。

    典型用法：
        # 构建 debug 包（默认）
        .\scripts\build-hap.ps1

        # 构建 release 包并清理旧的构建缓存
        .\scripts\build-hap.ps1 -BuildMode release -Clean

        # 构建后直接用 hap-sign-tool 对未签名产物签名
        .\scripts\build-hap.ps1 -Sign -Keystore C:\sign\app.p12 -KeystorePwd 123456 `
                               -KeyAlias key0 -KeyPwd 123456 `
                               -AppCert C:\sign\app.cer -Profile C:\sign\profile.p7b

    前置条件（缺一不可）：
        1. 已安装 DevEco Studio（提供 hvigor / ohpm / SDK）；
        2. 已设置 SDK 路径：工程下的 local.properties（见 local.properties.example）
           或环境变量 DEVECO_SDK_HOME；
        3. 需要签名时已准备好 .p12 / .cer / .p7b（见 docs/BUILD.md 第 4 节）。
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$BuildMode = 'debug',

    [string]$Product = 'default',
    [string]$Module = 'entry',

    # 构建前清理（等价于 Build -> Clean Project）
    [switch]$Clean,

    # 构建完成后自动调用 sign-hap.ps1 签名
    [switch]$Sign,

    # 以下参数仅 -Sign 时使用
    [string]$Keystore,
    [string]$KeystorePwd,
    [string]$KeyAlias = 'key0',
    [string]$KeyPwd,
    [string]$AppCert,
    [string]$Profile,
    [string]$SignAlg = 'SHA256withECDSA',

    # 显式指定 hap-sign-tool.jar（默认自动探测 DevEco SDK 与 HAPInstallTool）
    [string]$SignToolJar
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "    $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. 前置检查
# ---------------------------------------------------------------------------
Write-Step '检查构建环境'

$wrapper = Join-Path $ProjectRoot 'hvigorw.bat'
if (-not (Test-Path $wrapper)) {
    Write-Err2 "找不到 hvigorw.bat（$wrapper）"
    Write-Err2 '该文件是工程自带的 hvigor 启动脚本，请确认没有误删。'
    exit 1
}
Write-Ok 'hvigorw.bat 就绪'

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Err2 "PATH 中找不到 node。DevEco Studio 自带 node，也可以自行安装 Node.js 18+。"
    exit 1
}
Write-Ok "node $(& node --version)  ($($node.Source))"

# SDK 路径：local.properties > DEVECO_SDK_HOME > 常见默认位置
$localProps = Join-Path $ProjectRoot 'local.properties'
$sdkDir = $null
if (Test-Path $localProps) {
    $line = Select-String -Path $localProps -Pattern '^\s*sdk\.dir\s*=' | Select-Object -First 1
    if ($line) {
        $sdkDir = ($line.Line -replace '^\s*sdk\.dir\s*=\s*', '').Trim()
        # 还原 properties 里的转义
        $sdkDir = $sdkDir -replace '\\\\', '\' -replace '\:', ':'
    }
}
if (-not $sdkDir) { $sdkDir = $env:DEVECO_SDK_HOME }

if ($sdkDir -and (Test-Path $sdkDir)) {
    Write-Ok "SDK: $sdkDir"
} else {
    Write-Warn2 '未检测到有效的 SDK 路径。'
    Write-Warn2 '请二选一：'
    Write-Warn2 '  1) 复制 local.properties.example 为 local.properties 并填写 sdk.dir'
    Write-Warn2 '  2) 设置环境变量 DEVECO_SDK_HOME'
    Write-Warn2 '若 DevEco Studio 已正确安装，hvigor 也可能自行找到 SDK，继续尝试构建…'
}

# ---------------------------------------------------------------------------
# 2. 清理
# ---------------------------------------------------------------------------
if ($Clean) {
    Write-Step '清理旧构建产物'
    foreach ($p in @('entry\build', 'build', '.hvigor\cache')) {
        $full = Join-Path $ProjectRoot $p
        if (Test-Path $full) {
            Remove-Item -Recurse -Force $full -ErrorAction SilentlyContinue
            Write-Ok "已删除 $p"
        }
    }
}

# ---------------------------------------------------------------------------
# 3. 构建
# ---------------------------------------------------------------------------
Write-Step "构建 HAP（mode=$BuildMode, product=$Product, module=$Module）"

# 注意：不要用 $args 作为变量名，它是 PowerShell 的自动变量
$hvigorArgs = @(
    '--mode', 'module',
    '-p', "product=$Product",
    '-p', "module=$Module@default",
    '-p', "buildMode=$BuildMode",
    'assembleHap',
    '--no-daemon'
)

Write-Host "    hvigorw.bat $($hvigorArgs -join ' ')" -ForegroundColor DarkGray
& $wrapper @hvigorArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Err2 "构建失败（exit=$exitCode）。常见原因见 docs/BUILD.md 第 7 节。"
    exit $exitCode
}
Write-Ok '构建成功'

# ---------------------------------------------------------------------------
# 4. 定位产物
# ---------------------------------------------------------------------------
Write-Step '定位构建产物'

$outputsRoot = Join-Path $ProjectRoot "$Module\build"
$haps = @()
if (Test-Path $outputsRoot) {
    $haps = Get-ChildItem $outputsRoot -Recurse -File -Filter '*.hap' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

if ($haps.Count -eq 0) {
    Write-Warn2 "未在 $Module\build 下找到 .hap，请检查构建日志。"
} else {
    foreach ($h in $haps) {
        $sizeMb = [math]::Round($h.Length / 1MB, 2)
        Write-Host ("    {0}  ({1} MB)" -f $h.FullName, $sizeMb) -ForegroundColor White
    }
    $signed = $haps | Where-Object { $_.Name -notmatch 'unsigned' } | Select-Object -First 1
    $unsigned = $haps | Where-Object { $_.Name -match 'unsigned' } | Select-Object -First 1

    if ($signed) {
        Write-Ok "可安装产物：$($signed.FullName)"
    } elseif ($unsigned) {
        Write-Warn2 "只产出了未签名包：$($unsigned.FullName)"
        Write-Warn2 'DevEco 中配置签名后重新构建，或加 -Sign 参数用 hap-sign-tool 手动签名。'
    }
}

# ---------------------------------------------------------------------------
# 5. 可选签名
# ---------------------------------------------------------------------------
if ($Sign) {
    Write-Step '对未签名产物签名'
    if (-not $unsigned) {
        Write-Warn2 '没有找到 *unsigned.hap，跳过签名。'
    } elseif (-not $Keystore -or -not $AppCert -or -not $Profile) {
        Write-Err2 '签名需要同时提供 -Keystore、-AppCert、-Profile。详见 docs/BUILD.md 第 4 节。'
        exit 1
    } else {
        $signedBase = $unsigned.BaseName -replace '-unsigned$', ''
        $outFile = Join-Path (Split-Path -Parent $unsigned.FullName) "$signedBase-signed.hap"
        $signArgs = @{
            Input       = $unsigned.FullName
            Output      = $outFile
            Keystore    = $Keystore
            KeystorePwd = $KeystorePwd
            KeyAlias    = $KeyAlias
            KeyPwd      = $KeyPwd
            AppCert     = $AppCert
            Profile     = $Profile
            SignAlg     = $SignAlg
        }
        if ($SignToolJar) { $signArgs['SignToolJar'] = $SignToolJar }
        & (Join-Path $PSScriptRoot 'sign-hap.ps1') @signArgs
        if ($LASTEXITCODE -eq 0) { Write-Ok "签名产物：$outFile" }
    }
}

Write-Host ""
Write-Host "完成。安装到设备：" -ForegroundColor Cyan
Write-Host "    hdc install -r <上面输出的 .hap 路径>" -ForegroundColor DarkGray
Write-Host "（hdc 在 DevEco 的 sdk\...\toolchains 下，或已加入 PATH）" -ForegroundColor DarkGray
