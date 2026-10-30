# integration — 把 PassWall 接进 ImmortalWrt 源码树

结构已经按官方 `openwrt-passwall` 的形状摆好，所以接入就是**三条命令**，不用跑脚本。

## 适用版本

| | 状态 |
|---|---|
| ImmortalWrt **24.10**（`openwrt-24.10` 分支） | **已验证**，本文所有结论基于它 |
| ImmortalWrt 25.12 / master | 未验证，不建议 |
| 原版 OpenWrt 24.10 | 可用，但要额外补一个 feed（见文末） |

不碰 25.12 的理由：`luci-app-passwall` 4.70-5 是 **Lua CBI** 应用，依赖 `luci-compat` + `luci-lua-runtime`。25.12 的 LuCI 在往纯 JS 迁移，这两个包能不能留是未知数。

## 三条命令

在你 ImmortalWrt 源码根目录：

```sh
./scripts/feeds update -a && ./scripts/feeds install -a

rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/packages/net/hysteria feeds/packages/net/dns2tcp

git clone https://github.com/M4TRIX04/P455W4LL package/passwall-luci
```

然后 `make menuconfig`，在 `LuCI → 3. Applications → luci-app-passwall` 里选。选什么、要不要别的 LuCI，都是你自己的事 —— 这三条命令**不碰你的 `.config`**。

### 为什么第 2 步不能省

ImmortalWrt 的 feeds 里**自带 PassWall**。实测 `openwrt-24.10`：

```
luci-app-passwall  → feeds/luci/applications/luci-app-passwall   25.12.16
hysteria           → feeds/packages/net/hysteria                 v2
dns2tcp / chinadns-ng / dns2socks / tcping / ipt2socks / microsocks   都有
shadowsocks-libev-ss-*   只有本仓库提供
```

不删的话，`package/` 下会同时存在两份同名包（`package/passwall-luci/hysteria` 和 `package/feeds/packages/hysteria`），kconfig 里同一个符号有两个定义 —— 要么报错，要么你选中的是官方那份，编出来是 v2，跟 `util_hysteria.lua` 对不上。

`feeds install -a` 必须在 `rm` 之前：它要用 feed 的索引，删早了会找不到。

`rm` 之后 `package/feeds/` 里会留下几个悬空符号链接，这是正常的 —— 扫描器用 `find -L` 找 `Makefile`，链接断了就跳过，不会报错。

## menuconfig 里选什么

```
LuCI
└── 3. Applications
    └── <*> luci-app-passwall
        ├── [*] Nftables Transparent Proxy      ← 24.10 必须开
        └── [ ] Iptables Transparent Proxy      ← 只有没有 nftables 的老芯片才开
```

**`Nftables Transparent Proxy` 一定要勾。** 它会 `select` 掉：

```
kmod-nft-tproxy  kmod-nft-socket  kmod-nft-nat
dnsmasq-full     ipt2socks        nftables
```

不勾的话，PassWall 装上了、界面正常、节点能连，**就是上不了网** —— 这个症状特别容易误判成节点问题。

### 协议二进制要单独选

别用 `Include Shadowsocks Libev Client` 那类开关。它们在 kconfig 里有循环依赖：

```
luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

`make defconfig` 遇到循环依赖会放弃处理，把它们打回 `not set`。直接选包：

```
LuCI → 3. Applications
  <*> shadowsocks-libev-ss-local
  <*> shadowsocks-libev-ss-redir
  <*> shadowsocks-libev-ss-server
  <*> hysteria
```

效果一样 —— PassWall 运行时只认 `/usr/bin` 下有没有对应二进制。

### 不想手点的话

```sh
cat integration/passwall.config >> .config
```

这份片段只含包选择，不含 `CONFIG_TARGET_*`。里面的注释写了每一条为什么这么选，尤其是 `CONFIG_PACKAGE_dnsmasq=n` 不能删（见坑 2）。

## 编译前校验

```sh
sh integration/verify.sh            # 宽松：没选中的包只算跳过
sh integration/verify.sh --strict   # 严格：15 个必需包都要选中
```

宽松模式适合「刚 clone 进来、还没选」：

```
 通过 16 项，失败 0 项，跳过 14 项
 => 集成没问题，还有 14 个包等你在 menuconfig 里选
```

`--strict` 适合 `make` 之前把关：

```
 通过 30 项，失败 0 项，跳过 0 项
 => 可以开始 make 了
```

它抓的是**光看 menuconfig 看不出来**的问题：同名遮蔽、hysteria 版本错、`init.d` 是 CRLF、dnsmasq 冲突、以及「配置里有符号但构建系统不认识」的悬空项。

**必须在 `make defconfig` 之后跑**（`tmp/.packageinfo` 要有）。

## 三个坑

### 1. 同名遮蔽

见上面。`verify.sh` 第 [2] 组专门查：它会看 `package/` 下同名包有几份、分别在哪。有多份、或者只在 `package/feeds/` 下（说明是官方 feed 的），都判 FAIL。

这是唯一能自动发现「编出来不是你的版本」的手段 —— 两个版本在 menuconfig 里长得一模一样。

### 2. `dnsmasq-full` 和 `dnsmasq` 会撞文件

`Nftables Transparent Proxy` 会 `select dnsmasq-full`，但镜像默认又选了基础版。opkg 报：

```
check_data_file_clashes: Package dnsmasq-full wants to install file .../etc/init.d/dnsmasq
	But that file is already provided by package * dnsmasq
