#ifdef RFX_RLGR_OPTION

#ifdef WIN32
#define WINABI
#else
#ifdef _M_AMD64
#define WINABI  __attribute__((__ms_abi__))
#else
#define WINABI __attribute__((__cdecl__))
#endif
#endif


#if (RFX_RLGR_OPTION == 1)	// Our ASM RLGR implementation

#define RLGR_ENCODER_PROFILER_NAME "rfx_rlgr_encode_tsasm"
#define RLGR_DECODER_PROFILER_NAME "rfx_rlgr_decode_tsasm"

int WINABI rfx_rlgr_encode_asm(RLGR_MODE mode, const INT16* data, int data_size, BYTE* buffer, int buffer_size);
int WINABI rfx_rlgr_decode_asm(RLGR_MODE mode, const BYTE* data, int data_size, INT16* buffer, int buffer_size);

int rfx_rlgr_encode_function(RLGR_MODE mode, const INT16* data, int data_size, BYTE* buffer, int buffer_size) {
	return rfx_rlgr_encode_asm(mode, data, data_size, buffer, buffer_size);
}

int rfx_rlgr_decode_function(RLGR_MODE mode, const BYTE* data, int data_size, INT16* buffer, int buffer_size) {
	return rfx_rlgr_decode_asm(mode, data, data_size, buffer, buffer_size);
}

#elif (RFX_RLGR_OPTION == 2)	// Microsoft's native RLGR implementation ripped from rdpcorets.dll

#define RLGR_ENCODER_PROFILER_NAME "rfx_rlgr_encode_microsoft"
#define RLGR_DECODER_PROFILER_NAME "rfx_rlfr_decode_microsoft"

int WINABI microsoft_cacencoding_encrlgr3(const INT16* data, int data_size, BYTE* buffer, int buffer_size);
int WINABI microsoft_cacdecoding_decrlgr3(const BYTE* data, int data_size, INT16* buffer, int buffer_size);

int rfx_rlgr_encode_function(RLGR_MODE mode, const INT16* data, int data_size, BYTE* buffer, int buffer_size) {
	return (mode==1 ? microsoft_cacencoding_encrlgr3(data, data_size, buffer, buffer_size) : 0);
}

int rfx_rlgr_decode_function(RLGR_MODE mode, const BYTE* data, int data_size, INT16* buffer, int buffer_size) {
	return (mode==1 ? microsoft_cacdecoding_decrlgr3(data, data_size, buffer, buffer_size) : 0);
}

#endif


#define RFX_INIT_RLGR_OPTIONS(_ctx)                                                 \
{                                                                                   \
  IF_PROFILER(_ctx->priv->prof_rfx_rlgr_encode->name = RLGR_ENCODER_PROFILER_NAME); \
  _ctx->rlgr_encode = rfx_rlgr_encode_function;                                     \
  IF_PROFILER(_ctx->priv->prof_rfx_rlgr_decode->name = RLGR_DECODER_PROFILER_NAME); \
  _ctx->rlgr_decode = rfx_rlgr_decode_function;                                     \
}


#endif // RFX_RLGR_OPTION defined
