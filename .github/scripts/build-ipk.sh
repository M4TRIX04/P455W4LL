#!/bin/sh
# ============================================================================
# 一键构建：OpenWrt SDK + luci-app-passwall + vendor 包
#
# 用法：
#   ./build.sh [工作目录]              默认 /build
#
# 环境变量：
#   SDK_VERSION=24.10.8                SDK 版本
#   SDK_TARGET=x86/64                  目标平台（target/subtarget）
#   SDK_FILE=<文件名>                  手动指定 SDK 文件名（一般不用，会自动发现）
#   PASSWALL_SRC=/path                 指定 luci-app-passwall 源码目录
#   JOBS=8                             并行度，默认 nproc
#   BUILD_VERBOSE=1                    打印完整编译日志（V=s）
#   KEEP_BUILD=1                       保留 build_dir（默认保留，增量快）
#
# 产物：$WORK/out/*.ipk
#
# 依赖：wget 或 curl、tar（24.10 的 SDK 是 zstd 压缩，需要 zstd）、make、gcc、git
# ============================================================================

set -eu

WORK="${1:-/build}"
SDK_VERSION="${SDK_VERSION:-24.10.8}"
SDK_TARGET="${SDK_TARGET:-x86/64}"
SDK_FILE="${SDK_FILE:-}"
BUILD_VERBOSE="${BUILD_VERBOSE:-0}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

SDK_BASE="https://downloads.openwrt.org/releases/${SDK_VERSION}/targets/${SDK_TARGET}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# 仓库根目录：包目录（shadowsocks-c / hysteria / dns2tcp / luci-app-passwall）都在根下
ROOT="$(cd "$HERE/../.." && pwd)"

# 期望产出的包数，用于最后断言。加包时记得改这里。
EXPECT_PKGS=12

START_TS=$(date +%s)
MARK_TS=$START_TS
log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# 每个阶段结束时打一行耗时。CI 日志里能直接看出时间花在哪一步，
# 不用靠猜是「缓存没命中」还是「runner 慢」。
mark() {
	_now=$(date +%s)
	printf '    ↳ 本阶段 %d 分 %02d 秒（累计 %d 分 %02d 秒）\n' \
		$(( (_now - MARK_TS) / 60 )) $(( (_now - MARK_TS) % 60 )) \
		$(( (_now - START_TS) / 60 )) $(( (_now - START_TS) % 60 ))
	MARK_TS=$_now
}

# 优先 curl，其次 wget
fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1"
	else
		wget -qO- "$1"
	fi
}
download() {
	if command -v curl >/dev/null 2>&1; then
		curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
	else
		wget -q --tries=3 -O "$2" "$1"
	fi
}

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. SDK
# 用 sdk/scripts/feeds 当哨兵，而不是 sdk 目录本身 ——
# CI 里可能只恢复了缓存的 sdk/feeds，目录存在但 SDK 不完整。
if [ ! -f sdk/scripts/feeds ]; then
	log "下载 SDK ${SDK_VERSION} (${SDK_TARGET})"

	if [ -n "$SDK_FILE" ]; then
		F="$SDK_FILE"
	else
		F=$(fetch "$SDK_BASE/" | grep -oE "openwrt-sdk-${SDK_VERSION}-[^\"<]*\.tar\.(zst|xz)" | head -1)
	fi
	[ -n "$F" ] || die "在 ${SDK_BASE}/ 下找不到 SDK 文件名。检查 SDK_VERSION / SDK_TARGET，或用 SDK_FILE=... 指定"

	echo "   文件：$F"
	[ -f "$F" ] || download "$SDK_BASE/$F" "$F"
	mkdir -p sdk
	case "$F" in
		*.zst) tar --zstd -xf "$F" -C sdk --strip-components=1 ;;
		*)     tar -xJf   "$F" -C sdk --strip-components=1 ;;
	esac
	[ -f sdk/scripts/feeds ] || die "SDK 解压后没有 scripts/feeds，压缩包可能损坏"
else
	log "复用已有 SDK（sdk/scripts/feeds 存在）"
fi
cd sdk
mark

# ---------------------------------------------------------------- 2. feeds
# 必须包含 base feed —— SDK 的基础包（lua/ucode/libnl-tiny）来自它，不在 package/ 里
if [ ! -d feeds/luci ]; then
	log "配置并拉取 feeds"
	cp feeds.conf.default feeds.conf
	sed -i 's|^src-git-full base|src-git base|' feeds.conf
	# routing / telephony 用不上，去掉能少拉几十个包
	sed -i '/^src-git routing /d;/^src-git telephony /d' feeds.conf
	grep -q "passwall_packages" feeds.conf || \
		echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >> feeds.conf
	./scripts/feeds update -a
else
	log "复用已有 feeds（跳过 update）"
fi

# install 单独判断：CI 缓存可能只恢复了 feeds/ 而没恢复 package/feeds/ 的符号链接
if [ ! -d package/feeds/luci ]; then
	log "安装 feeds 到 package/"
	./scripts/feeds install -a
fi

# feed 里的 hysteria 是 v2，和 vendor 的 v1 同名冲突，必须先卸掉
./scripts/feeds uninstall hysteria >/dev/null 2>&1 || true

# 关于同名包：官方编译说明会先 rm 掉 feeds/packages/net/{microsocks,...} 再
# clone 整个 passwall-packages 仓库，因为整仓导入会和官方 feed 的同名包打架。
# 我们只 vendor 三个包、依赖直接用 feed 里的，所以不需要删 ——
# microsocks 官方 feed 里就有，且是同一个上游项目（1.0.5），直接用即可，
# 编译路径是 package/feeds/packages/microsocks（不是 passwall_packages）。

