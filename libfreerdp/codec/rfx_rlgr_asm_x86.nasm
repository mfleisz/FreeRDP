section .text

%ifdef WIN32
extern _memset
%define xmemset	_memset
%else
extern memset
%define xmemset	memset
%endif

section .code

%ifdef WIN32
%define rfx_rlgr_decode_asm _rfx_rlgr_decode_asm
%define rfx_rlgr_encode_asm _rfx_rlgr_encode_asm
%endif


; eax  - temp & return
; ebx  - bl:bits_left bh:sign 0xFF000000:mode
; dl   - kp
; dh   - krp
; edi  - read_bits
; esi  - temp
; ebp  - mag
; [esp]     - dst
; [esp+1Ch] - data
; [esp+20h] - data_size
; [esp+24h] - buffer
; [esp+28h] - buffer_size

; read 32 bits into read_bits if bits_left < nBits
%macro ReadBits 1 ; %1:nBits
	; if (bits_left >= nBits) break
	cmp bl, %1
	jge %%ReadBits_exit
	; if (data_size <= 0) exit
	mov esi, [esp+20h]
	test esi, esi
	jle rfx_rlgr_decode_exit
	; esi = first 2 bytes in [data] in big-endian order
	mov ecx, [esp+1Ch]
	mov si, [ecx]
	rol si, 8
	movzx esi, si
	; esi <<= 16 - bits_left
	mov cl, 16
	sub cl, bl
	shl esi, cl
	; read_bits |= esi
	or edi, esi
	; r = min(2, data_size)
	mov ecx, 2
	mov esi, [esp+20h]
	cmp ecx, esi
	cmovg ecx, esi
	; data += r
	; data_size -= r
	add [esp+1Ch], ecx
	sub [esp+20h], ecx
	; bits_left += r * 8
	shl cl, 3
	add bl, cl
%%ReadBits_exit:
%endmacro

%macro GetBits 2 ; %1:nBits, %2:result
	test %1, %1
	jne %%GetBits_1
	xor %2, %2
	jmp %%GetBits_exit
%%GetBits_1:
	ReadBits %1
	; result = read_bits >> (32 - nBits)
	mov %2, edi
	mov cl, 32
	sub cl, %1
	shr %2, cl
	; read_bits <<= nBits
	mov cl, %1
	shl edi, cl
	; bits_left -= nBits
	sub bl, %1
%%GetBits_exit:
%endmacro

%macro GetBit 1 ; %1:result
	ReadBits 1
	; read_bits <<= 1 (first bit shifted out to carry flag)
	shl edi, 1
	; result = carry flag
	setc %1
	; bits_left--
	dec bl
%%GetBit_exit:
%endmacro

%macro WriteValue 1 ; %1:value
	; if (buffer_size <= 0) exit
	dec DWORD [esp+28h]
	jl rfx_rlgr_decode_exit
	; *dst++ = %1;
	mov ecx, [esp]
	mov WORD [ecx], %1
	add DWORD [esp], 2
%endmacro

%macro WriteZeroes 1 ; %1:nZeroes
	sub DWORD [esp+28h], %1
	jle rfx_rlgr_decode_exit
	shl %1, 1
	add DWORD [esp], %1
%endmacro

%macro WriteZero 0
	dec DWORD [esp+28h]
	jle rfx_rlgr_decode_exit
	add DWORD [esp], 2
%endmacro

%macro UpdateParamUp 2 ; %1:param %2:deltaP
	movzx cx, %1
	add cx, %2
	; if (param > KPMAX) param = KPMAX
	mov si, 80
	cmp cx, si
	cmovg cx, si
	mov %1, cl
%endmacro

%macro UpdateParamDown 2 ; %1:param %2:deltaP
	movzx cx, %1
	xor si, si
	sub cx, %2
	; if (param < 0) param = 0
	cmovs cx, si
	mov %1, cl
%endmacro

%macro GetMinBits 2 ; %1:val, %2:nbits
	mov ecx, -1
	bsr %2, %1
	cmovz %2, ecx
	inc %2
%endmacro

%macro GetOneBits 1 ; %1:vk
	xor %1, %1
%%GetOneBits_loop:
	ReadBits 1
	; eax = position of the first zero bit
	mov ecx, edi
	not ecx
	bsr eax, ecx
	; if not found goto next
	jz %%GetOneBits_next
	; if (bits_left < 32 - eax) goto next
	mov ecx, 32
	sub ecx, eax
	cmp bl, cl
	jl %%GetOneBits_next
	; result = ecx - 1
	add %1, ecx
	dec %1
	; read_bits <<= cl
	shl edi, cl
	; bits_left -= cl
	sub bl, cl
	jmp %%GetOneBits_exit
