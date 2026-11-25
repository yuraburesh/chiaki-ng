# AnyPlay 116: окрема перевірка медіа трансляції (не входить у збірку програми).
#   cmake -S test/anyplaylive -B build-live -DFETCHCONTENT_SOURCE_DIR_LIBDATACHANNEL=<джерела, необов'язково>
#   cmake --build build-live && ./build-live/live_rtp_test
# Кодує тестові кадри (libx264 — лише тут; у програмі тільки апаратні кодувальники), пакує в RTP через
# libdatachannel, передає через справжнє з'єднання WebRTC на цьому комп'ютері, розпаковує й декодує.
cmake_minimum_required(VERSION 3.20)
project(anyplay_live_test C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CHIAKI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
list(APPEND CMAKE_MODULE_PATH "${CHIAKI_ROOT}/cmake")
include(AnyPlayLibDataChannel)
find_package(FFMPEG REQUIRED COMPONENTS avcodec avutil swscale)
find_package(Opus REQUIRED)
add_executable(live_rtp_test live_rtp_test.cpp "${CHIAKI_ROOT}/gui/src/anyplaylivemedia.cpp")
target_include_directories(live_rtp_test PRIVATE "${CHIAKI_ROOT}/gui/include" ${Opus_INCLUDE_DIRS})
target_link_libraries(live_rtp_test PRIVATE LibDataChannel::LibDataChannelStatic FFMPEG::avcodec FFMPEG::avutil FFMPEG::swscale ${Opus_LIBRARIES})
