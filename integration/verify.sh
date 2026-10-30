#!/bin/sh
# ============================================================================
# 校验 PassWall 是否真的会被编进固件
#
# 用法（在你的 OpenWrt / ImmortalWrt 源码根目录里跑）：
#   sh /path/to/integration/verify.sh
#   sh /path/to/integration/verify.sh /path/to/immortalwrt
#
# 前置：已经跑过 `make defconfig`（需要 tmp/.packageinfo）。
#
# 这个脚本查的不是「配置里写了没有」，而是「包到底会不会进镜像」。
# 两者不是一回事，最典型的就是同名遮蔽：
#   ImmortalWrt / OpenWrt 的 feeds 里自带 luci-app-passwall 和 hysteria，
#   feeds install -a 按 feeds.conf 顺序装，官方在前 → 官方版本先装先赢，
#   你的版本根本不进 package/feeds/，但 .config 里照样有 CONFIG_PACKAGE_xxx=y。
# ============================================================================

set -u

TREE="${1:-.}"
cd "$TREE" 2>/dev/null || { echo "!! 进不去目录：$TREE"; exit 1; }

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; }

echo "============================================================"
echo " PassWall 集成校验"
echo " 源码树：$(pwd)"
echo "============================================================"

# ---------------------------------------------------------------- 0. 前置
echo
echo "[0] 前置检查"
if [ ! -f .config ]; then
	bad ".config 不存在，先跑 make defconfig"
	exit 1
fi
ok ".config 存在"

if [ ! -f tmp/.packageinfo ]; then
	bad "tmp/.packageinfo 不存在 —— 还没跑 make defconfig"
	echo "     先执行：make defconfig"
	exit 1
fi
ok "tmp/.packageinfo 存在（defconfig 跑过了）"

# ---------------------------------------------------------------- 1. feed
echo
echo "[1] feed 是否装上（按源包名查，子包不算）"
for p in luci-app-passwall shadowsocks-c hysteria dns2tcp chinadns-ng ipt2socks; do
	if find -L package/feeds -maxdepth 2 -name "$p" 2>/dev/null | grep -q .; then
		ok "$p"
	else
		bad "$p 不在 package/feeds/ —— feeds.conf 加了吗？feeds install 跑了吗？"
	fi
done
echo "     （shadowsocks-libev-ss-* 是 shadowsocks-c 的子包，不单独出现在这里）"

# ---------------------------------------------------------------- 2. 同名遮蔽
echo
echo "[2] 同名遮蔽（ImmortalWrt/OpenWrt 自带 passwall 时的头号坑）"
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
		bad "$p 来自 $matches —— 被同名遮蔽了，不是我们的版本"
		echo "        修法：./scripts/feeds uninstall $p && ./scripts/feeds install -p p455w4ll $p"
	fi
done

# ---------------------------------------------------------------- 3. 必需包
echo
echo "[3] 必需包（.config 选中 + 构建系统认识）"
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
	if ! grep -qx "CONFIG_PACKAGE_$p=y" .config; then
		bad "$p —— .config 里没选中"
	elif ! grep -qx "Package: $p" tmp/.packageinfo; then
		bad "$p —— .config 里有，但构建系统不认识（悬空符号，不会进镜像）"
	else
		ok "$p"
	fi
done

# ---------------------------------------------------------------- 4. 透明代理
echo
echo "[4] 透明代理开关"
if grep -qx "CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y" .config; then
	ok "Nftables_Transparent_Proxy=y（24.10 默认 firewall4）"
elif grep -qx "CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=y" .config; then
	warn "用的是 Iptables_Transparent_Proxy —— 只有没有 nftables 的老芯片才该这样"
	PASS=$((PASS + 1))
else
	bad "两个 Transparent_Proxy 都没开 —— PassWall 装上但转发不了流量"
fi

# ---------------------------------------------------------------- 5. dnsmasq
echo
echo "[5] dnsmasq 冲突"
if grep -qx "CONFIG_PACKAGE_dnsmasq-full=y" .config && grep -qx "CONFIG_PACKAGE_dnsmasq=y" .config; then
	bad "dnsmasq 和 dnsmasq-full 同时选中 —— 镜像构建会在 check_data_file_clashes 处失败"
	echo "        修法：在 .config 里加 CONFIG_PACKAGE_dnsmasq=n"
elif grep -qx "CONFIG_PACKAGE_dnsmasq-full=y" .config; then
	ok "只有 dnsmasq-full（带 ipset/nftset 支持）"
else
	bad "dnsmasq-full 没选中 —— PassWall 的域名分流依赖它的 nftset 支持"
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
			echo "        修法：./scripts/feeds uninstall hysteria && ./scripts/feeds install -p p455w4ll hysteria"
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
	echo "        表现：镜像构建时 Configuring luci-app-passwall 之后 opkg 只报 Error 255，无其他信息"
	echo "        修法：find -L feeds/p455w4ll -type f -exec sed -i 's/\r\$//' {} +"
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
printf ' 通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
	echo " => 可以开始 make 了"
	echo "============================================================"
	exit 0
else
	echo " => 有 $FAIL 项没通过，先修掉再编，否则会编出一个没有（或不是你的）PassWall 的镜像"
	echo "============================================================"
	exit 1
fi