%%GetOneBits_next:
	; result += bits_left
	movzx ecx, bl
	add %1, ecx
	; read_bits = 0
	; bits_left = 0
	xor edi, edi
	xor bl, bl
	jmp %%GetOneBits_loop
%%GetOneBits_exit:
%endmacro

%macro GetGRCode 0
	; vk
	GetOneBits ebp
	; GetBits(kr, mag)
	movzx eax, dh
	shr eax, 3
	GetBits al, esi
	xchg esi, ebp
	; mag |= (vk << kr)
	mov cl, al
	mov eax, esi
	shl eax, cl
	or ebp, eax
	; if (!vk)
	cmp esi, 1
	je %%GetGRCode_exit
	jg %%GetGRCode_1
	;   UpdateParam(krp, -2, kr)
	UpdateParamDown dh, 2
	jmp %%GetGRCode_exit
%%GetGRCode_1:
	; else if (vk != 1)
	;   UpdateParam(krp, vk, kr)
	UpdateParamUp dh, si
%%GetGRCode_exit:
%endmacro

%macro GetIntFrom2MagSign 1 ; %1:mag
	; mag = (((mag) & 1) ? -1 * (INT16)(((mag) + 1) >> 1) : (INT16)((mag) >> 1))
	shr %1, 1
	jnc %%GetIntFrom2MagSign_1
	inc %1
	neg %1
%%GetIntFrom2MagSign_1:
%endmacro

global rfx_rlgr_decode_asm
rfx_rlgr_decode_asm:
	push ebx
	push edi
	push esi
	push ebp
	sub esp, 04h

	mov ecx, DWORD [esp+28h]
	shl ecx, 1
	mov edi, DWORD [esp+24h]
	push ecx
	push 0
	push edi
	call xmemset
	add esp,0Ch

	; read_bits = 0
	xor edi, edi
	; bits_used = 0
	xor ebx, ebx
	; mode
	mov bl, [esp+18h]
	bswap ebx
	; dst = buffer
	mov ecx, [esp+24h]
	mov [esp], ecx
	; k = 1
	; kp = k << LSGR
	; kr = 1
	; krp = kr << LSGR
	mov edx, 0808h

rfx_rlgr_decode_loop:
	; if (k) RL MODE
	test dl, 0F8h
	je rfx_rlgr_decode_grmode

rfx_rlgr_decode_rlmode:
	;   do
	;     GetBit r
	GetBit al
	;     if (r) break
	test al, al
	jne rfx_rlgr_decode_rlmode_1
	;     WriteZeroes(1 << k)
	mov eax, 1
	mov cl, dl
	shr cl, 3
	shl eax, cl
	WriteZeroes eax
	;     UpdateParam(kp, UP_GR, k)
	UpdateParamUp dl, 4
	;   loop
	jmp rfx_rlgr_decode_rlmode
rfx_rlgr_decode_rlmode_1:
	;   GetBits(k, run)
	mov al, dl
	shr al, 3
	GetBits al, esi
	;   WriteZeroes(run)
	test esi, esi
	je rfx_rlgr_decode_rlmode_2
	mov eax, esi
	WriteZeroes eax
rfx_rlgr_decode_rlmode_2:
	;   GetBits(1, sign)
	GetBit bh
	;   GetGRCode(krp, kr, vk, mag)
	GetGRCode
	;   mag = (int) (mag + 1)
	inc ebp
	;   WriteValue(sign ? -mag : mag)
	test bh, bh
	je rfx_rlgr_decode_rlmode_3
	neg ebp
rfx_rlgr_decode_rlmode_3:
	WriteValue bp
	; UpdateParam(kp, -DN_GR, k)
	UpdateParamDown dl, 6
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_grmode:
	; else GR MODE
	;   GetGRCode(krp, kr, vk, mag)
	GetGRCode
	;   if (mode == RLGR1)
	test ebx, 0FF000000h
	jne rfx_rlgr_decode_grmode_1
	;     if (!mag)
	test ebp, ebp
	jne rfx_rlgr_decode_grmode_2
	;       WriteValue(0)
	WriteZero
	;       UpdateParam(kp, UQ_GR, k)
	UpdateParamUp dl, 3
	jmp rfx_rlgr_decode_loop
