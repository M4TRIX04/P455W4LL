# integration — 把 PassWall 塞进你的 ImmortalWrt 源码树

做一件事：让本仓库的包出现在你源码树的 `make menuconfig` 里。选什么是你的事。

**不改你的 `.config`，不跑 defconfig。** 一条命令放进去，剩下的你自己点。

## 适用版本

| | 状态 |
|---|---|
| ImmortalWrt **24.10**（`openwrt-24.10` 分支） | **已验证**，本文所有结论基于它 |
| ImmortalWrt 25.12 / master | 未验证，不建议 |
| 原版 OpenWrt 24.10 | 同样适用（路径一致） |

不碰 25.12 的理由：`luci-app-passwall` 4.70-5 是 **Lua CBI** 应用，依赖 `luci-compat` + `luci-lua-runtime`。25.12 的 LuCI 在往纯 JS 迁移，这两个包能不能留是未知数。主路由要长期稳定跑，追新分支是负收益。

## 第一步：放进去

```sh
cd /path/to/immortalwrt
sh /path/to/P455W4LL/integration/install-into-tree.sh
```

它做四件事，**可以重复执行**（幂等）：

1. 往 `feeds.conf` 追加两行 feed（已有就跳过）
2. `feeds update -a` + `feeds install -a`
3. **处理同名遮蔽** —— 这是 ImmortalWrt 上最关键的一步，见下面
4. 归一化换行符与可执行位

本地开发想用工作树而不是 GitHub 上的：

```sh
FEED_LOCAL=/path/to/P455W4LL sh integration/install-into-tree.sh
```

它会先复制到 `/tmp/p455w4ll-feed` 再归一化，**不会改你的工作树**。

跑完应该看到：

```
==> 确认包已就位
   OK   luci-app-passwall    package/feeds/p455w4ll/luci-app-passwall  (4.70-5)
   OK   shadowsocks-c        package/feeds/p455w4ll/shadowsocks-c  (3.3.6)
   OK   hysteria             package/feeds/p455w4ll/hysteria  (1.3.5)
   OK   dns2tcp              package/feeds/p455w4ll/dns2tcp  (1.1.2)
```

## 为什么必须处理同名遮蔽

ImmortalWrt 的 feeds 里**自带 PassWall**。实测 `openwrt-24.10`：

```
luci-app-passwall  → feeds/luci/applications/luci-app-passwall   25.12.16
hysteria           → feeds/packages/net/hysteria                 v2
dns2tcp / chinadns-ng / dns2socks / tcping / ipt2socks / microsocks   都有
shadowsocks-libev-ss-*   只有本仓库提供
```

`feeds install -a` 按 `feeds.conf` 顺序装、**先装先赢**。官方 feed 在前，官方版本就占住 `package/feeds/luci/luci-app-passwall`，你的 4.70-5 根本不进去。

但 `.config` 里照样有 `CONFIG_PACKAGE_luci-app-passwall=y`，编译不报错 —— **最后镜像里是 25.12.16，不是你的**。完全静默。

这就是上游 README 里那段 `rm -rf feeds/packages/net/{...}` 的真正原因。不是为了避免整仓导入冲突，就是防同名遮蔽。

脚本里的处理顺序（**顺序本身也有讲究**）：

```sh
./scripts/feeds uninstall luci-app-passwall hysteria dns2tcp   # 先卸载，链接还能解析
rm -rf feeds/luci/applications/luci-app-passwall               # 再删源目录
rm -rf feeds/packages/net/{hysteria,dns2tcp}
./scripts/feeds install -p p455w4ll luci-app-passwall hysteria dns2tcp
```

反过来先删源目录的话，符号链接会先变悬空，`feeds uninstall` 处理不了它 —— 结果就是「脚本说替换成功了，实际两个版本都在」。我第一版就写错了这个顺序。

## 第二步：menuconfig 里选

```
make menuconfig

LuCI
└── 3. Applications
    └── <*> luci-app-passwall
```

选中它之后同级会出现子选项：

