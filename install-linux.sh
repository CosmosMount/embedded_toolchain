#!/usr/bin/env bash
# Standalone, Bash 3.2+. This file never needs to be sourced.
set -u
set -o pipefail
PLATFORM=Linux
ROOT="${HOME}/.local/opt/embedded_toolchain"
DEEP=0
SCAN_ONLY=0
NO_PAUSE=0
CUBE_INSTALLER=''
EXTRA_ROOTS=()
NAMES=(cmake git arm-none-eabi-gcc openocd STM32CubeMX ninja)
FOUND=()
STATUS=()
PATH_DIRS=()
FAILED=0
usage() {
    cat <<'EOF'
Options:
  --install-dir DIR     Portable tool destination (absolute path)
  --search-root DIR     Additional scan directory (repeatable)
  --deep-scan           Scan accessible local filesystem, excluding virtual FS
  --scan-only           Read-only discovery; no downloads or file changes
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
    if [ "${BASH_SUBSHELL:-0}" -eq 0 ] && [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
        printf '\nFinished. Press Enter to exit (output will remain in terminal history). '
        IFS= read -r _finish_reply || true
    fi
    exit "$code"
}
trap finish EXIT
[ "$(uname -s)" = "$PLATFORM" ] || { printf 'Wrong platform: expected %s\n' "$PLATFORM" >&2; exit 2; }
case "$ROOT" in /*) ;; *) echo 'Installation directory must be absolute.' >&2; exit 2 ;; esac
C=''; Y=''; G=''; RESET=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    # Change foreground only; preserve the terminal background and other styles.
    C=$'\033[36m'; Y=$'\033[33m'; G=$'\033[32m'; RESET=$'\033[39m'
fi
banner() { printf '\n%s+------------------------------------------------------------+\n  %s\n+------------------------------------------------------------+%s\n' "$C" "$1" "$RESET"; }
ask() { printf '%s ' "$1"; IFS= read -r REPLY || REPLY=''; }
scan() {
    local i p base root
    local roots=("$ROOT" /usr/local /opt "$HOME/.local" "$HOME/ST" "$HOME/Applications" /Applications)
    roots+=(${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"})
    for i in 0 1 2 3 4 5; do
        FOUND[$i]=''
        p=$(type -P "${NAMES[$i]}" 2>/dev/null || true)
        if [ "$PLATFORM" = Darwin ] && [ "$p" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then p=''; fi
        [ -z "$p" ] || FOUND[$i]=$p
    done
    [ "$DEEP" -eq 0 ] || roots=(/)
    printf 'Scanning accessible directories (permission errors are skipped)...\n'
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        printf '  %s\n' "$root"
        while IFS= read -r -d '' p; do
            if [ "$PLATFORM" = Darwin ] && [ "$p" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
            base=${p##*/}
            for i in 0 1 2 3 4 5; do
                if [ "$base" = "${NAMES[$i]}" ] && [ -z "${FOUND[$i]}" ] && [ -x "$p" ]; then FOUND[$i]=$p; fi
            done
        done < <(find "$root" \( -name '.staging.*' -o -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /Volumes -o -path /mnt -o -path /media \) -prune -o \
            \( -type f -o -type l \) \( -name cmake -o -name git -o -name arm-none-eabi-gcc -o -name openocd -o -name STM32CubeMX -o -name ninja \) -print0 2>/dev/null)
    done
}
plan() {
    local i
    banner 'Embedded toolchain | installation plan'
    for i in 0 1 2 3 4 5; do
        if [ -n "${FOUND[$i]}" ]; then printf '%s[FOUND / SKIP] %-20s %s%s\n' "$G" "${NAMES[$i]}" "${FOUND[$i]}" "$RESET"
        else printf '%s[MISSING]      %s%s\n' "$Y" "${NAMES[$i]}" "$RESET"; fi
    done
    printf 'Targets: CMake 3.22.6 | Arm 13.3.rel1 | CubeMX 6.18.0 (optional)\n'
    printf 'Portable tools: %s\nGit/Ninja/OpenOCD: system package manager default location\n' "$ROOT"
}
add_path() {
    local dir=${1%/*} old
    for old in ${PATH_DIRS[@]+"${PATH_DIRS[@]}"}; do [ "$old" != "$dir" ] || return 0; done
    PATH_DIRS+=("$dir")
    case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
}
download() {
    printf 'Download: %s\n' "$1" >&2
    curl --fail --location --retry 3 --connect-timeout 30 --max-time 1800 --proto '=https' --proto-redir '=https' "$1" -o "$2" >&2
}
install_archive() (
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
    relative=${exe#"$work/payload"}
    dest="$ROOT/$name-${work##*.}"
    [ ! -e "$dest" ] || exit 1
    mv "$work/payload" "$dest" || exit 1
    printf '%s\n' "$dest$relative"
)
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else echo 'sudo is required for system package installation.' >&2; return 1; fi
}
install_package() {
    local name=$1 package=$1
    if [ "$PLATFORM" = Darwin ]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo 'Homebrew is required for Git/Ninja/OpenOCD: https://brew.sh . Install it, then rerun.' >&2
            return 1
        fi
        brew install "$package" || return 1
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        [ "$name" != ninja ] || package=ninja-build
        as_root apt-get update && as_root apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        [ "$name" != ninja ] || package=ninja-build
        as_root dnf install -y "$package"
    elif command -v pacman >/dev/null 2>&1; then
        # Full upgrade avoids unsupported Arch partial upgrades.
        as_root pacman -Syu --needed "$package"
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper install -y "$package"
    elif command -v apk >/dev/null 2>&1; then
        as_root apk add "$package"
    else echo 'Unsupported package manager; install the missing package manually.' >&2; return 1; fi
}
install_cube() {
    local p
    if [ -z "$CUBE_INSTALLER" ]; then
        echo 'Download/extract CubeMX 6.18.0: https://www.st.com/en/development-tools/stm32cubemx.html'
        ask 'Path to the extracted official installer (empty to skip):'
        CUBE_INSTALLER=$REPLY
    fi
    if [ -z "$CUBE_INSTALLER" ]; then STATUS[4]='SKIPPED (optional ST login/manual download)'; return 0; fi
    [ -e "$CUBE_INSTALLER" ] || { echo 'Installer does not exist.' >&2; return 1; }
    ask 'Confirm this is the official CubeMX 6.18.0 installer: type 6.18.0:'
    if [ "$REPLY" != 6.18.0 ]; then STATUS[4]='SKIPPED'; return 0; fi
    if [ "$PLATFORM" = Darwin ]; then
        open -W "$CUBE_INSTALLER" || return 1
    else
        [ -x "$CUBE_INSTALLER" ] || { echo 'Installer needs execute permission; chmod +x it explicitly, then rerun.' >&2; return 1; }
        "$CUBE_INSTALLER" || return 1
    fi
    ask 'Full path to installed STM32CubeMX executable (empty to leave unverified):'
    p=$REPLY
    if [ -z "$p" ]; then STATUS[4]='UNVERIFIED (installer finished; PATH not configured)'; return 0; fi
    [ -x "$p" ] && [ "${p##*/}" = STM32CubeMX ] || { echo 'Expected executable STM32CubeMX.' >&2; return 1; }
    add_path "$p"
    STATUS[4]='INSTALLED (version confirmed by user)'
}
save_path() {
    local envfile="$ROOT/env.sh" tmp profile line dir
    tmp=$(mktemp "$ROOT/.env.XXXXXXXX") || return 1
    # Preserve previously managed directories when this run finds another copy.
    [ ! -f "$envfile" ] || cat "$envfile" >> "$tmp" || return 1
    for dir in ${PATH_DIRS[@]+"${PATH_DIRS[@]}"}; do
        printf -v line 'case ":$PATH:" in *:%q:*) ;; *) export PATH=%q:"$PATH" ;; esac' "$dir" "$dir"
        grep -Fqx "$line" "$tmp" || printf '%s\n' "$line" >> "$tmp" || return 1
    done
    mv "$tmp" "$envfile" || return 1
    printf -v line '[ ! -f %q ] || . %q # embedded-toolchain' "$envfile" "$envfile"
    # Bash login reads only the first existing login file; update that file too.
    local login="$HOME/.profile"
    if [ -f "$HOME/.bash_profile" ]; then login="$HOME/.bash_profile"
    elif [ -f "$HOME/.bash_login" ]; then login="$HOME/.bash_login"; fi
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
ask 'I = install missing tools + repair PATH, R = change destination, Q = quit:'
if [ "$REPLY" = R ] || [ "$REPLY" = r ]; then
    ask 'Absolute installation directory:'; ROOT=$REPLY
    case "$ROOT" in /*) ;; *) echo 'Absolute directory required.'; exit 2 ;; esac
    scan; plan
    ask 'Enter I to continue, anything else to quit:'
fi
case "$REPLY" in I|i) ;; *) exit 0 ;; esac
while ! mkdir -p "$ROOT" || [ ! -w "$ROOT" ]; do
    ask 'Destination is not writable. Enter another absolute directory (empty to cancel):'
    ROOT=$REPLY
    case "$ROOT" in /*) scan ;; *) exit 1 ;; esac
done
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
        STATUS[$i]='EXISTING (installation skipped)'
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
                    url="https://cmake.org/files/v3.22/cmake-3.22.6-$target.tar.gz"; version='3\.22\.6'
                else
                    url="https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-$host-arm-none-eabi.tar.xz"; version='13\.3\.1'
                fi
                if p=$(install_archive "$name" "$url" "$version"); then add_path "$p"; ok=1; fi
            fi ;;
        STM32CubeMX)
            if install_cube; then ok=1; fi ;;
        *)
            if install_package "$name"; then
                hash -r
                p=$(type -P "$name" 2>/dev/null || true)
                if [ -n "$p" ] && "$p" --version; then add_path "$p"; ok=1; fi
            fi ;;
    esac
    if [ "$ok" -eq 1 ]; then [ -n "${STATUS[$i]}" ] || STATUS[$i]=INSTALLED
    else STATUS[$i]='FAILED (see output above; rerun to retry)'; FAILED=1; fi
done
save_path || { echo 'Failed to persist PATH.' >&2; FAILED=1; }
banner Summary
for i in 0 1 2 3 4 5; do printf '%-20s %s\n' "${NAMES[$i]}" "${STATUS[$i]}"; done
echo 'Open a new terminal. Staging downloads are retained for diagnosis.'
exit "$FAILED"
