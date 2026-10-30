#!/bin/sh
# ============================================================================
# PassWall 私有构建 —— 设备安装脚本（在路由器上运行，不是在 PC 上）
#
# ⚠️ 这个脚本会【卸载旧版 PassWall】再装我们编的 4.70-5。
#    它会先自动备份配置，但请务必看完 README 再跑。
#
# 前提：
#   1. 12 个 ipk 已上传到 /tmp/pw-ipk/
#   2. 已经跑过 device-check.sh，且第 2 节出现 x86_64、第 3 节全部 OK
#
# 用法：
#   sh install.sh            # 正常安装
#   sh install.sh --dry-run  # 只打印将要做什么，不执行
# ============================================================================

IPK_DIR="${IPK_DIR:-/tmp/pw-ipk}"
DRY_RUN=0
[ "$1" = "--dry-run" ] && DRY_RUN=1

run() {
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] $*"
	else
		echo "  + $*"
		sh -c "$*" || return 1
	fi
}

# ---------------------------------------------------------------- 0. 前置检查
echo "========== 0. 前置检查 =========="
[ -d "$IPK_DIR" ] || { echo "!! 找不到 $IPK_DIR"; exit 1; }
N=$(ls "$IPK_DIR"/*.ipk 2>/dev/null | wc -l)
echo "  ipk 数量: $N"
[ "$N" -ge 12 ] || { echo "!! 期望 12 个，实际 $N 个"; exit 1; }

ARCH_OK=$(opkg print-architecture 2>/dev/null | awk '$2=="x86_64"{print "yes"}')
[ "$ARCH_OK" = "yes" ] || { echo "!! 设备不支持 x86_64 架构，装不了"; exit 1; }
echo "  架构: x86_64 ✓"

for lib in libcares.so.2 libsodium.so.26 libmbedcrypto.so.16 libuv.so.1 libstdc++.so.6; do
	find /usr/lib /lib -name "$lib" 2>/dev/null | grep -q . || {
		echo "!! 缺少 $lib，ss-local 会加载失败。先装对应依赖包。"
		exit 1
	}
done
echo "  共享库: 全部就位 ✓"

# ---------------------------------------------------------------- 1. 备份
echo
echo "========== 1. 备份 =========="
BK="/root/passwall-backup-$(date +%Y%m%d-%H%M%S)"
run "mkdir -p $BK"
[ -f /etc/config/passwall ] && run "cp -f /etc/config/passwall $BK/passwall.config"
[ -f /etc/config/passwall_server ] && run "cp -f /etc/config/passwall_server $BK/passwall_server.config"
run "opkg list-installed > $BK/pkgs-before.txt"
echo "  备份目录: $BK"

# ---------------------------------------------------------------- 2. 停服务
echo
echo "========== 2. 停止旧服务 =========="
run "/etc/init.d/passwall stop 2>/dev/null || true"
run "/etc/init.d/passwall disable 2>/dev/null || true"
run "/etc/init.d/passwall_server stop 2>/dev/null || true"
run "/etc/init.d/passwall_server disable 2>/dev/null || true"

# ---------------------------------------------------------------- 3. 卸载旧版
echo
echo "========== 3. 卸载旧版 PassWall =========="
OLD=$(opkg list-installed 2>/dev/null | awk '/passwall/{print $1}')
echo "  将要卸载: ${OLD:-（无）}"
if [ -n "$OLD" ]; then
	# --force-depends：新版依赖集和 4.70-5 不同，先不管依赖关系强卸
	run "opkg remove $OLD --force-depends"
fi
# 清掉残留（卸载不会删 conffiles 之外的东西）
run "rm -rf /tmp/etc/passwall /var/etc/passwall.include /tmp/log/passwall.log"

# ---------------------------------------------------------------- 4. 安装
echo
echo "========== 4. 安装新包 =========="
run "opkg install $IPK_DIR/*.ipk"

# ---------------------------------------------------------------- 5. 校验
echo
echo "========== 5. 校验 =========="
if [ "$DRY_RUN" = "1" ]; then
	echo "  [dry-run] 跳过校验"
	exit 0
fi

echo "--- 5.1 包是否都装上 ---"
opkg list-installed | grep -i passwall
echo
echo "--- 5.2 二进制 ---"
for b in ss-local ss-redir ss-server ss-tunnel ss-manager hysteria dns2tcp chinadns-ng dns2socks microsocks tcping; do
	p=$(command -v "$b" 2>/dev/null)
	if [ -n "$p" ]; then
		printf "  OK    %-14s %s\n" "$b" "$p"
	else
		printf "  MISS  %-14s\n" "$b"
	fi
done
echo
echo "--- 5.3 ss-local 能否运行（最关键一步）---"
if ss-local --version 2>&1 | head -2; then
	echo "  => ss-local 可执行 ✓"
else
	echo "  !! ss-local 运行失败，看上面的报错（通常是缺 .so）"
fi
echo
echo "--- 5.4 init.d 可执行位 ---"
ls -l /etc/init.d/passwall /etc/hotplug.d/iface/98-passwall 2>&1
echo
echo "--- 5.5 现有配置是否保留 ---"
if [ -f /etc/config/passwall ]; then
	printf "  /etc/config/passwall  %s 字节\n" "$(wc -c < /etc/config/passwall)"
	echo "  节点类型分布："
	uci show passwall 2>/dev/null | sed -n "s/^passwall\.\([^.]*\)\.type='\(.*\)'$/\2/p" | sort | uniq -c | sed 's/^/    /'
else
	echo "  !! 配置文件没了（不应该发生）"
fi

echo
echo "========== 安装完成 =========="
echo "备份在: $BK"
echo
echo "下一步："
echo "  1) 浏览器打开 LuCI → 服务 → PassWall，看能不能进得去"
echo "  2) 检查节点列表，type 为 xray / sing-box / brook 等的老节点已无法编辑，建议删掉"
echo "  3) 启用服务: /etc/init.d/passwall enable && /etc/init.d/passwall start"
echo "  4) 看日志:   tail -f /tmp/log/passwall.log"
echo
echo "回滚："
echo "  opkg remove luci-app-passwall --force-depends"
echo "  cp $BK/passwall.config /etc/config/passwall"
echo "  opkg install <旧版 ipk>   # 或从备份的 pkgs-before.txt 对照"
