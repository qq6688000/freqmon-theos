TARGET := iphone:clang:16.5:16.5
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FreqMon

FreqMon_FILES = Tweak.x
FreqMon_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation QuartzCore
FreqMon_CFLAGS = -fobjc-arc -O2

include $(THEOS_MAKE_PATH)/tweak.mk
