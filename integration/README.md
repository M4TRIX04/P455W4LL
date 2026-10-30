# integration — 把本仓库接进你自己的 ImmortalWrt 源码树

目标：编译你自己的 ImmortalWrt 时，`make menuconfig` 里 `LuCI → Applications → luci-app-passwall` 能勾选，编出来的 img 里带着我们这套（PassWall 4.70-5 + shadowsocks-c + hysteria v1）。

编译发生在**你的 ImmortalWrt 源码树**里，不是这里。

## 先说最要命的一件事：ImmortalWrt 自带 PassWall

ImmortalWrt 的 feeds 里**已经有 PassWall 了**，而且是更新的版本。实测：

```
luci-app-passwall   → feeds/luci/applications/luci-app-passwall   25.12.16
hysteria            → feeds/packages/net/hysteria                 v2
dns2tcp / chinadns-ng / dns2socks / tcping / ipt2socks / microsocks
                    → feeds/packages/net/...                      都有
shadowsocks-libev-ss-* → 完全没有（只有我们提供）
```

`feeds install -a` 是**按 feeds.conf 顺序装，先装先赢**。官方 feed 排在前面，所以官方版本会占住 `package/feeds/luci/luci-app-passwall`，我们的 4.70-5 **根本不进去** —— 但 `.config` 里照样有 `CONFIG_PACKAGE_luci-app-passwall=y`，编译也不报错，最后镜像里是 25.12.16，不是你的。

这就是上游 README 里那段 `rm -rf feeds/packages/net/{...}` + `rm -rf feeds/luci/applications/luci-app-passwall` 的原因。**不是为了避免整仓导入冲突，就是为了防止同名遮蔽。**

（我一开始判断成前者，是错的。）

## 完整步骤

在你 ImmortalWrt 源码根目录执行。

### 第一步：加 feed

```sh
cp feeds.conf.default feeds.conf
cat >> feeds.conf <<'EOF'
src-git p455w4ll https://github.com/M4TRIX04/P455W4LL.git;main
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
EOF
```

注意 ImmortalWrt 的 `feeds.conf.default` **没有 `base` feed**（基础包在源码树的 `package/` 里），所以直接追加两行就行，不用像 SDK 那样补 base。

### 第二步：拉取并处理同名遮蔽

```sh
./scripts/feeds update -a
./scripts/feeds install -a

# 删掉官方同名包的源目录，防止 feeds install 又把它们装回来
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/packages/net/hysteria
rm -rf feeds/packages/net/dns2tcp

# 显式重新安装，确保拿到本仓库的版本
./scripts/feeds uninstall luci-app-passwall hysteria dns2tcp 2>/dev/null
./scripts/feeds install -p p455w4ll luci-app-passwall hysteria dns2tcp

# 归一化换行符（Windows 提交过的仓库容易带 CRLF）
find -L feeds/p455w4ll -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod 755 feeds/p455w4ll/root/etc/init.d/* \
          feeds/p455w4ll/root/etc/hotplug.d/iface/* \
          feeds/p455w4ll/root/etc/uci-defaults/* \
          feeds/p455w4ll/root/usr/share/passwall/*.sh 2>/dev/null || true
```

**两个动作都要做**，别只做一个：

- 只 `rm` 不 `install -p` → 官方没了，你的也没装（`feeds install -a` 早跑完了）
- 只 `install -p` 不 `rm` → 这次能装上，但以后谁再跑一次 `feeds install -a` 就被顶回去

> **顺序陷阱：配置必须在这一步之后加，不能之前。**
>
> `scripts/feeds uninstall` 内部会触发一次 `make defconfig`。那一刻包刚被移除，`.config` 里 `CONFIG_PACKAGE_luci-app-passwall=y` 就成了未知符号，被 defconfig 直接丢掉。等你 `install -p` 装回来，`.config` 里已经没有这行了 —— 结果就是「包装好了但没选中」。
>
> 我第一次测就是这么翻车的：先加配置、再处理遮蔽，最后 `verify.sh` 报三个包 `没选中`。改成先处理遮蔽、再加配置，30 项立刻全绿。

