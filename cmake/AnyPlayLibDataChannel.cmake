# AnyPlay 116: libdatachannel (WebRTC: ICE, DTLS-SRTP, SCTP, RTP-пакетування H.264 і Opus) для трансляції друзям.
#
# Версія зафіксована тегом і перевіряється за комітом. Збирається статично разом з програмою (лише ціль
# LibDataChannel::LibDataChannelStatic і те, що їй потрібно), з OpenSSL, який уже є в збірці chiaki.
# Підмодулі беремо лише потрібні (без nlohmann/json — він лише для WebSocket, який вимкнено).
#
# CI заздалегідь кладе джерела в кеш і передає -DFETCHCONTENT_SOURCE_DIR_LIBDATACHANNEL=<тека> —
# тоді збірка не ходить у мережу. Без цього FetchContent клонує з GitHub сам.

include(FetchContent)

set(ANYPLAY_LIBDATACHANNEL_TAG "v0.24.6")
set(ANYPLAY_LIBDATACHANNEL_COMMIT "6b1e2e620f1e37f0eafeee702eaea0043cb305fd")

function(anyplay_add_libdatachannel)
	# змінні діють лише всередині функції, тобто лише на libdatachannel і її залежності
	set(BUILD_SHARED_LIBS OFF)
	set(NO_WEBSOCKET ON)
	set(NO_EXAMPLES ON)
	set(NO_TESTS ON)
	set(USE_NICE OFF)
	set(USE_GNUTLS OFF)
	set(USE_MBEDTLS OFF)
	set(PREFER_SYSTEM_LIB OFF)
	set(WARNINGS_AS_ERRORS OFF)
	set(sctp_werror OFF)
	# libSRTP типово вмикає «попередження = помилки»: новий компілятор у CI не має ламати збірку через чуже попередження
	# (ENABLE_WARNINGS лишаємо: без нього libSRTP не знає власної функції target_set_warnings)
	set(ENABLE_WARNINGS_AS_ERRORS OFF)
	set(BUILD_WITH_WARNINGS OFF)
	set(LIBSRTP_TEST_APPS OFF)
	set(sctp_build_programs OFF)
	set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
	set(CMAKE_POSITION_INDEPENDENT_CODE ON)
	if(ANDROID)
		# 124: на Android OpenSSL збирається разом з програмою (ExternalProject) уже під час збірки, тож перевірки
		# libSRTP «чи є OpenSSL» на етапі налаштування не пройшли б. libSRTP бере власне шифрування
		# (AES-CM, HMAC-SHA1): для 10–20 Мбіт/с цього досить. DTLS у libdatachannel однаково через OpenSSL.
		set(ENABLE_OPENSSL OFF)
	endif()

	set(_declare_args
		GIT_REPOSITORY https://github.com/paullouisageneau/libdatachannel.git
		GIT_TAG ${ANYPLAY_LIBDATACHANNEL_TAG}
		GIT_SHALLOW TRUE
		GIT_SUBMODULES deps/plog deps/usrsctp deps/libjuice deps/libsrtp
		GIT_PROGRESS FALSE)
	if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.28")
		list(APPEND _declare_args EXCLUDE_FROM_ALL)
	endif()
	FetchContent_Declare(libdatachannel ${_declare_args})
	FetchContent_MakeAvailable(libdatachannel)

	# та сама версія, що перевірена (тег на GitHub теоретично можна пересунути)
	find_package(Git QUIET)
	if(GIT_FOUND AND EXISTS "${libdatachannel_SOURCE_DIR}/.git")
		execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
			WORKING_DIRECTORY "${libdatachannel_SOURCE_DIR}"
			OUTPUT_VARIABLE _ldc_head OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
		if(_ldc_head AND NOT _ldc_head STREQUAL ANYPLAY_LIBDATACHANNEL_COMMIT)
			message(FATAL_ERROR "libdatachannel: очікувався коміт ${ANYPLAY_LIBDATACHANNEL_COMMIT} (${ANYPLAY_LIBDATACHANNEL_TAG}), а в ${libdatachannel_SOURCE_DIR} — ${_ldc_head}")
		endif()
	endif()
	foreach(_dep plog usrsctp libjuice libsrtp)
		if(NOT EXISTS "${libdatachannel_SOURCE_DIR}/deps/${_dep}/CMakeLists.txt")
			message(FATAL_ERROR "libdatachannel: немає підмодуля deps/${_dep} у ${libdatachannel_SOURCE_DIR}")
		endif()
	endforeach()
	if(NOT TARGET LibDataChannel::LibDataChannelStatic)
		message(FATAL_ERROR "libdatachannel: ціль LibDataChannel::LibDataChannelStatic не з'явилась")
	endif()
	message(STATUS "AnyPlay live: libdatachannel ${ANYPLAY_LIBDATACHANNEL_TAG} (${libdatachannel_SOURCE_DIR})")
endfunction()

anyplay_add_libdatachannel()
