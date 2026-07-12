#!/bin/bash
set -eo pipefail

# --- 核心改动：处理权限问题 ---
# 记录执行脚本的原始用户（非 root）
if [ -n "$SUDO_USER" ]; then
    ORIGINAL_USER="$SUDO_USER"
else
    ORIGINAL_USER=$(whoami)
fi

# 配置变量（可根据需要修改）
WRT_CONFIG="IPQ60XX-WIFI-YES"               # 编译配置，可选：MEDIATEK/ROCKCHIP/X86/IPQ系列等
WRT_THEME="argon"                  # 默认主题
WRT_NAME="AX1800Pro"                     # 主机名
WRT_SSID="JDC_AX1800Pro"                     # WIFI名称
WRT_WORD="12345678"                 # WIFI密码
WRT_IP="192.168.1.1"               # 管理IP地址
WRT_PW="无"                         # 登录密码（提示用）
WRT_REPO="https://github.com/VIKINGYFY/immortalwrt.git"  # 源码地址
WRT_BRANCH="main"                   # 源码分支
WRT_SOURCE="VIKINGYFY/immortalwrt"  # 源码名称
WRT_PACKAGE=""                      # 额外插件（多行用\n分隔）
WRT_TEST="false"                    # 是否仅生成配置文件

# 初始化环境变量
export WRT_DATE=$(TZ=UTC-8 date +"%y.%m.%d-%H.%M.%S")
export WRT_MARK="Puter"
export WRT_INFO=$(echo "$WRT_SOURCE" | cut -d '/' -f 1)
export WRT_WORKSPACE="$PWD"
export WRT_PATH=$WRT_WORKSPACE/wrt
export GITHUB_WORKSPACE="$WRT_WORKSPACE"

# 创建工作目录
mkdir -p "$WRT_PATH"
cd "$WRT_WORKSPACE" || exit 1
# 初始化编译环境
init_env() {
    echo "=== 初始化编译环境 ==="
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用root权限运行脚本"
        exit 1
    fi

    # 安装依赖
    apt update -y
    apt full-upgrade -y
    apt install -y build-essential clang flex bison g++ gawk \
        gcc-multilib gettext git libncurses5-dev libssl-dev \
        rsync unzip zlib1g-dev file wget \
        dos2unix python3-netifaces libfuse-dev

    # 安装ImmortalWRT环境脚本
    bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)
    
    # --- 核心改动：确保工作目录归普通用户所有 ---
    echo "=== [ROOT] 调整工作目录权限 ==="
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$WRT_WORKSPACE"
}

# 克隆源码
clone_source() {
    echo "=== [USER] 克隆源码 ==="
    sudo -u "$ORIGINAL_USER" bash -c "
        if [ -d \"$WRT_PATH/.git\" ]; then
            cd $WRT_PATH && git pull
        else
            git clone --depth=1 --single-branch --branch \"$WRT_BRANCH\" \"$WRT_REPO\" $WRT_PATH/
        fi

        # 记录提交哈希
        export WRT_HASH=\$(cd $WRT_PATH && git log -1 --pretty=format:'%h')
        echo \"export WRT_HASH=\$WRT_HASH\" > .env_hash
    "
    # 从文件中读取环境变量，因为子shell无法直接修改父shell环境
    source .env_hash
    rm .env_hash
    
    # 移除国内镜像源
    # PROJECT_MIRRORS_FILE="./immortalwrt/scripts/projectsmirrors.json"
    # if [ -f "$PROJECT_MIRRORS_FILE" ]; then
    #    sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$PROJECT_MIRRORS_FILE"
    # fi
}

# 处理脚本文件
prepare_scripts() {
    echo "=== 准备脚本文件 ==="
    find ./Scripts -type f -name "*.sh" -exec dos2unix {} \; -exec chmod +x {} \;
}

# 更新 feeds 和安装包
update_feeds() {
    echo "=== 更新Feeds ==="
    cd "$WRT_PATH" || exit 1
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

# 自定义软件包
custom_packages() {
    echo "=== 处理自定义软件包 ==="
    cd "$WRT_PATH/package" || exit 1
    source "$WRT_WORKSPACE/Scripts/Packages.sh"
    source "$WRT_WORKSPACE/Scripts/Handles.sh"
}

# 应用自定义设置
apply_settings() {
    echo "=== 应用自定义设置 ==="
    cd "$WRT_PATH" || exit 1

    # 合并配置文件
    if [[ "${WRT_CONFIG,,}" == *"test"* ]]; then
        cat "$WRT_WORKSPACE/Config/$WRT_CONFIG.txt" >> .config
    else
        cat "$WRT_WORKSPACE/Config/$WRT_CONFIG.txt" \
            "$WRT_WORKSPACE/Config/GENERAL.txt" >> .config
    fi

    # 执行设置脚本
    source "$WRT_WORKSPACE/Scripts/Settings.sh"

    # 生成配置并清理
    make defconfig -j"$(nproc)"
    make clean -j"$(nproc)"
}

# 下载依赖包
download_packages() {
    if [ "$WRT_TEST" = "true" ]; then
        return
    fi
    echo "=== 下载依赖包 ==="
    cd "$WRT_PATH" || exit 1
    make download -j"$(nproc)"
}


# 显示编译信息
show_info() {
    echo "=== 编译信息汇总 ==="
    echo "源码: $WRT_REPO"
    echo "分支: $WRT_BRANCH"
    echo "配置: $WRT_CONFIG"
    echo "平台: $WRT_TARGET"
    echo "登录地址: $WRT_IP"
    echo "登录密码: $WRT_PW"
    echo "WIFI名称: $WRT_SSID"
    echo "WIFI密码: $WRT_WORD"
    echo "内核版本: ${WRT_KVER:-未编译}"
}

# 编译固件
compile_firmware() {
    if [ "$WRT_TEST" = "true" ]; then
        return
    fi
    echo "=== 开始编译固件 ==="
    cd "$WRT_PATH" || exit 1
    if ! make -j"$(nproc)"; then
        echo "编译失败，尝试单线程编译并显示详细信息"
        make -j1 V=s
    fi
    show_info
}


# --- 核心改动：参数解析与执行逻辑 ---
usage() {
    echo "用法: $0 [命令]"
    echo "命令列表:"
    echo "  all           执行完整编译流程 (默认)"
    echo "  env           初始化环境"
    echo "  clone         克隆/更新源码"
    echo "  scripts       准备脚本文件"
    echo "  feeds         更新Feeds"
    echo "  packages      处理自定义软件包"
    echo "  settings      应用自定义设置"
    echo "  download      下载依赖包"
    echo "  compile       编译固件"
    echo "  help          显示此帮助信息"
    exit 1
}


# 主执行流程
main() {
    init_env
    clone_source
    prepare_scripts
    update_feeds
    custom_packages
    apply_settings
    download_packages
    compile_firmware
    package_output
    show_info
    echo "=== 所有操作完成 ==="
}


# 根据参数执行对应的函数
case "$1" in
    all)
        main
        ;;
    env)
        init_env
        ;;
    clone)
        clone_source
        ;;
    scripts)
        prepare_scripts
        ;;
    feeds)
        update_feeds
        ;;
    packages)
        custom_packages
        ;;
    settings)
        apply_settings
        ;;
    download)
        download_packages
        ;;
    compile)
        compile_firmware
        ;;
    help|*)
        usage
        ;;
esac

