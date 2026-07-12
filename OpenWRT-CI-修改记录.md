# OpenWRT-CI → OpenWRT-CI-AX1800Pro 差异记录

> 对比时间：2026-07-12（第三次更新）
> 基础版本：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)
> 修改版本：OpenWRT-CI-AX1800Pro（适配京东云 AX1800Pro / re-ss-01）

---

## 目录

- [一、文件结构差异](#一文件结构差异)
- [二、新增文件详解](#二新增文件详解)
- [三、修改文件详解](#三修改文件详解)
- [四、值差异汇总](#四值差异汇总)
- [五、设计意图总结](#五设计意图总结)
- [六、更新记录](#六更新记录)

---

## 一、文件结构差异

```
OpenWRT-CI/                          OpenWRT-CI-AX1800Pro/
├── .gitattributes                   ├── .gitattributes          (同)
├── .github/workflows/               ├── .github/workflows/
│   ├── Auto-Clean.yml               │   ├── Auto-Clean.yml      (改)
│   ├── Cache-Clean.yml              │   ├── Cache-Clean.yml     (改)
│   ├── MTK-ALL.yml                  │   ├── MTK-ALL.yml         (改)
│   ├── OWRT-ALL.yml                 │   ├── OWRT-ALL.yml        (改)
│   ├── QCA-ALL.yml                  │   ├── QCA-ALL.yml         (改)
│   ├── WRT-CORE.yml                 │   ├── WRT-CORE.yml        (同)
│   ├── WRT-TEST.yml                 │   ├── WRT-TEST.yml        (同)
│                                    │   ├── PRIVATE.yml         ★新增
│                                    ├── build.sh               ★新增
├── Config/                          ├── Config/
│   ├── GENERAL.txt                  │   ├── GENERAL.txt         (同)
│   ├── IPQ60XX-WIFI-NO.txt          │   ├── IPQ60XX-WIFI-NO.txt (同)
│   ├── IPQ60XX-WIFI-YES.txt        │   ├── IPQ60XX-WIFI-YES.txt(改)
│   ├── IPQ807X-WIFI-NO.txt          │   ├── IPQ807X-WIFI-NO.txt (同)
│   ├── IPQ807X-WIFI-YES.txt         │   ├── IPQ807X-WIFI-YES.txt(同)
│   ├── MEDIATEK-WIFI-NO.txt         │   ├── MEDIATEK-WIFI-NO.txt (同)
│   ├── MEDIATEK-WIFI-YES.txt        │   ├── MEDIATEK-WIFI-YES.txt(同)
│   ├── ROCKCHIP.txt                 │   ├── ROCKCHIP.txt        (同)
│   ├── TEST.txt                     │   ├── TEST.txt            (同)
│   ├── X86.txt                      │   ├── X86.txt             (同)
│                                    │   ├── PRIVATE.txt         ★新增
├── LICENSE                          ├── LICENSE                 (同)
├── README.md                        ├── README.md               (同)
├── Scripts/                         ├── Scripts/
│   ├── Handles.sh                   │   ├── Handles.sh          (改)
│   ├── Packages.sh                  │   ├── Packages.sh         (改)
│   ├── Settings.sh                  │   ├── Settings.sh         (改)
│                                    │   ├── PRIVATE.sh          ★新增
```

**图例：**(同)=内容相同、(改)=内容修改、★新增=全新文件

---

## 二、新增文件详解

### 1. `build.sh` — 本地编译脚本

**用途：** 在 GitHub Actions CI 之外，支持在本地 Linux 环境直接编译固件。

**关键特性：**

- **权限安全处理：** 记录 `SUDO_USER`，环境初始化完成后用 `chown` 将工作目录归还给普通用户，后续编译操作全部通过 `sudo -u "$ORIGINAL_USER"` 以普通用户身份执行，避免 root 污染编译产物。
- **分步执行：** 支持命令行参数拆分各阶段（`all`/`env`/`clone`/`scripts`/`feeds`/`packages`/`settings`/`download`/`compile`），方便调试。
- **默认值针对 AX1800Pro：** `WRT_CONFIG=IPQ60XX-WIFI-YES`、`WRT_IP=192.168.1.1`、`WRT_SSID=JDC_AX1800Pro` 等。
- **移除国内源镜像是可选（注释状态）：** 与 CI 版本不同，本地编译不自动移除 aliyun/tencent 镜像。

### 2. `Config/PRIVATE.txt` — 私有配置

**用途：** 由 `Settings.sh` 在合并配置时追加到 `.config`（位于 GENERAL.txt 之后），利用 Kconfig 后出现值覆盖原则，禁用或追加特定包。

```diff
# 覆盖 GENERAL.txt 中的 =y
+ CONFIG_PACKAGE_luci-app-samba4=n
+ CONFIG_PACKAGE_samba4=n
+ CONFIG_PACKAGE_luci-app-dockerman=n
# 追加私有包
+ CONFIG_PACKAGE_luci-app-tailscale=y
+ CONFIG_PACKAGE_luci-app-ddns-go=y
+ CONFIG_PACKAGE_luci-app-bandix=y
```

当构建 PRIVATE 工作流时，此配置自动生效。

### 3. `Scripts/PRIVATE.sh` — 私有扩展脚本

**用途：** 在 `Packages.sh` 末尾被 `source` 执行，实现 OpenWRT-CI 不具备的定制逻辑。

**功能拆解：**

| 功能 | 说明 |
|---|---|
| 构建者标记 | 在 CI 环境下将 `WRT_MARK` 设为 `Puter`（覆盖原版 `${GITHUB_REPOSITORY%%/*}`） |
| 2.4G/5G/6G 分频命名 | 修改 `mac80211.uc`，按 `band_name` 三元判断：2G=基础SSID、5G=基础SSID_5G、6G=基础SSID_6G |
| bandix 流量监控 | 引入 `timsaya/openwrt-bandix` 和 `timsaya/luci-app-bandix` |

**分频设计的升级安全性：** 由于 `mac80211.uc` 仅在 `/etc/config/wireless` 不存在时执行，升级（sysupgrade）不会覆盖用户已有设置。

### 4. `.github/workflows/PRIVATE.yml` — 私有 CI 工作流

**用途：** 专为 AX1800Pro 定制的 GitHub Actions 工作流。

**与通用工作流的区别：**

| 项目 | QCA-ALL / OWRT-ALL | PRIVATE |
|---|---|---|
| **编译目标** | 矩阵全量（4 个或 2 个配置） | 交互选择：all / IPQ60XX-WIFI-YES / X86 |
| **WRT_THEME** | `aurora` | `argon` |
| **WRT_NAME** | `OWRT` | `AX1800Pro` |
| **WRT_SSID** | `OWRT` | `JDC_AX1800Pro` |
| **WRT_IP** | `192.168.10.1` | `192.168.1.1` |
| **IPQ60XX 分支** | `main` | `main` |
| **X86 分支** | `owrt` | `owrt` |
| **动态矩阵** | 静态 matrix | `case` 分支动态生成 JSON（支持 all / IPQ60XX-WIFI-YES / X86 三种场景） |

---

## 三、修改文件详解

### 1. `Config/IPQ60XX-WIFI-YES.txt` — 仅保留京东云 re-ss-01

```diff
  #设备列表
- CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_qihoo_360v6=y
+ CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_qihoo_360v6=n
  ...
- CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_anysafe_e1=y
+ CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_anysafe_e1=n
  ...
+ CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y
  ...
- CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y
+ CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=n
```

**原版：** 18 个设备全部 =y（全量编译）。
**AX1800Pro：** 仅 `jdcloud_re-ss-01=y`，其余 17 个设备全部 =n。PRIVATE 工作流 + IPQ60XX-WIFI-YES 配置专用于京东云 AX1800Pro。

### 2. `.github/workflows/Auto-Clean.yml` — 禁用定时触发

```diff
  on:
-   schedule:
-     - cron: 0 21 * * *
+   # schedule:
+   #   - cron: 0 21 * * *
    workflow_dispatch:
```

**原版：** 每天早上 5 点自动清理 Release 和工作流。
**AX1800Pro：** 取消定时触发，仅支持手动清理。

### 3. `.github/workflows/Cache-Clean.yml` — 禁用定时触发

```diff
  on:
-   schedule:
-     - cron: 0 20 * * 0
+   # schedule:
+   #   - cron: 0 20 * * 0
    workflow_dispatch:
```

**原版：** 每周一早上 4 点自动清理缓存。
**AX1800Pro：** 取消定时触发，仅支持手动清理。

### 4. `.github/workflows/{QCA-ALL,OWRT-ALL,MTK-ALL}.yml` — 禁用自动编译触发器

**改动：** 将 `workflow_run` 自动触发注释掉，改为纯手动触发。

```diff
  on:
-   workflow_run:
-     workflows: ["Auto-Clean"]
-     types:
-       - completed
+   # workflow_run:
+   #   workflows: ["Auto-Clean"]
+   #   types:
+   #     - completed
    workflow_dispatch:
```

**影响：** 三个系列（QCA、OWRT、MTK）不再由 Auto-Clean 触发后自动编译，全部改为手动触发。

### 5. `Scripts/Settings.sh` — mac80211.uc 的 SSID 修改被注释

**原因：** PRIVATE.sh 实现了 2.4G/5G/6G 分频命名，原 Settings.sh 的全局 SSID 替换会覆盖分频逻辑。

```diff
  elif [ -f "$WIFI_UC" ]; then
    #修改WIFI名称
-   sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
+   # sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
    #修改WIFI密码
    sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
  fi
```

key（密码）替换保持不变，所有频段共用同一密码。

### 6. `Scripts/Handles.sh` — argon 主题调整被注释

```diff
- if [ -d *"luci-theme-argon"* ]; then
-     echo " " && cd ./luci-theme-argon/
-     sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon
-     cd $PKG_PATH && echo "theme-argon has been fixed!"
- fi
+ # if [ -d *"luci-theme-argon"* ]; then
+ #     echo " " && cd ./luci-theme-argon/
+ #     sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon
+ #     cd $PKG_PATH && echo "theme-argon has been fixed!"
+ # fi
```

**原因：** PRIVATE 工作流使用 argon 主题，但不再需要自定义 argon 颜色（采用上游默认外观）。

### 7. `Scripts/Packages.sh` — 禁用 argon 独立拉取

```diff
- UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
+ # UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
```

**原因：** argon 主题不再从 GitHub 单独拉取，改为使用 feeds 内的版本。配合 PRIVATE.txt 中的 `echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y"` 从 feeds 启用。

末尾的 PRIVATE.sh 引用保持不变：
```bash
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
```

---

## 四、值差异汇总

以下值在不同文件/场景中取值不同：

| 参数 | QCA/OWRT/MTK/WRT-TEST | PRIVATE.yml | build.sh（本地） |
|---|---|---|---|
| `WRT_NAME` | `OWRT` | `AX1800Pro` | `AX1800Pro` |
| `WRT_SSID` | `OWRT` | `JDC_AX1800Pro` | `JDC_AX1800Pro` |
| `WRT_WORD` | `12345678` | `12345678` | `12345678` |
| `WRT_IP` | `192.168.10.1` | `192.168.1.1` | `192.168.1.1` |
| `WRT_THEME` | `aurora` | `argon` | `argon` |
| `WRT_PW` | `无` | `无` | `无` |
| IPQ60XX 分支 | `main` | `main` | `main` |
| X86 分支 | `owrt` | `owrt` | - |
| `WRT_MARK` | `${GITHUB_REPOSITORY%%/*}` | `Puter`（PRIVATE.sh 覆盖） | `Puter`（build.sh export） |
| **IPQ60XX 设备列表** | **全量 18 个 =y** | **仅 jdcloud_re-ss-01=y** | **仅 jdcloud_re-ss-01=y** |
| **argon 主题来源** | feeds（Settings.sh 启用） | feeds（Settings.sh 启用） | feeds（Settings.sh 启用） |

---

## 五、设计意图总结

```
OpenWRT-CI（通用 CI 框架）
    │
    ├── 新增 build.sh         → 本地编译能力（脱离 GitHub Actions）
    ├── 新增 PRIVATE.yml      → 专为 AX1800Pro 优化的 CI 工作流
    ├── 新增 PRIVATE.txt      → 私有配置覆盖（禁用samba4/dockerman, 启用tailscale/ddns-go/bandix）
    ├── 新增 PRIVATE.sh       → 2.4G/5G/6G 分频 + 构建者标识 + bandix
    │
    ├── 修改 IPQ60XX-WIFI-YES → 仅编译 jdcloud_re-ss-01（只给 AX1800Pro 编译）
    ├── 修改 Settings.sh      → SSID 注释，让位给 PRIVATE.sh 分频
    ├── 修改 Handles.sh       → argon 主题定制注释
    ├── 修改 Packages.sh      → argon 独立拉取注释（改用 feeds 版）
    │
    └── 修改 5 个 workflow    → 禁用所有自动触发，全部改为手动编译

核心目标：
    在保留原项目全平台 CI 能力的前提下，
    独立出仅面向「京东云 AX1800Pro (re-ss-01)」的私有编译通道，
    并增加本地编译支持。
```

---

## 六、更新记录

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-07-12 | v1 | 首次对比分析并生成文档 |
| 2026-07-12 | v2 | 撤销 3 处改动：IPQ60XX-WIFI-YES.txt 恢复全量、GENERAL.txt wolplus→wolultra 回退、Packages.sh git pull 逻辑移除 |
| 2026-07-12 | v3 | **重新启用 AX1800Pro 专用配置**：IPQ60XX-WIFI-YES.txt 再次改为仅 `jdcloud_re-ss-01=y`；Packages.sh 的 argon 独立拉取被注释（改用 feeds 版） |
