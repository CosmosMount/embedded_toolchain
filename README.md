# Embedded toolchain 安装脚本

三个可单独分发的脚本，不依赖项目内的公共脚本：

| 平台 | 入口 | 支持范围 |
| --- | --- | --- |
| Windows | `install-windows.ps1` | x64，Windows PowerShell 5.1 / PowerShell 7 |
| Linux | `install-linux.sh` | x86_64 / aarch64，Bash；官方 Arm 二进制需要兼容的 glibc 系统 |
| macOS | `install-macos.sh` | Intel / Apple Silicon，系统 Bash 3.2 或更新版本 |

## 行为

1. 查找 PATH、常见安装目录中的六种工具。Windows 还读取卸载注册表中的安装目录；macOS 搜索 Applications 和 Homebrew 目录。
2. 打印彩色状态表、已有工具完整路径、安装目标和目录。发现任意版本即跳过安装，不升级、不降级。已有工具的发现基于可执行文件位置，不启动已有程序获取版本。
3. 选择 `I` 安装缺失项并补全 PATH，`R` 更换目标目录，`Q` 退出。单个工具失败不会中止其余工具的处理。
4. 新下载的命令行工具执行 `--version` 验证；CMake/Arm 还核对目标版本。最后输出逐项结果，必需工具或 PATH 配置失败时返回退出码 `1`。
5. 重复运行跳过已发现的安装，PATH 不重复追加。失败留下的 `.staging-*` / `.staging.*` 目录不参与发现；这些目录保留下载和诊断材料，不自动清理。

这是无需额外 UI 依赖的轻量终端界面：仅文字前景色的计划表、菜单、扫描状态和汇总，不设置彩色背景、不清屏。Windows 禁用可能带背景色的 PowerShell 进度面板，改用普通状态文字；Unix 下载使用 curl 文本进度。为避免各平台终端编码问题，界面使用英文；非彩色终端可正常使用，Unix 支持 `NO_COLOR`。

交互终端中，安装或只读扫描结束后默认保留输出，等待按 Enter 退出；失败结果也会保留。按 Enter 后输出仍在终端历史中，但若终端由外部启动器临时创建，窗口是否关闭取决于启动器。Windows 使用 `-NoPause`、Linux/macOS 使用 `--no-pause` 可关闭等待；输入重定向时不等待。外部安装器及包管理器的界面样式由相应程序控制。

## 版本与安装策略

| 工具 | 新安装版本 | Windows | Linux / macOS |
| --- | --- | --- | --- |
| CMake | **3.22.6**（3.22 系列最终补丁版） | 官方 ZIP | 官方 tar.gz，macOS 使用 universal 包 |
| Arm GNU Toolchain | **13.3.rel1**，GCC 显示 13.3.1 | 官方 ZIP | 对应 CPU 架构的官方 tar.xz |
| Git | 安装时可用版本 | Git for Windows 官方 MinGit ZIP | 系统包管理器 / Homebrew |
| Ninja | 安装时可用版本 | 官方 GitHub release ZIP | 系统包管理器 / Homebrew |
| OpenOCD | 安装时可用版本 | xPack OpenOCD release ZIP | 系统包管理器 / Homebrew |
| CubeMX | **6.18.0**，可跳过 | 本地官方安装器交互安装 | 本地官方安装器交互安装 |

Windows MinGit 提供命令行 Git，不包含 Git Bash 和 Git GUI。Windows 所有新下载的命令行工具安装在指定目录，默认 `D:\embedded_toolchain`。默认目录无法创建或写入时，要求输入其他绝对路径。

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

# 只读扫描：不会创建目录、下载、启动已有工具或修改 PATH
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

建议以普通用户启动，脚本会在系统包安装时单独使用 sudo。Unix 下载需要已有 `curl`、`tar` 和 SHA256 工具（`sha256sum` 或 `shasum`）；解压 Arm 归档需要 tar 支持 xz，部分 Linux 需安装 `xz-utils`。

## CubeMX

