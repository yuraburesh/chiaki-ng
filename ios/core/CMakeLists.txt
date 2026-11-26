# AnyPlay для iPhone та iPad: рідна частина (chiaki-lib + Opus + C-інтерфейс для Swift).
# Збирається з кореня сховища: -DCHIAKI_ENABLE_IOS=ON з набором інструментів iOS (див. .github/workflows/anyplay-ios.yml)
include(FetchContent)

# Opus — звук гри з PS5 (на Android його декодує система, на iOS — ця бібліотека)
set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(opus
	URL https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz
	URL_HASH SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1)
FetchContent_MakeAvailable(opus)

add_library(anyplay-core STATIC
	include/anyplay_core.h
	anyplay_core.c)
target_include_directories(anyplay-core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(anyplay-core PUBLIC chiaki-lib opus)