### 第三步：加配置

```sh
cat integration/passwall.config >> .config
make defconfig
```

`passwall.config` 不含 `CONFIG_TARGET_*`，target 由你自己定。

### 第四步：校验

```sh
sh integration/verify.sh
```

会查 8 组共 30 项，全过返回 0。它查的是「包到底会不会进镜像」，不是「配置里写了没有」——这两件事不一样，见下面的坑 2。

**必须在 `make defconfig` 之后、`make` 之前跑。** 早了没有 `tmp/.packageinfo`，晚了就白编了。

## menuconfig 里在哪

```
LuCI
└── 3. Applications
    └── <*> luci-app-passwall .............. LuCI support for PassWall
        ├── [ ] Iptables Transparent Proxy
        ├── [*] Nftables Transparent Proxy
        ├── [ ] Include Brook
        ├── [ ] Include Haproxy
        ├── [ ] Include Hysteria
        ├── [ ] Include Shadowsocks Libev Client
        ├── [ ] Include Shadowsocks Libev Server
        └── ... 其余 INCLUDE_*
```

实测确认：我们 4.70-5 的 20 个子选项全部出现在 Kconfig 里，包括 `INCLUDE_Shadowsocks_Libev_Client` —— 这个在 ImmortalWrt 自带的 25.12.16 里**没有**（它只有 rust 和 SSR）。

**但别用那些 INCLUDE 开关**，原因见坑 3。

## 五个坑

### 坑 1：同名遮蔽（ImmortalWrt 特有，最致命）

见上面。表现为「编译一切正常，装进 img 的是 25.12.16，不是你的 4.70-5」。

`verify.sh` 的第 [2] 组专门查这个，会检查 `package/feeds/*/luci-app-passwall` 到底指向哪个 feed。

### 坑 2：校验必须查两个地方

包里**根本不存在的名字**，`.config` 里照样会留下 `CONFIG_PACKAGE_xxx=y` 这个悬空符号 —— grep 得到、编译不报错、镜像「构建成功」但里面没有。

我第一次测就踩了：`ipt2socks` 显示 OK，实际构建树里不存在。

所以 `verify.sh` 同时查：

```sh
grep -qx "CONFIG_PACKAGE_$p=y" .config      # 配置里选中了
grep -qx "Package: $p" tmp/.packageinfo      # 构建系统认识这个包
```

`tmp/.packageinfo` 由 `make defconfig` 生成，是构建系统的包数据库，权威来源。

### 坑 3：别用 `INCLUDE_*` 开关，直接选包

`INCLUDE_Shadowsocks_Libev_Client` 这类开关在 kconfig 里有循环依赖：

```
luci-app-passwall → sing-box-tiny → sing-box → (selected by) luci-app-passwall
```

`make defconfig` 遇到循环依赖会放弃处理，把这些选项打回 `not set`。所以 `passwall.config` 里是直接选包：

```
CONFIG_PACKAGE_shadowsocks-libev-ss-redir=y
CONFIG_PACKAGE_hysteria=y
```

效果一样 —— PassWall 运行时只认 `/usr/bin` 下有没有对应二进制。

### 坑 4：`Nftables_Transparent_Proxy` 必须是 `y`

这项会 `select` 一整套透明代理依赖：

```
kmod-nft-tproxy  kmod-nft-socket  kmod-nft-nat
dnsmasq-full     ipt2socks        nftables
```

不开的话，PassWall 装上了、界面正常、节点能连，**就是转发不了流量**。表现是「上不了网」，很容易误判成节点问题。

只有没有 nftables 的老芯片才改用 `Iptables_Transparent_Proxy`。

### 坑 5：`dnsmasq-full` 和 `dnsmasq` 会撞文件

`Nftables_Transparent_Proxy` 会 `select dnsmasq-full`，但镜像默认又选了基础版。opkg 直接报：

```
check_data_file_clashes: Package dnsmasq-full wants to install file .../etc/init.d/dnsmasq
	But that file is already provided by package * dnsmasq
```

