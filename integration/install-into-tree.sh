#!/bin/sh
# ============================================================================
# 把 PassWall 和它的依赖装进你的 ImmortalWrt / OpenWrt 源码树
#
# 只做一件事：让包出现在 `make menuconfig` 里。
# **不改 .config、不跑 defconfig** —— 选什么是你自己的事。
#
# 用法（在你 ImmortalWrt 源码根目录）：
#   sh /path/to/P455W4LL/integration/install-into-tree.sh
#
# 环境变量：
#   FEED_REPO   本仓库地址，默认 GitHub
#   FEED_REF    分支，默认 main
#   FEED_LOCAL  用本地目录代替 GitHub（开发时用，会复制到 /tmp 再归一化，不动你的工作树）
#
# 可以重复执行，幂等。
# ============================================================================

set -eu

FEED_REPO="${FEED_REPO:-https://github.com/M4TRIX04/P455W4LL.git}"
FEED_REF="${FEED_REF:-main}"
FEED_LOCAL="${FEED_LOCAL:-}"
FEED_STAGE="${FEED_STAGE:-/tmp/p455w4ll-feed}"
TREE="${1:-.}"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

cd "$TREE" || die "进不去目录：$TREE"

# ---------------------------------------------------------------- 0. 确认
say "检查源码树"
[ -f scripts/feeds ]      || die "这里不像 OpenWrt/ImmortalWrt 源码树（找不到 scripts/feeds）"
[ -f feeds.conf.default ] || die "找不到 feeds.conf.default"
[ -f Makefile ]           || die "找不到 Makefile"
echo "   $(pwd)"
if grep -q "immortalwrt" feeds.conf.default 2>/dev/null; then
	echo "   检测到 ImmortalWrt"
else
	echo "   检测到 OpenWrt（或自定义源码树）"
fi

# ---------------------------------------------------------------- 1. feeds.conf
say "配置 feeds"
[ -f feeds.conf ] || cp feeds.conf.default feeds.conf

if [ -n "$FEED_LOCAL" ]; then
	# 复制到源码树外面再归一化，避免 sed 改到你的工作树
	rm -rf "$FEED_STAGE"
	mkdir -p "$FEED_STAGE"
	cp -a "$FEED_LOCAL/." "$FEED_STAGE/" 2>/dev/null || cp -r "$FEED_LOCAL/." "$FEED_STAGE/"
	rm -rf "$FEED_STAGE/.git"
	FEED_LINE="src-link p455w4ll $FEED_STAGE"
	echo "   本地模式：$FEED_LOCAL → $FEED_STAGE"
else
	FEED_LINE="src-git p455w4ll $FEED_REPO;$FEED_REF"
	echo "   远程模式：$FEED_REPO;$FEED_REF"
fi

if grep -qE "^src-(git|link) p455w4ll " feeds.conf; then
	echo "   p455w4ll 已在 feeds.conf 里，跳过"
else
	echo "$FEED_LINE" >> feeds.conf
	echo "   + $FEED_LINE"
fi

# 上游二进制 feed：chinadns-ng / dns2socks / tcping / ipt2socks
# ImmortalWrt 的 packages feed 里其实都有，但原版 OpenWrt 没有，加上能通用
if grep -qE "^src-(git|link) passwall_packages " feeds.conf; then
	echo "   passwall_packages 已在 feeds.conf 里，跳过"
else
	echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >> feeds.conf
	echo "   + passwall_packages"
fi

# ---------------------------------------------------------------- 2. 拉取
say "feeds update（首次较慢，要克隆几个仓库）"
./scripts/feeds update -a > /dev/null

say "feeds install"
./scripts/feeds install -a > /dev/null 2>&1 || true

