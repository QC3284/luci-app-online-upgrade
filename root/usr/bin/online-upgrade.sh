#!/bin/sh
# =====================================================
# Online Upgrade Script — 适配 QC3284/openwrt-actions
# 从 GitHub Releases 列表自动查找设备对应固件
# =====================================================

get_uci() { uci -q get "online-upgrade.settings.$1" 2>/dev/null; }

REPO="$(get_uci repo)"
PROXY="$(get_uci proxy)"

[ -z "$REPO" ] && REPO="QC3284/openwrt-actions"
[ -z "$PROXY" ] && PROXY="https://ghfast.top/"
# 确保代理 URL 以 / 结尾，避免拼接时出错
[ -n "$PROXY" ] && PROXY="${PROXY%/}/"

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

# ===== 查找设备对应的最新 Release (两阶段: Atom+HTML → API) =====
find_firmware() {
  local tag fw_url fw_name feed html json

  # === Phase 1: Atom Feed + Expanded Assets (直连优先, 代理兜底) ===
  feed="/tmp/releases.xml"
  echo "  正在获取 Release 列表..."
  curl -sL --connect-timeout 10 -H "User-Agent: online-upgrade" -o "$feed" \
    "https://github.com/${REPO}/releases.atom" 2>/dev/null
  if [ ! -s "$feed" ] && [ -n "$PROXY" ]; then
    curl -sL --connect-timeout 15 -H "User-Agent: online-upgrade" -o "$feed" \
      "${PROXY}https://github.com/${REPO}/releases.atom" 2>/dev/null
  fi

  if [ -s "$feed" ]; then
    tag=$(grep -o "/${DEVICE}-[^<]*<" "$feed" 2>/dev/null | head -1 | tr -d '/<>')
    rm -f "$feed"
    if [ -n "$tag" ]; then
      echo "  最新 Tag: ${tag}"
      html="/tmp/assets.html"
      curl -sL --connect-timeout 10 -H "User-Agent: online-upgrade" -o "$html" \
        "https://github.com/${REPO}/releases/expanded_assets/${tag}" 2>/dev/null
      if [ ! -s "$html" ] && [ -n "$PROXY" ]; then
        curl -sL --connect-timeout 15 -H "User-Agent: online-upgrade" -o "$html" \
          "${PROXY}https://github.com/${REPO}/releases/expanded_assets/${tag}" 2>/dev/null
      fi
      if [ -s "$html" ]; then
        fw_url=$(grep -o "/${REPO}/releases/download/${tag}/[^\"]*" "$html" 2>/dev/null \
          | grep "squashfs-sysupgrade" | grep -v "manifest" | head -1)
        rm -f "$html"
        if [ -n "$fw_url" ]; then
          fw_url="https://github.com${fw_url}"
          fw_name=$(basename "$fw_url" 2>/dev/null || echo "$fw_url" | sed 's|.*/||')
          echo "  固件: ${fw_name}"
          echo "TAG=${tag}" > /tmp/.online-upgrade.env
          echo "FW_URL=${fw_url}" >> /tmp/.online-upgrade.env
          echo "FW_NAME=${fw_name}" >> /tmp/.online-upgrade.env
          return 0
        fi
      fi
    fi
  fi
  rm -f "$feed" /tmp/assets.html

  # === Phase 2: GitHub API Fallback (Atom/HTML 失败或代理不支持网页时) ===
  echo "  尝试 GitHub API..."
  json="/tmp/releases.json"
  curl -sL --connect-timeout 10 -H "User-Agent: online-upgrade" -o "$json" \
    "https://api.github.com/repos/${REPO}/releases?per_page=30" 2>/dev/null
  if [ ! -s "$json" ] && [ -n "$PROXY" ]; then
    curl -sL --connect-timeout 15 -H "User-Agent: online-upgrade" -o "$json" \
      "${PROXY}https://api.github.com/repos/${REPO}/releases?per_page=30" 2>/dev/null
  fi

  if [ -s "$json" ]; then
    # 检测限速错误 (GitHub API 未认证 60次/小时)
    if grep -q 'rate limit' "$json" 2>/dev/null; then
      echo "错误: GitHub API 访问超60次/小时受限"
      rm -f "$json"
      return 1
    fi
    # 从 JSON 中找到匹配设备的第一个 release tag
    tag=$(grep -o '"tag_name": *"[^"]*"' "$json" 2>/dev/null \
      | grep "${DEVICE}-" | head -1 \
      | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    if [ -n "$tag" ]; then
      echo "  最新 Tag: ${tag}"
      # 从 assets 中提取 sysupgrade 固件下载链接 (URL 路径包含 /download/<tag>/)
      fw_url=$(grep -o '"browser_download_url": *"[^"]*"' "$json" 2>/dev/null \
        | grep "/download/${tag}/" \
        | grep "squashfs-sysupgrade" | grep -v manifest | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')
      rm -f "$json"
      if [ -n "$fw_url" ]; then
        fw_name=$(basename "$fw_url" 2>/dev/null || echo "$fw_url" | sed 's|.*/||')
        echo "  固件: ${fw_name}"
        echo "TAG=${tag}" > /tmp/.online-upgrade.env
        echo "FW_URL=${fw_url}" >> /tmp/.online-upgrade.env
        echo "FW_NAME=${fw_name}" >> /tmp/.online-upgrade.env
        return 0
      fi
    fi
  fi
  rm -f "$json"

  # 全部失败
  echo "错误: 无法获取固件信息"
  echo "提示: 直连和代理均失败，如使用下载专用代理请更换为支持网页/API 的代理"
  return 1
}

# ===== 版本对比 (通过固件内置版本文件 + 在线 TAG) =====
VERSION_FILE="/etc/firmware-build-info"
is_newer() {
  . /tmp/.online-upgrade.env 2>/dev/null
  # 从固件内版本文件提取构建时间戳 (格式: device YYYYMMDDHHMMSS run_id)
  if [ -f "$VERSION_FILE" ]; then
    local cur_ts=$(awk '{print $2}' "$VERSION_FILE" 2>/dev/null | grep -o '[0-9]\{12\}' | head -1)
    # 从在线 TAG 提取时间戳 (格式: device-YYYYMMDDHHMM-run_id)
    local new_ts=$(echo "$TAG" | grep -o '[0-9]\{12\}' | head -1)
    if [ -n "$cur_ts" ] && [ -n "$new_ts" ]; then
      [ "$cur_ts" -lt "$new_ts" ] 2>/dev/null && return 0
      return 1
    fi
  fi
  # 回退：无版本文件，首次检测认为有新固件
  return 0
}

# ===== 区域检测 (仅 check/upgrade 时调用) =====
detect_region() {
  local cc
  cc=$(curl -s --connect-timeout 3 "http://ip-api.com/json/?fields=countryCode" 2>/dev/null | jsonfilter -e '@.countryCode' 2>/dev/null)
  [ "$cc" = "CN" ] && return 0 || return 1
}

# ===== 检查模式 =====
if [ "$MODE" = "check" ] || [ "$MODE" = "status" ]; then
  # 国内网络检测并强制启用代理
  if detect_region; then
    echo "  检测到国内网络，强制启用代理"
    [ -z "$(get_uci proxy)" ] && PROXY="https://ghfast.top/"
  fi
  find_firmware
  if [ $? -ne 0 ] || [ ! -f /tmp/.online-upgrade.env ]; then
    echo "错误: 无法获取固件信息"
    exit 1
  fi
  . /tmp/.online-upgrade.env

  # 输出 JS 视图需要解析的标签行
  echo "最新固件: ${TAG}"
  echo "新固件版本: ${FW_NAME}"

  # 尝试获取文件大小 (HEAD 请求，先直连后代理)
  FW_SIZE=$(curl -sI --connect-timeout 5 -H "User-Agent: online-upgrade" "$FW_URL" 2>/dev/null | grep -i 'content-length' | awk '{print $2}' | tr -d '\r')
  if [ -z "$FW_SIZE" ] && [ -n "$PROXY" ]; then
    FW_SIZE=$(curl -sI --connect-timeout 8 -H "User-Agent: online-upgrade" "${PROXY}${FW_URL}" 2>/dev/null | grep -i 'content-length' | awk '{print $2}' | tr -d '\r')
  fi
  if [ -n "$FW_SIZE" ] && [ "$FW_SIZE" -gt 0 ] 2>/dev/null; then
    if [ "$FW_SIZE" -ge 1048576 ] 2>/dev/null; then
      echo "文件大小: $(awk "BEGIN {printf \"%.1fMB\", $FW_SIZE/1048576}")"
    else
      echo "文件大小: $(awk "BEGIN {printf \"%.1fKB\", $FW_SIZE/1024}")"
    fi
  else
    echo "文件大小: 下载时确定"
  fi

  if is_newer; then
    echo ""
    echo "  >>> 发现新固件！"
    echo "  升级: online-upgrade.sh upgrade"
    if [ -f "$VERSION_FILE" ]; then
      echo "检测依据: 在线版本时间戳更新"
    else
      echo "检测依据: 首次检测"
    fi
  else
    echo ""
    echo "  已是最新。"
    echo "检测依据: 已是最新版本"
  fi
  exit 0
fi

# ===== 升级模式 =====
if [ "$MODE" = "upgrade" ]; then
  # 国内网络检测并强制启用代理
  if detect_region; then
    echo "  检测到国内网络，强制启用代理"
    [ -z "$(get_uci proxy)" ] && PROXY="https://ghfast.top/"
  fi
  find_firmware
  if [ $? -ne 0 ] || [ ! -f /tmp/.online-upgrade.env ]; then
    echo "错误: 无法获取固件信息，升级中止"
    exit 1
  fi
  . /tmp/.online-upgrade.env

  if [ "$2" != "--force" ] && ! is_newer; then
    echo "已是最新，无需升级。"
    exit 0
  fi

  if [ "$2" = "--force" ]; then
    echo "  [强制模式] 跳过版本检查，直接升级"
  fi

  echo ""
  echo "========================================"
  echo "  [执行升级]"
  echo "========================================"

  # 下载
  echo "Step 1: 下载固件..."
  echo "downloading" > /tmp/online-upgrade-status
  echo "  正在下载: ${FW_NAME}"
  # 先直连下载，失败再走代理 (-f: HTTP 错误视为失败, -L: 跟随重定向)
  curl -fsL --connect-timeout 30 --retry 3 --retry-delay 5 -o "$TMP_FW" "$FW_URL" 2>&1
  DOWNLOAD_OK=$?
  if [ $DOWNLOAD_OK -ne 0 ] || [ ! -s "$TMP_FW" ] || grep -Eq '^(<html|<!DOCTYPE)' "$TMP_FW" 2>/dev/null; then
    if [ -n "$PROXY" ]; then
      echo "  直连失败，尝试代理下载..."
      curl -fsL --connect-timeout 60 --retry 3 --retry-delay 5 -o "$TMP_FW" "${PROXY}${FW_URL}" 2>&1
      DOWNLOAD_OK=$?
    fi
  fi
  if [ $DOWNLOAD_OK -ne 0 ] || [ ! -s "$TMP_FW" ] || grep -Eq '^(<html|<!DOCTYPE)' "$TMP_FW" 2>/dev/null; then
    echo "failed:下载失败" > /tmp/online-upgrade-status
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

  # 记录版本 (先保存旧版本文件，sysupgrade 失败时回滚)
  echo "Step 3: 记录版本..."
  echo "saving_ts" > /tmp/online-upgrade-status
  FW_DATE=$(echo "$TAG" | grep -o '[0-9]\{12\}' | head -1)
  FW_RUNID=$(echo "$TAG" | sed 's/.*-//')
  OLD_VERSION="$(cat "$VERSION_FILE" 2>/dev/null)"
  # 保持与 openwrt-actions 构建一致的格式: device YYYYMMDDHHMMSS run_id
  echo "${DEVICE} ${FW_DATE}00 ${FW_RUNID}" > "$VERSION_FILE"
  [ -n "$FW_DATE" ] && uci set online-upgrade.settings.last_upgrade_ts="$FW_DATE"
  uci set online-upgrade.settings.last_upgrade_tag="$TAG"
  uci set online-upgrade.settings.last_upgrade_version="$TAG"
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

  # sysupgrade 失败 (设备未重启才会执行到这里)
  echo "failed:sysupgrade 执行失败" > /tmp/online-upgrade-status
  uci -q delete online-upgrade.settings.last_upgrade_ts
  uci -q delete online-upgrade.settings.last_upgrade_tag
  uci -q delete online-upgrade.settings.last_upgrade_version
  uci commit online-upgrade
  # 回滚版本文件，避免下次检查误判"已是最新"
  if [ -n "$OLD_VERSION" ]; then
    echo "$OLD_VERSION" > "$VERSION_FILE"
  else
    rm -f "$VERSION_FILE"
  fi
  exit 1
fi

# ===== 后台模式 =====
if [ "$MODE" = "background" ] || [ "$MODE" = "--bg" ]; then
  ACTION="${2:-upgrade}"
  shift 2
  # shift 2 后 $@ 为原 $3 起的参数 (如 --force)，action 已移出需重新拼接
  setsid /bin/sh "$0" "$ACTION" "$@" </dev/null >/tmp/online-upgrade.log 2>&1 &
  echo "${ACTION} 已在后台启动 (PID: $!)"
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
    # 清理旧备份，保留最新 3 个
    OLD=$(ls -t /root/pre-upgrade-backup-*.tar.gz 2>/dev/null | tail -n +4)
    if [ -n "$OLD" ]; then
      echo "$OLD" | xargs rm -f 2>/dev/null
      echo "  已清理 $(echo "$OLD" | wc -l) 个旧备份"
    fi
  else
    echo "错误: 备份失败！"
    exit 1
  fi
  exit 0
fi

echo "用法: online-upgrade.sh [check|upgrade|background|backup]"
exit 1
