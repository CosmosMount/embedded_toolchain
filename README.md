# Embedded toolchain 安装脚本

三个可单独分发的脚本，不依赖项目内的公共脚本：

| 平台 | 入口 | 支持范围 |
| --- | --- | --- |
| Windows | `install-windows.ps1` | x64，Windows PowerShell 5.1 / PowerShell 7 |
| Linux | `install-linux.sh` | x86_64 / aarch64，Bash；官方 Arm 二进制需要兼容的 glibc 系统 |
| macOS | `install-macos.sh` | Intel / Apple Silicon，系统 Bash 3.2 或更新版本 |

## 行为

1. 默认扫描所有已挂载文件系统盘/根目录，包含用户自定义位置、隐藏目录和挂载的数据卷。遇到无法访问的目录，先列出，再询问是否通过 UAC / sudo 提权重试。
2. **扫描阶段只读目录及文件信息，不启动任何候选程序。** CubeMX 只检测是否已安装，已有安装直接跳过版本检查。其他工具在扫描结果中标记为“版本待检查”，用户授权进入安装阶段后才检查版本/可运行性；CMake 和 Arm 必须符合指定版本。
3. 选择 `I` 安装、替换旧版本并补全 PATH，`R` 更换目标目录，`Q` 退出。**先确保新版本安装验证成功，再卸载所有已检测到的不合格旧副本**，最后移除旧 PATH 条目并启用新目录。找到合格副本时也会清理已检测到的不合格副本；CubeMX 不参与旧版本清理。卸载失败/被取消会标记未完成，单个工具失败不会中止其余工具的处理。
   版本检查后提供逐项强制重装选项（默认否），可将版本正确但目录名冗长的旧安装迁移到规范目录。选中后，所有扫描发现的该工具副本都列入替换清理计划，确认计划后才开始安装；新副本验证后清理旧副本并更新 PATH。Windows 使用 `cmake`、`arm-none-eabi`、`git`、`ninja`、`openocd` 固定子目录；Linux/macOS 的 CMake、Arm 使用固定子目录，Git/Ninja/OpenOCD 在系统/Homebrew 位置重装。CubeMX 保持已有安装跳过，不参与此强制选项。没有旧脚本所有权标记的目录，仍需明确指定独立旧目录；不能确认安全删除时标记未完成。扫描未覆盖的副本不能保证清理。

4. 新下载的命令行工具执行 `--version` 验证；CMake/Arm 还核对目标版本。最后输出逐项结果，必需工具或 PATH 配置失败时返回退出码 `1`。
5. 重复运行复用已发现的合格版本，选中的工具目录移到脚本进程 PATH 前面，持久化配置去重。失败留下的 `.staging-*` / `.staging.*` 目录不参与发现；这些目录保留下载和诊断材料，不自动清理。

这是无需额外 UI 依赖的轻量终端界面：仅文字前景色的计划表、菜单、扫描状态和汇总，不设置彩色背景、不清屏。Windows 禁用可能带背景色的 PowerShell 进度面板，改用无背景色的文本进度条；Unix 下载使用 curl 文本进度。交互询问、权限范围说明和选择菜单使用中文，命令、路径及选项按键保留原样；Windows 脚本采用 UTF-8 BOM 兼容 Windows PowerShell 5.1，Linux/macOS 脚本采用无 BOM 的 UTF-8。部分状态日志及外部程序输出仍使用英文；非彩色终端可正常使用，三个平台均支持 `NO_COLOR`（设置该环境变量即可禁用颜色）。

界面配色：青色步骤标题和扫描条、绿色成功/发现结果、黄色待处理/跳过/警告、红色失败、紫色 `[ASK]` 交互提示。提示采用独立输入行，CubeMX 采用分行编号菜单；颜色之外保留文字标签，便于纯文本阅读。颜色仅作用于前景，不修改背景。外部安装器输出不受此配色控制。

目录遍历期间约每秒原地刷新移动式进度条（总目录数未知，不显示百分比）；输出重定向或终端不支持时退回逐行日志。状态包括耗时、已遍历目录数、候选工具数、权限错误数和当前目录；发现候选工具立即输出完整路径，结束后输出 `SCAN DONE` 汇总。提权重扫同样显示进度，Windows 会通过内存命名管道将隐藏的提权扫描器输出转回当前窗口。计数表示当前扫描轮次的遍历记录，不是假定的完成百分比；Unix 的 `errors` 包含权限错误，并在每个扫描根完成后输出收集到的错误。若文件系统读取阻塞，当前目录会保留在最后一条状态中。

