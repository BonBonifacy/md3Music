# `rust-local-force-fork` 上游同步计划

## 🎯 Project Overview & Scope

### 目标与验收标准

| 编号 | 场景 | 可观察结果 |
| --- | --- | --- |
| AC-01 | 将 `zzyoxml/md3Music` 的 `rust-local-force` 同步至 fork | 合并提交有原 fork `bdbaaf39` 和本轮上游 `fdfbb532` 两个父提交。自动合并纳入自 `3b02875d` 起的源码变化和 fork 独立改动。 |
| AC-02 | 从本地或下载文件读取内嵌歌词 | 完整读取 MP3 USLT 首字符及增强 LRC 时间戳，保留 SYLT 兜底。跳过大封面和填充区，继续读取 MP3/FLAC 歌词。 |
| AC-03 | Android 加载仓库提供的四种 ABI 库 | 每份库均由合并后的同一份 Rust 源码构建，且导出服务启停、下载标签、频谱 FFI 和 Android 频谱 JNI 接口。32 位和 64 位的方法通道整数均可解码。 |
| AC-04 | 使用 fork 下载、播放页、设置及单独的 Impeller 构建入口 | 自动合并后仍可从原入口访问。Impeller 构建检查下载标签与频谱导出。 |

### 范围与非目标

本轮交付为本地同步提交、四种 ABI 的现有预编译库及回归验证。上游播放器、设置、Windows 音频和构建改动随快照进入分支。正式发版与应用商店部署由现有流程触发。

### 当前实现与推荐设计

- Git 共同祖先为 `899d094b`，此处缺少上一份公开快照。上一轮合并提交 `bdbaaf39` 的第二父提交 `3b02875d` 已进入 fork，且其树包含上轮公开导出状态。以该提交为内容基线执行三方合并，并将 `fdfbb532` 记录为新合并提交的第二父提交。
- `git merge-tree` 预演显示 `lib/core/utils/local_lyric_loader.dart` 及 `android/app/src/main/jniLibs/` 四份库发生冲突。Dart 采用上游的 USLT/SYLT 解析入口，继续使用 fork 的随机访问策略跳过大封面。`LocalLyricLoader.loadForAudio` 与 `loadForSongAsync` 保持原调用契约。
- `lib/core/services/download/rust_tag_writer.dart` 通过 FFI 使用 `kugou_api_server/rust/src/audio_tags.rs`。上游 `SpectrumService` 分别通过 Dart FFI 与 `SpectrumPlugin.kt` JNI 使用 `src/spectrum.rs`。合并后的 `src/lib.rs` 与 `Cargo.lock` 作为四 ABI 构建输入，按库的 ELF 类型和动态导出验证结果。
- Kotlin 将两种方法通道整数转为 `Long`。停止采集时等待正在执行的 JNI 投递结束，Dart 收到回执后释放该次采集状态。Windows 沿用 WASAPI 通道。

### 关键决策与计划状态

Ready。使用已确认的上游引用和内容基线完成同步。旧 [下载实施计划](ARCHITECT_PLAN.downloads.md) 按原内容归档，Git blob 与合并前一致。

频谱回归发现原代码会在已处于前台时收到 `inactive` 事件立即重绑，断流检测随后又重绑一次。改为根据前后台切换决定是否重绑，可见失焦期间继续监测断流。

## ⚙️ Pre-requisites & Hidden Dependencies

### 环境与依赖

- 工作目录 `D:\Projects\md3Music`，Shell 为 PowerShell。Rust 使用仓库 `rust-toolchain.toml` 的 `1.95.0`，Android 使用 `android/app/build.gradle.kts` 的 NDK `28.2.13676358`，按 `scripts/tasks/android.ps1` 的 API 21 编译设置构建四个目标。
- Flutter 使用 Impeller 工作流固定的 `3.47.9` 和已有 `pubspec.lock`，通过 `flutter pub get --enforce-lockfile`。Rust 与 Flutter 使用工作区内的独立工具目录。Gradle 版本为 `9.3.1`，本地使用 JDK 17。

### 边界条件与失败模式

- 仅任取一方的 `.so` 会缺失标签或频谱接口，两种调用方共享同一库。先完成四 ABI 构建和符号比对，再替换已跟踪的库。
- 大封面或填充区可能让歌词帧位于 16 MiB 之后。按 ID3 帧长度和 FLAC 块长度定位，校验文件范围并限制缓冲量。保留有效的旧编码、USLT 优先级及 SYLT 回退。
- 两条分支的锁文件分别加入 `lofty` 与 `realfft`。使用 `--locked` 验证同一依赖树可以构建和测试。Android 方法通道可能将指针地址编码为 `Integer` 或 `Long`。

## 🗺️ Step-by-Step Execution Roadmap

### 合并与兼容性修复

进入条件是上游引用已获取，退出条件是所有合并冲突都有可验证的处理结果。