rfx_rlgr_decode_grmode_2:
	;     else // mag != 0
	;       WriteValue(GetIntFrom2MagSign(mag))
	GetIntFrom2MagSign ebp
	WriteValue bp
	;       UpdateParam(kp, -DQ_GR, k)
	UpdateParamDown dl, 3
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_grmode_1:
	;   else // mode == RLGR3
	;     GetMinBits(mag, nIdx)
	GetMinBits ebp, eax
	;     GetBits(nIdx, val1)
	GetBits al, esi
	;     val2 = mag - val1
	sub ebp, esi
	; WriteValue(GetIntFrom2MagSign(val1))
	GetIntFrom2MagSign si
	WriteValue si
	; WriteValue(GetIntFrom2MagSign(val2))
	GetIntFrom2MagSign bp
	WriteValue bp
	;     if (val1 && val2)
	test esi, esi
	je rfx_rlgr_decode_grmode_3
	test ebp, ebp
	je rfx_rlgr_decode_grmode_5
	;       UpdateParam(kp, -2 * DQ_GR, k)
	UpdateParamDown dl, 6
	jmp rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_3:
	;     else if (!val1 && !val2)
	test ebp, ebp
	jne rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_4:
	;       UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParamUp dl, 6
rfx_rlgr_decode_grmode_5:
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_exit:
	mov eax, [esp]
	sub eax, [esp+24h]
	shr eax, 1
	add esp, 04h
	pop ebp
	pop esi
	pop edi
	pop ebx
	ret



; ----------------------------------------------------------------------------


; eax  - temp & return
; ebx  - bl:bits_avail bh:temp 0xFF000000:mode
; dl   - kp
; dh   - krp
; edi  - write_bits
; esi  - temp
; ebp  - temp
; [esp]     - dst
; [esp+04h] - mag
; [esp+08h] - temp
; [esp+24h] - data
; [esp+28h] - data_size
; [esp+2Ch] - buffer
; [esp+30h] - buffer_size

%macro GetNextInput 2 ; %1:n, %2:exitIfNone
	; if (data_size <= 0) exit
	mov ecx, [esp+28h]
	test ecx, ecx
%if %2 = 1
	jle rfx_rlgr_encode_flush
%else
	jg %%GetNextInput_1
	xor %1, %1
	jmp %%GetNextInput_exit
%endif
%%GetNextInput_1:
	; n = *data++;
	; data_size--;
	mov ecx, [esp+24h]
	mov %1, WORD [ecx]
	add DWORD [esp+24h], 2
	dec DWORD [esp+28h]
%%GetNextInput_exit:
%endmacro

%macro GetNextNonzeroInput 2 ; %1:nZeroes, %2:n
	xor %1, %1
	; if (data_size <= 0) exit
	mov ecx, [esp+28h]
	test ecx, ecx
	jle rfx_rlgr_encode_flush
	mov esi, [esp+24h]
%%GetNextNonzeroInput_loop:
	mov %2, WORD [esi]
	add esi, 2
	dec ecx
	test %2, %2
	jnz %%GetNextNonzeroInput_exit
	inc %1
	test ecx, ecx
	jg %%GetNextNonzeroInput_loop
%%GetNextNonzeroInput_exit:
	mov [esp+24h], esi
	mov [esp+28h], ecx
%endmacro

%macro FlushOutput 1 ; %1:reset
	; if (buffer_size < 4) exit
	cmp DWORD [esp+30h], 4
	jl rfx_rlgr_encode_exit
	; write 4 bytes
	bswap edi
	mov ecx, [esp]
	mov DWORD [ecx], edi
	sub DWORD [esp+30h], 4
	add DWORD [esp], 4
%if %1 = 1
	; reset pending bits
	xor edi, edi
	mov bl, 32
%endif
%endmacro

%macro FlushRemainingOutput 0
	; if (buffer_size < 4) exit
	cmp DWORD [esp+30h], 4
	jl rfx_rlgr_encode_exit
	; if (bits_avail >= 4 * 8) exit
	cmp bl, 32
	jge rfx_rlgr_encode_exit
	; write 4 bytes
	bswap edi
	mov ecx, [esp]
	mov DWORD [ecx], edi
	; dst += (32 - bits_avail + 7) / 8
	mov ecx, 32 + 7
	sub cl, bl
	shr ecx, 3
	add [esp], ecx
%endmacro

%macro OutputBits 2 ; %1:numBits, %2:bitPattern
	; if (bits_avail > numBits)
	cmp bl, %1
	jl %%OutputBits_less
	je %%OutputBits_equal
	;   write_bits |= bitPattern << (bits_avail - numBits)
	mov cl, bl
	sub cl, %1
	mov esi, %2
	shl esi, cl
	or edi, esi
	;   bits_avail -= numBits
	sub bl, %1
	jmp %%OutputBits_exit
