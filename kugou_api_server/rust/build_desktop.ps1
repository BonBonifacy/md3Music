#Requires -Version 5.1
<#
.SYNOPSIS
  构建 Windows 桌面版 kugou_server（kugou_server.dll）。

.DESCRIPTION
  自动选择 host 工具链：优先 MSVC（装了 VS/VS Build Tools 的「使用 C++ 的桌面
  开发」即可，link.exe 由 rustc 自行定位，不需要开发者命令提示符）；没有 VS 时
  退回 GNU toolchain + MinGW 作为 host 编译器。
  两条路线都固定 Rust 1.95.0，与 rust-toolchain.toml 和 CI 保持一致。
  产物：target\release\kugou_server.dll
  可选 -OutDir：构建后把 dll 复制到指定目录（例如打包目录）。

.EXAMPLE
  .\build_desktop.ps1
  .\build_desktop.ps1 -OutDir 'C:\dist'
#>
param(
    [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot   # rust/..
$CargoBin = if ($env:CARGO_HOME) { Join-Path $env:CARGO_HOME 'bin' } else { Join-Path $env:USERPROFILE '.cargo\bin' }
$MsvcHost = 'x86_64-pc-windows-msvc'
$GnuHost  = 'x86_64-pc-windows-gnu'
# Cargo.lock 里 indexmap 2.14 → hashbrown 0.17 用了 edition2024，cargo 1.85 起才支持。
# 旧 cargo 会在 download 阶段就失败（error: feature `edition2024` is required），
# 所以工具链必须按 cargo 版本筛，只看"装没装 stable"是不够的。
$MinCargo = [version]'1.95.0'
$PinnedRust = '1.95.0'
$HostGcc = if ($env:MD3_DEVCPP_BIN) { Join-Path $env:MD3_DEVCPP_BIN 'gcc.exe' } else { (Get-Command gcc -ErrorAction SilentlyContinue).Source }
$HostAr = if ($env:MD3_DEVCPP_BIN) { Join-Path $env:MD3_DEVCPP_BIN 'ar.exe' } else { (Get-Command ar -ErrorAction SilentlyContinue).Source }
$VsWhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'

$env:Path = "$CargoBin;$env:Path"
# 唯一硬依赖是 rustup：所有 cargo 调用都经 `rustup run <toolchain> cargo`，
# 不要求 .cargo\bin 里存在 cargo.exe shim（部分安装方式下它并不存在）。
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { throw '未找到 rustup，请先安装 rustup' }
# 输出形如 "stable-x86_64-pc-windows-msvc (default)"，只取工具链名那一段。
$Installed = @(& rustup toolchain list 2>$null |
    ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })

# 在指定 host 的已装工具链里挑一个 cargo 版本达标的：stable-* 优先（名字稳定，
# 之后 rustup update 会自动跟进），stable 太旧时退到版本号最高的固定版本工具链。
function Select-Toolchain([string]$HostTriple) {
    $ok = foreach ($name in ($Installed | Where-Object { $_ -eq "$PinnedRust-$HostTriple" })) {
        $out = & rustup run $name cargo --version 2>$null
        if ("$out" -match '(\d+\.\d+\.\d+)' -and ([version]$Matches[1]) -ge $MinCargo) {
            [pscustomobject]@{ Name = $name; Version = [version]$Matches[1] }
        }
    }
    $ok = @($ok)
    if (-not $ok.Count) { return $null }
    return ($ok | Sort-Object Version -Descending)[0]
}

# 注意 -products *：只装了 Build Tools（无 IDE）时 vswhere 默认返回空，会误判"未装 VS"。
$VsPath = if (Test-Path $VsWhere) { & $VsWhere -latest -products * -property installationPath 2>$null } else { $null }

$Toolchain = $null
$Picked = if ($VsPath) { Select-Toolchain $MsvcHost } else { $null }
if ($Picked) {
    $Toolchain = $Picked.Name
    Write-Host "工具链：$Toolchain（cargo $($Picked.Version)，MSVC @ $VsPath）" -ForegroundColor Cyan
}
else {
    $Picked = if ($HostGcc -and (Test-Path $HostGcc)) { Select-Toolchain $GnuHost } else { $null }
    if ($Picked) {
        $Toolchain = $Picked.Name
        $env:CC_x86_64_pc_windows_gnu = $HostGcc
        $env:AR_x86_64_pc_windows_gnu = $HostAr
        Write-Host "工具链：$Toolchain（cargo $($Picked.Version)，MinGW @ $HostGcc）" -ForegroundColor Cyan
    }
}
if (-not $Toolchain) {
    throw @"
没有 cargo >= $MinCargo 的可用 host 工具链，二选一补齐后重跑：
  A) MSVC（推荐）：安装 VS Build Tools 2022 + 工作负载「使用 C++ 的桌面开发」，
     并执行 rustup toolchain install $PinnedRust-$MsvcHost
  B) GNU：安装 MinGW64 到 $HostGcc，
     并执行 rustup toolchain install $PinnedRust-$GnuHost
当前已安装工具链：
$($Installed -join "`n")
"@
}

Push-Location $PSScriptRoot
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & rustup run $Toolchain cargo build --release --locked
        if ($LASTEXITCODE -ne 0) { throw "cargo build 失败，退出码 $LASTEXITCODE" }
    }
    finally { $ErrorActionPreference = $prevEAP }

    $targetDir = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $PSScriptRoot 'target' }
    $dll = Join-Path $targetDir 'release\kugou_server.dll'
    if (-not (Test-Path $dll)) { throw "dll 未生成：$dll" }
    # 记录产出这份 dll 的工具链。MSVC 与 GNU 构建都落在同一个
    # target\release\kugou_server.dll，光看时间戳分不出是哪条路线编的；
    # MinGW 版 dll 依赖 libgcc_s_seh-1.dll / libwinpthread-1.dll，
    # 被打进便携包后 DynamicLibrary.open 会失败（App 起来但完全不能联网）。
    # scripts/tasks/windows.ps1 读这个戳来决定是否必须重编。
    Set-Content -Path (Join-Path $targetDir 'release\kugou_server.toolchain') `
        -Value $Toolchain -Encoding ASCII
    Write-Host "Built: $dll ($([math]::Round((Get-Item $dll).Length / 1MB, 1)) MB)" -ForegroundColor Green
    if ($OutDir) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        Copy-Item $dll $OutDir -Force
        Write-Host "Copied to: $OutDir" -ForegroundColor Green
    }
}
finally { Pop-Location }