ST 登录、许可接受与 GUI 安装由用户处理。未检测到 CubeMX 时，可以输入已从 ST 下载并解压的 **6.18.0** 安装器路径，也可直接回车跳过。不会猜测 ST 的受认证下载地址，也不会替用户接受许可。

可提前指定安装器：

```powershell
.\install-windows.ps1 -CubeMXInstaller 'C:\Downloads\SetupSTM32CubeMX-6.18.0.exe'
```

```bash
bash install-linux.sh --cubemx-installer "$HOME/Downloads/SetupSTM32CubeMX-6.18.0"
bash install-macos.sh --cubemx-installer "$HOME/Downloads/SetupSTM32CubeMX-6.18.0.app"
```

上面是路径示例，以实际解压文件为准。Linux 安装器需要已有执行权限和图形桌面；macOS 使用 `open -W` 打开安装器。启动前要求确认版本为 6.18.0，安装完成后输入实际 `STM32CubeMX.exe` / `STM32CubeMX` 可执行文件路径来补全 PATH。GUI 软件不强行执行通用 `--version`，所以该版本由用户核对；没有提供安装后的路径会标记 **UNVERIFIED**，不会假报安装成功。已有任意版本 CubeMX 仍按规则跳过。

## PATH 与扫描边界

- Windows 合并到当前用户 PATH，并更新安装脚本进程的 PATH；不使用可能截断值的 `setx`。已打开的终端和父应用可能需要重新启动。
- Linux/macOS 生成安装目录下的 `env.sh`，并向 Bash 的登录配置、`.bashrc`、Zsh 的 `.zshrc` / `.zprofile` 添加幂等加载语句。已有配置不覆盖；当前终端可按输出提示 `source`。Fish 等其他 shell 不在自动持久化支持范围内。
- 默认扫描常用目录，不保证找到任意磁盘任意位置的工具。用 `-SearchRoot` / `--search-root` 添加自定义目录，或用 `-DeepScan` / `--deep-scan` 扩大扫描。
- Windows 深度扫描可访问的文件系统盘；Unix 深度扫描 `/`，排除虚拟目录和 `/Volumes`、`/mnt`、`/media` 等挂载入口。没有读取权限的目录跳过，目录符号链接不递归跟随。扫描不是完整性证明；离线磁盘、容器内工具和无法访问的目录无法保证发现。
- 文件名必须对应标准可执行文件名；仅安装器、压缩包、注册表残留不算已安装。默认优先 PATH 上的版本，其次使用扫描找到的第一份。不启动已有二进制意味着损坏的旧安装也可能被识别；请自行移走损坏安装后重试。
- OpenOCD USB 驱动、Linux udev 规则和设备权限需要按调试器另行配置，本脚本不修改这些设置。

## 下载校验与验证记录

CMake 使用官方 SHA256 清单，Arm 使用官方 `.sha256asc`；校验文件下载失败或校验不匹配时停止该项。GitHub 资产提供 SHA256 digest 时核对 digest，未提供时依赖 HTTPS 与归档/运行版本检查。系统包交由原生包管理器验证。脚本不绕过 macOS Gatekeeper。

Arm 历史下载站点入口已发生迁移，历史二进制地址可能受限；此时该项明确失败，其他工具继续，不替换成不同版本。网络、认证、旧系统运行库或 GitHub API 限流也可能导致单项失败，修复原因后重新运行即可。

开发验证限于 PowerShell 语法解析、Bash `-n` 静态语法检查和文件审查；没有进行真实安装、网络安装包下载、跨平台运行、硬件烧录测试。因此脚本仍需在你授权的目标环境做首次安装验收。

官方来源：

- [CMake 3.22 官方归档](https://cmake.org/files/v3.22/)
- [Arm 13.3.rel1 官方发行说明](https://documentation-service.arm.com/static/66bb3acb882fec713ef48f84)
- [STM32CubeMX 官方下载页](https://www.st.com/en/development-tools/stm32cubemx.html)
- [Git for Windows](https://github.com/git-for-windows/git/releases/latest)
- [Ninja](https://github.com/ninja-build/ninja/releases/latest)
- [xPack OpenOCD](https://github.com/xpack-dev-tools/openocd-xpack/releases/latest)
