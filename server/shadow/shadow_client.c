/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 *
 * Copyright 2014 Marc-Andre Moreau <marcandre.moreau@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
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

#include <winpr/crt.h>
#include <winpr/file.h>
#include <winpr/path.h>
#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/sysinfo.h>

#include <freerdp/log.h>

#include "shadow.h"

#define TAG CLIENT_TAG("shadow")

void shadow_client_context_new(freerdp_peer* peer, rdpShadowClient* client)
{
	rdpSettings* settings;
	rdpShadowServer* server;

	server = (rdpShadowServer*) peer->ContextExtra;
	client->server = server;
	client->subsystem = server->subsystem;

	settings = peer->settings;

	settings->ColorDepth = 32;
	settings->NSCodec = TRUE;
	settings->RemoteFxCodec = TRUE;
	settings->BitmapCacheV3Enabled = TRUE;
	settings->FrameMarkerCommandEnabled = TRUE;
	settings->SurfaceFrameMarkerEnabled = TRUE;
	settings->SupportGraphicsPipeline = FALSE;

	settings->DrawAllowSkipAlpha = TRUE;
	settings->DrawAllowColorSubsampling = TRUE;
	settings->DrawAllowDynamicColorFidelity = TRUE;

	settings->RdpSecurity = TRUE;
	settings->TlsSecurity = TRUE;
	settings->NlaSecurity = FALSE;

	settings->CertificateFile = _strdup(server->CertificateFile);
	settings->PrivateKeyFile = _strdup(server->PrivateKeyFile);

	settings->RdpKeyFile = _strdup(settings->PrivateKeyFile);

	client->inLobby = TRUE;
	client->mayView = server->mayView;
	client->mayInteract = server->mayInteract;

	InitializeCriticalSectionAndSpinCount(&(client->lock), 4000);

	region16_init(&(client->invalidRegion));

	client->vcm = WTSOpenServerA((LPSTR) peer->context);

	client->StopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);

	client->encoder = shadow_encoder_new(client);

	ArrayList_Add(server->clients, (void*) client);
}

void shadow_client_context_free(freerdp_peer* peer, rdpShadowClient* client)
{
	rdpShadowServer* server = client->server;

	ArrayList_Remove(server->clients, (void*) client);

	DeleteCriticalSection(&(client->lock));

	region16_uninit(&(client->invalidRegion));

	WTSCloseServer((HANDLE) client->vcm);

	CloseHandle(client->StopEvent);

	if (client->lobby)
	{
		shadow_surface_free(client->lobby);
		client->lobby = NULL;
	}

	if (client->encoder)
	{
		shadow_encoder_free(client->encoder);
		client->encoder = NULL;
	}
}

void shadow_client_message_free(wMessage* message)
{
	if (message->id == SHADOW_MSG_IN_REFRESH_OUTPUT_ID)
	{
		SHADOW_MSG_IN_REFRESH_OUTPUT* wParam = (SHADOW_MSG_IN_REFRESH_OUTPUT*) message->wParam;

		free(wParam->rects);
		free(wParam);
	}
	else if (message->id == SHADOW_MSG_IN_SUPPRESS_OUTPUT_ID)
	{
		SHADOW_MSG_IN_SUPPRESS_OUTPUT* wParam = (SHADOW_MSG_IN_SUPPRESS_OUTPUT*) message->wParam;
		free(wParam);
	}
}

BOOL shadow_client_capabilities(freerdp_peer* peer)
{
	return TRUE;
}

