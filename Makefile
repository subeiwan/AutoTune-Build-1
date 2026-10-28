TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = 超自然行动组

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoTune
AutoTune_FILES = AutoTune.xm
AutoTune_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
AutoTune_FRAMEWORKS = Foundation UIKit
AutoTune_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 超自然行动组 || true"
