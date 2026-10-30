#!/bin/sh
# ============================================================================
# 全固件编译：OpenWrt 源码 + 本仓库 feed + .config → 固件镜像
#
# 和 vendor/build.sh 的区别：
#   vendor/build.sh   只编 ipk 包（用 SDK，10 分钟级，产物可装到任意设备）
#   firmware/build.sh 编整机固件（用 buildroot，1~2 小时，产物是本机专用镜像）
#
# 用法：
#   ./firmware/build.sh [工作目录]          默认 /build-fw
#
# 环境变量：
#   OPENWRT_VERSION=v24.10.8      OpenWrt 源码 tag
#   TARGET=x86/64                 target/subtarget
#   SEED_CONFIG=<路径>            额外追加的 .config 片段（包选择）
#   FEED_REPO=<git url>           本仓库地址，默认从 git remote 推断
#   FEED_REF=main                 feed 分支
#   FEED_LOCAL=<路径>             用本地目录代替 git（开发时用 src-link）
#   PASSWALL_PKGS_REF=main        上游 passwall 二进制 feed 的分支
#   PASSWALL_PKGS_PIN=<commit>    钉死上游 feed 到某个 commit（可复现构建）
#   JOBS=4                        并行度
#   KEEP_SRC=1                    保留源码树（默认保留，增量快）
#
# 产物：$WORK/out/（固件镜像 + sha256sums）
# ============================================================================

set -eu

WORK="${1:-/build-fw}"
OPENWRT_VERSION="${OPENWRT_VERSION:-v24.10.8}"
TARGET="${TARGET:-x86/64}"
SEED_CONFIG="${SEED_CONFIG:-}"
FEED_REPO="${FEED_REPO:-}"
FEED_REF="${FEED_REF:-main}"
FEED_LOCAL="${FEED_LOCAL:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

SRC="$WORK/openwrt"
START_TS=$(date +%s)
MARK_TS=$START_TS

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
mark() {
	_now=$(date +%s)
	printf '    ↳ 本阶段 %d 分 %02d 秒（累计 %d 分 %02d 秒）\n' \
		$(( (_now - MARK_TS) / 60 )) $(( (_now - MARK_TS) % 60 )) \
		$(( (_now - START_TS) / 60 )) $(( (_now - START_TS) % 60 ))
	MARK_TS=$_now
}

mkdir -p "$WORK"
cd "$WORK"

# 以 root 运行时，部分 host 工具（tools/tar 等）的 configure 会拒绝执行：
#   configure: error: you should not run configure as root
# GitHub 的 runner 是非 root 用户，不会遇到；本地用 Docker 构建（默认 root）会遇到。
# 这是个通用开关，非 root 环境下设置也无害。
if [ "$(id -u)" = "0" ]; then
	export FORCE_UNSAFE_CONFIGURE=1
	echo "==> 以 root 运行，已设置 FORCE_UNSAFE_CONFIGURE=1"
fi

# ---------------------------------------------------------------- 1. 源码
if [ ! -f "$SRC/Makefile" ]; then
	log "克隆 OpenWrt ${OPENWRT_VERSION}"
	rm -rf "$SRC"
	git clone --depth 1 --branch "$OPENWRT_VERSION" \
		https://github.com/openwrt/openwrt.git "$SRC"
else
	log "复用已有源码树（$SRC）"
fi
cd "$SRC"
mark

# ---------------------------------------------------------------- 2. feeds
log "配置 feeds"
# 保留 SDK/官方默认的 base/packages/luci，去掉用不上的 routing/telephony
cp feeds.conf.default feeds.conf
sed -i 's|^src-git-full |src-git |' feeds.conf
sed -i '/^src-git routing /d;/^src-git telephony /d' feeds.conf

