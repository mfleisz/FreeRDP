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

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/stream.h>
#include <winpr/sysinfo.h>

#include <freerdp/server/rdpgfx.h>

#define RDPGFX_MAX_SEGMENT_LENGTH 65535

#define RDPGFX_SINGLE 0xE0
#define RDPGFX_MULTIPART 0xE1

typedef struct _rdpgfx_server
{
	rdpgfx_server_context context;

	BOOL opened;

	HANDLE stopEvent;

	HANDLE thread;
	void* rdpgfx_channel;

	DWORD SessionId;

} rdpgfx_server;

static void rdpgfx_server_send_capabilities(rdpgfx_server* rdpgfx, wStream* s)
{
	Stream_SetPosition(s, 0);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_CAPSCONFIRM); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 20); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT32(s, rdpgfx->context.version); /* RDPGFX_CAPSET.version (4 bytes) */
	Stream_Write_UINT32(s, 4); /* RDPGFX_CAPSET.capsDataLength (4 bytes) */
	Stream_Write_UINT32(s, rdpgfx->context.flags);

	WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
}

static BOOL rdpgfx_server_recv_capabilities(rdpgfx_server* rdpgfx, wStream* s, UINT32 length)
{
	UINT16 i;
	UINT32 flags;
	UINT32 version;
	UINT16 capsSetCount;
	UINT32 capsDataLength;

	if (length < 2)
		return FALSE;
	Stream_Read_UINT16(s, capsSetCount);
	length -= 2;

	for (i = 0; i < capsSetCount; i++)
	{
		if (length < 8)
			return FALSE;
		Stream_Read_UINT32(s, version);
		Stream_Read_UINT32(s, capsDataLength);
		length -= 8;
		if (length < capsDataLength)
			return FALSE;
		if (capsDataLength >= 4)
		{
			Stream_Read_UINT32(s, flags);
		}
		else
		{
			flags = 0;
		}
		length -= capsDataLength;

		if (version > rdpgfx->context.version && version <= RDPGFX_CAPVERSION_81)
		{
			rdpgfx->context.version = version;
			rdpgfx->context.flags = flags;
		}
	}

	if (rdpgfx->context.version == 0)
		return FALSE;

	return TRUE;
}

static BOOL rdpgfx_server_recv_frameack(rdpgfx_server* rdpgfx, wStream* s, UINT32 length)
{
	RDPGFX_FRAME_ACKNOWLEDGE_PDU frame_acknowledge;

	if (length < 12)
		return FALSE;
	Stream_Read_UINT32(s, frame_acknowledge.queueDepth);
	Stream_Read_UINT32(s, frame_acknowledge.frameId);
	Stream_Read_UINT32(s, frame_acknowledge.totalFramesDecoded);

	IFCALL(rdpgfx->context.FrameAcknowledge, &rdpgfx->context, &frame_acknowledge);

	return TRUE;
}

static BOOL rdpgfx_server_open_channel(rdpgfx_server* rdpgfx)
{
	DWORD Error;
	HANDLE hEvent;
	DWORD StartTick;
	DWORD BytesReturned = 0;
	PULONG pSessionId = NULL;

	if (WTSQuerySessionInformationA(rdpgfx->context.vcm, WTS_CURRENT_SESSION,
		WTSSessionId, (LPSTR*) &pSessionId, &BytesReturned) == FALSE)
	{
		return FALSE;
	}
	rdpgfx->SessionId = (DWORD) *pSessionId;
	WTSFreeMemory(pSessionId);

	hEvent = WTSVirtualChannelManagerGetEventHandle(rdpgfx->context.vcm);
	StartTick = GetTickCount();

	while (rdpgfx->rdpgfx_channel == NULL)
	{
		WaitForSingleObject(hEvent, 1000);

		rdpgfx->rdpgfx_channel = WTSVirtualChannelOpenEx(rdpgfx->SessionId,
				RDPGFX_DVC_CHANNEL_NAME, WTS_CHANNEL_OPTION_DYNAMIC);

		if (rdpgfx->rdpgfx_channel)
			break;

		Error = GetLastError();
		if (Error == ERROR_NOT_FOUND)
			break;

		if (GetTickCount() - StartTick > 5000)
			break;
	}

	return rdpgfx->rdpgfx_channel ? TRUE : FALSE;
}