```

要有 `CONFIG_PACKAGE_dnsmasq=n`。这个报错藏在 `Configuring luci-app-passwall` 之后，第一反应会以为是 PassWall 的问题。

### 3. CRLF 会让 `init.d` 静默失效

`/etc/init.d/passwall` 首行是 `#!/bin/sh /etc/rc.common`。CRLF 会把它变成 `#!/bin/sh /etc/rc.common\r`，`rc.common` 完全无法解析。

失败同样发生在 `Configuring luci-app-passwall` 之后，opkg 只给 `Error 255`，**不打任何有用信息**。

本仓库的 `.gitattributes` 把 `*.sh` / `init.d` / `uci-defaults` / `hotplug` 都钉成了 `eol=lf`，从 GitHub clone 是干净的。但如果你 clone 的是 Windows 上的工作区副本，就会带 CRLF —— `verify.sh` 第 [7] 组能抓到。

## 编完看 manifest

```sh
grep passwall bin/targets/x86/64/*.manifest
```

应该是：

```
luci-app-passwall - 4.70-5
hysteria - 1.3.5-r1
shadowsocks-libev-ss-redir - 3.3.6-r1
```

manifest 列出镜像内**全部包及版本**，是「这个镜像里到底有什么」的唯一凭据。**编译成功 ≠ 装进去了**。

如果看到 `luci-app-passwall - 25.12.16`，说明第 2 步的 `rm` 没生效。

## 原版 OpenWrt 的差异

ImmortalWrt 的 `feeds/packages/net/` 里已经有 `chinadns-ng` / `dns2socks` / `tcping` / `ipt2socks` / `microsocks`，所以三条命令够了。

原版 OpenWrt 没有这些，要额外补上游的二进制 feed：

```sh
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,v2ray-plugin,xray-plugin,geoview,shadow-tls,smartdns}
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages
rm -rf feeds/luci/applications/luci-app-passwall
git clone https://github.com/M4TRIX04/P455W4LL package/passwall-luci
```

## 固定版本

`git clone` 默认拿 `main` 最新，上游一改你的固件内容就变。要复现就钉 commit：

```sh
git clone https://github.com/M4TRIX04/P455W4LL package/passwall-luci
git -C package/passwall-luci checkout <commit>
```

`verify.sh` 第 [8] 组会报出当前是哪个 commit。

值得钉：上游 `openwrt-passwall-packages` 删过一批包

```
cf2e235  remove unused packages - shadowsocks-libev - trojan-plus - tuic-client
6d4bc0f  remove packages that are no longer needed for passwall
```

`shadowsocks-libev` / `brook` / `trojan-go` / `trojan-plus` / `tuic-client` / `dns2tcp` 都是这么没的。本仓库把这几个都 vendor 进来了，所以即使上游继续删，你这边也不受影响。

## 实测记录

**接入验证**（全新 ImmortalWrt 树，`openwrt-24.10`，x86/64）：

- 三条命令执行后，`package/passwall-luci/` 下四个包目录齐全
- 构建系统全部识别（`Package: luci-app-passwall` / `shadowsocks-libev-ss-redir` / `hysteria` / `dns2tcp` 都在 `tmp/.packageinfo`）
- 版本正确：`luci-app-passwall 4.70-5`、`hysteria 1.3.5`
- Kconfig 里有 `config PACKAGE_luci-app-passwall`，menuconfig 能看到
- `verify.sh` 宽松：16 过 / 0 失败 / 14 跳过
- `verify.sh --strict`：30 过 / 0 失败

**完整编译验证**（同一棵树，14 核容器）：

**20 分 52 秒**，产物 6 个镜像共 145M，镜像内 **290 个包**：

```
luci-app-passwall - 4.70-5              ← 我们的，不是自带的 25.12.16
hysteria - 1.3.5-r1                     ← 我们的 v1，不是 feed 里的 v2
shadowsocks-libev-ss-local - 3.3.6-r1
shadowsocks-libev-ss-redir - 3.3.6-r1
shadowsocks-libev-ss-server - 3.3.6-r1
dns2tcp - 1.1.2-r1
dnsmasq-full - 2.93-r1
```

镜像 rootfs 里 PassWall 相关文件 **125 个**：`ss-redir`/`ss-local`/`hysteria`/`dns2tcp` 在 `/usr/bin`，`/etc/rc.d/S99passwall` 自启已建立，内核模块 `nft_tproxy`/`nft_socket`/`nft_nat` 三个齐全。

`/etc/config/passwall` 不在镜像里是正常的 —— 镜像构建阶段 `IPKG_INSTROOT` 非空，`default_postinst` 会跳过 uci-defaults，配置由首次开机生成。
