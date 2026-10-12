TARGET := iphone:clang:16.5:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ccevent
ccevent_FILES = main.c
ccevent_FRAMEWORKS = CoreFoundation IOKit
ccevent_CODESIGN_FLAGS = -Sent.plist
ccevent_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk
