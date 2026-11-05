#!/bin/bash
# ============================================================================
# build.sh — 在任意 Linux 电脑上本地编译 OpenWRT-CI 固件
# ----------------------------------------------------------------------------
# 本脚本是 GitHub Actions 工作流 WRT-CORE.yml 的本地等价物，并按其 steps 拆成
# 可单独调用的方法；同时提供 3 阶段方案：
#     阶段1  env    (初始化环境：装依赖 + 计算变量 + 克隆源码 + 修正脚本)
#     阶段2  update (更新包：feeds + 定制包 + 生成配置 + 工具链 + 下载)
#     阶段3  build  (执行编译：make + 打包)
#
# 重要：OpenWrt 编译（以及 feeds/defconfig/download）严禁使用 root。
#   脚本会在需要时自动降权到「非 root 专用编译用户」执行编译相关步骤；
#   而安装系统依赖（apt）仍使用 root / sudo。
#
# 调用方式：
#   ./build.sh env    --config IPQ60XX-WIFI-YES      # 阶段1
#   ./build.sh update --config IPQ60XX-WIFI-YES      # 阶段2
#   ./build.sh build  --config IPQ60XX-WIFI-YES      # 阶段3
#   ./build.sh all    --config IPQ60XX-WIFI-YES      # 一气呵成（= env+update+build）
#   ./build.sh step <name> --config ...              # 单步执行（见下方步骤名）
#   ./build.sh --list                                # 列出可用配置
#
# 单步名称（step <name>）：
#   deps values clone scripts feeds packages config toolchain download compile package
#
# 所有参数均可用同名环境变量预设（命令行优先）：
#   WRT_CONFIG WRT_THEME WRT_NAME WRT_SSID WRT_WORD WRT_IP WRT_PW
#   WRT_REPO WRT_BRANCH WRT_SOURCE WRT_PACKAGE WRT_TEST
# ============================================================================

set -euo pipefail

# ----------------------------- 基础路径 ---------------------------------------
# GITHUB_WORKSPACE 在 CI 中由运行环境注入，本地必须手动指定为项目根目录，
# 否则 Scripts/ 与 .github/scripts/ 下的脚本会因为找不到路径而失败。
export GITHUB_WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$GITHUB_WORKSPACE/build.sh"
cd "$GITHUB_WORKSPACE"

# 源码树目录（PRIVATE.sh 假设它位于 $GITHUB_WORKSPACE/wrt，故默认保持一致）
WRT_DIR="${WRT_DIR:-$GITHUB_WORKSPACE/wrt}"
# ccache 缓存目录（放在源码树之外，便于反复重编时复用）
CCACHE_DIR="${CCACHE_DIR:-$GITHUB_WORKSPACE/.ccache}"
# 产物输出目录
OUTPUT_DIR="${OUTPUT_DIR:-$GITHUB_WORKSPACE/upload}"
# 非 root 编译用户（root 下自动创建/使用；非 root 下即为当前用户）
WRT_USER="${WRT_USER:-}"

# ----------------------------- 默认参数 ---------------------------------------
WRT_CONFIG="${WRT_CONFIG:-IPQ60XX-WIFI-YES}" # 默认配置（可省略 --config）
WRT_THEME="${WRT_THEME:-argon}"
WRT_NAME="${WRT_NAME:-AX1800Pro}"
WRT_SSID="${WRT_SSID:-JDC_AX1800Pro}"
WRT_WORD="${WRT_WORD:-12345678}"
WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_PW="${WRT_PW:-无}"
WRT_SOURCE="${WRT_SOURCE:-VIKINGYFY/immortalwrt}"
WRT_BRANCH="${WRT_BRANCH:-owrt}"
WRT_REPO="${WRT_REPO:-https://github.com/${WRT_SOURCE}.git}"
WRT_PACKAGE="${WRT_PACKAGE:-}"
WRT_TEST="${WRT_TEST:-false}"