```
[*] Nftables Transparent Proxy      ← 24.10 必须开
[ ] Iptables Transparent Proxy      ← 只在没有 nftables 的老芯片上开
[ ] Include Shadowsocks Libev Client
[ ] Include Hysteria
...
```

**别用 `Include XXX` 开关。** 它们在 kconfig 里有循环依赖：

```
luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

`make defconfig` 遇到循环依赖会放弃处理，把它们打回 `not set`。直接在同一个菜单里选二进制包：

```
LuCI → 3. Applications
  <*> shadowsocks-libev-ss-local
  <*> shadowsocks-libev-ss-redir
  <*> shadowsocks-libev-ss-server
  <*> hysteria
```

其余 `3. Applications` 里的 LuCI 应用按你自己的需要勾。

### 不想手点的话

```sh
cat integration/passwall.config >> .config
```

这份片段只含包选择，不含 `CONFIG_TARGET_*`。里面的注释写了每一条为什么这么选，尤其是 `CONFIG_PACKAGE_dnsmasq=n` 不能删（见坑 4）。

## 第三步：校验

```sh
sh integration/verify.sh            # 宽松模式
sh integration/verify.sh --strict   # 严格模式，编译前把关
```

| 模式 | 行为 |
|---|---|
| 默认（宽松） | 只查集成问题（遮蔽 / 版本 / CRLF），**没选中的包只算跳过不算错** |
| `--strict` | 还要求 15 个必需包都被选中且构建系统认识 |

宽松模式适合「刚放进去、还没选」的时候，输出长这样：

```
 通过 16 项，失败 0 项，跳过 14 项
 => 集成没问题，还有 14 个包等你在 menuconfig 里选
```

严格模式全过才算可以编：

```
 通过 30 项，失败 0 项，跳过 0 项
 => 可以开始 make 了