%%OutputBits_less:
	; else if (bits_avail < numBits)
	;   write_bits |= bitPattern >> (numBits - bits_avail)
	mov cl, %1
	sub cl, bl
	mov esi, %2
	shr esi, cl
	or edi, esi
	mov bl, cl
	FlushOutput 0
	;   bits_avail = (32 - (numBits - bits_avail))
	;   write_bits = bitPattern << bits_avail
	neg bl
	add bl, 32
	mov cl, bl
	mov edi, %2
	shl edi, cl
	jmp %%OutputBits_exit
%%OutputBits_equal:
	; else // bits_avail == numBits
	;   write_bits |= bitPattern
	or edi, %2
	FlushOutput 1
%%OutputBits_exit:
%endmacro

%macro OutputRemainingBitsOne 0
	mov esi, -1
	mov cl, 32
	sub cl, bl
	shr esi, cl
	or edi, esi
	FlushOutput 1
%endmacro

%macro OutputBitsOne 1 ; %1:count
	; do
%%OutputBitsOne_loop:
	;   if (bits_avail < count)
	movzx eax, bl
	cmp eax, %1
	jg %%OutputBitsOne_greater
	je %%OutputBitsOne_equal
	;     output bits_avail bits
	OutputRemainingBitsOne
	;     count -= bits_avail
	sub %1, eax
	; while (count > 0)
	jmp %%OutputBitsOne_loop
%%OutputBitsOne_greater:
	; output count bits
	cmp bl, 32
	setl al
	movzx esi, al
	mov cl, bl
	shl esi, cl
	mov eax, 1
	sub ecx, %1
	shl eax, cl
	sub esi, eax
	or edi, esi
	; bits_avail -= count
	sub ebx, %1
	jmp %%OutputBitsOne_exit
%%OutputBitsOne_equal:
	OutputRemainingBitsOne
%%OutputBitsOne_exit:
%endmacro

%macro OutputBitZero 0
	; bits_avail--
	dec bl
	jnz %%OutputBitZero_exit
	FlushOutput 1
%%OutputBitZero_exit:
%endmacro

%macro OutputBitOne 0
	; output one bit
	mov cl, bl
	dec cl
	mov esi, 1
	shl esi, cl
	or edi, esi
	; bits_avail--
	dec bl
	jnz %%OutputBitZero_exit
	FlushOutput 1
%%OutputBitZero_exit:
%endmacro

%macro CodeGR 0
	mov [esp+04h], ebp
	; kr = *krp >> LSGR
	mov cl, dh
	shr cl, 3
	mov bh, cl
	; vk = (val) >> kr
	shr ebp, cl
	; if (vk > 1)
	cmp ebp, 1
	jl %%CodeGR_2
	je %%CodeGR_1
	;   UpdateParam(*krp, vk, kr)
	UpdateParamUp dh, bp
%%CodeGR_1:
	;   // vk >= 1
	;   OutputBit(vk, 1)
	;   OutputBit(1, 0)
	OutputBitsOne ebp
	OutputBitZero
	jmp %%CodeGR_3
%%CodeGR_2:
	; else // vk == 0
	;   UpdateParam(*krp, -2, kr)
	UpdateParamDown dh, 2
	;   OutputBit(1, 0)
	OutputBitZero
%%CodeGR_3:
	;   if (kr)
	;     OutputBits(kr, val & ((1 << kr) - 1))
	test bh, bh
	jz %%CodeGR_exit
	mov ebp, [esp+04h]
	mov esi, 1
	mov cl, bh
	shl esi, cl
	dec esi
	and ebp, esi
	OutputBits bh, ebp
%%CodeGR_exit:
%endmacro

%macro Get2MagSign 1 ; %1:value
	shl %1, 1
	jnc %%Get2MagSign_exit
	neg %1
	dec %1
%%Get2MagSign_exit:
%endmacro

global rfx_rlgr_encode_asm
rfx_rlgr_encode_asm:
	push ebx
	push edi
	push esi
	push ebp
	sub esp, 0Ch

	; write_bits = 0
	xor edi, edi
	; mode
	mov bl, [esp+20h]
	movzx ebx, bl
	bswap ebx
	; bits_avail = 32
	mov bl, 32
	; dst = buffer
	mov ecx, [esp+2Ch]
	mov [esp], ecx
	; k = 1
	; kp = k << LSGR
	; kr = 1
	; krp = kr << LSGR
	mov edx, 0808h