BOOL shadow_client_post_connect(freerdp_peer* peer)
{
	int authStatus;
	int width, height;
	rdpSettings* settings;
	rdpShadowClient* client;
	rdpShadowServer* server;
	RECTANGLE_16 invalidRect;
	rdpShadowSubsystem* subsystem;

	client = (rdpShadowClient*) peer->context;
	settings = peer->settings;
	server = client->server;
	subsystem = server->subsystem;

	if (!server->shareSubRect)
	{
		width = server->screen->width;
		height = server->screen->height;
	}
	else
	{
		width = server->subRect.right - server->subRect.left;
		height = server->subRect.bottom - server->subRect.top;
	}

	settings->DesktopWidth = width;
	settings->DesktopHeight = height;

	if (settings->ColorDepth == 24)
		settings->ColorDepth = 16; /* disable 24bpp */

	WLog_ERR(TAG, "Client from %s is activated (%dx%d@%d)",
			peer->hostname, settings->DesktopWidth, settings->DesktopHeight, settings->ColorDepth);

	peer->update->DesktopResize(peer->update->context);

	shadow_client_channels_post_connect(client);

	invalidRect.left = 0;
	invalidRect.top = 0;
	invalidRect.right = width;
	invalidRect.bottom = height;

	region16_union_rect(&(client->invalidRegion), &(client->invalidRegion), &invalidRect);

	shadow_client_init_lobby(client);

	authStatus = -1;

	if (settings->Username && settings->Password)
		settings->AutoLogonEnabled = TRUE;

	if (settings->AutoLogonEnabled && server->authentication)
	{
		if (subsystem->Authenticate)
		{
			authStatus = subsystem->Authenticate(subsystem,
					settings->Username, settings->Domain, settings->Password);
		}
	}

	if (server->authentication)
	{
		if (authStatus < 0)
		{
			WLog_ERR(TAG, "client authentication failure: %d", authStatus);
			return FALSE;
		}
	}

	return TRUE;
}

void shadow_client_refresh_rect(rdpShadowClient* client, BYTE count, RECTANGLE_16* areas)
{
	wMessage message = { 0 };
	SHADOW_MSG_IN_REFRESH_OUTPUT* wParam;
	wMessagePipe* MsgPipe = client->subsystem->MsgPipe;

	wParam = (SHADOW_MSG_IN_REFRESH_OUTPUT*) calloc(1, sizeof(SHADOW_MSG_IN_REFRESH_OUTPUT));

	if (!wParam)
		return;

	wParam->numRects = (UINT32) count;

	if (wParam->numRects)
	{
		wParam->rects = (RECTANGLE_16*) calloc(wParam->numRects, sizeof(RECTANGLE_16));

		if (!wParam->rects)
			return;
	}

	CopyMemory(wParam->rects, areas, wParam->numRects * sizeof(RECTANGLE_16));

	message.id = SHADOW_MSG_IN_REFRESH_OUTPUT_ID;
	message.wParam = (void*) wParam;
	message.lParam = NULL;
	message.context = (void*) client;
	message.Free = shadow_client_message_free;

	MessageQueue_Dispatch(MsgPipe->In, &message);
}

void shadow_client_suppress_output(rdpShadowClient* client, BYTE allow, RECTANGLE_16* area)
{
	wMessage message = { 0 };
	SHADOW_MSG_IN_SUPPRESS_OUTPUT* wParam;
	wMessagePipe* MsgPipe = client->subsystem->MsgPipe;

	wParam = (SHADOW_MSG_IN_SUPPRESS_OUTPUT*) calloc(1, sizeof(SHADOW_MSG_IN_SUPPRESS_OUTPUT));

	if (!wParam)
		return;

	wParam->allow = (UINT32) allow;

	if (area)
		CopyMemory(&(wParam->rect), area, sizeof(RECTANGLE_16));

	message.id = SHADOW_MSG_IN_SUPPRESS_OUTPUT_ID;
	message.wParam = (void*) wParam;
	message.lParam = NULL;
	message.context = (void*) client;
	message.Free = shadow_client_message_free;

	MessageQueue_Dispatch(MsgPipe->In, &message);
}

BOOL shadow_client_activate(freerdp_peer* peer)
{
	rdpSettings* settings = peer->settings;
	rdpShadowClient* client = (rdpShadowClient*) peer->context;

	if (strcmp(settings->ClientDir, "librdp") == 0)
	{
		/* Hack for Mac/iOS/Android Microsoft RDP clients */

		settings->RemoteFxCodec = FALSE;

		settings->NSCodec = FALSE;
		settings->NSCodecAllowSubsampling = FALSE;

		settings->SurfaceFrameMarkerEnabled = FALSE;
	}

	client->activated = TRUE;
	client->inLobby = client->mayView ? FALSE : TRUE;

	shadow_encoder_reset(client->encoder);

	shadow_client_refresh_rect(client, 0, NULL);

	return TRUE;
}

void shadow_client_surface_frame_acknowledge(rdpShadowClient* client, UINT32 frameId)
{
	SURFACE_FRAME* frame;
	wListDictionary* frameList;

	frameList = client->encoder->frameList;
	frame = (SURFACE_FRAME*) ListDictionary_GetItemValue(frameList, (void*) (size_t) frameId);

	if (frame)
	{
		ListDictionary_Remove(frameList, (void*) (size_t) frameId);
		free(frame);
	}
}