# ---------------------------------------------------------------- 3. 同名遮蔽
# ImmortalWrt / OpenWrt 的 feeds 里自带 luci-app-passwall（ImmortalWrt 24.10 是
# 25.12.16）和 hysteria（v2）。feeds install 按 feeds.conf 顺序装、先装先赢，
# 官方在前 → 你的版本根本不进 package/feeds/，但 .config 里照样有符号，
# 编译不报错，最后镜像里是官方的版本。
#
# 这就是上游 README 里那段 rm -rf feeds/packages/net/{...} 的真正原因。
say "处理同名遮蔽"
SHADOWED=""
for p in luci-app-passwall hysteria dns2tcp; do
	cur=$(ls -d package/feeds/*/"$p" 2>/dev/null | head -1 || true)
	if [ -n "$cur" ] && ! printf '%s' "$cur" | grep -q "/p455w4ll/"; then
		SHADOWED="$SHADOWED $p"
	fi
done

if [ -z "$SHADOWED" ]; then
	echo "   没有被遮蔽的包"
else
	echo "   被遮蔽：$SHADOWED"
	# 顺序很重要：先 uninstall（此时源目录还在，符号链接能正常解析），
	# 再删源目录（防止以后 feeds install -a 又装回来），最后从本仓库装。
	# 反过来做会让符号链接先变悬空，feeds uninstall 处理不了它。
	./scripts/feeds uninstall $SHADOWED 2>&1 | sed 's/^/     /' || true
	rm -rf feeds/luci/applications/luci-app-passwall
	rm -rf feeds/packages/net/hysteria feeds/packages/net/dns2tcp
	./scripts/feeds install -p p455w4ll $SHADOWED 2>&1 | sed 's/^/     /'
	echo "   已替换为本仓库版本"
fi

# ---------------------------------------------------------------- 4. 归一化
# CRLF 会让 /etc/init.d/passwall 的 shebang 变成 "#!/bin/sh /etc/rc.common\r"，
# rc.common 完全无法解析。失败发生在镜像构建的 Configuring luci-app-passwall
# 之后，opkg 只给 Error 255，不打任何有用信息。
say "归一化换行符与可执行位"
if [ -d feeds/p455w4ll ]; then
	find -L feeds/p455w4ll -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
	chmod 755 feeds/p455w4ll/root/etc/init.d/* \
		feeds/p455w4ll/root/etc/hotplug.d/iface/* \
		feeds/p455w4ll/root/etc/uci-defaults/* \
		feeds/p455w4ll/root/usr/share/passwall/*.sh 2>/dev/null || true
	echo "   完成"
else
	echo "   !! feeds/p455w4ll 不存在，feed 可能没拉下来"
fi

# ---------------------------------------------------------------- 5. 结果
say "确认包已就位"
BAD=0
for p in luci-app-passwall shadowsocks-c hysteria dns2tcp; do
	# 必须确认来自本仓库，不能只看「装上了」
	matches=$(ls -d package/feeds/*/"$p" 2>/dev/null || true)
	n=$(printf '%s\n' "$matches" | grep -c . 2>/dev/null || echo 0)
	if [ "$n" -eq 0 ]; then
		printf '   \033[31mFAIL\033[0m %-20s 没装进来\n' "$p"
		BAD=$((BAD + 1))
	elif [ "$n" -gt 1 ]; then
		printf '   \033[31mFAIL\033[0m %-20s 装了 %s 份\n' "$p" "$n"
		BAD=$((BAD + 1))
	elif printf '%s' "$matches" | grep -q "/p455w4ll/"; then
		ver=$(sed -n 's/^PKG_VERSION:=//p' "$matches/Makefile" 2>/dev/null | head -1 | tr -d '\r')
		printf '   \033[32mOK\033[0m   %-20s %s  (%s)\n' "$p" "$matches" "${ver:-?}"
	else
		printf '   \033[31mFAIL\033[0m %-20s 来自 %s，不是本仓库\n' "$p" "$matches"
		BAD=$((BAD + 1))
	fi
done

if [ "$BAD" -gt 0 ]; then
	die "有 $BAD 个包没到位，见上面的 FAIL"
fi

cat <<'EON'

============================================================
 完成。现在去 menuconfig 里选：

   make menuconfig

   LuCI
   └── 3. Applications
       └── <*> luci-app-passwall

 选中它之后，同级菜单里会出现子选项：

   [*] Nftables Transparent Proxy      ← 24.10 必须开
   [ ] Iptables Transparent Proxy      ← 只在没有 nftables 的老芯片上开

 然后进 3. Applications 里的其它子菜单，挑你需要的 LuCI 应用。

 协议二进制要单独选（别用 Include XXX 开关，那些有 kconfig 循环依赖）：
   LuCI → 3. Applications → <*> shadowsocks-libev-ss-local
                            <*> shadowsocks-libev-ss-redir
                            <*> shadowsocks-libev-ss-server
                            <*> hysteria

 或者直接把这些行追加到 .config 省得手点：
   cat integration/passwall.config >> .config

 选完跑一次校验（可选但强烈建议）：
   sh integration/verify.sh

 它会检查同名遮蔽、hysteria 版本、CRLF、dnsmasq 冲突这些
 光看 menuconfig 看不出来的问题。
============================================================
EON