rfx_rlgr_encode_loop:
	; if (k) RL MODE
	test dl, 0F8h
	je rfx_rlgr_encode_grmode

rfx_rlgr_encode_rlmode:
	GetNextNonzeroInput eax, bp
	mov [esp+04h], bp

rfx_rlgr_encode_rlmode_1:
	; runmax = 1 << k;
	; while (numZeros >= runmax)
	mov ebp, 1
	mov cl, dl
	shr cl, 3
	mov bh, cl
	shl ebp, cl
	cmp eax, ebp
	jl rfx_rlgr_encode_rlmode_2
	;   OutputBit(1, 0)
	OutputBitZero
	;   numZeros -= runmax
	sub eax, ebp
	;   UpdateParam(kp, UP_GR, k)
	UpdateParamUp dl, 4
	; loop
	jmp rfx_rlgr_encode_rlmode_1

rfx_rlgr_encode_rlmode_2:
	; OutputBit(1, 1)
	OutputBitOne
	; OutputBits(k, numZeros)
	OutputBits bh, eax
	; if (input < 0)
	mov bp, [esp+04h]
	test bp, bp
	jge rfx_rlgr_encode_rlmode_3
	; mag = -input;
	neg bp
	;   OutputBit(1, 1)
	OutputBitOne
	jmp rfx_rlgr_encode_rlmode_4
rfx_rlgr_encode_rlmode_3:
	; else
	;   OutputBit(1, 0)
	OutputBitZero

rfx_rlgr_encode_rlmode_4:
	; CodeGR(krp, mag ? mag - 1 : 0)
	test bp, bp
	jz rfx_rlgr_encode_rlmode_5
	dec bp
rfx_rlgr_encode_rlmode_5:
	movzx ebp, bp
	CodeGR
	; UpdateParam(kp, -DN_GR, k)
	UpdateParamDown dl, 6
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_grmode:
	; if (mode == RLGR1)
	test ebx, 0FF000000h
	jnz rfx_rlgr_encode_grmode_1
	;   GetNextInput(input)
	GetNextInput bp, 1
	;   twoMs = Get2MagSign(input)
	movsx ebp, bp
	Get2MagSign ebp
	;   CodeGR(&krp, twoMs)
	CodeGR
	;   if (twoMs)
	mov ebp, [esp+04h]
	test ebp, ebp
	jz rfx_rlgr_encode_grmode_2
	;     UpdateParam(kp, -DQ_GR, k)
	UpdateParamDown dl, 3
	jmp rfx_rlgr_encode_loop
rfx_rlgr_encode_grmode_2:
	;   else
	;     UpdateParam(kp, UQ_GR, k)
	UpdateParamUp dl, 3
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_grmode_1:
	; else // mode == RLGR3
	;   GetNextInput(input)
	GetNextInput si, 1
	;   twoMs1 = Get2MagSign(input)
	movsx esi, si
	Get2MagSign esi
	;   GetNextInput(input)
	GetNextInput bp, 0
	;   twoMs2 = Get2MagSign(input)
	movsx ebp, bp
	Get2MagSign ebp
	;   sum2Ms = twoMs1 + twoMs2
	add ebp, esi
	;   CodeGR(&krp, sum2Ms)
	mov [esp+08h], esi
	CodeGR
	;   GetMinBits(sum2Ms, nIdx)
	mov ebp, [esp+04h]
	bsr eax, ebp
	jz rfx_rlgr_encode_grmode_3
	inc eax
	;   OutputBits(nIdx, twoMs1)
	OutputBits al, [esp+08h]
rfx_rlgr_encode_grmode_3:
	;   if (twoMs1 && twoMs2)
	mov esi, [esp+08h]
	test esi, esi
	jz rfx_rlgr_encode_grmode_4
	cmp ebp, esi
	je rfx_rlgr_encode_loop
	;     UpdateParam(kp, -2 * DQ_GR, k)
	UpdateParamDown dl, 6
	jmp rfx_rlgr_encode_loop
	;   else if (!twoMs1 && !twoMs2)
rfx_rlgr_encode_grmode_4:
	test ebp, ebp
	jnz rfx_rlgr_encode_loop
	;     UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParamUp dl, 6
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_flush:
	FlushRemainingOutput

rfx_rlgr_encode_exit:
	; return dst - buffer
	mov eax, [esp]
	sub eax, [esp+2Ch]
	add esp, 0Ch
	pop ebp
	pop esi
	pop edi
	pop ebx
	ret