mark

# ---------------------------------------------------------------- 3. vendor
log "放入 vendor 包"
for d in shadowsocks-c hysteria dns2tcp; do
	rm -rf "package/$d"
	cp -r "$ROOT/$d" "package/$d"
done

SRC_PW="${PASSWALL_SRC:-$ROOT/luci-app-passwall}"
if [ -d "$SRC_PW" ]; then
	log "放入 luci-app-passwall（$SRC_PW）"
	rm -rf package/luci-app-passwall
	cp -r "$SRC_PW" package/luci-app-passwall
	# Windows 工作区是 CRLF，直接编会破坏 Makefile 和脚本
	find package/luci-app-passwall -type f -exec sed -i 's/\r$//' {} +
	# Windows 上 git 不保留可执行位，这里补回来（仓库里索引已修成 100755）
	chmod 755 package/luci-app-passwall/root/etc/init.d/* \
		package/luci-app-passwall/root/etc/hotplug.d/iface/* \
		package/luci-app-passwall/root/etc/uci-defaults/* \
		package/luci-app-passwall/root/usr/share/passwall/*.sh 2>/dev/null || true
else
	die "找不到 luci-app-passwall 源码：$SRC_PW"
fi

mark

# ---------------------------------------------------------------- 4. 配置
log "生成 .config"
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_PACKAGE_luci-app-passwall=m
CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=n
CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Brook=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Haproxy=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Hysteria=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_NaiveProxy=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_GO=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Trojan_Plus=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_tuic_client=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=n
CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray_Plugin=n
EOF
# defconfig 可能因为上游 kconfig 循环依赖报错，不阻塞，后面直接选包
make defconfig >/dev/null 2>&1 || true

# 直接选中需要的包。
# 不走 INCLUDE_Shadowsocks_Libev_* 那两个开关，是因为上游 feed 里
# luci-app-passwall → sing-box-tiny → sing-box → luci-app-passwall 存在 kconfig
# 循环依赖，会让 make defconfig 放弃处理、把 INCLUDE 选项打回 not set。
# 直接选包效果一样：PassWall 运行时只认 /usr/bin 下有没有对应二进制。
cat >> .config <<'EOF'
CONFIG_PACKAGE_shadowsocks-libev-ss-local=m
CONFIG_PACKAGE_shadowsocks-libev-ss-redir=m
CONFIG_PACKAGE_shadowsocks-libev-ss-server=m
CONFIG_PACKAGE_shadowsocks-libev-ss-tunnel=m
CONFIG_PACKAGE_shadowsocks-libev-ss-manager=m
CONFIG_PACKAGE_hysteria=m
CONFIG_PACKAGE_dns2tcp=m
EOF

mark

# ---------------------------------------------------------------- 5. 编译
V=""
[ "$BUILD_VERBOSE" = "1" ] && V="V=s"

# 不能直接用 `make package/compile` —— 那会把 SDK 默认选中的全部基础包
# （base-files、grub2、mac80211 …）都拉进来，其中 base-files 在 SDK 里会构建失败。
# 这里按依赖顺序定向编译：先补 luci-base 需要的三个基础库，再编本包和 vendor 包。
log "编译基础库（-j$JOBS）"
for p in lua ucode libnl-tiny; do
	if [ -d "package/feeds/base/$p" ]; then
		echo "--> $p"
		make "package/feeds/base/$p/compile" -j"$JOBS" $V
	fi
done
mark

log "编译主包与 vendor 包"
for p in luci-app-passwall shadowsocks-c hysteria dns2tcp; do
	echo "--> $p"
	make "package/$p/compile" -j"$JOBS" $V
done
mark

log "编译运行时依赖"
for p in chinadns-ng dns2socks tcping; do
	echo "--> $p"
	make "package/feeds/passwall_packages/$p/compile" -j"$JOBS" $V
done
# microsocks 官方 packages feed 里也有，feeds install 装的是官方那个
echo "--> microsocks"
make "package/feeds/packages/microsocks/compile" -j"$JOBS" $V
mark

# ---------------------------------------------------------------- 6. 收集
log "收集产物"
rm -rf "$WORK/out"
mkdir -p "$WORK/out"
find bin/packages \( \
	-name "luci-app-passwall*.ipk" -o \
	-name "shadowsocks-libev-ss-*.ipk" -o \
	-name "hysteria_*.ipk" -o \
	-name "dns2tcp_*.ipk" -o \
	-name "chinadns-ng_*.ipk" -o \
	-name "dns2socks_*.ipk" -o \
	-name "microsocks_*.ipk" -o \
	-name "tcping_*.ipk" \
	\) -exec cp -f {} "$WORK/out/" \;

N=$(find "$WORK/out" -name '*.ipk' | wc -l)
ls -lh "$WORK/out"
mark

if [ "$N" -ne "$EXPECT_PKGS" ]; then
	die "产物数量不对：期望 $EXPECT_PKGS 个，实际 $N 个。缺包说明某个 make 步骤没产出，检查上面的日志。"
fi

ELAPSED=$(( $(date +%s) - START_TS ))
cat <<EON

==> 完成：$WORK/out（$N 个包，耗时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒）

  装到设备上：
    opkg install *.ipk

  上面这批覆盖了官方源里没有的包。剩下这些依赖由设备自己的软件源提供：
    libc coreutils coreutils-base64 coreutils-nohup curl ip-full libuci-lua lua
    luci-compat luci-lib-jsonc resolveip unzip luci-lua-runtime
    以及运行时共享库：libuv libcares libsodium libmbedtls libstdcpp

  注意：ipk 架构必须和设备一致（当前 SDK_TARGET=$SDK_TARGET）。
EON
