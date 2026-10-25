include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYNEX

DYNEX_FILES = $(wildcard src/*.m) $(wildcard src/*.mm)
DYNEX_CFLAGS = -fobjc-arc -Isrc

EXTRA_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
