local m = Map("online-upgrade", "固件在线升级", "从 GitHub Releases 自动检测并升级固件。适配多设备矩阵编译项目。")

-- 配置区
local s = m:section(NamedSection, "settings", "settings", "仓库配置")

local repo = s:option(Value, "repo", "GitHub 仓库")
repo.default = "QC3284/openwrt-actions"
repo.rmempty = false

local proxy = s:option(Value, "proxy", "下载代理",
    "国内用户推荐 https://ghfast.top/，海外留空")
proxy.default = "https://ghfast.top/"

local keep = s:option(Flag, "keep_config", "保留配置")
keep.default = "1"
keep.rmempty = false
keep.description = "勾选：升级前备份配置并自动恢复。取消：全新安装，不保留配置。"

-- 版本信息（只读）
local ver_s = m:section(NamedSection, "settings", "settings", "设备与版本")

local dev = ver_s:option(DummyValue, "device", "当前设备")
dev.value = luci.sys.exec("uci -q get online-upgrade.settings.device 2>/dev/null") or "-"

local cur_ver = ver_s:option(DummyValue, "_cur_ver", "当前固件版本")
cur_ver.value = luci.sys.exec("grep DISTRIB_REVISION /etc/openwrt_release 2>/dev/null | cut -d\\\"'\\\" -f2 | sed 's/r//'") or "-"
local last_ver = ver_s:option(DummyValue, "last_upgrade_version", "当前固件版本")
local last_ts = ver_s:option(DummyValue, "last_upgrade_ts", "上次升级时间")

-- 清理旧版废弃字段 (tag / firmware_pattern)
if luci.sys.call("uci -q get online-upgrade.settings.tag >/dev/null 2>&1") == 0 then
    luci.sys.call("uci -q delete online-upgrade.settings.tag; uci -q delete online-upgrade.settings.firmware_pattern; uci commit online-upgrade")
end

-- 操作区
local as = m:section(NamedSection, "actions", "actions", "操作")

local check_btn = as:option(Button, "check", "监测版本")
check_btn.inputstyle = "action"
check_btn.description = "检查 GitHub Releases 是否有新固件"
function check_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh check > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

local upgrade_btn = as:option(Button, "upgrade", "在线更新")
upgrade_btn.inputstyle = "action important"
upgrade_btn.description = "根据「保留配置」选项，备份配置并刷写固件，或全新安装"
function upgrade_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh background > /dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "progress"))
end

local backup_btn = as:option(Button, "backup", "仅备份配置")
backup_btn.inputstyle = "action"
backup_btn.description = "创建当前配置的备份到 /root/ 目录，不升级固件"
function backup_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh backup > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

return m