```text
[    ===         ] [SCAN 8s] dirs=1240 tools=2 denied=3 err=3 | /opt/toolchains
[CANDIDATE] /opt/toolchains/arm/bin/arm-none-eabi-gcc
[SCAN DONE 15s] directories=2381 candidates=6 denied=3 errors=3
```

交互终端中，安装或仅扫描结束后默认保留输出，等待按 Enter 退出；失败结果也会保留。按 Enter 后输出仍在终端历史中，但若终端由外部启动器临时创建，窗口是否关闭取决于启动器。Windows 使用 `-NoPause`、Linux/macOS 使用 `--no-pause` 可关闭等待；输入重定向时不等待。外部安装器及包管理器的界面样式由相应程序控制。

## 版本与安装策略

| 工具 | 新安装版本 | Windows | Linux / macOS |
| --- | --- | --- | --- |
| CMake | **3.22.6**（3.22 系列最终补丁版） | 官方 ZIP | 官方 tar.gz，macOS 使用 universal 包 |
| Arm GNU Toolchain | **13.3.rel1**，GCC 显示 13.3.1 | 官方 ZIP | 对应 CPU 架构的官方 tar.xz |
| Git | 安装时可用版本 | Git for Windows 官方 MinGit ZIP | 系统包管理器 / Homebrew |
| Ninja | 安装时可用版本 | 官方 GitHub release ZIP | 系统包管理器 / Homebrew |
| OpenOCD | 安装时可用版本 | xPack OpenOCD release ZIP | 系统包管理器 / Homebrew |
| CubeMX | 缺失时安装分享包 **6.18.0**；已有任意版本跳过 | 下载 Windows ZIP、解压、启动安装向导 | Linux x64 ZIP / macOS ARM64 tar.gz、解压、启动向导 |

匹配规则：CMake 必须是 **3.22.6**，其他 3.22 补丁版也会列为需替换；Arm 同时核对发行标识 **13.3.rel1** 和 GCC **13.3.1**，不把任意 GCC 13 当成符合要求。CubeMX 不检查版本。Git、Ninja 和 OpenOCD 没有指定目标版本，因此接受能返回正常版本信息的已有版本，不强制追逐最新版本。

其他命令行工具使用 `--version` 检测，主进程超时约 10 秒会判为不可验证。CubeMX 不启动程序读取版本，也不再要求用户输入 About 版本。

Windows MinGit 提供命令行 Git，不包含 Git Bash 和 Git GUI。Windows 所有新下载的命令行工具安装在指定目录，默认 `D:\embedded_toolchain`。默认目录无法创建或写入时，要求输入其他绝对路径。

新安装的便携工具使用固定目录名，不再附加随机字母：

```text
embedded_toolchain/
  cmake/
  arm-none-eabi/
  git/
  ninja/
  openocd/
  stm32cubemx/    # 在 CubeMX 安装向导中选择此目录
```

归档中的单层厂商目录会尽量展开，保留完整的 bin/share/lib 和 macOS 应用包结构。同名目录已有旧版时，仅在新包验证成功且旧目录归属明确后替换；不向未知目录合并或覆盖。`.staging-*` / `.staging.*` 等下载、验证临时目录仍保留随机后缀，以避免冲突，它们不是正式安装目录。已有合格安装继续复用，不会自动改名或搬迁；Linux/macOS 的 Git/Ninja/OpenOCD 仍由包管理器使用其标准目录。

Linux/macOS 默认把固定版本的 CMake 和 Arm 装在 `~/.local/opt/embedded_toolchain`，避免系统包管理器无法提供指定旧版本的问题；其余工具按包管理器默认位置安装。可用 `--install-dir` 更改便携工具目录，但不会改变系统包管理器或 CubeMX 的安装目录。

Linux 支持 apt、dnf、pacman、zypper、apk；需要系统权限的步骤使用 sudo。Arch 的 `pacman -Syu` 会执行系统升级，并保留 pacman 自身的确认。Alpine 虽能安装其仓库包，但官方 Arm/CMake 归档可能因 musl/glibc 不兼容而失败。macOS 需要先有 Homebrew 才能自动安装 Git/Ninja/OpenOCD；没有时这些项会报告失败并给出官网，不自动下载执行 Homebrew 安装脚本。