int shadow_client_send_surface_frame_marker(rdpShadowClient* client, UINT32 action, UINT32 id)
{
	SURFACE_FRAME_MARKER surfaceFrameMarker;
	rdpContext* context = (rdpContext*) client;
	rdpUpdate* update = context->update;

	surfaceFrameMarker.frameAction = action;
	surfaceFrameMarker.frameId = id;

	IFCALL(update->SurfaceFrameMarker, context, &surfaceFrameMarker);

	return 1;
}

int shadow_client_send_surface_bits(rdpShadowClient* client, rdpShadowSurface* surface, int nXSrc, int nYSrc, int nWidth, int nHeight)
{
	int i;
	BOOL first;
	BOOL last;
	wStream* s;
	int nSrcStep;
	BYTE* pSrcData;
	int numMessages;
	UINT32 frameId = 0;
	rdpUpdate* update;
	rdpContext* context;
	rdpSettings* settings;
	rdpShadowServer* server;
	rdpShadowEncoder* encoder;
	SURFACE_BITS_COMMAND cmd;

	context = (rdpContext*) client;
	update = context->update;
	settings = context->settings;

	server = client->server;
	encoder = client->encoder;

	pSrcData = surface->data;
	nSrcStep = surface->scanline;

	if (server->shareSubRect)
	{
		int subX, subY;
		int subWidth, subHeight;

		subX = server->subRect.left;
		subY = server->subRect.top;
		subWidth = server->subRect.right - server->subRect.left;
		subHeight = server->subRect.bottom - server->subRect.top;

		nXSrc -= subX;
		nYSrc -= subY;
		pSrcData = &pSrcData[(subY * nSrcStep) + (subX * 4)];
	}

	if (encoder->frameAck)
		frameId = (UINT32) shadow_encoder_create_frame_id(encoder);

	if (settings->RemoteFxCodec)
	{
		RFX_RECT rect;
		RFX_MESSAGE* messages;

		shadow_encoder_prepare(encoder, FREERDP_CODEC_REMOTEFX);

		s = encoder->bs;

		rect.x = nXSrc;
		rect.y = nYSrc;
		rect.width = nWidth;
		rect.height = nHeight;

		messages = rfx_encode_messages(encoder->rfx, &rect, 1, pSrcData,
				surface->width, surface->height, nSrcStep, &numMessages,
				settings->MultifragMaxRequestSize);

		cmd.codecID = settings->RemoteFxCodecId;

		cmd.destLeft = 0;
		cmd.destTop = 0;
		cmd.destRight = surface->width;
		cmd.destBottom = surface->height;

		cmd.bpp = 32;
		cmd.width = surface->width;
		cmd.height = surface->height;

		for (i = 0; i < numMessages; i++)
		{
			Stream_SetPosition(s, 0);
			rfx_write_message(encoder->rfx, s, &messages[i]);
			rfx_message_free(encoder->rfx, &messages[i]);

			cmd.bitmapDataLength = Stream_GetPosition(s);
			cmd.bitmapData = Stream_Buffer(s);

			first = (i == 0) ? TRUE : FALSE;
			last = ((i + 1) == numMessages) ? TRUE : FALSE;

			if (!encoder->frameAck)
				IFCALL(update->SurfaceBits, update->context, &cmd);
			else
				IFCALL(update->SurfaceFrameBits, update->context, &cmd, first, last, frameId);
		}

		free(messages);
	}
	else if (settings->NSCodec)
	{
		shadow_encoder_prepare(encoder, FREERDP_CODEC_NSCODEC);

		s = encoder->bs;
		Stream_SetPosition(s, 0);

		pSrcData = &pSrcData[(nYSrc * nSrcStep) + (nXSrc * 4)];

		nsc_compose_message(encoder->nsc, s, pSrcData, nWidth, nHeight, nSrcStep);

		cmd.bpp = 32;
		cmd.codecID = settings->NSCodecId;
		cmd.destLeft = nXSrc;
		cmd.destTop = nYSrc;
		cmd.destRight = cmd.destLeft + nWidth;
		cmd.destBottom = cmd.destTop + nHeight;
		cmd.width = nWidth;
		cmd.height = nHeight;

		cmd.bitmapDataLength = Stream_GetPosition(s);
		cmd.bitmapData = Stream_Buffer(s);

		first = TRUE;
		last = TRUE;

		if (!encoder->frameAck)
			IFCALL(update->SurfaceBits, update->context, &cmd);
		else
			IFCALL(update->SurfaceFrameBits, update->context, &cmd, first, last, frameId);
	}

	return 1;
}

