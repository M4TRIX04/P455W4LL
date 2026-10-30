# firmware — 把 PassWall 编进 OpenWrt 镜像

这个目录解决的是**另一种**需求：不是产出能装到任意设备的 ipk，而是产出**已经内置 PassWall 的整机固件**，刷完开机就能用，不需要再 `opkg install`。

## 两条路的分工

| | `vendor/build.sh` | `firmware/build.sh` |
|---|---|---|
| 产物 | 12 个 ipk | 固件镜像（`.img.gz` / `.iso`）|
| 工具 | OpenWrt **SDK** | OpenWrt **buildroot**（完整源码）|
| 耗时 | 约 12 分钟 | 约 1 小时（4 核）|
| 可移植性 | 任意同架构设备 | 本机专用（含内核模块）|
| 用途 | 已有系统上装/升级 | 全新刷机、定制镜像 |

**两者可以并存。** 日常改代码用 SDK 出 ipk 快速验证；要出新固件时走 buildroot。CI 上分别是 `build.yml` 和 `build-firmware.yml`。

## 用法

```sh
# 本地（需要 buildroot 环境，约 30G 磁盘）
SEED_CONFIG=firmware/configs/x86-64.config \
TARGET=x86/64 \
./firmware/build.sh /path/to/workdir

# CI
gh workflow run build-firmware.yml -f target=x86/64
```

产物在 `$WORK/out/`。

**在 Docker 里以 root 跑**时，脚本会自动设置 `FORCE_UNSAFE_CONFIGURE=1` —— 否则 `tools/tar` 的 configure 会直接拒绝执行（`you should not run configure as root`）。GitHub runner 是非 root 用户，不受影响。这个坑我在容器里验证时踩过一次，表现为 `ERROR: tools/tar failed to build`，从错误信息完全看不出是权限问题。

## 怎么把本仓库变成 OpenWrt 的 feed

一行 `feeds.conf`：

```
src-git p455w4ll https://github.com/M4TRIX04/P455W4LL.git;main
```

**不需要调整仓库结构。** 这点我一开始判断错了，实测才发现：OpenWrt 的包扫描器（`include/scan.mk` 的 `find ... -name Makefile`）会递归到 `vendor/` 那一层，并把嵌套的包**扁平化**安装：

```
package/feeds/p455w4ll/luci-app-passwall     ← 来自仓库根的 luci-app-passwall/
package/feeds/p455w4ll/shadowsocks-c         ← 来自仓库的 vendor/shadowsocks-c/
package/feeds/p455w4ll/hysteria              ← 来自仓库的 vendor/hysteria/
package/feeds/p455w4ll/dns2tcp               ← 来自仓库的 vendor/dns2tcp/
```

所以仓库可以同时是「源码仓库」和「feed」，不用为了当 feed 而挪目录。

开发时想用本地目录（改一行立刻生效，不用 push）：

```sh
FEED_LOCAL=/path/to/P455W4LL ./firmware/build.sh
```

它会在 `feeds.conf` 里写 `src-link`，直接软链过去。

## 配置文件：`configs/x86-64.config`

只写**包选择**，target 部分由脚本根据 `TARGET` 环境变量生成。`make defconfig` 会补全其余默认项（内核、base 包、LuCI 等）。

改包就改这个文件，不用碰工作流。

## 五个必须知道的坑

### 1. `Nftables_Transparent_Proxy` 在固件里必须是 `y`

`vendor/build.sh` 编 ipk 时把它设成 `n` 是对的 —— SDK 不出镜像，内核模块由设备自带。但**固件里必须是 `y`**，因为这项会 `select` 一整套透明代理依赖：

```
kmod-nft-tproxy  kmod-nft-socket  kmod-nft-nat
dnsmasq-full     ipt2socks        nftables
```

设成 `n` 的话，PassWall 装上了但转发不了流量 —— 表现为「界面正常、节点能连、就是上不了网」。

### 2. 有四个包官方 feed 里没有

`chinadns-ng` / `dns2socks` / `tcping` / `ipt2socks` —— 官方 `openwrt/packages` 里全都没有，而它们是 `luci-app-passwall` 的硬依赖（`LUCI_DEPENDS` + `Nftables_Transparent_Proxy` 的 `select`）。

所以固件构建必须额外加一个 feed：

```
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
```

`dns2tcp` 这个包上游已删（`6d4bc0f`），由本仓库 vendor 提供。

### 3. `hysteria` 两个 feed 都有，且不兼容

- 本仓库：**v1.3.5**，配置格式是 `auth_str` / `up_mbps`，与 `util_hysteria.lua` 配套
- passwall_packages：**v2**，配置格式完全不同

`feeds install -a` 是「谁先装谁赢」，靠 `feeds.conf` 的书写顺序保证太脆。脚本里显式处理：

```sh
./scripts/feeds uninstall hysteria
./scripts/feeds install -p p455w4ll hysteria
```

### 4. CRLF 会让 `init.d` 脚本彻底失效，而且不报错

`/etc/init.d/passwall` 首行是 `#!/bin/sh /etc/rc.common`。如果文件是 CRLF，这行变成：

```
#!/bin/sh /etc/rc.common\r
```

那个 `\r` 让 `rc.common` 完全无法解析脚本。失败发生在镜像构建的 `Configuring luci-app-passwall` 之后，opkg 只给一个 `Error 255`，**不打任何有用信息**。我从头翻日志才定位到是换行符问题。

CI 从 GitHub clone 出来是 LF（`.gitattributes` 保证了 `*.sh` / `init.d` / `uci-defaults` / `hotplug` 全部 `eol=lf`），但本地 `FEED_LOCAL` 指向 Windows 工作区时是 CRLF。脚本里做了两件事：

