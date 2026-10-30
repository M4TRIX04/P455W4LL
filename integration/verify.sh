#!/bin/sh
# ============================================================================
# 校验 PassWall 集成是否正常
#
# 用法（在你的 OpenWrt / ImmortalWrt 源码根目录）：
#   sh verify.sh                 默认宽松模式：只查集成问题，不要求你已选中
#   sh verify.sh --strict        严格模式：还要求 15 个必需包都被选中
#   sh verify.sh /path/to/tree   指定源码树
#
# 宽松模式适合「包刚放进去、还没在 menuconfig 里选」的时候。
# 严格模式适合编译前把关，或者放进 CI。
#
# 这个脚本查的不是「配置里写了没有」，而是「包到底会不会进镜像」。
# 两者不是一回事，最典型的是同名遮蔽：ImmortalWrt 自带 luci-app-passwall，
# feeds install 先装先赢，你的版本根本不进 package/feeds/，
# 但 .config 里照样有 CONFIG_PACKAGE_xxx=y，编译也不报错。
# ============================================================================

set -u

MODE=lenient
TREE=.
for arg in "$@"; do
	case "$arg" in
		--strict) MODE=strict ;;
		*)        TREE="$arg" ;;
	esac
done

cd "$TREE" 2>/dev/null || { echo "!! 进不去目录：$TREE"; exit 1; }

PASS=0
FAIL=0
SKIP=0

ok()  { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; }
skip(){ SKIP=$((SKIP + 1)); printf '  \033[90m--\033[0m   %s\n' "$1"; }

selected() { grep -qx "CONFIG_PACKAGE_$1=y" .config 2>/dev/null; }

echo "============================================================"
echo " PassWall 集成校验（$MODE 模式）"
echo " 源码树：$(pwd)"
echo "============================================================"

# ---------------------------------------------------------------- 0. 前置
echo
echo "[0] 前置检查"
if [ ! -f .config ]; then
	bad ".config 不存在 —— 先跑 make menuconfig 或 make defconfig"
	exit 1
fi
ok ".config 存在"

if [ ! -f tmp/.packageinfo ]; then
	bad "tmp/.packageinfo 不存在 —— 先跑一次 make defconfig（menuconfig 保存时会自动生成）"
	exit 1
fi
ok "tmp/.packageinfo 存在"

# ---------------------------------------------------------------- 1. feed
echo
echo "[1] feed 是否装上（按源包名查，子包不算）"
for p in luci-app-passwall shadowsocks-c hysteria dns2tcp chinadns-ng ipt2socks; do
	if find -L package/feeds -maxdepth 2 -name "$p" 2>/dev/null | grep -q .; then
		ok "$p"
	else
		bad "$p 不在 package/feeds/ —— 跑过 install-into-tree.sh 吗？"
	fi
done
echo "     （shadowsocks-libev-ss-* 是 shadowsocks-c 的子包，不单独出现在这里）"

