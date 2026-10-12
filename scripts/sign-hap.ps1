<#
.SYNOPSIS
    用华为官方 hap-sign-tool.jar 对未签名的 HAP 签名。

.DESCRIPTION
    当工程未在 DevEco 中配置自动签名、或需要在 CI 中签名时使用。
    脚本会自动探测 java 与 hap-sign-tool.jar 的位置。

    典型用法：
        .\scripts\sign-hap.ps1 -Input .\entry\build\default\outputs\default\entry-default-unsigned.hap `
                               -Output .\out\folia-signed.hap `
                               -Keystore C:\sign\app.p12 -KeystorePwd 123456 `
                               -KeyAlias key0 -KeyPwd 123456 `
                               -AppCert C:\sign\app.cer -Profile C:\sign\profile.p7b

    OpenHarmony 调试签名（免华为账号，只能在 OpenHarmony 设备/模拟器上安装）：
        .\scripts\sign-hap.ps1 -Input <unsigned.hap> -Output <signed.hap> -UseOpenHarmonyDebugMaterial

    签名材料怎么来，见 docs/BUILD.md 第 4 节。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Input,
    [string]$Output,

    [string]$Keystore,
    [string]$KeystorePwd,
    [string]$KeyAlias = 'key0',
    [string]$KeyPwd,
    [string]$AppCert,
    [string]$Profile,
    [ValidateSet('SHA256withECDSA', 'SHA384withECDSA', 'SHA256withRSA', 'SHA384withRSA')]
    [string]$SignAlg = 'SHA256withECDSA',

    # 显式指定工具与 JDK
    [string]$SignToolJar,
    [string]$JavaExe,

    # 使用 SDK 自带的 OpenHarmony 调试签名材料（免账号，仅 OpenHarmony 设备可用）
    [switch]$UseOpenHarmonyDebugMaterial,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step([string]$Text) { Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "    $Text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. 校验输入
# ---------------------------------------------------------------------------
if (-not (Test-Path $Input)) {
    Write-Err2 "找不到输入 HAP：$Input"
    exit 1
}
$Input = (Resolve-Path $Input).Path

if (-not $Output) {
    $dir = Split-Path -Parent $Input
    $base = [IO.Path]::GetFileNameWithoutExtension($Input) -replace '-unsigned$', ''
    $Output = Join-Path $dir "$base-signed.hap"
}
if (Test-Path $Output) {
    if (-not $Force) {
        Write-Err2 "输出文件已存在：$Output（加 -Force 覆盖）"
        exit 1
    }
    Remove-Item $Output -Force
}
$outDir = Split-Path -Parent $Output
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

Write-Step '输入参数'
Write-Ok "输入 HAP : $Input"
Write-Ok "输出 HAP : $Output"

# ---------------------------------------------------------------------------
# 2. 探测 java
# ---------------------------------------------------------------------------
Write-Step '探测 JDK'

$javaCandidates = @()
if ($JavaExe) { $javaCandidates += $JavaExe }
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if ($javaCmd) { $javaCandidates += $javaCmd.Source }
# DevEco 自带 JBR
foreach ($p in @(
        "$env:ProgramFiles\Huawei\DevEco Studio\jbr\bin\java.exe",
        "C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe",
        "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java")) {
    $javaCandidates += $p
}
# HAPInstallTool 自带 JRE
$javaCandidates += 'C:\Program Files (x86)\HAPInstallTool\tools\jre\bin\java.exe'

$java = $javaCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $java) {
    Write-Err2 '找不到 java。hap-sign-tool 需要 JDK 8+，请安装 JDK 或指定 -JavaExe。'
    exit 1
}
Write-Ok "java: $java"

# ---------------------------------------------------------------------------
# 3. 探测 hap-sign-tool.jar
# ---------------------------------------------------------------------------
Write-Step '探测 hap-sign-tool.jar'