# 行为开关（可由命令行覆盖）
INSTALL_DEPS="${INSTALL_DEPS:-true}"   # 是否用包管理器安装编译依赖
TOOLCHAIN_PREP="${TOOLCHAIN_PREP:-auto}" # auto|yes|no：准备 Go/LLVM/Rust 外部工具链
FRESH="${FRESH:-true}"                  # 是否每次重新克隆源码树
RESUME="${RESUME:-false}"               # 复用已准备好的树，跳过 clone
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
GH_MIRROR="${GH_MIRROR:-}"             # 可选：GitHub 加速镜像前缀，如 https://mirror.ghproxy.com
NO_CN_MIRROR="${NO_CN_MIRROR:-false}"   # 是否移除国内下载源

# 把会影响行为的变量导出，确保降权后的子进程也能继承
export WRT_DIR CCACHE_DIR OUTPUT_DIR WRT_USER \
       WRT_THEME WRT_NAME WRT_SSID WRT_WORD WRT_IP WRT_PW \
       WRT_REPO WRT_BRANCH WRT_SOURCE WRT_PACKAGE WRT_TEST \
       INSTALL_DEPS TOOLCHAIN_PREP FRESH RESUME JOBS GH_MIRROR NO_CN_MIRROR

# ----------------------------- 颜色与日志 -------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''
fi
log()  { echo "${C_BLU}[build]${C_RST} $*"; }
ok()   { echo "${C_GRN}[ ok ]${C_RST} $*"; }
warn() { echo "${C_YEL}[warn]${C_RST} $*"; }
die()  { echo "${C_RED}[fail]${C_RST} $*" >&2; exit 1; }
phase_banner() { echo; echo "${C_BLU}========== $* ==========${C_RST}"; }

# 捕获中断，给出提示（尽早注册，覆盖后续所有步骤）
trap 'die "被用户中断或发生致命错误，源码树保留在: $WRT_DIR"' INT TERM

# ----------------------------- 帮助信息 ---------------------------------------
usage() {
  cat <<EOF
用法: ./build.sh <子命令> [选项]

子命令:
  env                    阶段1：初始化环境（装依赖 + 计算变量 + 克隆源码 + 修正脚本）
  update                 阶段2：更新包（feeds + 定制包 + 生成配置 + 工具链 + 下载）
  build                  阶段3：执行编译（make + 打包固件）
  all                    执行 env + update + build（默认，若未给子命令）
  step <name>            执行单个步骤（见下方）
  list / --list          列出可用配置
  help / --help          显示本帮助

单步名称 (step <name>):
  deps        安装系统编译依赖（需要 root / sudo）
  values      计算并展示派生变量（TARGET/SUBTARGET/WIFI 等）
  clone       克隆 / 更新源码树（自动降权到非 root 用户）
  scripts     修正项目脚本格式 (CRLF->LF) 并赋可执行权限
  feeds       更新并安装 feeds
  packages    应用定制软件包（Packages.sh / Handles.sh / prepare-i2c-tools.sh）
  config      拼接配置 + Settings.sh + 生成 .config（含 --test 仅生成配置）
  toolchain   准备 Rust 外部工具链（需要 rustup）
  download    下载软件包源码（make download）
  compile     编译固件（make，严禁 root，自动降权）
  package     打包固件到输出目录

必填（env/update/build/all/step 都需要，可省略，默认配置如下）:
  --config <NAME>      配置名（Config/ 下不带 .txt 后缀，如 IPQ60XX-WIFI-YES）
                         省略时默认使用: IPQ60XX-WIFI-YES

可选（也可用同名环境变量预设）:
  --theme <NAME>       默认主题        (默认: $WRT_THEME)
  --name <NAME>        主机名          (默认: $WRT_NAME)
  --ssid <NAME>        WIFI 名称       (默认: $WRT_SSID)
  --word <PASS>        WIFI 密码       (默认: $WRT_WORD)
  --ip <ADDR>          管理 IP         (默认: $WRT_IP)
  --pw <PASS>          登录密码提示    (默认: $WRT_PW，仅作提示)
  --source <OWNER/REPO> 源码仓库       (默认: $WRT_SOURCE)
  --branch <NAME>      源码分支        (默认: $WRT_BRANCH)
  --repo <URL>         源码完整地址    (默认: $WRT_REPO)
  --package <STR>      追加插件配置，多行用换行隔开
  --test               仅生成 .config，不编译固件
  --user <NAME>        root 下使用的非 root 编译用户（默认: \$SUDO_USER 或 openwrt）

行为控制:
  --no-deps            跳过安装系统依赖
  --toolchain <auto|yes|no>  准备外部 Go/LLVM/Rust 工具链 (默认: auto)
  --fresh / --no-fresh 是否每次重新克隆源码树 (默认: --fresh)
  --resume             复用已准备好的源码树，跳过 clone
  --jobs <N>           并行编译任务数 (默认: $(nproc 2>/dev/null || echo 1))
  --wrt-dir <PATH>     源码树目录 (默认: $WRT_DIR)
  --ccache-dir <PATH>  ccache 缓存目录 (默认: $CCACHE_DIR)
  --gh-mirror <URL>    GitHub 加速镜像前缀（用于 clone/下载）
  --no-cn-mirror       移除国内下载源（CI 默认行为；本地默认保留以加速）

示例:
  ./build.sh env    --config IPQ60XX-WIFI-YES
  ./build.sh update --config IPQ60XX-WIFI-YES
  ./build.sh build  --config IPQ60XX-WIFI-YES
  ./build.sh all    --config IPQ60XX-WIFI-YES
  ./build.sh step config --config IPQ60XX-WIFI-YES --test
EOF
}

