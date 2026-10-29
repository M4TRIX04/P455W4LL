#!/bin/sh
# 一键构建：OpenWrt SDK + luci-app-passwall + vendor 包
#
# 用法：
#   ./build.sh [工作目录]      默认 /build
#
# 产物：$WORK/out/*.ipk
#
# 依赖：wget、tar（24.10 的 SDK 是 zstd 压缩，需要 zstd）、make、gcc、git

set -e

WORK="${1:-/build}"
SDK_VER="24.10.8"
# 默认 x86/64，换设备时用环境变量覆盖，例如：
#   SDK_TARGET=ramips/mt7621 SDK_FILE=openwrt-sdk-24.10.8-ramips-mt7621_gcc-13.3.0_musl_eabi.Linux-x86_64.tar.zst ./build.sh
SDK_TARGET="${SDK_TARGET:-x86/64}"
SDK_FILE="${SDK_FILE:-}"
SDK_BASE="https://downloads.openwrt.org/releases/${SDK_VER}/targets/${SDK_TARGET}"
HERE="$(cd "$(dirname "$0")" && pwd)"
JOBS="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$WORK"
cd "$WORK"

# ---------------------------------------------------------------- 1. SDK
if [ ! -d sdk ]; then
	echo "==> 下载 SDK ${SDK_VER} (${SDK_TARGET})"
	if [ -n "$SDK_FILE" ]; then
		F="$SDK_FILE"
	else
		F=$(wget -qO- "$SDK_BASE/" | grep -oE "openwrt-sdk-${SDK_VER}-[^\"<]*\.tar\.(zst|xz)" | head -1)
	fi
	[ -n "$F" ] || { echo "找不到 SDK 文件名，请用 SDK_FILE=... 指定"; exit 1; }
	wget -q "$SDK_BASE/$F" -O "$F"
	mkdir -p sdk
	case "$F" in
		*.zst) tar --zstd -xf "$F" -C sdk --strip-components=1 ;;
		*)     tar -xJf   "$F" -C sdk --strip-components=1 ;;
	esac
fi
cd sdk

# ---------------------------------------------------------------- 2. feeds
# 必须包含 base feed —— SDK 的基础包（lua/ucode/libnl-tiny）来自它，不在 package/ 里
if [ ! -d feeds/luci ]; then
	echo "==> 配置 feeds"
	cp feeds.conf.default feeds.conf
	sed -i 's|^src-git-full base|src-git base|' feeds.conf
	# 只要 base/packages/luci 三个 feed，routing/telephony 用不上，
	# 去掉能少编译几十个包
	sed -i '/^src-git routing /d;/^src-git telephony /d' feeds.conf
	grep -q "passwall_packages" feeds.conf || \
		echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >> feeds.conf
	./scripts/feeds update -a
	./scripts/feeds install -a
fi

# feed 里的 hysteria 是 v2，和 vendor 的 v1 同名冲突，必须先卸掉
./scripts/feeds uninstall hysteria 2>/dev/null || true

# ---------------------------------------------------------------- 3. vendor
echo "==> 放入 vendor 包"
for d in shadowsocks-c hysteria dns2tcp; do
	rm -rf "package/$d"
	cp -r "$HERE/$d" "package/$d"
done

# luci-app-passwall 本体：默认取 vendor 的同级目录
SRC_PW="${PASSWALL_SRC:-$HERE/../luci-app-passwall}"
if [ -d "$SRC_PW" ]; then
	echo "==> 放入 luci-app-passwall（$SRC_PW）"
	rm -rf package/luci-app-passwall
	cp -r "$SRC_PW" package/luci-app-passwall
	# Windows 工作区是 CRLF，直接编会破坏 Makefile 和脚本
	find package/luci-app-passwall -type f -exec sed -i 's/\r$//' {} +
	# Windows 上 git 不保留可执行位，这里补回来（仓库里索引已修成 100755）
	chmod 755 package/luci-app-passwall/root/etc/init.d/* \
		package/luci-app-passwall/root/etc/hotplug.d/iface/* \
		package/luci-app-passwall/root/etc/uci-defaults/* \
		package/luci-app-passwall/root/usr/share/passwall/*.sh 2>/dev/null || true
fi

# ---------------------------------------------------------------- 4. 配置
echo "==> 生成 .config"
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

# ---------------------------------------------------------------- 5. 编译
# 不能直接用 `make package/compile` —— 那会把 SDK 默认选中的全部基础包
# （base-files、grub2、mac80211 …）都拉进来，其中 base-files 在 SDK 里会构建失败。
# 这里按依赖顺序定向编译：先补 luci-base 需要的三个基础库，再编本包和 vendor 包。
echo "==> 开始编译（-j$JOBS）"
for p in lua ucode libnl-tiny; do
	echo "--> $p"
	make "package/feeds/base/$p/compile" -j"$JOBS" || true
done

for p in luci-app-passwall shadowsocks-c hysteria dns2tcp; do
	echo "--> $p"
	make "package/$p/compile" -j"$JOBS"
done

# 运行时依赖：官方源里没有，设备上必须和上面的包一起装，
# 否则 opkg 报依赖不满足
for p in chinadns-ng dns2socks tcping; do
	echo "--> $p (依赖)"
	make "package/feeds/passwall_packages/$p/compile" -j"$JOBS"
done
# microsocks 官方 packages feed 里也有，feeds install 装的是官方那个
echo "--> microsocks (依赖)"
make "package/feeds/packages/microsocks/compile" -j"$JOBS"

# ---------------------------------------------------------------- 6. 收集
echo "==> 收集产物"
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
ls -lh "$WORK/out"

cat <<'EON'

==> 装到设备上：
  opkg install *.ipk

  上面这批覆盖了官方源里没有的包。剩下这些依赖由设备自己的软件源提供：
  libc coreutils coreutils-base64 coreutils-nohup curl ip-full libuci-lua lua
  luci-compat luci-lib-jsonc resolveip unzip luci-lua-runtime
  以及运行时的共享库：libuv libcares libsodium libmbedtls libstdcpp

  注意：ipk 的架构必须和设备一致（当前 SDK_TARGET=$SDK_TARGET）。
EON
echo "==> 完成：$WORK/out"
