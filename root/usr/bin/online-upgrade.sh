#!/bin/sh
# =====================================================
# Online Upgrade Script — 适配 QC3284/openwrt-actions
# 从 GitHub Releases 列表自动查找设备对应固件
# =====================================================

CONFIG_FILE="/etc/config/online-upgrade"
get_uci() { uci -q get "online-upgrade.settings.$1" 2>/dev/null; }

REPO="$(get_uci repo)"
PROXY="$(get_uci proxy)"

[ -z "$REPO" ] && REPO="QC3284/openwrt-actions"
PROXY="https://ghfast.top/"

TMP_JSON="/tmp/release_list.json"
TMP_FW="/tmp/firmware.bin"
MODE="${1:-check}"

# ===== 设备识别 =====
get_device() {
  # 优先从 UCI 读取，否则自动检测
  local dev=$(get_uci device)
  [ -n "$dev" ] && { echo "$dev"; return; }
  # 从 /etc/board.json 读取
  dev=$(jsonfilter -e '@.model.id' < /etc/board.json 2>/dev/null | tr ',' '_' | tr '[:upper:]' '[:lower:]')
  [ -n "$dev" ] && { echo "$dev"; return; }
  # 回退：从 /proc/device-tree/compatible 读取第一个
  dev=$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n' | tail -1 | tr ',' '_' | tr '[:upper:]' '[:lower:]')
  [ -n "$dev" ] && { echo "$dev"; return; }
  echo "unknown"
}

DEVICE="$(get_device)"
echo "========================================"
echo "  固件在线升级 (适配 openwrt-actions)"
echo "  仓库: ${REPO}"
echo "  设备: ${DEVICE}"
echo "========================================"

# ===== 获取最新 Release 列表 =====

# ===== 查找设备对应的最新 Release =====
find_firmware() {
  local atom="https://github.com/${REPO}/releases.atom"
  local feed="/tmp/releases.xml"
  local tag fw_url fw_name

  echo "  正在获取 Release 列表..."
  curl -sL --connect-timeout 10 -H "User-Agent: online-upgrade" -o "$feed" "$atom" 2>/dev/null
  if [ ! -s "$feed" ] && [ -n "$PROXY" ]; then
    curl -sL --connect-timeout 15 -H "User-Agent: online-upgrade" -o "$feed" "${PROXY}${atom}" 2>/dev/null
  fi
  [ ! -s "$feed" ] && { echo "错误: 无法获取 Release 列表"; return 1; }

  # Atom feed 中取设备最新 tag
  tag=$(grep -o "/${DEVICE}-[^<]*<" "$feed" 2>/dev/null | head -1 | tr -d '/<>')
  [ -z "$tag" ] && { echo "错误: 未找到设备 ${DEVICE} 的 Release"; rm -f "$feed"; return 1; }
  echo "  最新 Tag: ${tag}"
  rm -f "$feed"

  # 从 expanded_assets 页面获取具体固件下载链接
  local assets_url="https://github.com/${REPO}/releases/expanded_assets/${tag}"
  local html="/tmp/assets.html"
  echo "  正在获取固件列表..."
  curl -sL --connect-timeout 10 -H "User-Agent: online-upgrade" -o "$html" "$assets_url" 2>/dev/null
  if [ ! -s "$html" ] && [ -n "$PROXY" ]; then
    curl -sL --connect-timeout 15 -H "User-Agent: online-upgrade" -o "$html" "${PROXY}${assets_url}" 2>/dev/null
  fi

  fw_url=$(grep -o "/${REPO}/releases/download/${tag}/[^\"]*" "$html" 2>/dev/null | grep "squashfs-sysupgrade" | grep -v "manifest" | head -1)
  [ -z "$fw_url" ] && { echo "错误: 未找到 sysupgrade 固件"; rm -f "$html"; return 1; }
  fw_url="https://github.com${fw_url}"
  fw_name=$(basename "$fw_url" 2>/dev/null || echo "$fw_url" | sed 's|.*/||')
  echo "  固件: ${fw_name}"
  rm -f "$html"

  echo "TAG=${tag}" > /tmp/.online-upgrade.env
  echo "FW_URL=${fw_url}" >> /tmp/.online-upgrade.env
  echo "FW_NAME=${fw_name}" >> /tmp/.online-upgrade.env
  return 0
}

# ===== 版本对比 (通过本地记录文件) =====
VERSION_FILE="/etc/online-upgrade-version"
is_newer() {
  . /tmp/.online-upgrade.env 2>/dev/null
  [ ! -f "$VERSION_FILE" ] && return 0
  local cur_tag=$(head -1 "$VERSION_FILE" 2>/dev/null)
  [ -z "$cur_tag" ] && return 0
  [ "$TAG" != "$cur_tag" ] && return 0
  return 1
}

# ===== 检查模式 =====
if [ "$MODE" = "check" ] || [ "$MODE" = "status" ]; then
  find_firmware
  if [ $? -ne 0 ] || [ ! -f /tmp/.online-upgrade.env ]; then
    echo "错误: 无法获取固件信息"
    exit 1
  fi
  if is_newer; then
    echo ""
    echo "  >>> 发现新固件！"
    echo "  升级: online-upgrade.sh upgrade"
  else
    echo ""
    echo "  已是最新。"
  fi
  rm -f /tmp/releases.html
  exit 0
