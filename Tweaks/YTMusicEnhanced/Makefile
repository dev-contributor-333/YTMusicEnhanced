export TARGET = iphone:clang:17.5:14.0
export ARCHS = arm64
export SDK_PATH = $(THEOS)/sdks/iPhoneOS17.5.sdk/
export SYSROOT = $(SDK_PATH)

INSTALL_TARGET_PROCESSES = YouTubeMusic
TWEAK_NAME = YTMusicEnhanced

YTMusicEnhanced_FILES = Tweak.xm
YTMusicEnhanced_FRAMEWORKS = UIKit AVFoundation MediaPlayer
YTMusicEnhanced_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
