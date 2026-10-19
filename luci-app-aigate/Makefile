#
# PeDItXOS-AiGate — native Lua AI gateway control (LuCI app)
# Pure Lua + shell + JS: one arch-independent package for every device.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-aigate
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
PKGARCH:=all

LUCI_TITLE:=PeDItXOS-AiGate AI gateway control
LUCI_DESCRIPTION:=Native Lua AI gateway: provider/account fallback like 9Router, LuCI panel.
LUCI_DEPENDS:=+lua5.3 +uhttpd +curl +ca-bundle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