# 本仓库作为 feed。仓库结构是 luci-app-passwall/ 在根、vendor/ 下嵌套三个包，
# 实测 OpenWrt 的扫描器会递归到 vendor/ 那一层，并把它们扁平化安装到
# package/feeds/<feed>/<pkg>，所以不需要为了当 feed 而调整目录结构。
if [ -n "$FEED_LOCAL" ]; then
	# 不直接 src-link 到源目录，先复制一份到工作区再归一化 ——
	# 否则 sed 会改到用户的工作树。而且 Windows 工作区是 CRLF，
	# CRLF 会让 /etc/init.d/* 的 shebang 失效，后果见下面 feeds update 之后那段。
	FEED_STAGE="$WORK/feed-local"
	rm -rf "$FEED_STAGE"
	mkdir -p "$FEED_STAGE"
	cp -a "$FEED_LOCAL/." "$FEED_STAGE/" 2>/dev/null || cp -r "$FEED_LOCAL/." "$FEED_STAGE/"
	rm -rf "$FEED_STAGE/.git"
	echo "src-link p455w4ll $FEED_STAGE" >> feeds.conf
	echo "   本仓库：src-link $FEED_LOCAL（已复制到 $FEED_STAGE 并归一化）"
else
	if [ -z "$FEED_REPO" ]; then
		FEED_REPO=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
	fi
	[ -n "$FEED_REPO" ] || die "无法推断 FEED_REPO，请显式指定"
	echo "src-git p455w4ll $FEED_REPO;$FEED_REF" >> feeds.conf
	echo "   本仓库：src-git $FEED_REPO;$FEED_REF"
fi

# 上游 passwall 二进制 feed。提供 chinadns-ng / dns2socks / tcping / ipt2socks
# 这四个 —— 官方 openwrt/packages 里都没有，而它们是 luci-app-passwall 的
# 硬依赖（LUCI_DEPENDS + Nftables_Transparent_Proxy 的 select），缺一个就装不上。
#
# 默认跟 main；要可复现构建就设 PASSWALL_PKGS_PIN=<commit>，会改用 ^commit 语法钉死。
if [ -n "${PASSWALL_PKGS_PIN:-}" ]; then
	echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git^$PASSWALL_PKGS_PIN" >> feeds.conf
	echo "   passwall feed：钉在 $PASSWALL_PKGS_PIN"
else
	echo "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;${PASSWALL_PKGS_REF:-main}" >> feeds.conf
	echo "   passwall feed：跟 ${PASSWALL_PKGS_REF:-main}"
fi

./scripts/feeds update -a

# 归一化本仓库 feed 的换行符与可执行位。
#
# CRLF 是这套东西里最阴的坑：/etc/init.d/passwall 首行会变成
#   #!/bin/sh /etc/rc.common\r
# 那个 \r 让 rc.common 完全无法解析脚本。而失败发生在镜像构建的
# 「Configuring luci-app-passwall」之后，opkg 只报一个 Error 255，
# 不打任何有用信息 —— 我从头到尾翻日志才定位到是换行符。
#
# CI 从 GitHub clone 出来是 LF（.gitattributes 保证），但本地 FEED_LOCAL
# 指向 Windows 工作区时是 CRLF。这里统一处理，两种情况都安全。
if [ -d feeds/p455w4ll ]; then
	find -L feeds/p455w4ll -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
	chmod 755 feeds/p455w4ll/root/etc/init.d/* \
		feeds/p455w4ll/root/etc/hotplug.d/iface/* \
		feeds/p455w4ll/root/etc/uci-defaults/* \
		feeds/p455w4ll/root/usr/share/passwall/*.sh 2>/dev/null || true
fi

./scripts/feeds install -a

# hysteria 两个 feed 都有：本仓库的是 v1（与 util_hysteria.lua 的配置格式配套），
# passwall_packages 里是 v2。feeds install 是「谁先装谁赢」，靠 feeds.conf 的
# 书写顺序保证太脆 —— 这里显式指定，确保拿到 v1。
./scripts/feeds uninstall hysteria >/dev/null 2>&1 || true
./scripts/feeds install -p p455w4ll hysteria >/dev/null 2>&1 || true
mark

# ---------------------------------------------------------------- 3. .config
log "生成 .config（target=${TARGET}）"
board="${TARGET%%/*}"
sub="${TARGET##*/}"

# target 部分由脚本生成，避免每个 config 文件都重复写
cat > .config <<EOF
CONFIG_TARGET_${board}=y
CONFIG_TARGET_${board}_${sub}=y
CONFIG_TARGET_MULTI_PROFILE=n
EOF

