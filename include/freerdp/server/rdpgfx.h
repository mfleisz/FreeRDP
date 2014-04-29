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
typedef BOOL (*psRdpgfxServerWireToSurface1)(rdpgfx_server_context* context, RDPGFX_WIRE_TO_SURFACE_PDU_1* wire_to_surface_1);
typedef BOOL (*psRdpgfxServerCreateSurface)(rdpgfx_server_context* context, RDPGFX_CREATE_SURFACE_PDU* create_surface);
typedef BOOL (*psRdpgfxServerDeleteSurface)(rdpgfx_server_context* context, RDPGFX_DELETE_SURFACE_PDU* delete_surface);
typedef BOOL (*psRdpgfxServerStartFrame)(rdpgfx_server_context* context, RDPGFX_START_FRAME_PDU* start_frame);
typedef BOOL (*psRdpgfxServerEndFrame)(rdpgfx_server_context* context, RDPGFX_END_FRAME_PDU* end_frame);
typedef BOOL (*psRdpgfxServerResetGraphics)(rdpgfx_server_context* context, RDPGFX_RESET_GRAPHICS_PDU* reset_graphics);
typedef BOOL (*psRdpgfxServerMapSurfaceToOutput)(rdpgfx_server_context* context, RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU* map_surface_to_output);

typedef void (*psRdpgfxServerOpenResult)(rdpgfx_server_context* context, UINT32 result);
typedef void (*psRdpgfxServerFrameAcknowledge)(rdpgfx_server_context* context, RDPGFX_FRAME_ACKNOWLEDGE_PDU* frame_acknowledge);

struct _rdpgfx_server_context
{
	HANDLE vcm;

	/* Server self-defined pointer. */
	void* data;

	UINT32 version;
	UINT32 flags;

	/*** APIs called by the server. ***/
	/**
	 * Open the graphics channel. The server MUST wait until OpenResult callback is called
	 * before using the channel.
	 */
	psRdpgfxServerOpen Open;
	/**
	 * Transfer bitmap data to surface.
	 */
	psRdpgfxServerWireToSurface1 WireToSurface1;
	/**
	 * Create a surface.
	 */
	psRdpgfxServerCreateSurface CreateSurface;
	/**
	 * Delete a surface.
	 */
	psRdpgfxServerDeleteSurface DeleteSurface;
	/**
	 * Start a frame.
	 */
	psRdpgfxServerStartFrame StartFrame;
	/**
	 * End a frame.
	 */
	psRdpgfxServerEndFrame EndFrame;
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
	 * Indicate whether the channel is opened successfully.
	 */
	psRdpgfxServerOpenResult OpenResult;
	/**
	 * A frame is acknowledged by the client.
	 */
	psRdpgfxServerFrameAcknowledge FrameAcknowledge;
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
