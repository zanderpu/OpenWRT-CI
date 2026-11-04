#!/bin/bash
# ============================================================
# OpenWRT-AX1800Pro 私有扩展脚本 (PRIVATE.sh)
# 由 Scripts/Packages.sh 在末尾 source 执行，工作目录为 OpenWrt 源码根目录
# 用途：在 OpenWRT-CI 基础上实现 wrt 的部分定制，不修改上游脚本本体
# ============================================================

echo "=================================================="
echo " OpenWRT-AX1800Pro 私有扩展 (PRIVATE.sh) 开始执行"
echo "=================================================="

# 自定义构建者标记（LuCI 状态页显示的构建人名）
# 覆盖 WRT-CORE.yml 里写死的 WRT_MARK=${GITHUB_REPOSITORY%%/*}
# 仅 CI 环境（$GITHUB_ENV 存在）生效；本地编译由 build.sh 的 export WRT_MARK 控制
if [ -n "$GITHUB_ENV" ]; then
  echo "WRT_MARK=Puter" >> "$GITHUB_ENV"
fi

# 流量监控
UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main"
UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main"

# 用户独有包（上游 owci 未包含，外置在此，同步上游零冲突）
UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
UPDATE_PACKAGE "homeproxy" "VIKINGYFY/homeproxy" "main"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"


# ============================================================
# 直接在 mac80211.uc 生成脚本里实现 2.4G/5G 分频命名
# ------------------------------------------------------------
# 原理：mac80211.uc 是 ImmortalWrt 的无线配置生成脚本，按 radio 循环且每个 radio
#       的 band_name('2g'/'5g'/'6g') 在生成 ssid 时已可用。原脚本写死单一名字，
#       改成按 band_name 三元判断即可分频。
# 关键：mac80211.uc 只在 /etc/config/wireless 不存在时生成（首装），
#       升级(syupgrade)时该文件已被保留 -> 不再重跑 -> 不会覆盖用户设置，天然升级安全。
# 注意冲突：Settings.sh 对 mac80211.uc 有统一改名 sed（s/ssid='.*'/ssid='$WRT_SSID'/g），
#       且 Settings.sh 跑在 PRIVATE.sh 之后，会覆盖上面的分频。故需要把Setttings.sh中的方法注释。
# ============================================================
MAC80211_UC="$GITHUB_WORKSPACE/wrt/package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -n "$MAC80211_UC" ] && [ -f "$MAC80211_UC" ]; then
  # ssid 行：按 band_name 三选一（ucode 嵌套三元，2G=基础名 / 5G=基础名_5G / 6G=基础名_6G）
  sed -i "s|^set \${si}\.ssid='.*'|set \${si}.ssid='\${ band_name == \"2g\" ? \"$WRT_SSID\" : (band_name == \"5g\" ? \"${WRT_SSID}_5G\" : \"${WRT_SSID}_6G\") }'|" "$MAC80211_UC"
  # key 行：三频段统一同一密码
  sed -i "s|^set \${si}\.key='.*'|set \${si}.key='$WRT_WORD'|" "$MAC80211_UC"
  echo ">>> 已修改 mac80211.uc 实现 2.4G/5G/6G 分频: $MAC80211_UC"
else
  echo "!!! 未找到 mac80211.uc（find 路径 */network/config/wifi-scripts/files/lib/wifi/mac80211.uc），跳过分频 patch"
fi


#设置wifi结束