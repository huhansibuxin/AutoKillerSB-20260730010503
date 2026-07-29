TARGET := iphone:clang:latest:16.5
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoKillerSB

AutoKillerSB_FILES = Tweak.xm
AutoKillerSB_CFLAGS = -fobjc-arc
AutoKillerSB_FRAMEWORKS = UIKit
AutoKillerSB_PRIVATE_FRAMEWORKS = FrontBoard

include $(THEOS_MAKE_PATH)/tweak.mk