fi

# ===== 升级模式 =====
if [ "$MODE" = "upgrade" ]; then
  find_firmware
  if [ $? -ne 0 ] || [ ! -f /tmp/.online-upgrade.env ]; then
    echo "错误: 无法获取固件信息，升级中止"
    exit 1
  fi
  . /tmp/.online-upgrade.env

  if ! is_newer; then
    echo "已是最新，无需升级。"
    exit 0
  fi

  echo ""
  echo "========================================"
  echo "  [执行升级]"
  echo "========================================"

  # 下载
  echo "Step 1: 下载固件..."
  echo "downloading" > /tmp/online-upgrade-status
  DOWNLOAD_URL="${FW_URL}"
  [ -n "$PROXY" ] && DOWNLOAD_URL="${PROXY}${FW_URL}"
  curl -sL -o "$TMP_FW" "$DOWNLOAD_URL" 2>&1
  if [ $? -ne 0 ] || [ ! -s "$TMP_FW" ]; then
    echo "错误: 下载失败"
    exit 1
  fi
  echo "  下载成功 ($(du -h "$TMP_FW" | cut -f1))"

  # 备份 (根据 keep_config 设置)
  KEEP_CONFIG=$(get_uci keep_config)
  [ -z "$KEEP_CONFIG" ] && KEEP_CONFIG="1"

  if [ "$KEEP_CONFIG" = "1" ]; then
    echo "Step 2: 创建配置备份 (keep_config=1)..."
    echo "backing_up" > /tmp/online-upgrade-status
    TS=$(date +%Y%m%d-%H%M%S)
    BACKUP="/tmp/pre-upgrade-backup-${TS}.tar.gz"
    sysupgrade -b "$BACKUP"
    if [ $? -ne 0 ] || [ ! -s "$BACKUP" ]; then
      echo "failed:备份失败" > /tmp/online-upgrade-status
      echo "错误: 备份失败"
      exit 1
    fi
    cp "$BACKUP" "/root/pre-upgrade-backup-${TS}.tar.gz"
    echo "  备份: /root/pre-upgrade-backup-${TS}.tar.gz"
  else
    echo "Step 2: 跳过配置备份 (keep_config=0, 将执行全新安装)"
    BACKUP=""
  fi

  # 记录版本
  echo "Step 3: 记录版本..."
  echo "saving_ts" > /tmp/online-upgrade-status
  echo "$TAG" > /etc/online-upgrade-version
  uci set online-upgrade.settings.last_upgrade_ts="$FW_DATE"
  uci set online-upgrade.settings.last_upgrade_tag="$TAG"
  uci commit online-upgrade

  # 升级
  echo "Step 4: 执行 sysupgrade..."
  echo "sysupgrade" > /tmp/online-upgrade-status
  sync
  sleep 1
  if [ -n "$BACKUP" ] && [ -s "$BACKUP" ]; then
    /sbin/sysupgrade -f "$BACKUP" "$TMP_FW"
  else
    /sbin/sysupgrade "$TMP_FW"
  fi

  # sysupgrade 失败
  echo "failed:sysupgrade 执行失败" > /tmp/online-upgrade-status
  uci -q delete online-upgrade.settings.last_upgrade_ts
  uci -q delete online-upgrade.settings.last_upgrade_tag
  uci commit online-upgrade
  exit 1
fi

# ===== 后台模式 =====
if [ "$MODE" = "background" ] || [ "$MODE" = "--bg" ]; then
  setsid /bin/sh "$0" "upgrade" </dev/null >/tmp/online-upgrade.log 2>&1 &
  echo "升级已在后台启动 (PID: $!)"
  exit 0
fi

# ===== 仅备份 =====
if [ "$MODE" = "backup" ] || [ "$MODE" = "--backup" ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  BAK="/tmp/pre-upgrade-backup-${TS}.tar.gz"
  echo "正在创建配置备份..."
  sysupgrade -b "$BAK"
  if [ $? -eq 0 ] && [ -s "$BAK" ]; then
    cp "$BAK" "/root/pre-upgrade-backup-${TS}.tar.gz"
    echo "备份成功: /root/pre-upgrade-backup-${TS}.tar.gz ($(du -h "$BAK" | cut -f1))"
    echo "备份中包含 $(tar tzf "$BAK" 2>/dev/null | wc -l) 个文件"
    # 清理旧备份，保留最新 5 个
    ls -t /root/pre-upgrade-backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
  else
    echo "错误: 备份失败！"
    exit 1
  fi
  exit 0
fi

echo "用法: online-upgrade.sh [check|upgrade|background|backup]"
exit 1

# ===== IP 检测 =====
detect_region() {
  local cc
  cc=$(curl -s --connect-timeout 3 "http://ip-api.com/json/?fields=countryCode" 2>/dev/null | jsonfilter -e '@.countryCode' 2>/dev/null)
  [ "$cc" = "CN" ] && return 0 || return 1
}

# 国内强制启用代理
if detect_region; then
  echo "  检测到国内网络，强制启用代理"
  PROXY="https://ghfast.top/"
fi