# ---------------------------------------------------------------- 2. 同名遮蔽
echo
echo "[2] 同名遮蔽（ImmortalWrt 自带 passwall 时的头号坑）"
for p in luci-app-passwall hysteria dns2tcp; do
	matches=$(ls -d package/feeds/*/"$p" 2>/dev/null)
	n=$(printf '%s\n' "$matches" | grep -c . 2>/dev/null || echo 0)
	if [ "$n" -eq 0 ]; then
		bad "$p 未安装"
	elif [ "$n" -gt 1 ]; then
		bad "$p 装了 $n 份 —— 官方 feed 和本仓库同时存在，会打架"
		echo "        现有：$(echo "$matches" | tr '\n' ' ')"
	elif printf '%s' "$matches" | grep -q "/p455w4ll/"; then
		ok "$p 来自本仓库"
	else
		bad "$p 来自 $matches —— 被同名遮蔽了，编出来不是你想要的版本"
		echo "        修法：重跑 install-into-tree.sh"
	fi
done

# ---------------------------------------------------------------- 3. 包状态
echo
echo "[3] 必需包（$( [ "$MODE" = strict ] && echo "严格模式：必须全部选中" || echo "宽松模式：未选中不算错" )）"
REQUIRED="
luci-app-passwall
shadowsocks-libev-ss-local
shadowsocks-libev-ss-redir
shadowsocks-libev-ss-server
hysteria
dns2tcp
chinadns-ng
dns2socks
microsocks
tcping
ipt2socks
dnsmasq-full
kmod-nft-tproxy
kmod-nft-socket
kmod-nft-nat
"
for p in $REQUIRED; do
	if selected "$p"; then
		if grep -qx "Package: $p" tmp/.packageinfo; then
			ok "$p"
		else
			bad "$p —— 悬空符号（.config 里有，但构建系统不认识，不会进镜像）"
		fi
	else
		if [ "$MODE" = strict ]; then
			bad "$p —— 没选中"
		else
			skip "$p 未选中"
		fi
	fi
done

# ---------------------------------------------------------------- 4. 透明代理
echo
echo "[4] 透明代理开关"
if ! selected luci-app-passwall; then
	skip "luci-app-passwall 还没选中，跳过"
elif selected luci-app-passwall_Nftables_Transparent_Proxy; then
	ok "Nftables_Transparent_Proxy（24.10 默认 firewall4）"
elif selected luci-app-passwall_Iptables_Transparent_Proxy; then
	warn "用的是 Iptables_Transparent_Proxy —— 只有没有 nftables 的老芯片才该这样"
	PASS=$((PASS + 1))
else
	bad "两个 Transparent_Proxy 都没开 —— PassWall 装上但转发不了流量"
fi

# ---------------------------------------------------------------- 5. dnsmasq
echo
echo "[5] dnsmasq 冲突"
if selected dnsmasq-full && selected dnsmasq; then
	bad "dnsmasq 和 dnsmasq-full 同时选中 —— 镜像构建会在 check_data_file_clashes 处失败"
	echo "        修法：menuconfig 里取消基础版 dnsmasq，或加 CONFIG_PACKAGE_dnsmasq=n"
elif selected dnsmasq-full; then
	ok "只有 dnsmasq-full（带 ipset/nftset 支持）"
elif selected dnsmasq; then
	bad "只有基础版 dnsmasq —— 它没有 nftset 支持，PassWall 的域名分流会失效"
else
	skip "两个都没选"
fi

# ---------------------------------------------------------------- 6. hysteria
echo
echo "[6] hysteria 版本"
HYS_MK=$(ls package/feeds/*/hysteria/Makefile 2>/dev/null | head -1)
if [ -z "$HYS_MK" ]; then
	bad "找不到 hysteria 的 Makefile"
else
	HYS_VER=$(sed -n 's/^PKG_VERSION:=//p' "$HYS_MK" | head -1 | tr -d '\r')
	case "$HYS_VER" in
		1.*) ok "hysteria $HYS_VER（v1，与 util_hysteria.lua 的配置格式配套）" ;;
		*)
			bad "hysteria $HYS_VER —— 不是 v1。v2 的配置格式与 util_hysteria.lua 不兼容"
			echo "        修法：重跑 install-into-tree.sh"
			;;
	esac
fi

# ---------------------------------------------------------------- 7. CRLF
echo
echo "[7] 换行符（CRLF 会让 init.d 静默失效）"
INIT_F=$(ls package/feeds/*/luci-app-passwall/root/etc/init.d/passwall 2>/dev/null | head -1)
if [ -z "$INIT_F" ]; then
	bad "找不到 init.d/passwall"
elif grep -q "$(printf '\r')" "$INIT_F" 2>/dev/null; then
	bad "init.d/passwall 是 CRLF —— rc.common 会完全无法解析它"
	echo "        表现：镜像构建时 Configuring luci-app-passwall 之后 opkg 只报 Error 255"
	echo "        修法：重跑 install-into-tree.sh"
else
	ok "init.d/passwall 是 LF"
fi

# ---------------------------------------------------------------- 8. 可复现性
echo
echo "[8] 可复现性"
if grep -qE "^src-git p455w4ll .*\^[0-9a-f]{7,}" feeds.conf 2>/dev/null; then
	ok "本仓库 feed 已钉到具体 commit"
elif grep -qE "^src-git p455w4ll " feeds.conf 2>/dev/null; then
	warn "本仓库 feed 跟分支（;main）—— 上游一改，你的固件内容就变"
	echo "        要复现构建就把 ;main 换成 ^<commit>"
elif grep -qE "^src-link p455w4ll " feeds.conf 2>/dev/null; then
	warn "本仓库 feed 用 src-link 指向本地目录（开发模式，不适合正式固件）"
else
	bad "feeds.conf 里没有 p455w4ll"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "============================================================"
printf ' 通过 %d 项，失败 %d 项，跳过 %d 项\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -eq 0 ]; then
	if [ "$MODE" = strict ]; then
		echo " => 可以开始 make 了"
	elif [ "$SKIP" -gt 0 ]; then
		echo " => 集成没问题，还有 $SKIP 个包等你在 menuconfig 里选"
		echo "    选完用 --strict 再跑一次，确认没有遗漏"
	else
		echo " => 可以开始 make 了"
	fi
	echo "============================================================"
	exit 0
else
	echo " => 有 $FAIL 项没通过，先修掉再编，否则会编出一个没有（或不是你的）PassWall 的镜像"
	echo "============================================================"
	exit 1
fi