int shadow_client_send_bitmap_update(rdpShadowClient* client, rdpShadowSurface* surface, int nXSrc, int nYSrc, int nWidth, int nHeight)
{
	BYTE* data;
	BYTE* buffer;
	int yIdx, xIdx, k;
	int rows, cols;
	int nSrcStep;
	BYTE* pSrcData;
	UINT32 DstSize;
	UINT32 SrcFormat;
	BITMAP_DATA* bitmap;
	rdpUpdate* update;
	rdpContext* context;
	rdpSettings* settings;
	UINT32 maxUpdateSize;
	UINT32 totalBitmapSize;
	UINT32 updateSizeEstimate;
	BITMAP_DATA* bitmapData;
	BITMAP_UPDATE bitmapUpdate;
	rdpShadowServer* server;
	rdpShadowEncoder* encoder;

	context = (rdpContext*) client;
	update = context->update;
	settings = context->settings;

	server = client->server;
	encoder = client->encoder;

	maxUpdateSize = settings->MultifragMaxRequestSize;

	if (settings->ColorDepth < 32)
		shadow_encoder_prepare(encoder, FREERDP_CODEC_INTERLEAVED);
	else
		shadow_encoder_prepare(encoder, FREERDP_CODEC_PLANAR);

	pSrcData = surface->data;
	nSrcStep = surface->scanline;
	SrcFormat = PIXEL_FORMAT_RGB32;

	if ((nXSrc % 4) != 0)
	{
		nWidth += (nXSrc % 4);
		nXSrc -= (nXSrc % 4);
	}

	if ((nYSrc % 4) != 0)
	{
		nHeight += (nYSrc % 4);
		nYSrc -= (nYSrc % 4);
	}

	rows = (nHeight / 64) + ((nHeight % 64) ? 1 : 0);
	cols = (nWidth / 64) + ((nWidth % 64) ? 1 : 0);

	k = 0;
	totalBitmapSize = 0;

	bitmapUpdate.count = bitmapUpdate.number = rows * cols;
	bitmapData = (BITMAP_DATA*) malloc(sizeof(BITMAP_DATA) * bitmapUpdate.number);
	bitmapUpdate.rectangles = bitmapData;

	if (!bitmapData)
		return -1;

	if ((nWidth % 4) != 0)
	{
		nXSrc -= (nWidth % 4);
		nWidth += (nWidth % 4);
	}

	if ((nHeight % 4) != 0)
	{
		nYSrc -= (nHeight % 4);
		nHeight += (nHeight % 4);
	}

	for (yIdx = 0; yIdx < rows; yIdx++)
	{
		for (xIdx = 0; xIdx < cols; xIdx++)
		{
			bitmap = &bitmapData[k];

			bitmap->width = 64;
			bitmap->height = 64;
			bitmap->destLeft = nXSrc + (xIdx * 64);
			bitmap->destTop = nYSrc + (yIdx * 64);

			if ((bitmap->destLeft + bitmap->width) > (nXSrc + nWidth))
				bitmap->width = (nXSrc + nWidth) - bitmap->destLeft;

			if ((bitmap->destTop + bitmap->height) > (nYSrc + nHeight))
				bitmap->height = (nYSrc + nHeight) - bitmap->destTop;

			bitmap->destRight = bitmap->destLeft + bitmap->width - 1;
			bitmap->destBottom = bitmap->destTop + bitmap->height - 1;
			bitmap->compressed = TRUE;

			if ((bitmap->width < 4) || (bitmap->height < 4))
				continue;

			if (settings->ColorDepth < 32)
			{
				int bitsPerPixel = settings->ColorDepth;
				int bytesPerPixel = (bitsPerPixel + 7) / 8;

				DstSize = 64 * 64 * 4;
				buffer = encoder->grid[k];

				interleaved_compress(encoder->interleaved, buffer, &DstSize, bitmap->width, bitmap->height,
						pSrcData, SrcFormat, nSrcStep, bitmap->destLeft, bitmap->destTop, NULL, bitsPerPixel);

				bitmap->bitmapDataStream = buffer;
				bitmap->bitmapLength = DstSize;
				bitmap->bitsPerPixel = bitsPerPixel;
				bitmap->cbScanWidth = bitmap->width * bytesPerPixel;
				bitmap->cbUncompressedSize = bitmap->width * bitmap->height * bytesPerPixel;
			}
			else
			{
				int dstSize;

				buffer = encoder->grid[k];
				data = &pSrcData[(bitmap->destTop * nSrcStep) + (bitmap->destLeft * 4)];

				buffer = freerdp_bitmap_compress_planar(encoder->planar, data, SrcFormat,
						bitmap->width, bitmap->height, nSrcStep, buffer, &dstSize);

				bitmap->bitmapDataStream = buffer;
				bitmap->bitmapLength = dstSize;
				bitmap->bitsPerPixel = 32;
				bitmap->cbScanWidth = bitmap->width * 4;
				bitmap->cbUncompressedSize = bitmap->width * bitmap->height * 4;
			}

			bitmap->cbCompFirstRowSize = 0;
			bitmap->cbCompMainBodySize = bitmap->bitmapLength;

			totalBitmapSize += bitmap->bitmapLength;
			k++;
		}
	}

	bitmapUpdate.count = bitmapUpdate.number = k;

	updateSizeEstimate = totalBitmapSize + (k * bitmapUpdate.count) + 16;

	if (updateSizeEstimate > maxUpdateSize)
	{
		fprintf(stderr, "update size estimate larger than maximum update size\n");
	}

	IFCALL(update->BitmapUpdate, context, &bitmapUpdate);

	free(bitmapData);

	return 1;
}