static void* rdpgfx_server_thread_func(void* arg)
{
	wStream* s;
	void* buffer;
	DWORD nCount;
	UINT16 cmdId;
	UINT16 flags;
	UINT32 pduLength;
	HANDLE events[8];
	BOOL ready = FALSE;
	HANDLE ChannelEvent;
	DWORD BytesReturned = 0;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) arg;

	if (rdpgfx_server_open_channel(rdpgfx) == FALSE)
	{
		IFCALL(rdpgfx->context.OpenResult, &rdpgfx->context, RDPGFX_SERVER_OPEN_RESULT_NOTSUPPORTED);
		return NULL;
	}

	buffer = NULL;
	BytesReturned = 0;
	ChannelEvent = NULL;

	if (WTSVirtualChannelQuery(rdpgfx->rdpgfx_channel, WTSVirtualEventHandle, &buffer, &BytesReturned) == TRUE)
	{
		if (BytesReturned == sizeof(HANDLE))
			CopyMemory(&ChannelEvent, buffer, sizeof(HANDLE));

		WTSFreeMemory(buffer);
	}

	nCount = 0;
	events[nCount++] = rdpgfx->stopEvent;
	events[nCount++] = ChannelEvent;

	/* Wait for the client to confirm that the Graphics Pipeline dynamic channel is ready */

	while (1)
	{
		if (WaitForMultipleObjects(nCount, events, FALSE, 100) == WAIT_OBJECT_0)
		{
			IFCALL(rdpgfx->context.OpenResult, &rdpgfx->context, RDPGFX_SERVER_OPEN_RESULT_CLOSED);
			break;
		}

		if (WTSVirtualChannelQuery(rdpgfx->rdpgfx_channel, WTSVirtualChannelReady, &buffer, &BytesReturned) == FALSE)
		{
			IFCALL(rdpgfx->context.OpenResult, &rdpgfx->context, RDPGFX_SERVER_OPEN_RESULT_ERROR);
			break;
		}

		ready = *((BOOL*) buffer);

		WTSFreeMemory(buffer);

		if (ready)
			break;
	}

	s = Stream_New(NULL, 4096);

	while (ready)
	{
		if (WaitForMultipleObjects(nCount, events, FALSE, INFINITE) == WAIT_OBJECT_0)
			break;

		Stream_SetPosition(s, 0);

		if (WTSVirtualChannelRead(rdpgfx->rdpgfx_channel, 0, (PCHAR) Stream_Buffer(s),
			(ULONG) Stream_Capacity(s), &BytesReturned) == FALSE)
		{
			if (BytesReturned == 0)
				break;
			
			Stream_EnsureRemainingCapacity(s, BytesReturned);

			if (WTSVirtualChannelRead(rdpgfx->rdpgfx_channel, 0, (PCHAR) Stream_Buffer(s),
				(ULONG) Stream_Capacity(s), &BytesReturned) == FALSE)
			{
				break;
			}
		}

		if (BytesReturned < 8)
			continue;

		Stream_Read_UINT16(s, cmdId);
		Stream_Read_UINT16(s, flags);
		Stream_Read_UINT32(s, pduLength);
		if (BytesReturned < pduLength)
			continue;
		BytesReturned -= 8;

		switch (cmdId)
		{
			case RDPGFX_CMDID_CAPSADVERTISE:
				if (rdpgfx_server_recv_capabilities(rdpgfx, s, BytesReturned))
				{
					rdpgfx_server_send_capabilities(rdpgfx, s);
					IFCALL(rdpgfx->context.OpenResult, &rdpgfx->context, RDPGFX_SERVER_OPEN_RESULT_OK);
				}
				else
				{
					IFCALL(rdpgfx->context.OpenResult, &rdpgfx->context, RDPGFX_SERVER_OPEN_RESULT_ERROR);
				}
				break;

			case RDPGFX_CMDID_FRAMEACKNOWLEDGE:
				rdpgfx_server_recv_frameack(rdpgfx, s, BytesReturned);
				break;

			default:
				fprintf(stderr, "rdpgfx_server_thread_func: unknown cmdId %d\n", cmdId);
				break;
		}
	}

	Stream_Free(s, TRUE);
	WTSVirtualChannelClose(rdpgfx->rdpgfx_channel);
	rdpgfx->rdpgfx_channel = NULL;

	return NULL;
}

static void rdpgfx_server_open(rdpgfx_server_context* context)
{
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	if (rdpgfx->thread == NULL)
	{
		rdpgfx->stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
		rdpgfx->thread = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE) rdpgfx_server_thread_func, (void*) rdpgfx, 0, NULL);
	}
}

