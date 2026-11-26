
cmake_minimum_required(VERSION 3.2)

# 124: трансляція друзям (libdatachannel і спільна з комп'ютером медіа-частина) потребують C++17
set(CMAKE_CXX_STANDARD 17)

# AnyPlay 124: трансляція друзям з телефона (WebRTC через libdatachannel, відео й звук гри пересилаються як є)
option(ANYPLAY_ANDROID_LIVE "AnyPlay: broadcast to friends from the phone" ON)

add_library(chiaki-jni SHARED
        src/main/cpp/chiaki-jni.c
        src/main/cpp/log.h
        src/main/cpp/log.c
        src/main/cpp/video-decoder.h
        src/main/cpp/video-decoder.c
        src/main/cpp/audio-decoder.h
        src/main/cpp/audio-decoder.c
        src/main/cpp/audio-output.h
        src/main/cpp/audio-output.cpp
        src/main/cpp/crash-handler.c
        src/main/cpp/circular-fifo.hpp)
target_link_libraries(chiaki-jni chiaki-lib)

find_library(ANDROID_LIB_LOG log)
find_library(ANDROID_LIB_MEDIANDK mediandk)
find_library(ANDROID_LIB_ANDROID android)
target_link_libraries(chiaki-jni "${ANDROID_LIB_LOG}" "${ANDROID_LIB_MEDIANDK}" "${ANDROID_LIB_ANDROID}")

find_package (oboe REQUIRED CONFIG)
target_link_libraries(chiaki-jni oboe::oboe)
# AnyPlay: файл кореневих сертифікатів для HTTPS-запитів бібліотеки до PSN (пояснення в src/main/cpp/chiaki-jni.c біля
# __wrap_curl_easy_init). Без цього OpenSSL у застосунку не бачить жодного сертифіката (SSL_CERT_FILE він ігнорує через
# AT_SECURE=1 у процесах Android), і всі запити до Sony падають з помилкою перевірки сертифіката (curl 60).
target_link_options(chiaki-jni PRIVATE "-Wl,--wrap=curl_easy_init" "-Wl,--wrap=OPENSSL_issetugid")

if(ANYPLAY_ANDROID_LIVE)
	include(AnyPlayLibDataChannel)
	set(ANYPLAY_GUI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../gui")
	target_sources(chiaki-jni PRIVATE
		src/main/cpp/anyplay-live.h
		src/main/cpp/anyplay-live.cpp
		"${ANYPLAY_GUI_DIR}/include/anyplaylivemedia.h"
		"${ANYPLAY_GUI_DIR}/src/anyplaylivemedia.cpp")
	target_include_directories(chiaki-jni PRIVATE "${ANYPLAY_GUI_DIR}/include")
	# без Opus: звук гри йде з PS5 як є, мікрофона й голосів глядачів на телефоні поки немає
	target_compile_definitions(chiaki-jni PRIVATE ANYPLAY_ANDROID_LIVE ANYPLAY_LIVE_NO_OPUS)
	target_link_libraries(chiaki-jni LibDataChannel::LibDataChannelStatic)
	message(STATUS "AnyPlay Android live: enabled")
endif()
