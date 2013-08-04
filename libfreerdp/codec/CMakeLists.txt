# FreeRDP: A Remote Desktop Protocol Implementation
# libfreerdp-codec cmake build script
#
# Copyright 2012 Marc-Andre Moreau <marcandre.moreau@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set(MODULE_NAME "freerdp-codec")
set(MODULE_PREFIX "FREERDP_CODEC")

set(${MODULE_PREFIX}_SRCS
	dsp.c
	color.c
	audio.c
	bitmap_decode.c
	bitmap_encode.c
	rfx_bitstream.h
	rfx_constants.h
	rfx_decode.c
	rfx_decode.h
	rfx_differential.c
	rfx_differential.h
	rfx_dwt.c
	rfx_dwt.h
	rfx_encode.c
	rfx_encode.h
	rfx_quantization.c
	rfx_quantization.h
	rfx_rlgr.c
	rfx_rlgr.h
	rfx_types.h
	rfx.c
	nsc.c
	nsc_encode.c
	nsc_encode.h
	nsc_types.h
	mppc_dec.c
	mppc_enc.c
	jpeg.c)

set(${MODULE_PREFIX}_SSE2_SRCS
	rfx_sse2.c
	rfx_sse2.h
	nsc_sse2.c
	nsc_sse2.h)

set(${MODULE_PREFIX}_NEON_SRCS
	rfx_neon.c
	rfx_neon.h)

if(WITH_SSE2)
	set(${MODULE_PREFIX}_SRCS ${${MODULE_PREFIX}_SRCS} ${${MODULE_PREFIX}_SSE2_SRCS})

	if(CMAKE_COMPILER_IS_GNUCC)
		set_source_files_properties(${${MODULE_PREFIX}_SSE2_SRCS} PROPERTIES COMPILE_FLAGS "-msse2")
	endif()

	if(MSVC)
		set_source_files_properties(${${MODULE_PREFIX}_SSE2_SRCS} PROPERTIES COMPILE_FLAGS "/arch:SSE2")
	endif()
endif()

if(WITH_NEON)
	set(${MODULE_PREFIX}_SRCS ${${MODULE_PREFIX}_SRCS} ${${MODULE_PREFIX}_NEON_SRCS})
	set_source_files_properties(${${MODULE_PREFIX}_NEON_SRCS} PROPERTIES COMPILE_FLAGS "-mfpu=neon -mfloat-abi=${ARM_FP_ABI} -Wno-unused-variable")
endif()

if(TARGET_ARCH MATCHES "x64|x86")
	set(WITH_RFX_RLGR_OPTION_VALUES "default" "asm" "microsoft")
	set(WITH_RFX_RLGR_OPTION "default" CACHE STRING "Select RemoteFX RLGR codec implementation. Possible values: ${WITH_RFX_RLGR_OPTION_VALUES}")
	set_property(CACHE WITH_RFX_RLGR_OPTION PROPERTY STRINGS ${WITH_RFX_RLGR_OPTION_VALUES})
	list(FIND WITH_RFX_RLGR_OPTION_VALUES ${WITH_RFX_RLGR_OPTION} WITH_RFX_RLGR_OPTION_INDEX)
	if(${WITH_RFX_RLGR_OPTION_INDEX} EQUAL -1)
		message(FATAL_ERROR "RemoteFX RLGR codec option [${WITH_RFX_RLGR_OPTION}] not supported, possible values are ${WITH_RFX_RLGR_OPTION_VALUES}")
	endif()
	if(${WITH_RFX_RLGR_OPTION_INDEX} GREATER 0)
		enable_language(ASM_NASM)
		if(WIN32)
			set(CMAKE_ASM_NASM_FLAGS "-DWIN32")
		endif()

		set(${MODULE_PREFIX}_SRCS ${${MODULE_PREFIX}_SRCS}
			"rfx_rlgr_options.h")

		if(${WITH_RFX_RLGR_OPTION} STREQUAL "asm")
			set(${MODULE_PREFIX}_SRCS ${${MODULE_PREFIX}_SRCS}
				"rfx_rlgr_asm_${TARGET_ARCH}.nasm")
		endif()
		if(${WITH_RFX_RLGR_OPTION} STREQUAL "microsoft")
			set(${MODULE_PREFIX}_SRCS ${${MODULE_PREFIX}_SRCS}
				"rfx_rlgr_microsoft_decrlgr3_${TARGET_ARCH}.nasm"
				"rfx_rlgr_microsoft_encrlgr3_${TARGET_ARCH}.nasm")
		endif()
		add_definitions("-DRFX_RLGR_OPTION=${WITH_RFX_RLGR_OPTION_INDEX}")
	endif()
endif()

if(WITH_JPEG)
	set(FREERDP_JPEG_LIBS jpeg)
endif()

add_complex_library(MODULE ${MODULE_NAME} TYPE "OBJECT"
	MONOLITHIC ${MONOLITHIC_BUILD}
	SOURCES ${${MODULE_PREFIX}_SRCS})

set_target_properties(${MODULE_NAME} PROPERTIES VERSION ${FREERDP_VERSION} SOVERSION ${FREERDP_API_VERSION} PREFIX "lib")

set(${MODULE_PREFIX}_LIBS
	${FREERDP_JPEG_LIBS})

set_complex_link_libraries(VARIABLE ${MODULE_PREFIX}_LIBS
	MONOLITHIC ${MONOLITHIC_BUILD} INTERNAL
	MODULE freerdp
	MODULES freerdp-primitives freerdp-utils)
	
set_complex_link_libraries(VARIABLE ${MODULE_PREFIX}_LIBS
	MONOLITHIC ${MONOLITHIC_BUILD}
	MODULE winpr
	MODULES winpr-crt winpr-pool winpr-registry winpr-sysinfo winpr-utils)

if(MONOLITHIC_BUILD)
	set(FREERDP_LIBS ${FREERDP_LIBS} ${${MODULE_PREFIX}_LIBS} PARENT_SCOPE)
else()
	target_link_libraries(${MODULE_NAME} ${${MODULE_PREFIX}_LIBS})
	install(TARGETS ${MODULE_NAME} DESTINATION ${CMAKE_INSTALL_LIBDIR})
endif()

set_property(TARGET ${MODULE_NAME} PROPERTY FOLDER "FreeRDP/libfreerdp")