## 使用

以下命令供你确认后自行执行。开发过程中未运行这些安装脚本，也未安装工具或修改本机 PATH。

Windows：

```powershell
# 安装向导
powershell -NoProfile -File .\install-windows.ps1

# 指定目录，同时扫描已有的自定义软件目录
.\install-windows.ps1 -InstallDir 'E:\Dev Tools' -SearchRoot 'E:\SDK','C:\CustomTools'

# 只读扫描：不启动候选程序，不创建临时文件，不安装、不改权限或 PATH
.\install-windows.ps1 -ScanOnly
.\install-windows.ps1 -DeepScan -ScanOnly
```

如果 PowerShell 执行策略阻止脚本，可在核对文件内容后使用单进程策略，不需要永久修改系统设置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Linux：

```bash
bash install-linux.sh
bash install-linux.sh --scan-only
bash install-linux.sh --install-dir "$HOME/dev tools" --search-root /data/sdk
```

macOS：

```bash
bash install-macos.sh
bash install-macos.sh --deep-scan --scan-only
```

建议以普通用户启动，脚本会在系统包安装/卸载时单独使用 sudo。Unix 下载需要已有 `curl`、`tar` 和 SHA256 工具（`sha256sum` 或 `shasum`）；解压 Arm 归档需要 tar 支持 xz，部分 Linux 需安装 `xz-utils`。Linux 的 CubeMX ZIP 解压还需要 `unzip`。

## CubeMX

脚本已接入以下三个用户提供的分享包，并通过分享页面核实文件名：

| 平台 | 分享包 |
| --- | --- |
| Windows x64 | [SetupSTM32CubeMX-6.18.0-Win-x86_64.zip](https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQAhhy-uMdyhTK8LwSanKsiNAShn5shcsRkNmBqSKGvIrZw?e=cpKvAb) |
| macOS Apple Silicon | [SetupSTM32CubeMX-6.18.0-Mac-aarch64.tar.gz](https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQBi0ZlmZkFcSbUxlVfa4GUTAdpQuEDETtKtoDKH_uyoZgg?e=Nb34fh) |
| Linux x64 | [SetupSTM32CubeMX-6.18.0-Lin-x86_64.zip](https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQAXX5o6ZdrcSorLXnMmoY1vAdAB2Ce_DfWZJ_dW-ImdNE4) |

检测不到 CubeMX 时，先显示菜单：

| 输入 | 行为 |
| --- | --- |
| `1` | 下载解压，然后在获得安装器写入范围授权后启动安装向导 |
| `2` | 仅下载解压，打印安装器完整路径，不启动安装器，结果显示 `READY (not installed)` |
| `3` 或回车 | 跳过，不下载、不启动 |

选择 `1` 或 `2` 后请求平台对应的分享链接（附加 `download=1`）、校验压缩包可读性、解压并找到安装器，保留安装器所需的同级 JRE。Linux 会为解压出的安装器添加当前用户执行权限。**选择 `1` 会自动启动安装器，但不会代替用户完成许可接受和向导设置。请在向导中选择安装根目录下的 `stm32cubemx`；最终目录由向导设置决定。** 尚未验证此版安装器的静默安装参数，因此不声称无人值守安装。已有 CubeMX 时直接跳过，不显示重复安装菜单。

在另一台电脑直接下载的前提是分享权限允许该电脑的用户下载，且链接未过期。未授权、登录页或非压缩包响应不会作为程序执行；会提示输入已手动下载的本地压缩包，也可跳过。脚本不会导出本机登录 Cookie。分享包尚未下载进行内容/签名校验，也没有可供固定校验的 SHA256。

没有提供 macOS Intel / Linux ARM64 的 CubeMX 包，这两个平台会提示提供兼容的本地安装器或跳过；不会错误使用另一种架构的包。

可提前指定安装器：

```powershell
.\install-windows.ps1 -CubeMXInstaller 'C:\Downloads\SetupSTM32CubeMX-6.18.0.exe'
```

```bash
bash install-linux.sh --cubemx-installer "$HOME/Downloads/SetupSTM32CubeMX-6.18.0"
bash install-macos.sh --cubemx-installer "$HOME/Downloads/SetupSTM32CubeMX-6.18.0.app"
```

