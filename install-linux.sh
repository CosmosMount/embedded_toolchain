#!/usr/bin/env bash
# Standalone, Bash 3.2+. This file never needs to be sourced.
set -u
set -o pipefail
PLATFORM=Linux
ROOT="${HOME}/.local/opt/embedded_toolchain"
DEEP=1
SCAN_ONLY=0
NO_PAUSE=0
CUBE_INSTALLER=''
EXTRA_ROOTS=()
NAMES=(cmake git arm-none-eabi-gcc openocd STM32CubeMX ninja)
FOUND=()
OLD_NAMES=()
OLD_PATHS=()
REMOVED_DIRS=()
SEEN=()
CANDIDATES=()
SCAN_WORK=''
SCAN_ERRORS=()
WRITE_AUTHORIZED=0
VERSIONS_CHECKED=0
FORCE_TOOLS=()
STATUS=()
PATH_DIRS=()
FAILED=0
SCAN_LINE=0
SCAN_TICK=0
usage() {
    cat <<'EOF'
Options:
  --install-dir DIR     Portable tool destination (absolute path)
  --search-root DIR     Additional scan directory (repeatable)
  --deep-scan           Compatibility option; full filesystem scan is default
  --scan-only           Read-only discovery; no execution, temporary files or writes
  --no-pause            Exit without waiting for Enter
  --cubemx-installer P  Extracted official CubeMX 6.18.0 installer
  --help
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir|--search-root|--cubemx-installer)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            case "$1" in
                --install-dir) ROOT=$2 ;;
                --search-root) EXTRA_ROOTS+=("$2") ;;
                --cubemx-installer) CUBE_INSTALLER=$2 ;;
            esac
            shift 2 ;;
        --deep-scan) DEEP=1; shift ;;
        --scan-only) SCAN_ONLY=1; shift ;;
        --no-pause) NO_PAUSE=1; shift ;;
        --help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
