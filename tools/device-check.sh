#!/bin/sh
# ============================================================================
# PassWall 私有构建 —— 装机前只读体检
#
# 这个脚本【不修改任何文件、不重启任何服务、不安装任何包】。
# 它只做一件事：把设备现状打印出来，判断我们编的 12 个 ipk 能不能装、装了能不能跑。
#
# 用法：
#   sh device-check.sh          # 直接跑
#   sh device-check.sh > /tmp/check.txt 2>&1   # 存成文件
#
# 把输出整段贴回来即可。
# ============================================================================

# ------------------------------------------------------------------ 1. 系统
echo "========== 1. 系统信息 =========="
if [ -f /etc/openwrt_release ]; then
	. /etc/openwrt_release 2>/dev/null
	echo "发行版    : ${DISTRIB_ID:-unknown} ${DISTRIB_RELEASE:-}"
	echo "版本描述  : ${DISTRIB_DESCRIPTION:-}"
	echo "目标平台  : ${DISTRIB_TARGET:-}"
	echo "包架构    : ${DISTRIB_ARCH:-}"
else
	echo "!! /etc/openwrt_release 不存在"
fi
printf "内核      : %s\n" "$(uname -r)"
printf "CPU 架构  : %s\n" "$(uname -m)"

# ------------------------------------------------------------------ 2. opkg 架构
echo
echo "========== 2. opkg 支持的架构 =========="
if opkg print-architecture 2>/dev/null; then
	:
else
	echo "!! opkg 不可用（新版 OpenWrt 用 apk？）"
fi
echo "--- 判断：必须出现 x86_64 ---"

# ------------------------------------------------------------------ 3. soname
# 这几个 soname 是编包时链接进去的，设备上缺一个，ss-local 就起不来。
echo
echo "========== 3. 关键共享库（soname 必须完全匹配）=========="
MISS=0
for lib in libcares.so.2 libsodium.so.26 libmbedcrypto.so.16 libuv.so.1 libstdc++.so.6 libgcc_s.so.1; do
	if find /usr/lib /lib -name "$lib" 2>/dev/null | grep -q .; then
		printf "  OK    %s\n" "$lib"
	else
		printf "  MISS  %s\n" "$lib"
		MISS=$((MISS + 1))
	fi
done
[ "$MISS" -eq 0 ] && echo "  => 全部就位" || echo "  => 缺 $MISS 个，ss-local/ss-redir 会加载失败"

# ------------------------------------------------------------------ 4. 依赖包
echo
echo "========== 4. 依赖包可获取性 =========="
printf "  %-20s %s\n" "包名" "状态"
for p in libuv1 libcares libsodium libmbedtls21 libstdcpp6 \
	coreutils coreutils-base64 coreutils-nohup \
	curl ip-full resolveip tcping unzip \
	luci-compat luci-lib-jsonc lua; do
	inst=$(opkg list-installed 2>/dev/null | awk -v p="$p" '$1==p{print $3; exit}')
	avail=$(opkg list 2>/dev/null | awk -v p="$p" '$1==p{print $3; exit}')
	if [ -n "$inst" ]; then
		printf "  %-20s 已装 %s\n" "$p" "$inst"
	elif [ -n "$avail" ]; then
		printf "  %-20s 可装 %s\n" "$p" "$avail"
	else
		printf "  %-20s !! 源里没有\n" "$p"
	fi
done

# ------------------------------------------------------------------ 5. 现有 PassWall
echo
echo "========== 5. 现有 PassWall =========="
opkg list-installed 2>/dev/null | grep -i passwall || echo "  （未安装）"
echo "--- 服务状态 ---"
if /etc/init.d/passwall enabled 2>/dev/null; then echo "  开机自启: 是"; else echo "  开机自启: 否"; fi
if pgrep -f "/usr/share/passwall" >/dev/null 2>&1 || pgrep -f "passwall/bin" >/dev/null 2>&1; then
	echo "  进程    : 运行中"
else
	echo "  进程    : 未运行"
fi
echo "--- 配置文件 ---"
if [ -f /etc/config/passwall ]; then
	printf "  /etc/config/passwall  %s 字节\n" "$(wc -c < /etc/config/passwall)"
	printf "  section 数           %s\n" "$(uci show passwall 2>/dev/null | wc -l)"
	echo "  节点类型分布："
	uci show passwall 2>/dev/null | sed -n "s/^passwall\.\([^.]*\)\.type='\(.*\)'$/\2/p" | sort | uniq -c | sed 's/^/    /'
else
	echo "  /etc/config/passwall 不存在"
fi

# ------------------------------------------------------------------ 6. 磁盘
echo
echo "========== 6. 磁盘空间 =========="
df -h / /overlay /tmp 2>/dev/null | sort -u
echo "--- 本套包总大小约 8.2M，解包后约 25M ---"

# ------------------------------------------------------------------ 7. DNS 组件
echo
echo "========== 7. DNS 相关组件 =========="
opkg list-installed 2>/dev/null | grep -iE "mosdns|smartdns|dnsmasq|chinadns|dns2socks" || echo "  （无）"

# ------------------------------------------------------------------ 8. 当前 DNS 配置
echo
echo "========== 8. 当前 PassWall DNS / 代理模式 =========="
for k in dns_mode remote_dns chinadns_ng tcp_proxy_mode udp_proxy_mode use_nft; do
	v=$(uci -q get "passwall.@global[0].$k" 2>/dev/null)
	v2=$(uci -q get "passwall.@global_forwarding[0].$k" 2>/dev/null)
	printf "  %-16s %s\n" "$k" "${v:-${v2:-（未设置）}}"
done

echo
echo "========== 体检结束 =========="
