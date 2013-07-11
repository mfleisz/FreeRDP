#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/stream.h>

#include <freerdp/freerdp.h>
#include <freerdp/constants.h>
#include <freerdp/utils/pcap.h>
#include <freerdp/utils/stopwatch.h>
#include <freerdp/codec/rfx.h>
#include <freerdp/codec/nsc.h>

#ifndef _WIN32
#include <sys/time.h>
#endif

//#define PERFTEST_DEBUG 1
//#define PERFTEST_DUMP_FRAMES 1
#define PERFTEST_WIDTH 1920
#define PERFTEST_HEIGHT 1080

enum SURFCMD_CMDTYPE
{
	CMDTYPE_SET_SURFACE_BITS = 0x0001,
	CMDTYPE_FRAME_MARKER = 0x0004,
	CMDTYPE_STREAM_SURFACE_BITS = 0x0006
};

RFX_CONTEXT* rfx_context;
NSC_CONTEXT* nsc_context;

#ifndef ABS
#define ABS(x) (((x) < 0) ? -(x) : (x))
#endif

#ifndef COUNTOF
#define COUNTOF(x) ((sizeof(x)/sizeof(0[x])) / ((size_t)(!(sizeof(x) % sizeof(0[x])))))
#endif

BOOL perftest_intersect_rect(const RFX_RECT *A, const RFX_RECT *B, RFX_RECT *result);
void perftest_handle_decoded_rfx_message(SURFACE_BITS_COMMAND* surface_bits_command, RFX_MESSAGE* message, wStream *s, int level);
void perftest_surface_bits(SURFACE_BITS_COMMAND* surface_bits_command, wStream *s);

BOOL perftest_intersect_rect(const RFX_RECT *A, const RFX_RECT *B, RFX_RECT *result)
{
	UINT32 Amin, Amax, Bmin, Bmax;
	INT32 height, width;

	if (!A || !B || !result) {
		return FALSE;
	}

	/* Special cases for empty rects */
	if (A->width==0 || A->height==0 || B->width==0 || B->height==0) {
		return FALSE;
	}

	/* Horizontal intersection */
	Amin = A->x;
	Amax = Amin + A->width;
	Bmin = B->x;
	Bmax = Bmin + B->width;
	if (Bmin > Amin)
		Amin = Bmin;
	result->x = Amin;
	if (Bmax < Amax)
		Amax = Bmax;
	width = Amax - Amin;
	if (width<=0)
		return FALSE;
	result->width = width;

	/* Vertical intersection */
	Amin = A->y;
	Amax = Amin + A->height;
	Bmin = B->y;
	Bmax = Bmin + B->height;
	if (Bmin > Amin)
		Amin = Bmin;
	result->y = Amin;
	if (Bmax < Amax)
		Amax = Bmax;
	height = Amax - Amin;
	if (height<=0)
		return FALSE;
	result->height = height;

	return TRUE;
}


void perftest_handle_decoded_rfx_message(SURFACE_BITS_COMMAND* surface_bits_command, RFX_MESSAGE* message, wStream *s, int level)
{
	int i, j, y;
	UINT8 *src;
	UINT8 *dst;

	RFX_RECT rect_a;
	RFX_RECT rect_b;
	RFX_RECT rect_c;

	static BYTE* screen_buffer = NULL;

	if (screen_buffer == NULL)
	{
		screen_buffer = (BYTE*)malloc(PERFTEST_WIDTH*PERFTEST_HEIGHT*4);
		if (screen_buffer == NULL) {
			printf("Error allocating screen buffer memory\n");
			return;
		}
	}

	rect_a.width = 64;
	rect_a.height = 64;

	for (i = 0; i < message->num_tiles; i++)
	{
		rect_a.x = message->tiles[i]->x;
		rect_a.y = message->tiles[i]->y;

		for (j = 0; j < message->num_rects; j++)
		{
			rect_b.x = message->rects[j].x;
			rect_b.y = message->rects[j].y;
			rect_b.width = message->rects[j].width;
			rect_b.height = message->rects[j].height;

			if (perftest_intersect_rect(&rect_a, &rect_b, &rect_c))
			{
				rect_c.x -= rect_a.x;
				rect_c.y -= rect_a.y;
				src = message->tiles[i]->data + rect_c.y*256 + rect_c.x*4;
				dst = screen_buffer +
					4 * PERFTEST_WIDTH * (surface_bits_command->destTop + message->tiles[i]->y + rect_c.y) +
					4 * (surface_bits_command->destLeft + message->tiles[i]->x + rect_c.x);

				for (y = 0; y < rect_c.height; y++)
				{
					memcpy(dst, src, rect_c.width*4);
					dst+=PERFTEST_WIDTH*4;
					src+=256;
				}
			}
		}
	}

#ifdef PERFTEST_DUMP_FRAMES
	{
		static int id = 0;
		FILE* fp;
		BYTE* p;
		char fname[1024] = { 0 };

		sprintf(fname, "perftest-%08d.ppm", id++);
		if (!(fp = fopen(fname, "wb")))
		{
			printf("Error opening [%s] for writing\n", fname);
		}
		else
		{
			fprintf(fp, "P6\n# CREATOR: FreeRDP-PerfTest\n%d %d\n255\n", PERFTEST_WIDTH, PERFTEST_HEIGHT);
			p = screen_buffer;
			for (i=0; i<PERFTEST_HEIGHT*PERFTEST_WIDTH; i++)
			{
				fwrite(p, 3, 1, fp);
				p+=4;
			}
			fclose(fp);
		}
	}
#endif

	if (level==0)
	{
		int left, top, width, height;
		RFX_RECT rect;
		BYTE* offset;
		Stream_SetPosition(s, 0);

		left   = surface_bits_command->destLeft;
		top    = surface_bits_command->destTop;
		width  = surface_bits_command->destRight - surface_bits_command->destLeft;
		height = surface_bits_command->destBottom - surface_bits_command->destTop;

		rect.x = 0;
		rect.y = 0;
		rect.width = width;
		rect.height = height;

		offset = screen_buffer + (top * PERFTEST_WIDTH * 4) + (left * 4);

		rfx_compose_message(rfx_context, s, &rect, 1, offset, width, height, PERFTEST_WIDTH * 4);

#ifdef PERFTEST_DUMP_FRAMES
#if 0	// Enable this to verify our decoded data (only useful in combination with PERFTEST_DUMP_FRAMES defined
		{
			RFX_MESSAGE* msg = rfx_process_message(rfx_context, Stream_Buffer(s), Stream_GetPosition(s));
			perftest_handle_decoded_rfx_message(surface_bits_command, msg, s, 1);
			rfx_message_free(rfx_context, msg);
		}
#endif
#endif
	}
}

void perftest_surface_bits(SURFACE_BITS_COMMAND* surface_bits_command, wStream *s)
{
#ifdef PERFTEST_DEBUG
	printf("-------------------------------------------------------------------------------\n");
	printf("%s dstrect: %04d %04d %04d %04d %02dbpp %04dx%04d len:%07d",
		surface_bits_command->codecID == RDP_CODEC_ID_REMOTEFX ? "RFX" : \
		surface_bits_command->codecID == RDP_CODEC_ID_NSCODEC  ? "NSC" : \
		surface_bits_command->codecID == RDP_CODEC_ID_NONE     ? "NOC" : \
		                                                         "UNK",
		surface_bits_command->destLeft,
		surface_bits_command->destTop,
		surface_bits_command->destRight,
		surface_bits_command->destBottom,
		surface_bits_command->bpp,
		surface_bits_command->width,
		surface_bits_command->height,
		surface_bits_command->bitmapDataLength);
#endif

	if (surface_bits_command->codecID == RDP_CODEC_ID_REMOTEFX)
	{
		RFX_MESSAGE* message = rfx_process_message(rfx_context,	surface_bits_command->bitmapData, surface_bits_command->bitmapDataLength);
#ifdef PERFTEST_DEBUG
		printf(" rec:%04d til:%04d", message->num_rects, message->num_tiles);
#endif
		perftest_handle_decoded_rfx_message(surface_bits_command, message, s, 0);

		rfx_message_free(rfx_context, message);
	}
	else if (surface_bits_command->codecID == RDP_CODEC_ID_NSCODEC)
	{
		nsc_process_message(nsc_context, surface_bits_command->bpp, surface_bits_command->width, surface_bits_command->height,
			surface_bits_command->bitmapData, surface_bits_command->bitmapDataLength);
	}
	else if (surface_bits_command->codecID == RDP_CODEC_ID_NONE)
	{
		// nothing to measure
	}
	else
	{
		fprintf(stderr, "Unsupported codecID %d\n", surface_bits_command->codecID);
	}
#ifdef PERFTEST_DEBUG
	printf("\n");
#endif
}