finish() {
    local code=$?
    trap - EXIT
    [ "$SCAN_LINE" -eq 0 ] || printf '\n'
    if [ "${BASH_SUBSHELL:-0}" -eq 0 ] && [ -n "$SCAN_WORK" ]; then
        rm -f "$SCAN_WORK/paths" "$SCAN_WORK/errors" "$SCAN_WORK/version"
        rmdir "$SCAN_WORK" 2>/dev/null || true
    fi
    if [ "${BASH_SUBSHELL:-0}" -eq 0 ] && [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
        printf '\n操作结束。按 Enter 退出（输出仍保留在终端历史中）. '
        IFS= read -r _finish_reply || true
    fi
    exit "$code"
}
trap finish EXIT
[ "$(uname -s)" = "$PLATFORM" ] || { printf 'Wrong platform: expected %s\n' "$PLATFORM" >&2; exit 2; }
case "$ROOT" in /*) ;; *) echo 'Installation directory must be absolute.' >&2; exit 2 ;; esac
C=''; Y=''; G=''; R=''; M=''; RESET=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    # Change foreground only; preserve the terminal background and other styles.
    C=$'\033[36m'; Y=$'\033[33m'; G=$'\033[32m'; RESET=$'\033[39m'
    R=$'\033[31m'; M=$'\033[35m'
fi
banner() { printf '\n%s+------------------------------------------------------------+\n  >> %s\n+------------------------------------------------------------+%s\n' "$C" "$1" "$RESET"; }
ui_status() {
    local color=$C
    case "$1" in
        *FAIL*|*ERROR*|*INCOMPLETE*) color=$R ;;
        *DENIED*|*MISMATCH*|*PENDING*|*READY*|*SKIP*|*REMOVE*) color=$Y ;;
        *DONE*|*MATCH*|*CANDIDATE*|*INSTALLED*|*FOUND*|*SUCCESS*) color=$G ;;
    esac
    printf '%s%s%s\n' "$color" "$1" "$RESET"
}
ask() { printf '\n%s[ASK] %s%s\n  > ' "$M" "$1" "$RESET"; IFS= read -r REPLY || REPLY=''; }
confirm_write_scope() {
    [ "$WRITE_AUTHORIZED" -eq 1 ] || { echo 'Installation write access has not been authorized.' >&2; return 1; }
    ask "是否允许以下额外写入范围：$1 [y=是 / N=否，默认 N]："
    case "$REPLY" in y|Y) return 0 ;; *) echo "Write scope declined: $1" >&2; return 1 ;; esac
}
scan_display() {
    local message=$1 width=${COLUMNS:-80} position bar line LC_ALL=C
    case "$width" in ''|*[!0-9]*) width=80 ;; esac
    if [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ] || [ "$width" -lt 40 ]; then
        printf '%s\n' "$message"; return
    fi
    if [ "$SCAN_LINE" -gt 0 ]; then
        printf '\r%*s\r' "$SCAN_LINE" ''
        SCAN_LINE=0
    fi
    case "$message" in
        '[SCAN '[0-9]*s']'*)
            position=$((SCAN_TICK % 26))
            [ "$position" -le 13 ] || position=$((26 - position))
            SCAN_TICK=$((SCAN_TICK + 1))
            printf -v bar '[%*s===%*s] ' "$position" '' "$((13 - position))" ''
            # Full paths remain in candidate records; keep the live row ASCII
            # so control characters and wide glyphs cannot wrap the bar.
            line=${message//[^[:print:]]/?}
            line="$bar$line"
            if [ "${#line}" -gt "$((width - 1))" ]; then line="${line:0:$((width - 4))}..."; fi
            printf '\r%s%s%s' "$C" "$line" "$RESET"
            SCAN_LINE=${#line} ;;
        *) ui_status "$message" ;;
    esac
}
collect_paths() {
    local elevated=$1 root p directory count=0 candidates=0 started=$SECONDS last=-1 denied=0 errors=0
    local prefix=()
    [ "$elevated" -eq 0 ] || prefix=(sudo -k)
    SCAN_ERRORS=()
    # Include mounted data/removable volumes. Never traverse virtual filesystems.
    for root in / ${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"}; do
        case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
        scan_display "Scanning: $root"
        directory=$root
        scan_display "[SCAN 0s] dirs=$count tools=$candidates | $directory"
        # Emit directory records as well, so a tree containing no tools still
        # produces progress. Stream paths using NUL delimiters (spaces/newlines safe).
        while IFS= read -r -d '' p; do
            case "$p" in
                '!ERROR!'*)
                    p=${p#'!ERROR!'}; SCAN_ERRORS+=("$p"); errors=$((errors + 1))
                    case "$p" in *'Permission denied'*|*'Operation not permitted'*) denied=$((denied + 1)) ;; esac
                    scan_display "[SCAN ERROR] $p"; continue ;;
                '!EXIT!'*)
                    [ "$p" = '!EXIT!0' ] || scan_display "[SCAN INCOMPLETE] find exit status: ${p#'!EXIT!'}"
                    continue ;;
            esac
            if [ -d "$p" ]; then
                count=$((count + 1)); directory=$p
            else
                case "${p##*/}" in
                    cmake|git|arm-none-eabi-gcc|openocd|STM32CubeMX|ninja)
                        CANDIDATES+=("$p")
                        candidates=$((candidates + 1))
                        scan_display "[CANDIDATE] $p" ;;
                    *) count=$((count + 1)); directory=$p ;;
                esac
            fi
            if [ "$SECONDS" -ne "$last" ]; then
                scan_display "[SCAN $((SECONDS - started))s] dirs=$count tools=$candidates denied=$denied err=$errors | $directory"
                last=$SECONDS
            fi
        done < <(
            # Stream paths through fd 3 and collect stderr in memory. Emit error
            # records only after find finishes, avoiding mixed partial records.
            exec 3>&1
            scan_errors=$(LC_ALL=C ${prefix[@]+"${prefix[@]}"} /usr/bin/find -H "$root" \
                \( -name '.staging.*' -o -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /private/var/run \) -prune -o \
                -type d -print0 -o \( -type f -o -type l \) \
                \( -name cmake -o -name git -o -name arm-none-eabi-gcc -o -name openocd -o -name STM32CubeMX -o -name ninja \) \
                -print0 2>&1 1>&3)
            scan_exit=$?
            while IFS= read -r scan_error; do
                [ -z "$scan_error" ] || printf '!ERROR!%s\0' "$scan_error"
            done < <(printf '%s\n' "$scan_errors")
            printf '!EXIT!%s\0' "$scan_exit"
        )
    done
    scan_display "[SCAN DONE $((SECONDS - started))s] directories=$count candidates=$candidates denied=$denied errors=$errors"
}
read_version() {
    local pid watchdog result
    [ "$WRITE_AUTHORIZED" -eq 1 ] || { echo 'Version execution is forbidden in read-only discovery.' >&2; return 1; }
    [ -x "$1" ] || return 1
    (cd "$ROOT" && export TMPDIR="$SCAN_WORK" && exec "$1" --version) > "$SCAN_WORK/version" 2>&1 &
    pid=$!
    # macOS has no default timeout command. Bound each probe without sudo.
    ( sleep 10; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"; result=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    [ "$result" -eq 0 ] || return 1
    cat "$SCAN_WORK/version"
}
check_candidate() {
    local p=$1 base i prior version='' ok=0 bundle label
    for prior in ${SEEN[@]+"${SEEN[@]}"}; do [ "$prior" != "$p" ] || return 0; done
    SEEN+=("$p")
    if [ "$PLATFORM" = Darwin ] && [ "$p" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then return 0; fi
    base=${p##*/}
    for i in 0 1 2 3 4 5; do
        [ "$base" = "${NAMES[$i]}" ] || continue
        if [ "$base" = STM32CubeMX ]; then
            version='existing installation; version check disabled'
            [ ! -x "$p" ] || ok=1
        else
            version=$(read_version "$p" || true)
            case "$base" in
                cmake) printf '%s\n' "$version" | grep -Eq '^cmake version 3\.22\.6([[:space:]]|$)' && ok=1 ;;
                arm-none-eabi-gcc)
                    if printf '%s\n' "$version" | grep -Eiq '13\.3\.rel1' && printf '%s\n' "$version" | grep -Eq '13\.3\.1([^0-9.]|$)'; then ok=1; fi ;;
                git) printf '%s\n' "$version" | grep -Eq '^git version [0-9]' && ok=1 ;;
                ninja) printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+' && ok=1 ;;
                openocd) printf '%s\n' "$version" | grep -q 'Open On-Chip Debugger' && ok=1 ;;
            esac
        fi
        label='MISMATCH / UNKNOWN / UNUSABLE'
        if [ "$ok" -eq 1 ]; then
            label=MATCH
            [ -n "${FOUND[$i]}" ] || FOUND[$i]=$p
        fi
        ui_status "[$label] $base | ${version%%$'\n'*} | $p"
        if [ "$ok" -eq 0 ] && [ "$base" != STM32CubeMX ]; then OLD_NAMES+=("$base"); OLD_PATHS+=("$p"); fi
    done
}
scan() {
    local i p
    SEEN=()
    CANDIDATES=()
    OLD_NAMES=(); OLD_PATHS=()
    VERSIONS_CHECKED=0
    for i in 0 1 2 3 4 5; do
        FOUND[$i]=''
        p=$(type -P "${NAMES[$i]}" 2>/dev/null || true)
        [ -z "$p" ] || CANDIDATES+=("$p")
    done
    banner 'Scanning all accessible directories and mounted volumes; this can take several minutes'
    collect_paths 0
    if [ "${SCAN_ERRORS[0]+set}" = set ]; then
        if [ "$(id -u)" -ne 0 ] && [ -t 0 ]; then
            ask '是否授权 sudo find 只读重扫？不写入文件、不修改 ACL、不运行候选程序；系统仍可能进行认证和审计 [y=是 / N=否，默认 N]：'
            if [ "$REPLY" = y ] || [ "$REPLY" = Y ]; then
                if command -v sudo >/dev/null 2>&1; then
                    collect_paths 1
                else echo 'Elevation unavailable or declined; scan remains incomplete.'; fi
            else echo 'Permission retry skipped; scan remains incomplete.'; fi
        fi
        if [ "$PLATFORM" = Darwin ]; then echo 'macOS privacy-protected folders may require Full Disk Access for the terminal in System Settings; sudo cannot bypass it.'; fi
    fi
    for p in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
        for i in 0 1 2 3 4 5; do
            if [ "${p##*/}" = "${NAMES[$i]}" ] && [ -z "${FOUND[$i]}" ]; then FOUND[$i]=$p; fi
        done
    done
    echo '[READ ONLY] Discovery complete. No programs probed, files created, ACLs or PATH changed.'
}
check_discovered_versions() {
    local i p
    [ "$WRITE_AUTHORIZED" -eq 1 ] || return 1
    SEEN=(); OLD_NAMES=(); OLD_PATHS=()
    for i in 0 1 2 3 4 5; do FOUND[$i]=''; done
    banner 'Installation phase: checking versions (not part of read-only discovery)'
    for p in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do check_candidate "$p"; done
    VERSIONS_CHECKED=1
}
plan() {
    local i
    banner 'Embedded toolchain | installation plan'
    for i in 0 1 2 3 4 5; do
        if [ "${FORCE_TOOLS[$i]:-0}" = 1 ]; then
            ui_status "[FORCE REINSTALL] ${NAMES[$i]} (replace even if version matches)"
            continue
        fi
        if [ -n "${FOUND[$i]}" ]; then
            if [ "$VERSIONS_CHECKED" -eq 0 ] && [ "${NAMES[$i]}" != STM32CubeMX ]; then printf '[FOUND / VERSION CHECK PENDING] %s | %s\n' "${NAMES[$i]}" "${FOUND[$i]}"
            else printf '%s[FOUND / SKIP] %-20s %s%s\n' "$G" "${NAMES[$i]}" "${FOUND[$i]}" "$RESET"; fi
        else printf '%s[INSTALL / REINSTALL] %s (missing, wrong version, or unverifiable)%s\n' "$Y" "${NAMES[$i]}" "$RESET"; fi
    done
    printf 'Targets: CMake 3.22.6 | Arm 13.3.rel1 | CubeMX 6.18.0 (optional)\n'
    printf 'Portable tools: %s\nGit/Ninja/OpenOCD: system package manager default location\n' "$ROOT"
    for p in ${OLD_PATHS[@]+"${OLD_PATHS[@]}"}; do printf '[REMOVE AFTER REPLACEMENT] %s\n' "$p"; done
}
select_force_reinstall() {
    local i p j exists folder destination
    banner '可选操作：强制重装版本正确的工具／迁移旧目录'
    ui_status '[INFO] 逐项输入 Y 可替换该工具的所有已发现副本，包括版本正确的副本；直接按 Enter 跳过。'
    ui_status '[INFO] CubeMX 已安装时跳过；其安装目录由安装向导管理。'
    for i in 0 1 2 3 5; do
        [ -n "${FOUND[$i]}" ] || continue
        folder=${NAMES[$i]}; [ "$folder" != arm-none-eabi-gcc ] || folder=arm-none-eabi
        destination="$ROOT/$folder"
        case "${NAMES[$i]}" in git|ninja|openocd) destination='系统／Homebrew 包安装位置' ;; esac
        ui_status "[INFO] 当前路径：${FOUND[$i]}"
        ask "是否将 ${NAMES[$i]} 强制重装到 ${destination}？[y=是 / N=否，默认 N]："
        case "$REPLY" in y|Y) ;; *) continue ;; esac
        FORCE_TOOLS[$i]=1
        for p in ${SEEN[@]+"${SEEN[@]}"}; do
            [ "${p##*/}" = "${NAMES[$i]}" ] || continue
            exists=0
            for j in ${OLD_PATHS[@]+"${OLD_PATHS[@]}"}; do [ "$j" != "$p" ] || exists=1; done
            if [ "$exists" -eq 0 ]; then OLD_NAMES+=("${NAMES[$i]}"); OLD_PATHS+=("$p"); fi
        done
        FOUND[$i]=''
    done
}
resolve_executable() {
    local p=$1 target count=0 directory
    while [ -L "$p" ]; do
        count=$((count + 1)); [ "$count" -le 40 ] || return 1
        target=$(readlink "$p") || return 1
        case "$target" in /*) p=$target ;; *) p="${p%/*}/$target" ;; esac
    done
    directory=$(cd -P "${p%/*}" && pwd) || return 1
    printf '%s/%s\n' "$directory" "${p##*/}"
}
remove_old_tool() {
    local name=$1 selected=$2 index old real package root cursor marker owned other directory count=0
    [ -x "$selected" ] || { echo 'No validated replacement; refusing old installation removal.' >&2; return 1; }
    [ "${OLD_PATHS[0]+set}" != set ] || count=${#OLD_PATHS[@]}
    for ((index=0; index<count; index++)); do
        [ "${OLD_NAMES[$index]}" = "$name" ] || continue
        old=${OLD_PATHS[$index]}
        [ -e "$old" ] || [ -L "$old" ] || continue
        if [ -L "$old" ] && [ ! -e "$old" ]; then
            confirm_write_scope "删除此失效的旧工具链接：$old" || return 1
            if [ -w "${old%/*}" ]; then rm -- "$old" || return 1; else as_root rm -- "$old" || return 1; fi
            continue
        fi
        real=$(resolve_executable "$old") || return 1
        # A package manager may have already replaced the old binary in place.
        [ "$real" != "$(resolve_executable "$selected")" ] || continue
        package=''; owned=0
        if [ "$PLATFORM" = Linux ]; then
            if command -v dpkg-query >/dev/null 2>&1; then
                package=$(dpkg-query -S "$real" 2>/dev/null | head -n 1); package=${package%%: /*}
                if [ -z "$package" ] && [ "$real" != "$old" ]; then package=$(dpkg-query -S "$old" 2>/dev/null | head -n 1); package=${package%%: /*}; fi
                if [ -n "$package" ]; then
                    printf 'Remove old system package: %s (%s)\n' "$package" "$real"
                    confirm_write_scope "卸载软件包 ${package}（${real}）；涉及系统软件包文件和数据库" || return 1
                    as_root apt-get remove "$package" || return 1; owned=1
                fi
            elif command -v rpm >/dev/null 2>&1; then
                package=$(rpm -qf --qf '%{NAME}' "$real" 2>/dev/null) || package=''
                if [ -n "$package" ]; then
                    confirm_write_scope "卸载软件包 ${package}（${real}）；涉及系统软件包文件和数据库" || return 1
                    if command -v dnf >/dev/null 2>&1; then as_root dnf remove "$package" || return 1
                    else as_root zypper remove "$package" || return 1; fi
                    owned=1
                fi
            elif command -v pacman >/dev/null 2>&1; then
                package=$(pacman -Qqo "$real" 2>/dev/null) || package=''
                if [ -n "$package" ]; then confirm_write_scope "卸载软件包 ${package}（${real}）；涉及系统软件包文件和数据库" || return 1; as_root pacman -R "$package" || return 1; owned=1; fi
            elif command -v apk >/dev/null 2>&1; then
                # Do not guess apk package names from versioned ownership text.
                if apk info --who-owns "$real" >/dev/null 2>&1; then
                    echo "Remove the owning Alpine package explicitly, then rerun: $real" >&2; return 1
                fi
            fi
        elif command -v brew >/dev/null 2>&1; then
            case "$real" in
                /opt/homebrew/Cellar/*|/usr/local/Cellar/*)
                    package=${real#*/Cellar/}; package=${package%%/*}
                    case "$selected" in */Cellar/"$package"/*) echo 'Replacement is in the same Homebrew formula; refusing uninstall.' >&2; return 1 ;; esac
                    confirm_write_scope "卸载 Homebrew 软件包 $package 并更新 Homebrew 记录" || return 1
                    brew uninstall --formula "$package" || return 1; owned=1 ;;
            esac
        fi
        if [ "$owned" -eq 0 ]; then
            root=''; cursor=${real%/*}
            while [ "$cursor" != / ] && [ -n "$cursor" ]; do
                marker="$cursor/.embedded-toolchain-owner"
                if [ -f "$marker" ] && [ "$(head -n 1 "$marker")" = "$name" ]; then root=$cursor; break; fi
                cursor=${cursor%/*}
            done
            if [ -z "$root" ]; then
                printf 'Unregistered old tool: %s\n' "$real"
                ask "请输入仅属于 $name 的独立目录完整路径，以永久删除该目录（留空则替换未完成）："
                root=$REPLY
                [ -n "$root" ] || { echo 'Old installation not removed.' >&2; return 1; }
            fi
            root=$(cd -P "$root" && pwd) || return 1
            case "$root" in /|/usr|/usr/local|/usr/bin|/usr/local/bin|/bin|/sbin|/opt|/Applications|/home|/Users|/Library|/System|/etc|/var|/private|"$HOME"|"$HOME/.local"|"$ROOT") echo "Unsafe removal root: $root" >&2; return 1 ;; esac
            case "$HOME" in "$root"/*) echo 'Removal root contains the user home.' >&2; return 1 ;; esac
            case "$real" in "$root"/*) ;; *) echo 'Old executable is outside removal root.' >&2; return 1 ;; esac
            case "$(resolve_executable "$selected")" in "$root"/*) echo 'Removal root also contains replacement.' >&2; return 1 ;; esac
            case "$(pwd -P)" in "$root"|"$root"/*) echo 'Removal root contains the working directory.' >&2; return 1 ;; esac
            other=$(find "$root" -type f \( -name cmake -o -name git -o -name arm-none-eabi-gcc -o -name openocd -o -name STM32CubeMX -o -name ninja \) ! -name "$name" -print -quit) || return 1
            [ -z "$other" ] || { echo "Shared directory contains another tool: $other" >&2; return 1; }
            printf 'Removing verified old installation directory: %s\n' "$root"
            confirm_write_scope "永久删除旧安装目录 $root" || return 1
            if [ -w "${root%/*}" ] && [ -w "$root" ]; then rm -rf -- "$root" || return 1
            else as_root rm -rf -- "$root" || return 1; fi
            if [ -L "$old" ]; then
                # Remove only the dangling link that referred to this removed tool.
                confirm_write_scope "删除位于旧安装目录之外的工具链接：$old" || return 1
                if [ -w "${old%/*}" ]; then rm -- "$old" || return 1; else as_root rm -- "$old" || return 1; fi
            fi
        fi
        if [ -e "$old" ] || [ -e "$real" ]; then echo "Old installation still exists: $old" >&2; return 1; fi
        for directory in "${old%/*}" "${real%/*}"; do
            case "$directory" in /bin|/sbin|/usr/bin|/usr/sbin|/usr/local/bin|/usr/local/sbin|/opt/homebrew/bin|/opt/homebrew/sbin) ;; *) REMOVED_DIRS+=("$directory") ;; esac
        done
    done
}
add_path() {
    local dir=${1%/*} old
    for old in ${PATH_DIRS[@]+"${PATH_DIRS[@]}"}; do [ "$old" != "$dir" ] || return 0; done
    PATH_DIRS+=("$dir")
    # Always promote the selected version, including an existing target copy.
    local part remainder='' rest="$PATH:"
    while [ -n "$rest" ]; do
        part=${rest%%:*}; rest=${rest#*:}
        [ "$part" = "$dir" ] || remainder="$remainder:$part"
    done
    export PATH="$dir$remainder"
}
download() {
    [ "$WRITE_AUTHORIZED" -eq 1 ] || { echo 'Downloads are forbidden before directory write authorization.' >&2; return 1; }
    printf 'Download: %s\n' "$1" >&2
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 1800 --proto '=https' --proto-redir '=https' "$1" -o "$2" >&2
}
install_archive() (
    [ "$WRITE_AUTHORIZED" -eq 1 ] || exit 1
    # Subshell confines temporary variables; every mutating step checks failure.
    name=$1; url=$2; version=$3
    work=$(mktemp -d "$ROOT/.staging.XXXXXXXX") || exit 1
    archive="$work/archive.tar"
    download "$url" "$archive" || exit 1
    if [ "$name" = cmake ] || [ "$name" = arm-none-eabi-gcc ]; then
        if [ "$name" = cmake ]; then
            download 'https://cmake.org/files/v3.22/cmake-3.22.6-SHA-256.txt' "$work/checksums" || exit 1
            file=${url##*/}
            expected=$(awk -v f="$file" '$2 == f {print $1}' "$work/checksums")
        else
            download "$url.sha256asc" "$work/checksums" || exit 1
            expected=$(awk 'length($1)==64 && $1 !~ /[^a-fA-F0-9]/ {print tolower($1); exit}' "$work/checksums")
        fi
        [ "${#expected}" -eq 64 ] || { echo 'Missing SHA256 checksum' >&2; exit 1; }
        if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$archive")
        else actual=$(shasum -a 256 "$archive"); fi
        [ "${actual%% *}" = "$expected" ] || { echo 'SHA256 mismatch' >&2; exit 1; }
    fi
    mkdir "$work/payload" || exit 1
    tar -xf "$archive" -C "$work/payload" || exit 1
    exe=$(find "$work/payload" -type f -name "$name" -print | head -n 1)
    [ -n "$exe" ] && [ -x "$exe" ] || { echo "Missing executable: $name" >&2; exit 1; }
    output=$("$exe" --version 2>&1) || { printf '%s\n' "$output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -Eq "$version" || { echo "Unexpected version: $output" >&2; exit 1; }
    printf '%s\n' "$output" >&2
    payload="$work/payload"
    # Flatten a single vendor wrapper (retain macOS .app bundles intact).
    entries=()
    while IFS= read -r -d '' entry; do entries+=("$entry"); done < <(find "$payload" -mindepth 1 -maxdepth 1 -print0)
    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
        case "${entries[0]}" in *.app) ;; *) payload=${entries[0]} ;; esac
    fi
    relative=${exe#"$payload"}
    folder=$name; [ "$name" != arm-none-eabi-gcc ] || folder=arm-none-eabi
    dest="$ROOT/$folder"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        # Only remove an installation we own; never merge into unrelated files.
        [ ! -L "$dest" ] && [ -f "$dest/.embedded-toolchain-owner" ] && [ "$(head -n 1 "$dest/.embedded-toolchain-owner")" = "$name" ] || {
            echo "Fixed destination is occupied by an unverified directory; move it explicitly before retrying: $dest" >&2; exit 1;
        }
        other=$(find "$dest" -type f \( -name cmake -o -name git -o -name arm-none-eabi-gcc -o -name ninja -o -name openocd -o -name STM32CubeMX \) ! -name "$name" -print -quit) || exit 1
        [ -z "$other" ] || { echo 'Fixed destination contains another tool; refusing deletion.' >&2; exit 1; }
        confirm_write_scope "使用已验证的新版本替换本脚本管理的目录 $dest" >&2 || exit 1
        rm -rf -- "$dest" || exit 1
    fi
    mv "$payload" "$dest" || exit 1
    printf '%s\n' "$name" > "$dest/.embedded-toolchain-owner" || exit 1
    printf '%s\n' "$dest$relative"
)
as_root() {
    [ "$WRITE_AUTHORIZED" -eq 1 ] || { echo 'System mutations are forbidden in read-only discovery.' >&2; return 1; }
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else echo 'sudo is required for system package installation.' >&2; return 1; fi
}
install_package() {
    local name=$1 package=$1
    confirm_write_scope "通过包管理器安装／重装 ${name}；涉及系统／Homebrew 目录、软件包数据库和缓存" || return 1
    if [ "$PLATFORM" = Darwin ]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo 'Homebrew is required for Git/Ninja/OpenOCD: https://brew.sh . Install it, then rerun.' >&2
            return 1
        fi
        if brew list --versions "$package" >/dev/null 2>&1; then brew reinstall "$package" || return 1
        else brew install "$package" || return 1; fi
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        [ "$name" != ninja ] || package=ninja-build
        as_root apt-get update && as_root apt-get install --reinstall -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        [ "$name" != ninja ] || package=ninja-build
        if rpm -q "$package" >/dev/null 2>&1; then as_root dnf reinstall -y "$package"
        else as_root dnf install -y "$package"; fi
    elif command -v pacman >/dev/null 2>&1; then
        # Full upgrade avoids unsupported Arch partial upgrades.
        as_root pacman -Syu "$package"
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper install -y --force "$package"
    elif command -v apk >/dev/null 2>&1; then
        if apk info -e "$package" >/dev/null 2>&1; then as_root apk fix "$package"
        else as_root apk add "$package"; fi
    else echo 'Unsupported package manager; install the missing package manually.' >&2; return 1; fi
}
install_cube() {
    local p url archive work setup='' unpack format member choice
    banner 'CubeMX 安装选项'
    ui_status '[1] 下载、解压并启动安装向导'
    ui_status '[2] 仅下载、解压（已准备好，尚未安装）'
    ui_status '[3] 跳过 CubeMX（默认）'
    ask '请选择 [1/2/3，默认 3]:'
    choice=$REPLY
    case "$choice" in 1|2) ;; *) STATUS[4]='SKIPPED (user choice)'; return 0 ;; esac
    if [ -z "$CUBE_INSTALLER" ]; then
        case "$PLATFORM:$(uname -m)" in
            Linux:x86_64)
                command -v unzip >/dev/null 2>&1 || { echo 'Install unzip to extract the CubeMX ZIP.' >&2; return 1; }
                url='https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQAXX5o6ZdrcSorLXnMmoY1vAdAB2Ce_DfWZJ_dW-ImdNE4?download=1'; format=zip ;;
            Darwin:arm64)
                url='https://hkustgz-my.sharepoint.com/:u:/g/personal/pnx_hkust-gz_edu_cn/IQBi0ZlmZkFcSbUxlVfa4GUTAdpQuEDETtKtoDKH_uyoZgg?e=Nb34fh&download=1'; format=tar ;;
            *)
                echo 'No supplied CubeMX package for this CPU/platform.'
                ask '请输入与本机兼容且已解压的 CubeMX 安装器路径（留空跳过）：'
                CUBE_INSTALLER=$REPLY; url='' ;;
        esac
        if [ -n "$url" ]; then
            work=$(mktemp -d "$ROOT/.staging.cubemx.XXXXXXXX") || return 1
            archive="$work/download"; unpack="$work/payload"
            mkdir "$unpack" || return 1
            if ! download "$url" "$archive" || { [ "$format" = zip ] && ! unzip -tq "$archive" >/dev/null 2>&1; } || { [ "$format" = tar ] && ! tar -tf "$archive" >/dev/null 2>&1; }; then
                echo 'Shared download unavailable, login required, or response is not the expected archive.'
                ask "请输入本地已下载的 CubeMX $format 安装包路径（留空跳过）："
                archive=$REPLY
                if [ -z "$archive" ]; then STATUS[4]='SKIPPED (shared download unavailable)'; return 0; fi
            fi
            if [ "$format" = zip ]; then
                command -v unzip >/dev/null 2>&1 || { echo 'Install unzip to extract CubeMX.' >&2; return 1; }
                unzip -Z1 "$archive" > "$work/members" || return 1
            else tar -tf "$archive" > "$work/members" || return 1; fi
            while IFS= read -r member; do
                case "$member" in /*|../*|*/../*|*/..) echo 'Unsafe archive member.' >&2; return 1 ;; esac
            done < "$work/members"
            if [ "$format" = zip ]; then unzip -q "$archive" -d "$unpack" || return 1
            else tar -xf "$archive" -C "$unpack" || return 1; fi
            while IFS= read -r -d '' p; do
                [ -z "$setup" ] || { echo 'Archive contains multiple CubeMX installers; provide --cubemx-installer explicitly.' >&2; return 1; }
                setup=$p
            done < <(find "$unpack" -name 'SetupSTM32CubeMX*.app' -prune -print0 -o -type f \( -name 'SetupSTM32CubeMX*.pkg' -o -name 'SetupSTM32CubeMX*' \) -print0)
            [ -n "$setup" ] || { echo 'No CubeMX installer found in archive.' >&2; return 1; }
            CUBE_INSTALLER=$setup
            if [ "$PLATFORM" = Linux ]; then chmod u+x "$CUBE_INSTALLER" || return 1; fi
        fi
    fi
    if [ -z "$CUBE_INSTALLER" ]; then STATUS[4]='SKIPPED (optional ST login/manual download)'; return 0; fi
    if [ "$choice" = 2 ]; then STATUS[4]="READY (not installed): $CUBE_INSTALLER"; printf '稍后可运行此安装器： %s\n' "$CUBE_INSTALLER"; return 0; fi
    [ -e "$CUBE_INSTALLER" ] || { echo 'Installer does not exist.' >&2; return 1; }
    printf '即将启动 CubeMX 安装器，请在向导中选择此安装目录： %s/stm32cubemx\n' "$ROOT"
    confirm_write_scope '运行 CubeMX 安装向导；涉及所选目标目录写入和系统安装注册信息修改' || return 1
    if [ "$PLATFORM" = Darwin ]; then
        open -W "$CUBE_INSTALLER" || return 1
    else
        [ -x "$CUBE_INSTALLER" ] || { echo 'Installer needs execute permission; chmod +x it explicitly, then rerun.' >&2; return 1; }
        (cd "${CUBE_INSTALLER%/*}" && "./${CUBE_INSTALLER##*/}") || return 1
    fi
    p=''
    while IFS= read -r -d '' member; do p=$member; break; done < <(
        find "$ROOT" "$HOME/STMicroelectronics" "$HOME/STM32CubeMX" "$HOME/ST" /Applications /opt/ST /usr/local/ST \
            -name '.staging.*' -prune -o -type f -name STM32CubeMX -print0 2>/dev/null)
    if [ -z "$p" ]; then ask '请输入已安装的 STM32CubeMX 可执行文件完整路径（留空则不验证）：'; p=$REPLY; fi
    if [ -z "$p" ]; then STATUS[4]='UNVERIFIED (installer finished; PATH not configured)'; return 0; fi
    [ -x "$p" ] && [ "${p##*/}" = STM32CubeMX ] || { echo 'Expected executable STM32CubeMX.' >&2; return 1; }
    add_path "$p"
    STATUS[4]='INSTALLED (version check disabled)'
}
save_path() {
    [ "$WRITE_AUTHORIZED" -eq 1 ] || return 1
    local envfile="$ROOT/env.sh" tmp profile line dir
    tmp=$(mktemp "$ROOT/.env.XXXXXXXX") || return 1
    # Persist removals, including after a later rerun no longer finds old files.
    for dir in ${REMOVED_DIRS[@]+"${REMOVED_DIRS[@]}"}; do
        grep -Fqx -- "$dir" "$ROOT/removed-paths.txt" 2>/dev/null || printf '%s\n' "$dir" >> "$ROOT/removed-paths.txt" || return 1
    done
    if [ -f "$ROOT/removed-paths.txt" ]; then
        while IFS= read -r dir; do
            [ -n "$dir" ] || continue
            printf -v line '_et_dir=%q; _et_rest="$PATH:"; _et_path=""; while [ -n "$_et_rest" ]; do _et_part=${_et_rest%%%%:*}; _et_rest=${_et_rest#*:}; [ "$_et_part" = "$_et_dir" ] || _et_path="$_et_path:$_et_part"; done; export PATH="${_et_path#:}"; unset _et_dir _et_rest _et_path _et_part' "$dir"
            printf '%s\n' "$line" >> "$tmp" || return 1
        done < "$ROOT/removed-paths.txt"
    fi
    # Rebuild our own env file so stale tool selections cannot outrank this run.
    for dir in ${PATH_DIRS[@]+"${PATH_DIRS[@]}"}; do
        printf -v line '_et_dir=%q; _et_rest="$PATH:"; _et_path=""; while [ -n "$_et_rest" ]; do _et_part=${_et_rest%%%%:*}; _et_rest=${_et_rest#*:}; [ "$_et_part" = "$_et_dir" ] || _et_path="$_et_path:$_et_part"; done; export PATH="$_et_dir$_et_path"; unset _et_dir _et_rest _et_path _et_part' "$dir"
        grep -Fqx "$line" "$tmp" || printf '%s\n' "$line" >> "$tmp" || return 1
    done
    mv "$tmp" "$envfile" || return 1
    # Only execute the generated PATH assignments, not any user's shell profile.
    . "$envfile"
    printf -v line '[ ! -f %q ] || . %q # embedded-toolchain' "$envfile" "$envfile"
    # Bash login reads only the first existing login file; update that file too.
    local login="$HOME/.profile"
    if [ -f "$HOME/.bash_profile" ]; then login="$HOME/.bash_profile"
    elif [ -f "$HOME/.bash_login" ]; then login="$HOME/.bash_login"; fi
    confirm_write_scope "向 ${login}、$HOME/.bashrc、${ZDOTDIR:-$HOME}/.zshrc 和 ${ZDOTDIR:-$HOME}/.zprofile 写入 PATH 加载条目" || return 1
    for profile in "$login" "$HOME/.bashrc" "${ZDOTDIR:-$HOME}/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile"; do
        [ -d "${profile%/*}" ] || mkdir -p "${profile%/*}" || return 1
        if ! grep -Fqx "$line" "$profile" 2>/dev/null; then printf '\n%s\n' "$line" >> "$profile" || return 1; fi
    done
    printf 'PATH persisted for bash/zsh. Current terminal: source %q\n' "$envfile"
    case "${SHELL:-}" in */fish) echo 'Fish: use fish_add_path with the directories listed above; automatic startup setup supports bash/zsh only.' ;; esac
}
scan
plan
[ "$SCAN_ONLY" -eq 0 ] || exit 0
[ -t 0 ] || { echo 'Interactive terminal required for installation.' >&2; exit 2; }
ask 'I = 安装／重装所需工具并修复 PATH，R = 修改目标目录，Q = 退出：'
if [ "$REPLY" = R ] || [ "$REPLY" = r ]; then
    ask '请输入安装目录的绝对路径:'; ROOT=$REPLY
    case "$ROOT" in /*) ;; *) echo 'Absolute directory required.'; exit 2 ;; esac
    scan; plan
    ask '输入 I 继续，输入其他内容退出:'
fi
case "$REPLY" in I|i) ;; *) exit 0 ;; esac
while :; do
    while [ "$ROOT" != / ] && [ "${ROOT%/}" != "$ROOT" ]; do ROOT=${ROOT%/}; done
    case "$ROOT" in */../*|*/..|*/./*|*/.) echo 'Use a normalized absolute installation path without dot components.' >&2; exit 2 ;; esac
    if [ -d "$ROOT" ]; then ROOT=$(cd -P "$ROOT" && pwd) || exit 1; fi
    case "$ROOT" in /|/usr|/usr/local|/opt|/Applications|/Users|/home|"$HOME") echo 'Choose a dedicated toolchain subdirectory.' >&2; exit 2 ;; esac
    ask "是否授权仅创建／写入所选安装目录 ${ROOT}？[y=是 / N=否，默认 N]："
    case "$REPLY" in y|Y) WRITE_AUTHORIZED=1 ;; *) exit 0 ;; esac
    if mkdir -p "$ROOT" && probe=$(mktemp "$ROOT/.write-test.XXXXXXXX"); then rm -- "$probe"; break; fi
    ask "是否通过 sudo 仅授予当前用户对 $ROOT 的写入权限（不修改父目录、不递归修改权限）？[y=是 / N=否，默认 N]："
    if [ "$REPLY" = y ] || [ "$REPLY" = Y ]; then
        parent=${ROOT%/*}; [ -n "$parent" ] || parent=/
        # Resolve the parent before granting rights; do not grant through links.
        if [ -d "$parent" ] && [ "$(cd -P "$parent" && pwd)" = "$parent" ] && [ ! -L "$ROOT" ]; then
            if [ "$PLATFORM" = Linux ]; then
                if command -v setfacl >/dev/null 2>&1; then
                    if [ -d "$ROOT" ] || sudo mkdir -- "$ROOT"; then sudo setfacl -m "u:$(id -u):rwx" -- "$ROOT"; fi
                else echo 'setfacl is unavailable; choose a writable directory or grant access manually.'; fi
            else
                if [ -d "$ROOT" ] || sudo mkdir "$ROOT"; then
                    sudo chmod +a "$(id -un) allow read,write,append,execute,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity" "$ROOT"
                fi
            fi
            if probe=$(mktemp "$ROOT/.write-test.XXXXXXXX"); then rm -- "$probe"; break; fi
        else echo 'Grant requires an existing, non-linked parent and a non-linked target.'; fi
    fi
    WRITE_AUTHORIZED=0
    ask '请输入另一个目录的绝对路径（留空取消）：'
    ROOT=$REPLY
    case "$ROOT" in /*) scan ;; *) exit 1 ;; esac
done
SCAN_WORK=$(mktemp -d "$ROOT/.staging.runtime.XXXXXXXX") || exit 1
confirm_write_scope '运行已发现的工具并传入 --version 以确定安装方案；外部程序不受操作系统沙箱限制' || exit 1
check_discovered_versions
select_force_reinstall
plan
if [ "${FORCE_TOOLS[0]+set}${FORCE_TOOLS[1]+set}${FORCE_TOOLS[2]+set}${FORCE_TOOLS[3]+set}${FORCE_TOOLS[5]+set}" != '' ]; then
    ask '是否执行上述替换计划并清理旧副本？[y=是 / N=否，默认 N]:'
    case "$REPLY" in y|Y) ;; *) exit 0 ;; esac
fi
for dependency in curl tar; do
    command -v "$dependency" >/dev/null 2>&1 || { echo "Install prerequisite: $dependency" >&2; exit 1; }
done
# Make existing Homebrew visible without installing or executing its shellenv.
for bin in /opt/homebrew/bin /usr/local/bin; do
    [ ! -x "$bin/brew" ] || add_path "$bin/brew"
done
ARCH=$(uname -m)
for i in 0 1 2 3 4 5; do
    name=${NAMES[$i]}
    banner "$name"
    STATUS[$i]=''
    if [ -n "${FOUND[$i]}" ]; then
        add_path "${FOUND[$i]}"
        if remove_old_tool "$name" "${FOUND[$i]}"; then STATUS[$i]='EXISTING (obsolete versions removed if present)'
        else STATUS[$i]='INCOMPLETE (old version removal failed)'; FAILED=1; fi
        continue
    fi
    ok=0
    case "$name" in
        cmake|arm-none-eabi-gcc)
            host=''
            case "$PLATFORM:$ARCH" in
                Linux:x86_64) host=x86_64 ;;
                Linux:aarch64|Linux:arm64) host=aarch64 ;;
                Darwin:x86_64) host=darwin-x86_64 ;;
                Darwin:arm64) host=darwin-arm64 ;;
            esac
            if [ -z "$host" ]; then echo "Unsupported architecture: $ARCH" >&2
            else
                if [ "$name" = cmake ]; then
                    target="linux-$host"
                    [ "$PLATFORM" != Darwin ] || target=macos-universal
                    url="https://cmake.org/files/v3.22/cmake-3.22.6-$target.tar.gz"; version='^cmake version 3\.22\.6([[:space:]]|$)'
                else
                    url="https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-$host-arm-none-eabi.tar.xz"; version='13\.3\.[rR][eE][lL]1.*13\.3\.1([^0-9.]|$)'
                fi
                if p=$(install_archive "$name" "$url" "$version"); then add_path "$p"; if remove_old_tool "$name" "$p"; then ok=1; fi; fi
            fi ;;
        STM32CubeMX)
            if install_cube; then ok=1; fi ;;
        *)
            if install_package "$name"; then
                hash -r
                if [ "$PLATFORM" = Darwin ]; then
                    p="$(brew --prefix "$name")/bin/$name"
                else p="/usr/bin/$name"; fi
                if [ -n "$p" ] && "$p" --version; then add_path "$p"; if remove_old_tool "$name" "$p"; then ok=1; fi; fi
            fi ;;
    esac
    if [ "$ok" -eq 1 ]; then [ -n "${STATUS[$i]}" ] || STATUS[$i]=INSTALLED
    else STATUS[$i]='FAILED (see output above; rerun to retry)'; FAILED=1; fi
done
save_path || { echo 'Failed to persist PATH.' >&2; FAILED=1; }
banner Summary
for i in 0 1 2 3 4 5; do
    printf -v summary_row '%-20s %s' "${NAMES[$i]}" "${STATUS[$i]}"
    ui_status "$summary_row"
done
echo 'Open a new terminal. Staging downloads are retained for diagnosis.'
exit "$FAILED"