int shadow_client_send_surface_update(rdpShadowClient* client)
{
	int status = -1;
	int nXSrc, nYSrc;
	int nWidth, nHeight;
	rdpContext* context;
	rdpSettings* settings;
	rdpShadowServer* server;
	rdpShadowSurface* surface;
	rdpShadowEncoder* encoder;
	REGION16 invalidRegion;
	RECTANGLE_16 surfaceRect;
	const RECTANGLE_16* extents;

	context = (rdpContext*) client;
	settings = context->settings;
	server = client->server;
	encoder = client->encoder;

	surface = client->inLobby ? client->lobby : server->surface;

	EnterCriticalSection(&(client->lock));

	region16_init(&invalidRegion);
	region16_copy(&invalidRegion, &(client->invalidRegion));
	region16_clear(&(client->invalidRegion));

	LeaveCriticalSection(&(client->lock));

	surfaceRect.left = 0;
	surfaceRect.top = 0;
	surfaceRect.right = surface->width;
	surfaceRect.bottom = surface->height;

	region16_intersect_rect(&invalidRegion, &invalidRegion, &surfaceRect);

	if (server->shareSubRect)
	{
		region16_intersect_rect(&invalidRegion, &invalidRegion, &(server->subRect));
	}

	if (region16_is_empty(&invalidRegion))
	{
		region16_uninit(&invalidRegion);
		return 1;
	}

	extents = region16_extents(&invalidRegion);

	nXSrc = extents->left - 0;
	nYSrc = extents->top - 0;
	nWidth = extents->right - extents->left;
	nHeight = extents->bottom - extents->top;

	//WLog_INFO(TAG, "shadow_client_send_surface_update: x: %d y: %d width: %d height: %d right: %d bottom: %d",
	//	nXSrc, nYSrc, nWidth, nHeight, nXSrc + nWidth, nYSrc + nHeight);

	if (settings->RemoteFxCodec || settings->NSCodec)
	{
		status = shadow_client_send_surface_bits(client, surface, nXSrc, nYSrc, nWidth, nHeight);
	}
	else
	{
		status = shadow_client_send_bitmap_update(client, surface, nXSrc, nYSrc, nWidth, nHeight);
	}

	region16_uninit(&invalidRegion);

	return status;
}

int shadow_client_surface_update(rdpShadowClient* client, REGION16* region)
{
	int index;
	int numRects = 0;
	const RECTANGLE_16* rects;

	EnterCriticalSection(&(client->lock));

	rects = region16_rects(region, &numRects);

	for (index = 0; index < numRects; index++)
	{
		region16_union_rect(&(client->invalidRegion), &(client->invalidRegion), &rects[index]);
	}

	LeaveCriticalSection(&(client->lock));

	return 1;
}

