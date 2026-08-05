local m = Map("online-upgrade", "固件在线升级", "从 GitHub Releases 自动检测并升级固件。适配多设备矩阵编译项目。")

local s = m:section(NamedSection, "settings", "settings", "仓库配置")

local repo = s:option(Value, "repo", "GitHub 仓库")
repo.default = "QC3284/openwrt-actions"
repo.rmempty = false

local proxy = s:option(Value, "proxy", "下载代理", "国内用户推荐 https://ghfast.top/")
proxy.default = "https://ghfast.top/"

local keep = s:option(Flag, "keep_config", "保留配置")
keep.default = "1"
keep.rmempty = false
keep.description = "勾选：升级前备份配置并自动恢复。取消：全新安装，不保留配置。"

local as = m:section(NamedSection, "actions", "actions", "操作")

local check_btn = as:option(Button, "check", "监测版本")
check_btn.inputstyle = "action"
function check_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh check > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

local upgrade_btn = as:option(Button, "upgrade", "在线更新")
upgrade_btn.inputstyle = "action important"
function upgrade_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh background > /dev/null 2>&1 &")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "progress"))
end

local backup_btn = as:option(Button, "backup", "仅备份配置")
backup_btn.inputstyle = "action"
function backup_btn.write()
    luci.sys.call("/usr/bin/online-upgrade.sh backup > /tmp/online-upgrade.log 2>&1")
    luci.http.redirect(luci.dispatcher.build_url("admin", "system", "online_upgrade", "log"))
end

return m
