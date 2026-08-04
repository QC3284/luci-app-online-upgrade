"use strict";"require view";"require fs";"require ui";
return view.extend({
	render: function() {
		var statusEl = null, stepEl = null;
		var timer = null;

		function checkStatus() {
			return fs.read("/tmp/online-upgrade-status").then(function(status) {
				status = (status || "").trim();
				if (status.indexOf("failed:") === 0) {
					var msg = status.replace("failed:", "").trim();
					if (stepEl) stepEl.textContent = "失败: " + msg;
					if (statusEl) statusEl.innerHTML = '<span style="color:red">⚠️ 升级失败！请返回手动检查。</span>';
					if (timer) { clearInterval(timer); timer = null; }
				} else if (status === "sysupgrade") {
					if (stepEl) stepEl.textContent = "正在刷写固件，即将重启...";
					if (statusEl) statusEl.innerHTML = '<span class="spinning">正在刷写，请勿断电！</span>';
				} else if (status === "downloading") {
					if (stepEl) stepEl.textContent = "正在下载固件...";
				} else if (status === "backing_up") {
					if (stepEl) stepEl.textContent = "正在备份配置...";
				}
			}).catch(function() {
				// status file not yet created, that's OK
			});
		}

		// Start polling
		setTimeout(function() {
			timer = setInterval(checkStatus, 1500);
			checkStatus();
		}, 500);

		return E("div", {"class":"cbi-map"}, [
			E("h2", {"class":"cbi-page-title"},"正在更新..."),
			E("div", {"class":"alert-message","style":"padding:30px;text-align:center;font-size:16px;"}, [
				E("p", function(el) { statusEl = el; }, E("span", {"class":"spinning"}, "系统正在后台下载固件并自动刷写，请勿断电！")),
				E("p", function(el) { stepEl = el; }),
				E("p", {"style":"margin-top:20px;color:#888;font-size:13px;"},"如果长时间无响应，请手动检查路由器状态。")
			]),
			E("div", {"class":"cbi-page-actions"}, [
				E("button", {"class":"btn cbi-button","click":function(){ui.awaitReconnect(window.location.host,"192.168.5.1");}},"等待重连"),
				E("button", {"class":"btn cbi-button-action","style":"margin-left:10px","click":function(){window.location.href=L.url("admin/system/online_upgrade");}},"返回")
			])
		]);
	}
});