static BOOL rdpgfx_server_wire_to_surface_1(rdpgfx_server_context* context, RDPGFX_WIRE_TO_SURFACE_PDU_1* wire_to_surface_1)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	if (25 + wire_to_surface_1->bitmapDataLength <= RDPGFX_MAX_SEGMENT_LENGTH)
	{
		s = Stream_New(NULL, 27 + wire_to_surface_1->bitmapDataLength);

		Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
		Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

		Stream_Write_UINT16(s, RDPGFX_CMDID_WIRETOSURFACE_1); /* RDPGFX_HEADER.cmdId (2 bytes) */
		Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
		Stream_Write_UINT32(s, 25 + wire_to_surface_1->bitmapDataLength); /* RDPGFX_HEADER.pduLength (4 bytes) */
		Stream_Write_UINT16(s, wire_to_surface_1->surfaceId);
		Stream_Write_UINT16(s, wire_to_surface_1->codecId);
		Stream_Write_UINT8(s, wire_to_surface_1->pixelFormat);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.left);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.top);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.right);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.bottom);
		Stream_Write_UINT32(s, wire_to_surface_1->bitmapDataLength);
		Stream_Write(s, wire_to_surface_1->bitmapData, wire_to_surface_1->bitmapDataLength);

		result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
		Stream_Free(s, TRUE);
	}
	else
	{
		UINT32 segmentCount;
		UINT32 segmentLength;
		BYTE* bitmapData = wire_to_surface_1->bitmapData;
		UINT32 bitmapDataLength = wire_to_surface_1->bitmapDataLength;

		segmentCount = (25 + wire_to_surface_1->bitmapDataLength + (RDPGFX_MAX_SEGMENT_LENGTH - 1)) / RDPGFX_MAX_SEGMENT_LENGTH;
		s = Stream_New(NULL, 7 + (5 + RDPGFX_MAX_SEGMENT_LENGTH) * segmentCount);

		Stream_Write_UINT8(s, RDPGFX_MULTIPART); /* descriptor (1 byte) */
		Stream_Write_UINT16(s, segmentCount);
		Stream_Write_UINT32(s, 25 + wire_to_surface_1->bitmapDataLength); /* uncompressedSize (4 bytes) */

		segmentLength = RDPGFX_MAX_SEGMENT_LENGTH - 25;

		Stream_Write_UINT32(s, 1 + RDPGFX_MAX_SEGMENT_LENGTH);
		Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

		Stream_Write_UINT16(s, RDPGFX_CMDID_WIRETOSURFACE_1); /* RDPGFX_HEADER.cmdId (2 bytes) */
		Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
		Stream_Write_UINT32(s, 25 + wire_to_surface_1->bitmapDataLength); /* RDPGFX_HEADER.pduLength (4 bytes) */
		Stream_Write_UINT16(s, wire_to_surface_1->surfaceId);
		Stream_Write_UINT16(s, wire_to_surface_1->codecId);
		Stream_Write_UINT8(s, wire_to_surface_1->pixelFormat);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.left);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.top);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.right);
		Stream_Write_UINT16(s, wire_to_surface_1->destRect.bottom);
		Stream_Write_UINT32(s, wire_to_surface_1->bitmapDataLength);
		Stream_Write(s, bitmapData, segmentLength);

		bitmapData += segmentLength;
		bitmapDataLength -= segmentLength;

		while (bitmapDataLength > 0)
		{
			segmentLength = bitmapDataLength;
			if (segmentLength > RDPGFX_MAX_SEGMENT_LENGTH)
				segmentLength = RDPGFX_MAX_SEGMENT_LENGTH;

			Stream_Write_UINT32(s, 1 + segmentLength);
			Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

			Stream_Write(s, bitmapData, segmentLength);

			bitmapData += segmentLength;
			bitmapDataLength -= segmentLength;
		}

		result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
		Stream_Free(s, TRUE);
	}

	return result;
}

static BOOL rdpgfx_server_create_surface(rdpgfx_server_context* context, RDPGFX_CREATE_SURFACE_PDU* create_surface)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 17);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_CREATESURFACE); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 15); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT16(s, create_surface->surfaceId);
	Stream_Write_UINT16(s, create_surface->width);
	Stream_Write_UINT16(s, create_surface->height);
	Stream_Write_UINT8(s, create_surface->pixelFormat);

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
	Stream_Free(s, TRUE);

	return result;
}

