include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYNEX

DYNEX_FILES = $(wildcard src/*.m) $(wildcard src/*.mm)
DYNEX_CFLAGS = -fobjc-arc -Isrc

# Thêm các framework UIKit và CoreGraphics để fix triệt để lỗi Undefined symbols
DYNEX_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