$sdkDir = $null
$localProps = Join-Path $ProjectRoot 'local.properties'
if (Test-Path $localProps) {
    $line = Select-String -Path $localProps -Pattern '^\s*sdk\.dir\s*=' | Select-Object -First 1
    if ($line) { $sdkDir = (($line.Line -replace '^\s*sdk\.dir\s*=\s*', '').Trim() -replace '\\\\', '\' -replace '\:', ':') }
}
if (-not $sdkDir) { $sdkDir = $env:DEVECO_SDK_HOME }

$jarCandidates = @()
if ($SignToolJar) { $jarCandidates += $SignToolJar }
if ($sdkDir -and (Test-Path $sdkDir)) {
    $jarCandidates += Get-ChildItem $sdkDir -Recurse -File -Filter 'hap-sign-tool.jar' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
}
foreach ($p in @(
        "$env:ProgramFiles\Huawei\DevEco Studio\sdk",
        "C:\Program Files\Huawei\DevEco Studio\sdk")) {
    if (Test-Path $p) {
        $jarCandidates += Get-ChildItem $p -Recurse -File -Filter 'hap-sign-tool.jar' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    }
}
# 已安装的 HAP 安装工具通常也带一份
$jarCandidates += 'C:\Program Files (x86)\HAPInstallTool\tools\hap-sign-tool.jar'

$signJar = $jarCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $signJar) {
    Write-Err2 '找不到 hap-sign-tool.jar。请指定 -SignToolJar，或安装 DevEco Studio。'
    exit 1
}
Write-Ok "hap-sign-tool: $signJar"

# ---------------------------------------------------------------------------
# 4. 解析签名材料
# ---------------------------------------------------------------------------
if ($UseOpenHarmonyDebugMaterial) {
    Write-Step '使用 SDK 自带的 OpenHarmony 调试签名材料'
    if (-not $sdkDir -or -not (Test-Path $sdkDir)) {
        Write-Err2 '该模式需要 SDK 路径（local.properties 的 sdk.dir 或 DEVECO_SDK_HOME）。'
        exit 1
    }
    # OpenHarmony 公开 SDK 把这些放在 toolchains/lib 下
    $libDir = Get-ChildItem $sdkDir -Recurse -Directory -Filter 'lib' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'OpenHarmony.p12') } |
        Select-Object -First 1
    if (-not $libDir) {
        Write-Err2 '未在 SDK 中找到 OpenHarmony.p12（通常位于 <sdk>/.../toolchains/lib）。'
        exit 1
    }
    $Keystore = Join-Path $libDir.FullName 'OpenHarmony.p12'
    $KeystorePwd = '123456'
    $KeyAlias = 'OpenHarmony Application Release'
    $KeyPwd = '123456'
    $AppCert = Join-Path $libDir.FullName 'OpenHarmonyApplication.pem'
    # 调试 profile 需要先用模板生成，见 docs/BUILD.md 第 4.3 节
    $profileCandidate = Join-Path $libDir.FullName 'UnsgnedDebugProfileTemplate.json'
    Write-Warn2 "使用：$Keystore"
    Write-Warn2 "应用证书：$AppCert"
    Write-Warn2 "⚠️ 该模式产出的 HAP 只能安装到 OpenHarmony 设备/模拟器，不能装到鸿蒙 NEXT 手机。"
    Write-Warn2 "   还需要一个已签名的 profile（.p7b）；模板位于 $profileCandidate"
    if (-not $Profile -and (Test-Path (Join-Path $libDir.FullName 'profile.p7b'))) {
        $Profile = Join-Path $libDir.FullName 'profile.p7b'
    }
}

if (-not $Keystore -or -not $AppCert -or -not $Profile) {
    Write-Err2 '缺少签名材料。需要同时提供：-Keystore、-AppCert、-Profile'
    Write-Err2 '详细获取方式见 docs/BUILD.md 第 4 节。'
    exit 1
}
foreach ($f in @($Keystore, $AppCert, $Profile)) {
    if (-not (Test-Path $f)) { Write-Err2 "找不到签名材料文件：$f"; exit 1 }
}

Write-Step '签名参数'
Write-Ok "keystore : $Keystore"
Write-Ok "keyAlias : $KeyAlias"
Write-Ok "appCert  : $AppCert"
Write-Ok "profile  : $Profile"
Write-Ok "signAlg  : $SignAlg"

# ---------------------------------------------------------------------------
# 5. 调用 hap-sign-tool
# ---------------------------------------------------------------------------
Write-Step '执行签名'

$signArgs = @(
    '-jar', $signJar,
    'sign-app',
    '-keyAlias', $KeyAlias,
    '-signAlg', $SignAlg,
    '-mode', 'localSign',
    '-appCertFile', $AppCert,
    '-profileFile', $Profile,
    '-inFile', $Input,
    '-keystoreFile', $Keystore,
    '-outFile', $Output,
    '-keyPwd', $KeyPwd,
    '-keystorePwd', $KeystorePwd
)

Write-Host "    java -jar hap-sign-tool.jar sign-app ..." -ForegroundColor DarkGray
& $java @signArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0 -or -not (Test-Path $Output)) {
    Write-Err2 "签名失败（exit=$exitCode）"
    Write-Err2 '常见原因：密码错误（error 0x1000 / 0x1001）、profile 与证书不匹配（0x1002）、signAlg 与密钥类型不符。'
    exit 1
}

$sizeKb = [math]::Round((Get-Item $Output).Length / 1KB, 1)
Write-Host ""
Write-Ok "签名成功：$Output ($sizeKb KB)"
Write-Host ""
Write-Host "安装到设备：" -ForegroundColor Cyan
Write-Host "    hdc install -r `"$Output`"" -ForegroundColor DarkGray