if [ -n "$SEED_CONFIG" ]; then
	[ -f "$SEED_CONFIG" ] || die "找不到 SEED_CONFIG：$SEED_CONFIG"
	echo "   追加种子配置：$SEED_CONFIG"
	# 去掉注释和空行，避免混进奇怪内容
	grep -vE '^\s*(#|$)' "$SEED_CONFIG" >> .config || true
fi

make defconfig
mark

# ---------------------------------------------------------------- 4. 校验
# defconfig 会静默丢掉它认为不可选的项，而且更隐蔽的一种情况是：
# 包里根本不存在的名字，.config 里照样会留下 CONFIG_PACKAGE_xxx=y 这个「悬空符号」，
# grep .config 能查到、编译也「成功」，但镜像里根本没有那个包。
# 所以这里必须两头都查：.config 选中 + 构建系统的包数据库 tmp/.packageinfo 里存在。
log "校验关键包（.config 选中 + 构建树存在）"
REQUIRED_PKGS="
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

MISSING=""
for p in $REQUIRED_PKGS; do
	if ! grep -qx "CONFIG_PACKAGE_$p=y" .config; then
		MISSING="$MISSING\n  $p —— .config 里没被选中"
	elif ! grep -qx "Package: $p" tmp/.packageinfo; then
		MISSING="$MISSING\n  $p —— 构建树里不存在（feed 没装好？）"
	fi
done

if [ -n "$MISSING" ]; then
	printf '!! 以下包有问题：%b\n' "$MISSING" >&2
	echo "   排查方向：" >&2
	echo "     - feed 是否装好：ls package/feeds/" >&2
	echo "     - 包是否被识别：grep -n 'Package: <包名>' tmp/.packageinfo" >&2
	echo "     - 依赖是否满足：grep -n '<包名>' tmp/.packageinfo | head" >&2
	exit 1
fi
echo "   全部就位（$(echo $REQUIRED_PKGS | wc -w) 个）"
mark

# ---------------------------------------------------------------- 5. 编译
log "预下载源码包"
make download -j"$JOBS" || true
mark

log "开始编译（-j$JOBS，这一步最久，1~2 小时）"
# 不用 V=s，全量日志太大；失败时看 logs/ 目录
make -j"$JOBS" || {
	echo
	echo "!! 编译失败。最近出错的目标：" >&2
	ls -t logs/ 2>/dev/null | head -5 >&2
	exit 1
}
mark

# ---------------------------------------------------------------- 6. 收集
log "收集固件镜像"
OUT="$WORK/out"
rm -rf "$OUT"
mkdir -p "$OUT"

IMG_DIR="bin/targets/$TARGET"
[ -d "$IMG_DIR" ] || die "找不到产物目录 $IMG_DIR"

# 只挑能直接烧写/导入的镜像，跳过 packages/ 和中间文件。
# buildinfo / manifest 也带上 —— 它们记录了这次构建用的精确配置和 feed 提交，
# 是「这个镜像到底是什么」的唯一凭据，而且 sha256sums 里本来就引用了它们。
for pat in '*.img.gz' '*.img' '*.iso' '*.vmdk' '*.qcow2' '*.bin' '*.buildinfo' '*.manifest' 'sha256sums'; do
	find "$IMG_DIR" -maxdepth 1 -name "$pat" -exec cp -f {} "$OUT/" \; 2>/dev/null || true
done

N=$(find "$OUT" -type f | wc -l)
ls -lh "$OUT"
[ "$N" -gt 0 ] || die "没有收集到任何镜像，检查 $IMG_DIR"

ELAPSED=$(( $(date +%s) - START_TS ))
cat <<EON

==> 完成：$OUT（$N 个文件，耗时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒）

  x86/64 常见产物：
    *-squashfs-combined.img.gz   写盘用（可恢复出厂）
    *-ext4-combined.img.gz       写盘用（ext4 根，不可恢复出厂）
    *.iso                        虚拟机 / U 盘启动

  写入 U 盘或硬盘：
    gunzip -c openwrt-x86-64-generic-squashfs-combined.img.gz | dd of=/dev/sdX bs=4M

  注意：固件已内置 PassWall 与本仓库 vendor 的全部包，装完不需要再 opkg install。
EON