- [x] S01 应用基于 `3b02875d` 的合并树，并将 `fdfbb532` 作为合并父提交，满足 AC-01。
- [x] S02 在 `lib/core/utils/local_lyric_loader.dart` 配合上游的 USLT/SYLT 解析保留大标签读取，满足 AC-02。
- [x] S03 让 Android 频谱桥接与重建的四份 `jniLibs` 使用一致的接口，在 Impeller 工作流检查导出，满足 AC-03、AC-04。
- [x] S04 运行现有回归及提交前检查，满足 AC-01 至 AC-04。

| 步骤 | 依赖 | 文件或符号 | 实施要点与契约 | 完成条件 | 验证编号 |
| --- | --- | --- | --- | --- | --- |
| S01 | 上游引用 | Git 合并树 | 以上次公开快照为共同内容来源 | Git 父提交与目标一致，保留两方单独改动 | V01 |
| S02 | S01 | `LocalLyricLoader` | ID3/FLAC 随机读取及文本完整性 | 大封面与既有格式回归通过 | V02 |
| S03 | S01 | `Cargo.lock`、`spectrum_service.dart`、`SpectrumPlugin.kt`、`jniLibs`、`build-android-impeller.yml` | 兼容两种整数编码与 FFI 采集状态生命周期 | 4 份库按锁构建且导出服务、标签和频谱接口 | V03、V04 |
| S04 | S02、S03 | Flutter/Rust/CI | 检查既有调用入口与合并提交 | 按验证矩阵记录可复现的结果 | V01 至 V05 |

## 🧪 Verification & Testing Strategy

### 验证矩阵

| 验证编号 | 对应步骤与验收项 | 场景或风险 | 工作目录与命令或操作 | 预期结果 | 状态与证据 |
| --- | --- | --- | --- | --- | --- |
| V01 | S01、S04 / AC-01 | 快照基线和冲突状态 | 根目录用 `git ls-files -u`、`git show --format=%P -s HEAD`、`git diff --check HEAD^1 HEAD` 检查 | 两个父提交正确，无未解决项 | 通过，基线 `3b02875d`，本轮 5 个冲突已处理，合并父提交为 `bdbaaf39` 和 `fdfbb532` |
| V02 | S02 / AC-02 | 普通和大标签 USLT/SYLT/FLAC | 根目录在依赖解析后执行 `flutter test test/core/utils/local_lyric_loader_test.dart test/core/utils/download_embedded_lyric_readback_test.dart` | 保留首字符、逐字时间、`=` 及 sidecar 回退 | 通过，含 ID3v2.3 去同步和大封面读回 |
| V03 | S03 / AC-03 | Rust 锁定依赖及 Android 导出 | 在 `kugou_api_server/rust` 按下方命令测试与构建，再用 NDK `llvm-readelf --dyn-syms --wide` 检查 `.so` | 四架构编译成功，服务、标签和频谱动态符号均存在 | 通过，Rust 测试退出码 0，四份库各有 19 个预期导出，两份 64 位库的 LOAD 段按 16 KiB 对齐 |
| V04 | S03、S04 / AC-04 | Impeller APK 与工作流 | 根目录解析 YAML，检查 Bash 和 PowerShell 脚本。依赖解析后执行 `flutter build apk --no-pub --release --flavor lite --split-per-abi --target-platform android-arm64 --android-project-arg=md3EnableImpeller=true` | 配置有效，包名、签名、渲染引擎及 JNI 检查通过 | 通过，APK 仅包含 arm64，启用 Impeller，v2 签名有效。包内库有 19 个预期导出，DEX 保留频谱 JNI 方法名与签名 |
| V05 | S04 / AC-04 | 下载和播放器入口 | 根目录运行稳定性工作流中的下载测试，运行 `test/core/services/spectrum*_test.dart` 和相关播放恢复、封面切歌测试。执行 `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings` | 测试通过，静态分析无错误 | 通过，120 项 Flutter 测试通过，静态分析 0 错误、48 个非阻断警告。上游 Windows DSP 单测也通过 |

V03 先执行 `cargo fetch --locked`。为 Android 目标设置 NDK clang 和 llvm-ar，链接器参数同 `scripts/tasks/android.ps1`。在已安装四个目标的 Rust 1.95.0 下执行以下 PowerShell 命令。

```powershell
cargo test --offline --locked
foreach ($target in @('aarch64-linux-android', 'armv7-linux-androideabi', 'i686-linux-android', 'x86_64-linux-android')) {
    cargo build --offline --locked --release --target $target
}
```

### 完成定义

合并提交包含两个父提交，四份原生库与源码一致。APK 检查覆盖本地构建和包内容，Android 真机播放与写入共享音乐库仍需设备验收。

本地 Gradle 原镜像返回无效 ZIP，改用 SHA-256 校验通过的官方 Gradle 9.3.1 包。构建中 `m3e_core` 依赖下载断连，使用隔离缓存内的临时 Maven 配置解析同版本依赖，构建后移除该配置。APK 为 `build/app/outputs/flutter-apk/app-arm64-v8a-lite-release.apk`，SHA-256 为 `11fc01cbd92f8877ae598a27ae9daaa27c0de30a7f4254fd97d3838b72badff1`。
