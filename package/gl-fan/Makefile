include $(TOPDIR)/rules.mk

PKG_NAME:=gl-fan
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=openwrt-beryl-ax

include $(INCLUDE_DIR)/package.mk

define Package/gl-fan
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=PID fan controller for GL.iNet Beryl AX / GL-MT3000
  URL:=https://github.com/
endef

define Package/gl-fan/description
  Userspace PID fan controller for the GL.iNet Beryl AX / GL-MT3000,
  reimplemented from the vendor gl_fan daemon. Reads the CPU temperature
  from a thermal sysfs node and drives the thermal cooling device PWM.
endef

define Package/gl-fan/conffiles
/etc/config/glfan
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/gl_fan.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/gl_fan $(PKG_BUILD_DIR)/gl_fan.c
endef

define Package/gl-fan/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gl_fan $(1)/usr/bin/gl_fan
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/gl_fan.init $(1)/etc/init.d/gl_fan
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/glfan.config $(1)/etc/config/glfan
endef

$(eval $(call BuildPackage,gl-fan))
