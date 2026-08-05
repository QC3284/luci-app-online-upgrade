local m = Map("online-upgrade", "固件在线升级",
    "从 GitHub Releases 自动检测并升级固件。<br>" ..
    "设备名和固件信息自动检测，无需手动配置。")

local s = m:section(NamedSection, "settings", "settings", "仓库配置")

s:option(Value, "repo", "仓库").default = "QC3284/openwrt-actions"
s:option(Value, "proxy", "下载代理").default = "https://ghfast.top/"
s:option(Flag, "keep_config", "保留配置").default = "1"

local info = m:section(NamedSection, "settings", "settings", "设备信息")
info:option(DummyValue, "device", "设备")
info:option(DummyValue, "last_upgrade_version", "固件版本")
info:option(DummyValue, "last_upgrade_ts", "构建序号")

local act = m:section(NamedSection, "actions", "actions", "操作")

local c = act:option(Button, "check", "检查更新")
c.inputstyle = "action"
function c.write(self)
    luci.sys.call("/usr/bin/online-upgrade.sh check > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

local u = act:option(Button, "upgrade", "在线升级")
u.inputstyle = "action important"
function u.write(self)
    luci.sys.call("/usr/bin/online-upgrade.sh background > /dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "progress"))
end

local b = act:option(Button, "backup", "备份配置")
b.inputstyle = "action"
function b.write(self)
    luci.sys.call("/usr/bin/online-upgrade.sh backup > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

return m
