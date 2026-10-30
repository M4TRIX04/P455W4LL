# SPDX-License-Identifier: GPL-3.0-only
#
# shadowsocks-c —— shadowsocks-libev 的继任者（2026-09 改名并重写构建系统）
# 注意：v3.3.6 tag 仍残留 libcork/libev 旧代码且 libcork 是子模块（tarball 不含），
#       因此固定到 master 上删除该遗留代码之后的 commit
# 上游声明：ss-local / ss-server / ss-redir 的命令行与 JSON 配置格式保持兼容
# 这里保持旧的包名（shadowsocks-libev-ss-*），使 luci-app-passwall 无需改动

include $(TOPDIR)/rules.mk

PKG_NAME:=shadowsocks-c
PKG_VERSION:=3.3.6
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/shadowsocks/shadowsocks-c.git
PKG_SOURCE_VERSION:=50f1ae54f737aa66f8edba05bdbf7250ff7f8a60
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

CMAKE_OPTIONS += \
	-DSS_DEPENDENCY_MODE=system \
	-DWITH_STATIC=OFF \
	-DCMAKE_PREFIX_PATH=$(STAGING_DIR)/usr \
	-DSS_BUILD_SHARED_LIBRARY=OFF \
	-DSS_WARNINGS_AS_ERRORS=OFF \
	-DSS_ENABLE_REGEX=OFF \
	-DSS_ENABLE_PLUGINS=ON \
	-DSS_INSTALL_TOOLS=OFF

# 构建模式说明（实测体积，ss-local）：
#   bundled + regex ON   -> 924K
#   bundled + regex OFF  -> 621K
#   system  + regex OFF  -> 202K  ← 当前配置，与 libev 原版基本持平
# system 模式靠上游自带的 cmake/Find*.cmake 定位 staging 里的库，
# 因此必须给 CMAKE_PREFIX_PATH，否则 find_package 找不到。
# SS_ENABLE_REGEX 关掉是因为 PassWall 不使用 ACL 正则，可省掉 PCRE2 依赖。

define Package/shadowsocks-libev-ss-local
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=SS Local (shadowsocks-c $(PKG_VERSION))
  URL:=https://github.com/shadowsocks/shadowsocks-c
  DEPENDS:=+libuv +libcares +libsodium +libmbedtls +libstdcpp +libpthread
endef

define Package/shadowsocks-libev-ss-redir
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=SS Redir (shadowsocks-c $(PKG_VERSION))
  URL:=https://github.com/shadowsocks/shadowsocks-c
  DEPENDS:=+libuv +libcares +libsodium +libmbedtls +libstdcpp +libpthread
endef

define Package/shadowsocks-libev-ss-server
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=SS Server (shadowsocks-c $(PKG_VERSION))
  URL:=https://github.com/shadowsocks/shadowsocks-c
  DEPENDS:=+libuv +libcares +libsodium +libmbedtls +libstdcpp +libpthread
endef

define Package/shadowsocks-libev-ss-tunnel
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=SS Tunnel (shadowsocks-c $(PKG_VERSION))
  URL:=https://github.com/shadowsocks/shadowsocks-c
  DEPENDS:=+libuv +libcares +libsodium +libmbedtls +libstdcpp +libpthread
endef

define Package/shadowsocks-libev-ss-manager
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=SS Manager (shadowsocks-c $(PKG_VERSION))
  URL:=https://github.com/shadowsocks/shadowsocks-c
  DEPENDS:=+libuv +libcares +libsodium +libmbedtls +libstdcpp +libpthread
endef

define Package/shadowsocks-libev-ss-local/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ss-local $(1)/usr/bin/
endef

define Package/shadowsocks-libev-ss-redir/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ss-redir $(1)/usr/bin/
endef

define Package/shadowsocks-libev-ss-server/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ss-server $(1)/usr/bin/
endef

define Package/shadowsocks-libev-ss-tunnel/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ss-tunnel $(1)/usr/bin/
endef

define Package/shadowsocks-libev-ss-manager/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ss-manager $(1)/usr/bin/
endef

$(eval $(call BuildPackage,shadowsocks-libev-ss-local))
$(eval $(call BuildPackage,shadowsocks-libev-ss-redir))
$(eval $(call BuildPackage,shadowsocks-libev-ss-server))
$(eval $(call BuildPackage,shadowsocks-libev-ss-tunnel))
$(eval $(call BuildPackage,shadowsocks-libev-ss-manager))