上面是路径示例，以实际解压文件为准。Linux 需要图形桌面；macOS 使用 `open -W` 打开安装器。向导结束后扫描常用安装位置以补全 PATH，未找到时才要求输入实际 `STM32CubeMX.exe` / `STM32CubeMX` 路径。没有找到或提供安装后的路径会标记 **UNVERIFIED**，不会假报安装成功。

## 旧版本卸载

- 新版本未安装验证成功时，不删除旧安装。
- Windows 优先使用注册表中与工具及安装目录匹配的 MSI/EXE 卸载器；Linux 根据文件所属软件包使用 apt/dnf/zypper/pacman；macOS 识别 Homebrew Cellar 后使用 brew uninstall。包管理器会保留依赖变更确认，不使用强制忽略依赖选项。
- 脚本新装的便携目录记录归属标记，后续可自动识别删除边界。对于没有卸载记录/归属标记的旧便携安装，必须输入确切的独立安装根目录；脚本校验旧可执行文件位于其中、新安装位于其外，拒绝系统根、用户根和包含其他已知工具的共享目录，不根据一个 `bin` 文件夹猜测整个安装位置。
- 删除目录是永久删除，不保留旧安装备份。拒绝指定根目录、权限不足、包管理器取消、文件仍占用或卸载需重启时，会报告未完成；不会悄悄保留旧版本并报告成功。Alpine 的已有包归属无法安全自动转换为删除命令时，会要求先通过原包管理器卸载后重试。
- IDE 内嵌工具、共享 SDK 和未知安装布局可能需要通过其原始安装方式卸载，不会递归删除整个 IDE。无法访问的目录内仍可能存在未发现的旧版本，这部分不会被声称已清除。

## PATH 与扫描边界

权限按阶段交互授权：

| 范围 | 扫描阶段 | 安装阶段 |
| --- | --- | --- |
| 已有目录、文件信息 | 只读；不可访问时可选择只读辅助进程提权重试 | 按需要读取 |
| 指定安装目录 | 不创建、不写入、不修改 ACL | 用户确认后允许创建、下载、解压及保存记录；不可写时可选择仅为该目录授予当前用户写权限 |
| 版本检查程序 | 不执行 | 单独确认后执行 `--version`，临时输出放在指定安装目录内 |
| 旧安装目录、系统包文件及数据库 | 不修改 | 各自说明范围并询问，拒绝则对应操作未完成 |
| 用户 PATH、Shell 启动文件、机器 PATH | 不修改 | 分别授权；拒绝不会跳过权限要求继续写入 |

Windows 的安装目录授权使用 UAC 为当前用户添加该目录的 Modify ACL，不修改父目录或递归改写其他目录；Linux 使用 `setfacl` 添加当前用户的目录 rwx 权限，macOS 使用目录 ACL。Linux 缺少 `setfacl` 时不自动改成 chown 或放宽全局权限，可改选已有写权限的目录。扫描阶段不调用这些授权写操作，扫描辅助进程不执行磁盘日志或结果文件写入。

这是脚本的操作范围约束，**不是操作系统层面的只读 token 或沙箱**：UAC/sudo 身份本身具有更高权限，操作系统仍可能记录认证、审计或访问时间。外部版本程序、包管理器和 CubeMX 安装器也不是沙箱进程，因此执行它们属于单独确认的安装阶段，不能保证第三方程序只写指定目录。若需要内核强制限制第三方程序，应在受限容器/虚拟机中另行验收。