static BOOL rdpgfx_server_delete_surface(rdpgfx_server_context* context, RDPGFX_DELETE_SURFACE_PDU* delete_surface)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 12);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_DELETESURFACE); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 10); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT16(s, delete_surface->surfaceId);

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
	Stream_Free(s, TRUE);

	return result;
}

static BOOL rdpgfx_server_start_frame(rdpgfx_server_context* context, RDPGFX_START_FRAME_PDU* start_frame)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 18);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_STARTFRAME); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 16); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT32(s, start_frame->timestamp);
	Stream_Write_UINT32(s, start_frame->frameId);

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
	Stream_Free(s, TRUE);

	return result;
}

static BOOL rdpgfx_server_end_frame(rdpgfx_server_context* context, RDPGFX_END_FRAME_PDU* end_frame)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 14);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_ENDFRAME); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 12); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT32(s, end_frame->frameId);

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
	Stream_Free(s, TRUE);

	return result;
}

static BOOL rdpgfx_server_reset_graphics(rdpgfx_server_context* context, RDPGFX_RESET_GRAPHICS_PDU* reset_graphics)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 342);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_RESETGRAPHICS); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 340); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT32(s, reset_graphics->width);
	Stream_Write_UINT32(s, reset_graphics->height);
	Stream_Write_UINT32(s, 1); /* monitorCount (4 bytes) */
	Stream_Write_UINT32(s, 0); /* TS_MONITOR_DEF.left (4 bytes) */
	Stream_Write_UINT32(s, 0); /* TS_MONITOR_DEF.top (4 bytes) */
	Stream_Write_UINT32(s, reset_graphics->width); /* TS_MONITOR_DEF.right (4 bytes) */
	Stream_Write_UINT32(s, reset_graphics->height); /* TS_MONITOR_DEF.bottom (4 bytes) */
	Stream_Write_UINT32(s, MONITOR_PRIMARY); /* TS_MONITOR_DEF.flags (4 bytes) */

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), 342, NULL);
	Stream_Free(s, TRUE);

	return result;
}

static BOOL rdpgfx_server_map_surface_to_output(rdpgfx_server_context* context, RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU* map_surface_to_output)
{
	wStream* s;
	BOOL result;
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	s = Stream_New(NULL, 22);

	Stream_Write_UINT8(s, RDPGFX_SINGLE); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, PACKET_COMPR_TYPE_RDP8); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_MAPSURFACETOOUTPUT); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 20); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT16(s, map_surface_to_output->surfaceId);
	Stream_Write_UINT16(s, 0); /* reserved (2 bytes) */
	Stream_Write_UINT32(s, map_surface_to_output->outputOriginX);
	Stream_Write_UINT32(s, map_surface_to_output->outputOriginY);

	result = WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), (ULONG) Stream_GetPosition(s), NULL);
	Stream_Free(s, TRUE);

	return result;
}

static void rdpgfx_server_close(rdpgfx_server_context* context)
{
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	if (rdpgfx->thread)
	{
		SetEvent(rdpgfx->stopEvent);
		WaitForSingleObject(rdpgfx->thread, INFINITE);
		CloseHandle(rdpgfx->thread);
		CloseHandle(rdpgfx->stopEvent);
		rdpgfx->thread = NULL;
		rdpgfx->stopEvent = NULL;
	}
}

rdpgfx_server_context* rdpgfx_server_context_new(HANDLE vcm)
{
	rdpgfx_server* rdpgfx;

	rdpgfx = (rdpgfx_server*) calloc(1, sizeof(rdpgfx_server));

	rdpgfx->context.vcm = vcm;
	rdpgfx->context.Open = rdpgfx_server_open;
	rdpgfx->context.Close = rdpgfx_server_close;
	rdpgfx->context.WireToSurface1 = rdpgfx_server_wire_to_surface_1;
	rdpgfx->context.CreateSurface = rdpgfx_server_create_surface;
	rdpgfx->context.DeleteSurface = rdpgfx_server_delete_surface;
	rdpgfx->context.StartFrame = rdpgfx_server_start_frame;
	rdpgfx->context.EndFrame = rdpgfx_server_end_frame;
	rdpgfx->context.ResetGraphics = rdpgfx_server_reset_graphics;
	rdpgfx->context.MapSurfaceToOutput = rdpgfx_server_map_surface_to_output;

	return (rdpgfx_server_context*) rdpgfx;
}

void rdpgfx_server_context_free(rdpgfx_server_context* context)
{
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	rdpgfx_server_close(context);

	free(rdpgfx);
}
