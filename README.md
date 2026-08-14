# luci-app-online-upgrade

ImmortalWrt / OpenWrt LuCI 插件 —— 从 GitHub Releases 在线检查并升级固件。

![Screenshot](screenshot.png)

## 功能

- 自动识别设备型号，在多设备共用的 Release 列表中查找对应固件
- 检查更新：按固件构建时间戳比较版本（本地 `/etc/firmware-build-info` vs Release tag）
- 一键在线升级：下载固件 → 备份配置 → sysupgrade 刷写并恢复配置
- 强制更新：即使已是最新版本也可重新刷写
- 支持 GitHub 下载代理，检测到国内网络时自动启用
- 备份管理：创建配置备份、下载备份到本地、自动恢复 / 手动上传恢复
- 同时支持 opkg（.ipk）与 apk（.apk）两种包格式

## 固件仓库要求

默认仓库为 [QC3284/openwrt-actions](https://github.com/QC3284/openwrt-actions)。要使用本插件，Release 需满足：

- tag 命名 `<设备名>-<YYYYMMDDHHMM>-<run_id>`，如 `glinet_gl-mt3600be-202608051927-30988961261`
- 固件资产文件名包含 `squashfs-sysupgrade`（自动排除 manifest 文件）
- 设备名与 `/etc/board.json` 中 `model.id` 的规范化结果一致（逗号转下划线、转小写）

## 使用方法

1. 安装后，在 LuCI 菜单 **系统 → 在线升级** 进入
2. 点击 **检查更新**：自动识别设备、查找最新 Release、对比构建时间戳
3. 点击 **立即升级**（或 **强制更新**）：路由器自动下载固件 → 备份配置 → 刷写 → 重启恢复配置
4. **备份 & 恢复** 卡片：随时创建备份（存于 `/root/pre-upgrade-backup-*.tar.gz`，保留最近 3 个）、下载到本地、或从本地/上传的备份恢复

> 注意：固件升级后插件本身会被清除，需要重新安装；UCI 配置与备份文件会通过 `/lib/upgrade/keep.d` 保留。

## 编译

```bash
# 将本插件放到 openwrt/package/luci-app-online-upgrade/
cd openwrt
make package/luci-app-online-upgrade/compile V=s
```

仓库自带 GitHub Actions 工作流（`.github/workflows/build.yml`）：push 后自动使用 ImmortalWrt 23.05 与 25.12 两个 SDK 分别编译 .ipk 与 .apk，并发布到 Release。

## 手动安装

**opkg（ImmortalWrt 23.05 及更早）：**

```bash
opkg install luci-app-online-upgrade_2.0.0_all.ipk
```

**apk（ImmortalWrt 25.12+）：**

```bash
apk add --allow-untrusted luci-app-online-upgrade-2.0.0-r1.apk
```

## 依赖

- curl
- jsonfilter
- LuCI（luci-base）

## 配置

UCI 配置文件 `/etc/config/online-upgrade`：

```bash
config online-upgrade 'settings'
    option repo 'QC3284/openwrt-actions'   # GitHub 仓库 owner/repo
    option proxy 'https://ghfast.top/'     # 下载代理，留空使用默认 ghfast.top
    option keep_config '1'                 # 1=升级时备份并恢复配置；0=全新刷写
    option device ''                       # 留空自动检测，可手动指定设备名
```

## 工作原理

- **设备识别**：UCI `device` 优先，其次 `/etc/board.json` 的 `model.id`，最后回退 `/proc/device-tree/compatible`
- **查找固件**：优先 Atom feed + expanded_assets（直连，失败走代理），再回退 GitHub API；按设备名匹配 tag、按 `squashfs-sysupgrade` 匹配资产文件
- **版本比较**：比较本地 `/etc/firmware-build-info` 与在线 tag 中的 12 位构建时间戳；无本地版本文件时首次检测视为有新固件
- **升级流程**：curl 下载（直连失败自动走代理）→ `sysupgrade -b` 备份到 `/tmp` 与 `/root` → `sysupgrade -f <备份> <固件>` 刷写并恢复配置
- **状态与日志**：升级状态写入 `/tmp/online-upgrade-status`，后台升级日志写入 `/tmp/online-upgrade.log`

## 许可证

GNU GENERAL PUBLIC LICENSE v2（GPL-2.0）