void* shadow_client_thread(rdpShadowClient* client)
{
	DWORD status;
	DWORD nCount;
	HANDLE events[32];
	HANDLE StopEvent;
	HANDLE ClientEvent;
	HANDLE ChannelEvent;
	HANDLE UpdateEvent;
	freerdp_peer* peer;
	rdpContext* context;
	rdpSettings* settings;
	rdpShadowServer* server;
	rdpShadowScreen* screen;
	rdpShadowEncoder* encoder;
	rdpShadowSubsystem* subsystem;

	server = client->server;
	screen = server->screen;
	encoder = client->encoder;
	subsystem = server->subsystem;

	context = (rdpContext*) client;
	peer = context->peer;
	settings = peer->settings;

	peer->Capabilities = shadow_client_capabilities;
	peer->PostConnect = shadow_client_post_connect;
	peer->Activate = shadow_client_activate;

	shadow_input_register_callbacks(peer->input);

	peer->Initialize(peer);

	peer->update->RefreshRect = (pRefreshRect) shadow_client_refresh_rect;
	peer->update->SuppressOutput = (pSuppressOutput) shadow_client_suppress_output;
	peer->update->SurfaceFrameAcknowledge = (pSurfaceFrameAcknowledge) shadow_client_surface_frame_acknowledge;

	StopEvent = client->StopEvent;
	UpdateEvent = subsystem->updateEvent;
	ClientEvent = peer->GetEventHandle(peer);
	ChannelEvent = WTSVirtualChannelManagerGetEventHandle(client->vcm);

	while (1)
	{
		nCount = 0;
		events[nCount++] = StopEvent;
		events[nCount++] = UpdateEvent;
		events[nCount++] = ClientEvent;
		events[nCount++] = ChannelEvent;

		status = WaitForMultipleObjects(nCount, events, FALSE, INFINITE);

		if (WaitForSingleObject(StopEvent, 0) == WAIT_OBJECT_0)
		{
			if (WaitForSingleObject(UpdateEvent, 0) == WAIT_OBJECT_0)
			{
				EnterSynchronizationBarrier(&(subsystem->barrier), 0);
			}

			break;
		}

		if (WaitForSingleObject(UpdateEvent, 0) == WAIT_OBJECT_0)
		{
			if (client->activated)
			{
				int index;
				int numRects = 0;
				const RECTANGLE_16* rects;

				rects = region16_rects(&(subsystem->invalidRegion), &numRects);

				for (index = 0; index < numRects; index++)
				{
					region16_union_rect(&(client->invalidRegion), &(client->invalidRegion), &rects[index]);
				}

				shadow_client_send_surface_update(client);
			}

			EnterSynchronizationBarrier(&(subsystem->barrier), 0);

			while (WaitForSingleObject(UpdateEvent, 0) == WAIT_OBJECT_0);
		}

		if (WaitForSingleObject(ClientEvent, 0) == WAIT_OBJECT_0)
		{
			if (!peer->CheckFileDescriptor(peer))
			{
				WLog_ERR(TAG, "Failed to check FreeRDP file descriptor");
				break;
			}
		}

		if (WaitForSingleObject(ChannelEvent, 0) == WAIT_OBJECT_0)
		{
			if (WTSVirtualChannelManagerCheckFileDescriptor(client->vcm) != TRUE)
			{
				WLog_ERR(TAG, "WTSVirtualChannelManagerCheckFileDescriptor failure");
				break;
			}
		}
	}

	peer->Disconnect(peer);
	
	freerdp_peer_context_free(peer);
	freerdp_peer_free(peer);

	ExitThread(0);

	return NULL;
}

void shadow_client_accepted(freerdp_listener* listener, freerdp_peer* peer)
{
	rdpShadowClient* client;
	rdpShadowServer* server;

	server = (rdpShadowServer*) listener->info;

	peer->ContextExtra = (void*) server;
	peer->ContextSize = sizeof(rdpShadowClient);
	peer->ContextNew = (psPeerContextNew) shadow_client_context_new;
	peer->ContextFree = (psPeerContextFree) shadow_client_context_free;
	freerdp_peer_context_new(peer);

	client = (rdpShadowClient*) peer->context;

	client->thread = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)
			shadow_client_thread, client, 0, NULL);
}
