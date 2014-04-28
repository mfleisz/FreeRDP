/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * Server Graphics Pipeline Virtual Channel
 *
 * Copyright 2014 Vic Lee
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *	 http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef FREERDP_CHANNEL_RDPGFX_SERVER_H
#define FREERDP_CHANNEL_RDPGFX_SERVER_H

#include <freerdp/channels/wtsvc.h>
#include <freerdp/channels/rdpgfx.h>

typedef struct _rdpgfx_server_context rdpgfx_server_context;

typedef void (*psRdpgfxServerOpen)(rdpgfx_server_context* context);
typedef BOOL (*psRdpgfxServerCreateSurface)(rdpgfx_server_context* context, RDPGFX_CREATE_SURFACE_PDU* create_surface);
typedef BOOL (*psRdpgfxServerDeleteSurface)(rdpgfx_server_context* context, RDPGFX_DELETE_SURFACE_PDU* delete_surface);
typedef BOOL (*psRdpgfxServerResetGraphics)(rdpgfx_server_context* context, RDPGFX_RESET_GRAPHICS_PDU* reset_graphics);
typedef BOOL (*psRdpgfxServerMapSurfaceToOutput)(rdpgfx_server_context* context, RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU* map_surface_to_output);

typedef void (*psRdpgfxServerActivated)(rdpgfx_server_context* context);

struct _rdpgfx_server_context
{
	HANDLE vcm;

	/* Server self-defined pointer. */
	void* data;

	UINT32 version;
	UINT32 flags;

	/*** APIs called by the server. ***/
	/**
	 * Open the graphics channel. The server MUST wait until Activated callback is called
	 * before using the channel.
	 */
	psRdpgfxServerOpen Open;
	/**
	 * Create a surface.
	 */
	psRdpgfxServerCreateSurface CreateSurface;
	/**
	 * Delete a surface.
	 */
	psRdpgfxServerDeleteSurface DeleteSurface;
	/**
	 * Change the width and height of the graphics output buffer, and update the monitor layout.
	 */
	psRdpgfxServerResetGraphics ResetGraphics;
	/**
	 * Map a surface to a rectangular area of the graphics output buffer.
	 */
	psRdpgfxServerMapSurfaceToOutput MapSurfaceToOutput;

	/*** Callbacks registered by the server. ***/
	/**
	 * The channel is activated and ready for sending graphics.
	 */
	psRdpgfxServerActivated Activated;
};

#ifdef __cplusplus
extern "C" {
#endif

FREERDP_API rdpgfx_server_context* rdpgfx_server_context_new(HANDLE vcm);
FREERDP_API void rdpgfx_server_context_free(rdpgfx_server_context* context);

#ifdef __cplusplus
}
#endif

#endif /* FREERDP_CHANNEL_RDPGFX_SERVER_H */