```

**必须在 `make defconfig` 之后跑**（`tmp/.packageinfo` 要有）。

## 四个坑

### 1. 同名遮蔽

见上面。`verify.sh` 第 [2] 组专门查这个：`ls -d package/feeds/*/luci-app-passwall`，有多份或指向官方都判 FAIL。

这是唯一能自动发现「编出来不是你的版本」的手段 —— 光看 menuconfig 看不出来，两个版本在菜单里长得一样。

### 2. 校验必须查两个地方

包里**根本不存在的名字**，`.config` 里照样会留下 `CONFIG_PACKAGE_xxx=y` 这个悬空符号：grep 得到、编译不报错、镜像「构建成功」但里面没有那个包。

所以 `verify.sh` 同时查：

```sh
grep -qx "CONFIG_PACKAGE_$p=y" .config      # 配置里选中了
grep -qx "Package: $p" tmp/.packageinfo      # 构建系统认识这个包
```

### 3. `Nftables_Transparent_Proxy` 必须开

这项会 `select` 一整套透明代理依赖：

```
kmod-nft-tproxy  kmod-nft-socket  kmod-nft-nat
dnsmasq-full     ipt2socks        nftables
```

不开的话，PassWall 装上了、界面正常、节点能连，**就是转发不了流量**。表现是「上不了网」，很容易误判成节点问题。

### 4. `dnsmasq-full` 和 `dnsmasq` 会撞文件

`Nftables_Transparent_Proxy` 会 `select dnsmasq-full`，但镜像默认又选了基础版。opkg 报：

```
check_data_file_clashes: Package dnsmasq-full wants to install file .../etc/init.d/dnsmasq
	But that file is already provided by package * dnsmasq
```

所以要有 `CONFIG_PACKAGE_dnsmasq=n`。这个报错藏在 `Configuring luci-app-passwall` 之后，第一反应会以为是 PassWall 的问题。

### 附：CRLF 会让 `init.d` 静默失效

`/etc/init.d/passwall` 首行是 `#!/bin/sh /etc/rc.common`。CRLF 会把它变成 `#!/bin/sh /etc/rc.common\r`，`rc.common` 完全无法解析。

失败同样发生在 `Configuring luci-app-passwall` 之后，opkg 只给 `Error 255`，**不打任何有用信息**。

脚本里已经做了 `sed -i 's/\r$//'`，但如果你的构建环境另有转换，`verify.sh` 第 [7] 组会抓到。

## 可复现构建

默认跟 `main`，上游一改你的固件内容就变。要钉死就编辑 `feeds.conf`，把 `;main` 换成 `^<commit>`：

```
src-git p455w4ll https://github.com/M4TRIX04/P455W4LL.git^<commit>
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git^<commit>
```

值得钉：上游 `openwrt-passwall-packages` 删过一批包

```
cf2e235  remove unused packages - shadowsocks-libev - trojan-plus - tuic-client
6d4bc0f  remove packages that are no longer needed for passwall
```

`shadowsocks-libev` / `brook` / `trojan-go` / `trojan-plus` / `tuic-client` / `dns2tcp` 都是这么没的。本仓库 vendor 了其中三个，剩下的靠钉 commit 防漂移。

## 排错

| 症状 | 先查 |
|---|---|
| menuconfig 里找不到 luci-app-passwall | `ls package/feeds/p455w4ll/`，feed 装没装？`feeds.conf` 加了吗？ |
| 编出来是 25.12.16 不是 4.70-5 | `ls -d package/feeds/*/luci-app-passwall`，指向哪个 feed？ |
| 报某包 `悬空符号` | 包不存在或 feed 没装好，`grep '<包名>' tmp/.packageinfo` |
| 报 `hysteria 不是 v1` | `grep PKG_VERSION package/feeds/*/hysteria/Makefile` |
| 报 `init.d/passwall 是 CRLF` | `head -1 .../init.d/passwall \| od -c` |
| 编译过了但镜像里没 PassWall | `grep passwall bin/targets/*/*/*.manifest` |
| 装上了但上不了网 | 查 `Nftables_Transparent_Proxy` 和内核模块 `nft_tproxy` |

最后两条最重要：`bin/targets/<target>/<sub>/*.manifest` 列出镜像内**全部包及版本**，是「这个镜像里到底有什么」的唯一凭据。编译成功 ≠ 装进去了。

## 实测记录

在 `immortalwrt/immortalwrt` 的 `openwrt-24.10`、x86/64、14 核容器里完整编译过一次：

**20 分 52 秒**，产物 6 个镜像共 145M。镜像内 **290 个包**，PassWall 相关：

```
luci-app-passwall - 4.70-5              ← 我们的，不是自带的 25.12.16
hysteria - 1.3.5-r1                     ← 我们的 v1，不是 feed 里的 v2
shadowsocks-libev-ss-local - 3.3.6-r1   ← 我们的 ss-c
shadowsocks-libev-ss-redir - 3.3.6-r1
shadowsocks-libev-ss-server - 3.3.6-r1
dns2tcp - 1.1.2-r1
dnsmasq-full - 2.93-r1
```

镜像 rootfs 里 PassWall 相关文件 **125 个**：`ss-redir`/`ss-local`/`hysteria`/`dns2tcp` 在 `/usr/bin`，`/etc/rc.d/S99passwall` 自启已建立，内核模块 `nft_tproxy`/`nft_socket`/`nft_nat` 三个齐全。

`/etc/config/passwall` 不在镜像里是正常的 —— 镜像构建阶段 `IPKG_INSTROOT` 非空，`default_postinst` 会跳过 uci-defaults，配置由首次开机生成。

**脚本验证**（都在全新 ImmortalWrt 树上跑）：

- `install-into-tree.sh`：干净树 → 4 个包正确落到 `package/feeds/p455w4ll/`，版本 4.70-5 / 3.3.6 / 1.3.5 / 1.1.2
- `verify.sh` 宽松模式（未选）：16 通过 / 0 失败 / 14 跳过
- `verify.sh --strict`（未选）：正确报 15 个包没选中
- `verify.sh --strict`（选好）：30 通过 / 0 失败
- 反向验证：故意造「Transparent_Proxy 全关」「dnsmasq 冲突」「init.d 加 CRLF」三个错误，全部抓到并给出修法