- `FEED_LOCAL` 不直接 `src-link` 到源目录，而是**先复制到 `$WORK/feed-local` 再归一化** —— 否则 `sed` 会改到你的工作树
- 无论 `src-link` 还是 `src-git`，`feeds update` 之后都会对 `feeds/p455w4ll` 做一次 `sed -i 's/\r$//'` + `chmod 755`

### 5. `dnsmasq-full` 和 `dnsmasq` 会撞文件

`Nftables_Transparent_Proxy` 会 `select dnsmasq-full`，但镜像默认又选了基础版 `dnsmasq`。两者提供同一批文件，opkg 直接报：

```
check_data_file_clashes: Package dnsmasq-full wants to install file .../etc/init.d/dnsmasq
	But that file is already provided by package * dnsmasq
```

必须在配置里显式关掉基础版：

```
CONFIG_PACKAGE_dnsmasq=n
CONFIG_PACKAGE_dnsmasq-full=y
```

这个报错同样很坑 —— 它出现在 `Configuring luci-app-passwall` 之后，冲突详情要往前翻几十行才能看到，第一反应会以为是 PassWall 的问题。

## 校验为什么查两个地方
`build.sh` 编译前会逐条核对 15 个关键包，而且查**两处**：

```sh
grep -qx "CONFIG_PACKAGE_$p=y" .config          # 配置里选中了
grep -qx "Package: $p" tmp/.packageinfo          # 构建系统认识这个包
```

只查第一处会漏掉一种很隐蔽的失败：**包根本不存在时，`.config` 里照样会留下 `CONFIG_PACKAGE_xxx=y` 这个「悬空符号」**。`grep .config` 查得到、编译也不报错、镜像「构建成功」—— 但里面根本没有那个包。

我第一次测的时候就踩了这个：`ipt2socks` 显示 OK，实际构建树里不存在，因为忘了加 passwall_packages feed。

`tmp/.packageinfo` 是构建系统自己的包数据库，由 `make defconfig` 生成，是权威来源。

## 实测验证

在容器里跑通了一次完整构建（x86/64，14 核）。产物 8 个文件，共 130M：

```
openwrt-x86-64-generic-squashfs-combined.img.gz      21M   ← 写盘用
openwrt-x86-64-generic-squashfs-combined-efi.img.gz  22M
openwrt-x86-64-generic-ext4-combined.img.gz          25M
openwrt-x86-64-generic-ext4-rootfs.img.gz            19M
openwrt-x86-64-generic-kernel.bin                   6.0M
sha256sums
```

镜像根目录里 PassWall 相关文件 **121 个**，关键项逐个核对：

| 检查项 | 结果 |
|---|---|
| `/usr/bin/ss-redir` `/ss-local` `/ss-server` | 存在 |
| `/usr/bin/hysteria` `/dns2tcp` `/chinadns-ng` `/dns2socks` `/microsocks` `/ipt2socks` | 存在 |
| `/etc/init.d/passwall` + `/etc/rc.d/S99passwall` | 存在（开机自启已建立）|
| `/etc/uci-defaults/luci-passwall` | 存在（首次启动生成 `/etc/config/passwall`）|
| `/usr/lib/lua/luci/model/cbi/passwall/` | 存在（121 个文件里含全套 CBI）|
| 内核模块 `nft_tproxy.ko` `nft_socket.ko` `nft_nat.ko` | 存在 |

`/etc/config/passwall` **不在**镜像里是正常的 —— 它由 `/etc/uci-defaults/luci-passwall` 在首次开机时生成。镜像构建阶段 uci-defaults 不会执行（`IPKG_INSTROOT` 非空时 `default_postinst` 会跳过那段）。

## 输出与刷写

x86/64 的产物：

| 文件 | 用途 |
|---|---|
| `*-squashfs-combined.img.gz` | 写盘用，支持恢复出厂设置 |
| `*-ext4-combined.img.gz` | 写盘用，ext4 根分区，不能恢复出厂 |
| `*.iso` | 虚拟机 / U 盘启动 |

```sh
gunzip -c openwrt-x86-64-generic-squashfs-combined.img.gz | \
  dd of=/dev/sdX bs=4M status=progress
```

**注意**：固件已内置 PassWall 和 vendor 的全部包，刷完不需要再 `opkg install`。

## 可复现构建

默认 `passwall_packages` feed 跟 `main`，意味着上游一改，你的固件内容就变。要钉死：

```sh
PASSWALL_PKGS_PIN=<commit> ./firmware/build.sh
```

它会在 `feeds.conf` 里写 `^<commit>`，而不是 `;main`。

OpenWrt 源码本身已经钉在 `OPENWRT_VERSION`（默认 `v24.10.8`），本仓库钉在 `FEED_REF`（默认 `main`）。

## 换架构

```sh
TARGET=ramips/mt7621 SEED_CONFIG=firmware/configs/x86-64.config ./firmware/build.sh
```

`TARGET` 会同时决定：
- `CONFIG_TARGET_<board>=y` / `CONFIG_TARGET_<board>_<sub>=y`（脚本自动生成）
- 产物目录 `bin/targets/<target>/`

配置文件里的包选择通常跨架构通用（都是 `all` 或纯 C 包），但 `hysteria` 是 Go 静态编译、`shadowsocks-c` 依赖 `libmbedtls` 等，换架构会重新编译，不需要改配置。

如果目标架构不支持 nftables（很老的芯片），要把 `Nftables_Transparent_Proxy` 换成 `Iptables_Transparent_Proxy`。