int main(int argc, char **argv)
{
	rdpPcap* pcap;
	pcap_record record;
	char *pcap_file;
	UINT16 cmdType;
	SURFACE_BITS_COMMAND cmd;
	wStream *s;
	STOPWATCH* swtotal = stopwatch_create();
	UINT32 record_count = 0;

	if (argc != 2)
	{
		printf("usage: \"%s\" session.pcap\nNote: resolution maximum of pcap is expected to be %dx%d!\n\n", argv[0], PERFTEST_WIDTH, PERFTEST_HEIGHT);
		return 1;
	}
	pcap_file = argv[1];

	stopwatch_start(swtotal);

	rfx_context = rfx_context_new();
	rfx_context->mode = RLGR3;
	rfx_context->width = PERFTEST_WIDTH;
	rfx_context->height = PERFTEST_HEIGHT;
	rfx_context_set_pixel_format(rfx_context, RDP_PIXEL_FORMAT_R8G8B8A8);

	nsc_context = nsc_context_new();

	if (!(pcap = pcap_open(pcap_file, FALSE)))
	{
		printf("Error opening [%s] for reading\n", pcap_file);
		return 1;
	}

	if (!(s = Stream_New(NULL, PERFTEST_WIDTH*PERFTEST_HEIGHT*4)))
	{
		printf("Error allocating stream\n");
		return 1;
	}

	record.data = Stream_Buffer(s);

	printf(">> Processing pcap file ...\n");

	while (pcap_has_next_record(pcap) && record_count++ < 100)
	{
		Stream_SetPosition(s, 0);
		pcap_get_next_record_header(pcap, &record);
		if (Stream_Capacity(s) < record.length)
		{
			printf("Error: insufficient stream buffer size\n");
			return 1;
		}
		pcap_get_next_record_content(pcap, &record);
		Stream_SetLength(s, record.length);
		Stream_Read_UINT16(s, cmdType);
		switch (cmdType)
		{
			case CMDTYPE_SET_SURFACE_BITS:
			case CMDTYPE_STREAM_SURFACE_BITS:
				{
					if (Stream_GetRemainingLength(s) < 20)
					{
						printf("Error: invalid length for surface command\n");
						return 1;
					}
					Stream_Read_UINT16(s, cmd.destLeft);
					Stream_Read_UINT16(s, cmd.destTop);
					Stream_Read_UINT16(s, cmd.destRight);
					Stream_Read_UINT16(s, cmd.destBottom);
					Stream_Read_UINT8(s,  cmd.bpp);
					Stream_Seek(s, 2); /* reserved1, reserved2 */
					Stream_Read_UINT8(s,  cmd.codecID);
					Stream_Read_UINT16(s, cmd.width);
					Stream_Read_UINT16(s, cmd.height);
					Stream_Read_UINT32(s, cmd.bitmapDataLength);
					if (Stream_GetRemainingLength(s) < cmd.bitmapDataLength)
					{
						printf("Error: invalid bitmapDataLength \n");
						return 1;
					}
					cmd.bitmapData = Stream_Pointer(s);
					perftest_surface_bits(&cmd, s);
				}
				break;
			case CMDTYPE_FRAME_MARKER:
#ifdef PERFTEST_DEBUG
				printf("--------------------------------------------------------------------------------\n");
				printf("CMDTYPE_FRAME_MARKER\n");
#endif
				break;
			default:
				printf("--------------------------------------------------------------------------------\n");
				printf("UNKNOWN CMDTYPE 0x%04X\n", cmdType);
		}
	}
	pcap_close(pcap);

	stopwatch_stop(swtotal);
	printf("\n>>> Execution time: %fs\n    Note: set WITH_PROFILER if you don't see any stats!\n", stopwatch_get_elapsed_time_in_seconds(swtotal));

	rfx_context_free(rfx_context);
	nsc_context_free(nsc_context);

	return 0;
}