# ----------------------------- 列出配置 ---------------------------------------
list_configs() {
  echo "可用配置 (Config/ 目录，GENERAL/PRIVATE 为公共/私有附加配置，非编译目标):"
  local found=0
  for f in "$GITHUB_WORKSPACE"/Config/*.txt; do
    [ -e "$f" ] || continue
    local base; base="$(basename "$f" .txt)"
    case "$base" in GENERAL|PRIVATE) continue;; esac
    if [ "$base" = "$WRT_CONFIG" ]; then
      printf "  - %s  (默认)\n" "$base"
    else
      printf "  - %s\n" "$base"
    fi
    found=1
  done
  [ "$found" -eq 0 ] && echo "  (未找到任何配置)"
  return 0
}

# ----------------------------- 子命令解析 -------------------------------------
SUBCMD=""
case "${1:-}" in
  env|update|build|all|step|list|help) SUBCMD="$1"; shift;;
  --help|-h) usage; exit 0;;
  --list) list_configs; exit 0;;
  "") usage; exit 1;;
  --*) SUBCMD="all";;   # 直接给选项（不带子命令）视为完整编译
  *) die "未知子命令: $1 （可用: env / update / build / all / step / list / help）";;
esac
STEP=""
if [ "$SUBCMD" = "step" ]; then
  [ $# -ge 1 ] || die "step 需要指定步骤名（deps/values/clone/scripts/feeds/packages/config/toolchain/download/compile/package）"
  STEP="$1"; shift
fi

# ----------------------------- 选项解析 ---------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --config)    WRT_CONFIG="$2"; shift 2;;
    --theme)     WRT_THEME="$2"; shift 2;;
    --name)      WRT_NAME="$2"; shift 2;;
    --ssid)      WRT_SSID="$2"; shift 2;;
    --word)      WRT_WORD="$2"; shift 2;;
    --ip)        WRT_IP="$2"; shift 2;;
    --pw)        WRT_PW="$2"; shift 2;;
    --source)    WRT_SOURCE="$2"; shift 2;;
    --branch)    WRT_BRANCH="$2"; shift 2;;
    --repo)      WRT_REPO="$2"; shift 2;;
    --package)   WRT_PACKAGE="$2"; shift 2;;
    --test)      WRT_TEST=true; shift;;
    --user)      WRT_USER="$2"; shift 2;;
    --no-deps)   INSTALL_DEPS=false; shift;;
    --toolchain) TOOLCHAIN_PREP="$2"; shift 2;;
    --fresh)     FRESH=true; shift;;
    --no-fresh)  FRESH=false; shift;;
    --resume)    RESUME=true; shift;;
    --jobs)      JOBS="$2"; shift 2;;
    --wrt-dir)   WRT_DIR="$2"; shift 2;;
    --ccache-dir) CCACHE_DIR="$2"; shift 2;;
    --gh-mirror) GH_MIRROR="$2"; shift 2;;
    --no-cn-mirror) NO_CN_MIRROR=true; shift;;
    --list)      list_configs; exit 0;;
    --help|-h)   usage; exit 0;;
    *) die "未知参数: $1 （用 --help 查看用法）";;
  esac
done
export WRT_CONFIG WRT_THEME WRT_NAME WRT_SSID WRT_WORD WRT_IP WRT_PW \
       WRT_REPO WRT_BRANCH WRT_SOURCE WRT_PACKAGE WRT_TEST WRT_USER

# 若用户只给了 --repo 没给 --source，尝试从 URL 反推 source
if [ -z "${WRT_SOURCE:-}" ] && [[ "$WRT_REPO" == https://github.com/*.git ]]; then
  WRT_SOURCE="${WRT_REPO#https://github.com/}"; WRT_SOURCE="${WRT_SOURCE%.git}"
fi

# ----------------------------- 配置与变量 -------------------------------------
require_config() {
  CONFIG_FILE="$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt"
  [ -f "$CONFIG_FILE" ] || die "配置文件不存在: $CONFIG_FILE （用 --list 查看；默认配置为 IPQ60XX-WIFI-YES）"
}
derive_vars() {
  WRT_INFO="${WRT_SOURCE%%/*}"
  WRT_TARGET="$(grep -m1 -oP '^CONFIG_TARGET_\K[^=_]+(?==y)' "$CONFIG_FILE")"
  WRT_SUBTARGET="$(grep -m1 -oP "^CONFIG_TARGET_${WRT_TARGET}_\K[^=_]+(?==y)" "$CONFIG_FILE")"
  WRT_WIFI="$(grep -oE 'WIFI-(YES|NO)$' <<<"${WRT_CONFIG^^}" || true)"; WRT_WIFI="${WRT_WIFI:-none}"
  WRT_MARK="${WRT_MARK:-Puter}"
  WRT_DATE="$(TZ=UTC-8 date +"%y.%m.%d-%H.%M.%S")"
  export WRT_INFO WRT_TARGET WRT_SUBTARGET WRT_WIFI WRT_MARK WRT_DATE
}
need_config() { require_config; derive_vars; }

# ----------------------------- 用户与降权 -------------------------------------
# 解析并准备好「非 root 编译用户」；root 下确保该用户存在且产物目录归其所有。
ensure_build_user() {
  if [ "$(id -u)" -ne 0 ]; then
    WRT_USER="$(id -un)"; export WRT_USER; return 0
  fi
  [ -n "$WRT_USER" ] || WRT_USER="${SUDO_USER:-openwrt}"
  if ! id -u "$WRT_USER" &>/dev/null; then
    log "创建编译专用非 root 用户: $WRT_USER"
    useradd -m -s /bin/bash "$WRT_USER" || die "无法创建用户 $WRT_USER（请手动创建或用 --user 指定已存在用户）"
  fi
  export WRT_USER
  # root 可对任意目录建/改属主；保证编译用户能写入产物目录与源码树
  mkdir -p "$WRT_DIR" "$CCACHE_DIR" "$OUTPUT_DIR" "$GITHUB_WORKSPACE/build-reports"
  chown -R "$WRT_USER:$WRT_USER" "$WRT_DIR" "$CCACHE_DIR" "$OUTPUT_DIR" "$GITHUB_WORKSPACE/build-reports" 2>/dev/null || true
}

# 若当前是 root，则把「编译相关步骤」交给非 root 编译用户执行（OpenWrt 禁止 root 编译）。
# 通过导出环境文件 + runuser/su 重新进入本脚本的同名步骤；父进程仅等待子进程返回。
drop_if_root() {
  local step="$1"
  if [ "$(id -u)" -eq 0 ]; then
    ensure_build_user
    local ef; ef="$(mktemp)"
    export -p > "$ef"          # 导出当前所有环境变量，供子进程继承
    chmod 644 "$ef"
    local cmd="source '$ef'; rm -f '$ef'; bash '$SCRIPT_PATH' step '$step'"
    log "以非 root 用户 [$WRT_USER] 执行步骤: $step （OpenWrt 不允许 root 编译）"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$WRT_USER" -- bash -c "$cmd" || die "步骤 $step 以 $WRT_USER 执行失败"
    else
      su -m "$WRT_USER" -c "bash -c \"$cmd\"" || die "步骤 $step 以 $WRT_USER 执行失败"
    fi
    return 0                  # 父进程（root）到此返回，由子进程完成实际工作
  fi
  return 1                    # 非 root：调用方继续执行实际逻辑
}

# ----------------------------- GitHub 镜像 ------------------------------------
apply_gh_mirror() {
  [ -n "$GH_MIRROR" ] || return 0
  # root 写系统级（对所有用户生效），否则写当前用户全局配置
  if [ "$(id -u)" -eq 0 ]; then
    git config --system "url.${GH_MIRROR}/https://github.com/.insteadOf" "https://github.com/" \
      && log "已启用系统级 GitHub 镜像前缀: $GH_MIRROR" \
      || warn "设置 GitHub 镜像失败，将直连 github.com"
  else
    git config --global "url.${GH_MIRROR}/https://github.com/.insteadOf" "https://github.com/" \
      && log "已启用 GitHub 镜像前缀: $GH_MIRROR" \
      || warn "设置 GitHub 镜像失败，将直连 github.com"
  fi
}

# ----------------------------- 步骤实现 ---------------------------------------
install_dependencies() {
  if [ "$INSTALL_DEPS" != "true" ]; then
    log "按 --no-deps 跳过系统依赖安装"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "未检测到 apt-get（非 Debian/Ubuntu？）。请手动安装以下依赖后加 --no-deps 运行："
    cat <<'EOF'
    bc bison build-essential bzip2 ca-certificates ccache clang cmake cpio curl
    device-tree-compiler dos2unix file flex g++-multilib gawk gcc-multilib genisoimage
    gettext git jq libbpf-dev libclang-dev libdw-dev libelf-dev libncurses-dev libssl-dev
    lld llvm ninja-build patch perl pkgconf python3 python3-cryptography python3-dev
    python3-packaging python3-pyelftools python3-setuptools qemu-utils rsync swig unzip
    wget xz-utils zlib1g-dev zstd
EOF
    return 0
  fi
  local SUDO=""
  [ "$(id -u)" -eq 0 ] || SUDO="sudo"
  log "更新软件包索引并安装编译依赖（需要 root 权限）..."
  $SUDO apt-get -yqq update
  $SUDO apt-get -yqq install --no-install-recommends \
    bc bison build-essential bzip2 ca-certificates ccache clang \
    cmake cpio curl device-tree-compiler dos2unix file flex \
    g++-multilib gawk gcc-multilib genisoimage gettext git jq \
    libbpf-dev libclang-dev libdw-dev libelf-dev libncurses-dev libssl-dev lld \
    llvm ninja-build patch perl pkgconf python3 python3-cryptography \
    python3-dev python3-packaging python3-pyelftools python3-setuptools qemu-utils rsync swig \
    unzip wget xz-utils zlib1g-dev zstd
  $SUDO timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true
  ok "依赖安装完成"
}

prepare_source() {
  if [ "$RESUME" = "true" ]; then
    [ -d "$WRT_DIR" ] || die "--resume 需要已存在的源码树: $WRT_DIR"
    cd "$WRT_DIR"
    return 0
  fi
  if [ -d "$WRT_DIR" ] && [ "$FRESH" = "true" ]; then
    log "删除旧源码树: $WRT_DIR"
    rm -rf "$WRT_DIR"
  fi
  if [ ! -d "$WRT_DIR" ]; then
    log "克隆源码: $WRT_REPO @ $WRT_BRANCH"
    git clone --depth=1 --single-branch --branch "$WRT_BRANCH" "$WRT_REPO" "$WRT_DIR"
  else
    log "源码树已存在，更新到 $WRT_BRANCH 最新提交"
    cd "$WRT_DIR"
    git fetch --depth=1 origin "$WRT_BRANCH"
    git reset --hard "origin/$WRT_BRANCH"
    git clean -fdx -e .ccache
    cd "$GITHUB_WORKSPACE"
  fi
  cd "$WRT_DIR"
  WRT_HASH="$(git rev-parse HEAD)"; export WRT_HASH
  log "源码 HEAD: $WRT_HASH"
  if [ "$NO_CN_MIRROR" = "true" ]; then
    local PMF="./scripts/projectsmirrors.json"
    [ -f "$PMF" ] && sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$PMF"
  fi
}

fix_scripts() {
  log "修正项目脚本格式 (CRLF -> LF) 并赋可执行权限"
  find "$GITHUB_WORKSPACE/Scripts" "$GITHUB_WORKSPACE/Config" "$GITHUB_WORKSPACE/.github/scripts" \
    -maxdepth 3 -type f \( -iname '*.sh' -o -iname '*.txt' \) 2>/dev/null \
    | while read -r f; do
        if command -v dos2unix >/dev/null 2>&1; then
          dos2unix -q "$f" 2>/dev/null || sed -i 's/\r$//' "$f"
        else
          sed -i 's/\r$//' "$f"
        fi
        chmod +x "$f"
      done
}

# Go/LLVM/BPF 外部工具链：必须在 .config 存在且 make defconfig 之前执行（与 CI 一致）
prepare_host_toolchain() {
  case "$TOOLCHAIN_PREP" in
    no)  log "按 --toolchain no 跳过外部 Go/LLVM 工具链准备"; return 0;;
    yes|auto) : ;;
  esac
  local can_go=0 can_llvm=0
  command -v go >/dev/null 2>&1 && can_go=1
  command -v llvm-config >/dev/null 2>&1 && can_llvm=1
  if [ "$can_go" -eq 1 ] && [ "$can_llvm" -eq 1 ]; then
    log "准备 Go/LLVM/BPF 外部工具链 (prepare-build-host.sh)"
    if ! bash "$GITHUB_WORKSPACE/.github/scripts/prepare-build-host.sh"; then
      [ "$TOOLCHAIN_PREP" = "yes" ] && die "prepare-build-host.sh 执行失败"
      warn "prepare-build-host.sh 失败，将使用 OpenWrt 自带工具链（更慢）"
    fi
  else
    [ "$TOOLCHAIN_PREP" = "yes" ] && die "缺少 go 或 llvm-config，无法准备外部工具链"
    warn "未检测到 go($can_go) / llvm-config($can_llvm)，跳过外部 Go/LLVM 工具链准备；"
    warn "OpenWrt 将从源码构建 Go/LLVM（编译更慢）。若想加速请安装 go 与 llvm。"
  fi
}

# Rust 工具链在 make defconfig 之后准备（CI 顺序），依赖 rustup
prepare_rust_toolchain() {
  [ "$TOOLCHAIN_PREP" != "no" ] || { log "按 --toolchain no 跳过 Rust 工具链准备"; return 0; }
  if command -v rustup >/dev/null 2>&1; then
    log "准备 Rust 工具链 (prepare-rust.sh)"
    if ! bash "$GITHUB_WORKSPACE/.github/scripts/prepare-rust.sh"; then
      [ "$TOOLCHAIN_PREP" = "yes" ] && die "prepare-rust.sh 执行失败"
      warn "prepare-rust.sh 失败，将使用 OpenWrt 自带 Rust（更慢）"
    fi
  else
    [ "$TOOLCHAIN_PREP" = "yes" ] && die "缺少 rustup，无法准备 Rust 工具链"
    warn "未检测到 rustup，跳过 Rust 工具链准备；OpenWrt 将从源码构建 Rust（更慢）。"
  fi
}

apply_config() {
  log "拼接配置文件"
  if [[ "${WRT_CONFIG,,}" == *"test"* ]]; then
    cat "$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt" >> .config
  else
    cat "$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt" "$GITHUB_WORKSPACE/Config/GENERAL.txt" >> .config
  fi
  log "应用定制脚本 Settings.sh"
  bash "$GITHUB_WORKSPACE/Scripts/Settings.sh"
  prepare_host_toolchain
  log "生成默认配置并清理 (make defconfig && make clean)"
  make defconfig -j"$JOBS" && make clean -j"$JOBS"
}

package_firmware() {
  log "打包固件"
  mkdir -p ./upload
  cp -f ./.config "./upload/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"
  WRT_KVER="$(find ./bin/targets/ -type f -name '*.manifest' -exec grep -oP '^kernel - \K[\d.]+' {} \; | head -n1)"
  WRT_LIST="$(find ./bin/targets/ -type f -name '*.manifest' -exec grep -oP '^luci-(app|theme)[^ ]*' {} \; | tr '\n' ' ')"
  find ./bin/targets/ -iregex '.*\(buildinfo\|json\|sha256sums\|packages\)$' -exec rm -rf {} + 2>/dev/null || true
  for FILE in $(find ./bin/targets/ -type f -iname "*$WRT_TARGET*" 2>/dev/null); do
    EXT="$(basename "$FILE" | cut -d '.' -f 2-)"
    NAME="$(basename "$FILE" | cut -d '.' -f 1 | grep -io "\($WRT_TARGET\).*")"
    [ -z "$NAME" ] && NAME="$(basename "$FILE" | cut -d '.' -f 1)"
    NEW_FILE="$NAME-$WRT_INFO-$WRT_BRANCH-$WRT_WIFI-$WRT_DATE.$EXT"
    mv -f "$FILE" "./upload/$NEW_FILE"
  done
  find ./bin/targets/ -type f -exec mv -f {} ./upload/ \; 2>/dev/null || true
  mkdir -p "$OUTPUT_DIR"
  cp -rf ./upload/* "$OUTPUT_DIR/" 2>/dev/null || true
  log "====== 编译产物 ======"
  log "内核版本: ${WRT_KVER:-未知}"
  log "插件列表: ${WRT_LIST:-无}"
  ok "固件已输出到: $OUTPUT_DIR"
  ls -lh "$OUTPUT_DIR" | sed 's/^/  /'
}

# ----------------------------- 各步骤入口（可单独调用） -----------------------
do_deps() {
  install_dependencies
}
do_values() {
  need_config
  log "派生变量 => TARGET=$WRT_TARGET | SUBTARGET=$WRT_SUBTARGET | WIFI=$WRT_WIFI | INFO=$WRT_INFO"
}
do_clone() {
  need_config
  apply_gh_mirror
  drop_if_root clone && return
  prepare_source
}
do_scripts() {
  fix_scripts
}
do_feeds() {
  need_config
  drop_if_root feeds && return
  cd "$WRT_DIR"
  log "更新 feeds"
  ./scripts/feeds update -a
  ./scripts/feeds install -a
}
do_packages() {
  need_config
  drop_if_root packages && return
  cd "$WRT_DIR"
  log "应用定制软件包 (Packages.sh / Handles.sh / prepare-i2c-tools.sh)"
  bash "$GITHUB_WORKSPACE/Scripts/Packages.sh"
  bash "$GITHUB_WORKSPACE/Scripts/Handles.sh"
  bash "$GITHUB_WORKSPACE/.github/scripts/prepare-i2c-tools.sh"
}
do_config() {
  need_config
  drop_if_root config && return
  cd "$WRT_DIR"
  apply_config
  if [ "$WRT_TEST" = "true" ]; then
    log "测试模式：保留最终 .config 并退出（不编译）"
    mkdir -p "$OUTPUT_DIR"
    cp -f ./.config "$OUTPUT_DIR/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"
    ok "配置已生成: $OUTPUT_DIR/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"
    exit 0
  fi
}
do_toolchain() {
  need_config
  drop_if_root toolchain && return
  cd "$WRT_DIR"
  prepare_rust_toolchain
}
do_download() {
  need_config
  drop_if_root download && return
  cd "$WRT_DIR"
  export CCACHE_DIR; mkdir -p "$CCACHE_DIR"
  command -v ccache >/dev/null 2>&1 && export CCACHE_BASEDIR="$WRT_DIR"
  log "下载软件包源码 (make download)"
  make download -j"$JOBS" || warn "部分下载失败，编译时可能报错"
}
do_compile() {
  need_config
  drop_if_root compile && return
  cd "$WRT_DIR"
  export CCACHE_DIR; mkdir -p "$CCACHE_DIR"
  command -v ccache >/dev/null 2>&1 && export CCACHE_BASEDIR="$WRT_DIR"
  log "开始编译 (make -j$JOBS)，失败将自动降级为单线程 V=s"
  mkdir -p "$GITHUB_WORKSPACE/build-reports"
  if ! make -j"$JOBS" BUILD_TIME_LOG="$GITHUB_WORKSPACE/build-reports/parallel.tsv"; then
    warn "并行编译失败，降级为单线程详细编译..."
    make -j1 V=s BUILD_TIME_LOG="$GITHUB_WORKSPACE/build-reports/serial.tsv" || die "编译失败，请查看上方日志"
  fi
  ok "编译完成"
}
do_package() {
  need_config
  drop_if_root package && return
  cd "$WRT_DIR"
  package_firmware
}

# ----------------------------- 三阶段方案 -------------------------------------
phase_env() {
  phase_banner "阶段1/3  初始化环境 (env)"
  do_deps
  do_values
  do_clone
  do_scripts
}
phase_update() {
  phase_banner "阶段2/3  更新包 (update)"
  do_feeds
  do_packages
  do_config
  do_toolchain
  do_download
}
phase_build() {
  phase_banner "阶段3/3  执行编译 (build)"
  do_compile
  do_package
}
run_all() {
  phase_env
  phase_update
  phase_build
}

# ----------------------------- 调度 -------------------------------------------
case "$SUBCMD" in
  all)    run_all;;
  env)    phase_env;;
  update) phase_update;;
  build)  phase_build;;
  step)
    case "$STEP" in
      deps)      do_deps;;
      values)    do_values;;
      clone)     do_clone;;
      scripts)   do_scripts;;
      feeds)     do_feeds;;
      packages)  do_packages;;
      config)    do_config;;
      toolchain) do_toolchain;;
      download)  do_download;;
      compile)   do_compile;;
      package)   do_package;;
      *) die "未知步骤: $STEP （可用: deps/values/clone/scripts/feeds/packages/config/toolchain/download/compile/package）";;
    esac
    ;;
  list)   list_configs;;
  help)   usage;;
esac