所以 `passwall.config` 里有 `CONFIG_PACKAGE_dnsmasq=n`，**别删**。

这个报错藏在 `Configuring luci-app-passwall` 之后，第一反应会以为是 PassWall 的问题。

### 附：CRLF 会让 `init.d` 静默失效

`/etc/init.d/passwall` 首行是 `#!/bin/sh /etc/rc.common`。CRLF 会让它变成 `#!/bin/sh /etc/rc.common\r`，`rc.common` 完全无法解析。

失败同样发生在 `Configuring luci-app-passwall` 之后，opkg 只给 `Error 255`，**不打任何有用信息**。

本仓库的 `.gitattributes` 已经钉了 `eol=lf`，从 GitHub clone 是干净的。但如果你 `src-link` 到 Windows 工作区，必踩 —— 所以第二步里有 `sed -i 's/\r$//'`。

## 做成脚本

把第二步到第四步写成一个脚本，放在源码树根目录，每次编译前跑：

```sh
#!/bin/bash
# 文件名：passwall-integrate.sh，放在 ImmortalWrt 源码根目录
set -e

# 1. 处理同名遮蔽
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/packages/net/hysteria feeds/packages/net/dns2tcp
./scripts/feeds uninstall luci-app-passwall hysteria dns2tcp 2>/dev/null || true
./scripts/feeds install -p p455w4ll luci-app-passwall hysteria dns2tcp

# 2. 归一化
find -L feeds/p455w4ll -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod 755 feeds/p455w4ll/root/etc/init.d/* \
          feeds/p455w4ll/root/etc/hotplug.d/iface/* \
          feeds/p455w4ll/root/etc/uci-defaults/* \
          feeds/p455w4ll/root/usr/share/passwall/*.sh 2>/dev/null || true

# 3. 配置
cat integration/passwall.config >> .config
make defconfig

# 4. 校验
sh integration/verify.sh
```

在 `./scripts/feeds install -a` 之后、`make` 之前调用。

## 可复现构建

默认跟 `main`，上游一改你的固件内容就变。要钉死就把 `;main` 换成 `^<commit>`：

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
| 编出来是 25.12.16 不是 4.70-5 | `ls -d package/feeds/*/luci-app-passwall` —— 指向哪个 feed？ |
| `verify.sh` 报某包 `.config 里没选中` | `grep '<包名>' tmp/.packageinfo`，包在不在？依赖满不满足？ |
| 报某包 `构建系统不认识` | feed 装没装：`ls package/feeds/` |
| 报 `hysteria 不是 v1` | `grep PKG_VERSION package/feeds/*/hysteria/Makefile` |
| 报 `init.d/passwall 是 CRLF` | `head -1 .../init.d/passwall \| od -c` |
| 编译过了但镜像里没 PassWall | `grep passwall bin/targets/*/*/*.manifest` |
| 装上了但上不了网 | 查 `Nftables_Transparent_Proxy` 和内核模块 `nft_tproxy` |

最后一条最重要：`bin/targets/<target>/<sub>/*.manifest` 列出镜像内**全部包及版本**，是「这个镜像里到底有什么」的唯一凭据。编译成功 ≠ 装进去了。

## 实测记录

在 `immortalwrt/immortalwrt` 的 `openwrt-24.10` 分支上验证过：

- 4 个包（luci-app-passwall / shadowsocks-c / hysteria / dns2tcp）正确落到 `package/feeds/p455w4ll/`，版本分别是 4.70-5 / 3.3.6 / 1.3.5 / 1.1.2
- 12 个依赖（luci-compat / luci-lua-runtime / luci-lib-jsonc / libuci-lua / coreutils* / ip-full / resolveip / unzip / curl / lua）ImmortalWrt 全部提供
- `make defconfig` 通过，`verify.sh` **30 项全绿**
- menuconfig 路径：`LuCI → 3. Applications → luci-app-passwall`，20 个子选项齐全
- 反向验证：故意制造「两个 Transparent_Proxy 都没开」「dnsmasq 冲突」「init.d 是 CRLF」三个错误，`verify.sh` 全部抓到并给出修法
