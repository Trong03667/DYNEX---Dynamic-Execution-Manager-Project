include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYNEX

DYNEX_FILES = $(wildcard src/*.m) $(wildcard src/*.mm)
DYNEX_CFLAGS = -fobjc-arc -Isrc

# Khai báo các Frameworks bắt buộc để không bị lỗi Undefined symbols
DYNEX_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
