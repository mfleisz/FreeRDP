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

#include <freerdp/server/rdpgfx.h>

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

	Stream_Write_UINT8(s, 0xE0); /* descriptor (1 byte) */
	Stream_Write_UINT8(s, 0x04); /* RDP8_BULK_ENCODED_DATA.header (1 byte) */

	Stream_Write_UINT16(s, RDPGFX_CMDID_CAPSCONFIRM); /* RDPGFX_HEADER.cmdId (2 bytes) */
	Stream_Write_UINT16(s, 0); /* RDPGFX_HEADER.flags (2 bytes) */
	Stream_Write_UINT32(s, 20); /* RDPGFX_HEADER.pduLength (4 bytes) */
	Stream_Write_UINT32(s, rdpgfx->context.version); /* RDPGFX_CAPSET.version (4 bytes) */
	Stream_Write_UINT32(s, 4); /* RDPGFX_CAPSET.capsDataLength (4 bytes) */
	Stream_Write_UINT32(s, rdpgfx->context.flags);

	WTSVirtualChannelWrite(rdpgfx->rdpgfx_channel, (PCHAR) Stream_Buffer(s), Stream_GetPosition(s), NULL);
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

static BOOL rdpgfx_server_open_channel(rdpgfx_server* rdpgfx)
{
	DWORD Error;
	HANDLE hEvent;
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
		return NULL;

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

	/* Wait for the client to confirm that the Audio Input dynamic channel is ready */

	while (1)
	{
		if (WaitForMultipleObjects(nCount, events, FALSE, 100) == WAIT_OBJECT_0)
			break;

		if (WTSVirtualChannelQuery(rdpgfx->rdpgfx_channel, WTSVirtualChannelReady, &buffer, &BytesReturned) == FALSE)
			break;

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
			Stream_Capacity(s), &BytesReturned) == FALSE)
		{
			if (BytesReturned == 0)
				break;
			
			Stream_EnsureRemainingCapacity(s, BytesReturned);

			if (WTSVirtualChannelRead(rdpgfx->rdpgfx_channel, 0, (PCHAR) Stream_Buffer(s),
				Stream_Capacity(s), &BytesReturned) == FALSE)
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
					IFCALL(rdpgfx->context.Activated, &rdpgfx->context);
				}
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

	rdpgfx->stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
	rdpgfx->thread = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE) rdpgfx_server_thread_func, (void*) rdpgfx, 0, NULL);
}

static BOOL rdpgfx_server_close(rdpgfx_server_context* context)
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

	if (rdpgfx->rdpgfx_channel)
	{
		WTSVirtualChannelClose(rdpgfx->rdpgfx_channel);
		rdpgfx->rdpgfx_channel = NULL;
	}

	return TRUE;
}

rdpgfx_server_context* rdpgfx_server_context_new(HANDLE vcm)
{
	rdpgfx_server* rdpgfx;

	rdpgfx = (rdpgfx_server*) calloc(1, sizeof(rdpgfx_server));

	rdpgfx->context.vcm = vcm;
	rdpgfx->context.Open = rdpgfx_server_open;

	return (rdpgfx_server_context*) rdpgfx;
}

void rdpgfx_server_context_free(rdpgfx_server_context* context)
{
	rdpgfx_server* rdpgfx = (rdpgfx_server*) context;

	rdpgfx_server_close(context);

	free(rdpgfx);
}