- Windows 移除已卸载工具的旧用户 PATH 条目，将新目录置前，并更新脚本进程 PATH；不使用 `setx`。若旧条目位于机器 PATH，会单独请求 UAC 清理；拒绝或失败会报告未完成。`removed-paths.json` 记录待清理条目，便于重试。另生成 `Activate-Toolchain.ps1` 供当前 PowerShell 终端使用；其他未处理的系统 PATH 冲突会明确提示。重启已打开的终端和父应用后再构建。
- Linux/macOS 重建安装目录内的 `env.sh`，先剔除记录在 `removed-paths.txt` 中的旧工具专属目录，再启用新目录；Bash/Zsh 启动配置自动加载它。不会从 PATH 中移除 `/usr/bin` 等共享系统目录，也不会猜测改写用户自定义 shell 代码。当前终端可按提示 `source`。Fish 等其他 shell 不在自动持久化支持范围内。
- 默认进行完整目录发现，`-DeepScan` / `--deep-scan` 保留为兼容参数。用 `-SearchRoot` / `--search-root` 添加额外根目录、UNC 路径或需要显式跟随的目录链接。全盘扫描尤其是在机械盘或网络挂载上可能耗时较长。
- Windows 扫描所有 PowerShell 可见文件系统盘，并跟随可解析的 junction/符号链接目标，按目标路径去重，避免循环；无法解析的链接会列出。Unix 从 `/` 扫描，包含 `/Volumes`、`/mnt`、`/media` 等挂载入口，仅排除 `/proc`、`/sys`、`/dev`、`/run`、`/private/var/run` 等虚拟/运行时目录与安装暂存目录。Unix 不递归跟随途中遇到的目录链接，真实目标通常通过全盘扫描覆盖；`--search-root` 明确传入的链接会被跟随。
- 权限错误单独展示并提供 `[y/N]` 选择。Windows 启动仅枚举目录的 UAC 子进程，通过仅允许当前用户和管理员访问的内存命名管道返回结果；Linux/macOS 只对固定的 `/usr/bin/find` 使用 sudo，候选路径与错误均通过内存/进程管道传递。扫描不修改 ACL，也不会将后续版本检测和用户配置改为管理员身份执行。拒绝、取消或提权后仍无法读取的目录会保留提示，不能声称已扫描完整。
- macOS 隐私保护可能需要在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中授权所使用的终端，然后重新扫描。sudo 不会自动授予该权限。离线磁盘、未挂载镜像、容器内部和操作系统仍禁止访问的目录无法保证发现。
- 文件名必须对应标准可执行文件名；仅安装器、压缩包、注册表残留不算已安装。默认优先 PATH 上符合目标的版本，其次使用扫描找到的第一份合格版本；所有发现的副本都会显示检测结果。
- `-ScanOnly` / `--scan-only` 只列出候选位置；不执行候选程序，不创建扫描临时文件、不下载、不安装或卸载、不修改 ACL 或 PATH。交互模式下仍可能询问只读扫描提权。版本匹配结果必须进入已授权的安装阶段后获得。
- OpenOCD USB 驱动、Linux udev 规则和设备权限需要按调试器另行配置，本脚本不修改这些设置。

## 下载校验与验证记录

CMake 使用官方 SHA256 清单，Arm 使用官方 `.sha256asc`；校验文件下载失败或校验不匹配时停止该项。GitHub 资产提供 SHA256 digest 时核对 digest，未提供时依赖 HTTPS 与归档/运行版本检查。系统包交由原生包管理器验证。脚本不绕过 macOS Gatekeeper。

Arm 历史下载站点入口已发生迁移，历史二进制地址可能受限；此时该项明确失败，其他工具继续，不替换成不同版本。网络、认证、旧系统运行库或 GitHub API 限流也可能导致单项失败，修复原因后重新运行即可。

开发验证限于 PowerShell 语法解析、Bash `-n` 静态语法检查和文件审查；没有进行真实安装、网络安装包下载、跨平台运行、硬件烧录测试。因此脚本仍需在你授权的目标环境做首次安装验收。

首次运行建议在可恢复测试环境验收：已有 CubeMX 不检查版本/不下载；无 CubeMX 时平台匹配、登录页回退、压缩包解压和向导；新版本安装失败时保留旧工具；新版本成功后旧 MSI/包管理器/便携目录清理；取消卸载时明确失败；共享目录拒绝递归删除；新终端 PATH 剔除旧目录并启用新目录。上述场景尚未在本机执行。

官方来源：

- [CMake 3.22 官方归档](https://cmake.org/files/v3.22/)
- [Arm 13.3.rel1 官方发行说明](https://documentation-service.arm.com/static/66bb3acb882fec713ef48f84)
- [STM32CubeMX 官方下载页](https://www.st.com/en/development-tools/stm32cubemx.html)
- [Git for Windows](https://github.com/git-for-windows/git/releases/latest)
- [Ninja](https://github.com/ninja-build/ninja/releases/latest)
- [xPack OpenOCD](https://github.com/xpack-dev-tools/openocd-xpack/releases/latest)
- [Apple 隐私与安全性、完全磁盘访问权限说明](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac)
