
set(OPTION_DEFAULT OFF)
set(OPTION_CLIENT_DEFAULT ON)
set(OPTION_SERVER_DEFAULT ON)

if(ANDROID)
	set(OPTION_SERVER_DEFAULT OFF)
endif()

define_channel_options(NAME "rdpgfx" TYPE "dynamic"
	DESCRIPTION "Graphics Pipeline Extension"
	SPECIFICATIONS "[MS-RDPEGFX]"
	DEFAULT ${OPTION_DEFAULT})

define_channel_client_options(${OPTION_CLIENT_DEFAULT})
define_channel_server_options(${OPTION_SERVER_DEFAULT})

