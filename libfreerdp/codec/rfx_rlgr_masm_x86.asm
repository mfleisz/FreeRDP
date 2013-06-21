.686p
.xmm
.model FLAT, C

.data

XmmZero dd 0, 0, 0, 0

.code

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
ReadBits MACRO nBits
LOCAL ReadBits_exit
	; if (bits_left >= nBits) break
	cmp bl, nBits
	jge ReadBits_exit
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
ReadBits_exit:
ENDM

GetBits MACRO nBits, result
LOCAL GetBits_1, GetBits_exit
	test nBits, nBits
	jne GetBits_1
	xor result, result
	jmp GetBits_exit
GetBits_1:
	ReadBits nBits
	; result = read_bits >> (32 - nBits)
	mov result, edi
	mov cl, 32
	sub cl, nBits
	shr result, cl
	; read_bits <<= nBits
	mov cl, nBits
	shl edi, cl
	; bits_left -= nBits
	sub bl, nBits
GetBits_exit:
ENDM

GetBit MACRO result
LOCAL GetBit_exit
	ReadBits 1
	; read_bits <<= 1 (first bit shifted out to carry flag)
	shl edi, 1
	; result = carry flag
	setc result
	; bits_left--
	dec bl
GetBit_exit:
ENDM

WriteValue MACRO value
	; if (buffer_size <= 0) exit
	mov ecx, [esp+28h]
	test ecx, ecx
	jle rfx_rlgr_decode_exit
	; *dst++ = value;
	mov ecx, [esp]
	mov WORD PTR [ecx], value
	add DWORD PTR [esp], 2
	dec DWORD PTR [esp+28h]
ENDM

WriteZeroes MACRO nZeroes
LOCAL WriteZeroes_loop, WriteZeroes_loop2, WriteZeroes_last, WriteZeroes_lastx, WriteZeroes_exit
	mov ecx, [esp+28h]
WriteZeroes_loop:
	cmp ecx, 8
	jl WriteZeroes_loop2
	cmp nZeroes, 8
	jl WriteZeroes_loop2
	mov esi, [esp]
	movdqu [esi], xmm1
	add DWORD PTR [esp], 16
	sub ecx, 8
	sub nZeroes, 8
	jmp WriteZeroes_loop
WriteZeroes_loop2:
	cmp ecx, 1
	jl rfx_rlgr_decode_exit
	je WriteZeroes_last
	cmp nZeroes, 1
	jl WriteZeroes_exit
	je WriteZeroes_lastx
	mov esi, [esp]
	mov DWORD PTR [esi], 0
	add DWORD PTR [esp], 4
	sub ecx, 2
	sub nZeroes, 2
	jmp WriteZeroes_loop2
WriteZeroes_last:
	test nZeroes, nZeroes
	je WriteZeroes_exit
WriteZeroes_lastx:
	mov esi, [esp]
	mov WORD PTR [esi], 0
	add DWORD PTR [esp], 2
	dec ecx
WriteZeroes_exit:
	mov [esp+28h], ecx
ENDM

UpdateParam MACRO param, deltaP
	movzx cx, param
	add cx, deltaP
	; if (param > KPMAX) param = KPMAX
	mov si, 80
	cmp cx, si
	cmovg cx, si
	; if (param < 0) param = 0
	xor si, si
	cmp cx, si
	cmovl cx, si
	; k = (param >> LSGR)
	mov param, cl
ENDM

GetMinBits MACRO val, nbits
	mov ecx, -1
	bsr nbits, val
	cmovz nbits, ecx
	inc nbits
ENDM

GetOneBits MACRO vk
LOCAL GetOneBits_loop, GetOneBits_next, GetOneBits_exit
	xor vk, vk
GetOneBits_loop:
	ReadBits 1
	; eax = position of the first zero bit
	mov ecx, edi
	not ecx
	bsr eax, ecx
	; if not found goto next
	jz GetOneBits_next
	; if (bits_left < 32 - eax) goto next
	mov ecx, 32
	sub ecx, eax
	cmp bl, cl
	jl GetOneBits_next
	; result = ecx - 1
	add vk, ecx
	dec vk
	; read_bits <<= cl
	shl edi, cl
	; bits_left -= cl
	sub bl, cl
	jmp GetOneBits_exit
GetOneBits_next:
	; result += bits_left
	movzx ecx, bl
	add vk, ecx
	; read_bits = 0
	; bits_left = 0
	xor edi, edi
	xor bl, bl
	jmp GetOneBits_loop
GetOneBits_exit:
ENDM

GetGRCode MACRO
LOCAL GetGRCode_1, GetGRCode_exit
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
	test esi, esi
	jne GetGRCode_1
	;   UpdateParam(krp, -2, kr)
	UpdateParam dh, -2
	jmp GetGRCode_exit
GetGRCode_1:
	; else if (vk != 1)
	cmp esi, 1
	je GetGRCode_exit
	;   UpdateParam(krp, vk, kr)
	UpdateParam dh, si
GetGRCode_exit:
ENDM

GetIntFrom2MagSign MACRO mag
LOCAL GetIntFrom2MagSign_1
	; mag = (((mag) & 1) ? -1 * (INT16)(((mag) + 1) >> 1) : (INT16)((mag) >> 1))
	shr mag, 1
	jnc GetIntFrom2MagSign_1
	inc mag
	neg mag
GetIntFrom2MagSign_1:
ENDM

rfx_rlgr_decode PROC
	push ebx
	push edi
	push esi
	push ebp
	sub esp, 04h

	lea ecx, [XmmZero]
	movdqu xmm1, [ecx]
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
	UpdateParam dl, 4
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
	UpdateParam dl, -6
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
	WriteValue 0
	;       UpdateParam(kp, UQ_GR, k)
	UpdateParam dl, 3
	jmp rfx_rlgr_decode_loop
rfx_rlgr_decode_grmode_2:
	;     else // mag != 0
	;       WriteValue(GetIntFrom2MagSign(mag))
	GetIntFrom2MagSign ebp
	WriteValue bp
	;       UpdateParam(kp, -DQ_GR, k)
	UpdateParam dl, -3
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
	UpdateParam dl, -6
	jmp rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_3:
	;     else if (!val1 && !val2)
	test ebp, ebp
	jne rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_4:
	;       UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParam dl, 6
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

rfx_rlgr_decode ENDP

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

GetNextInput MACRO n, exitIfNone
LOCAL GetNextInput_1, GetNextInput_exit
	; if (data_size <= 0) exit
	mov ecx, [esp+28h]
	test ecx, ecx
IF exitIfNone EQ 1
	jle rfx_rlgr_encode_flush
ELSE
	jg GetNextInput_1
	xor n, n
	jmp GetNextInput_exit
ENDIF
GetNextInput_1:
	; n = *data++;
	; data_size--;
	mov ecx, [esp+24h]
	mov n, WORD PTR [ecx]
	add DWORD PTR [esp+24h], 2
	dec DWORD PTR [esp+28h]
GetNextInput_exit:
ENDM

GetNextNonzeroInput MACRO nZeroes, n
LOCAL GetNextNonzeroInput_exit, GetNextNonzeroInput_loop
	xor nZeroes, nZeroes
	; if (data_size <= 0) exit
	mov ecx, [esp+28h]
	test ecx, ecx
	jle rfx_rlgr_encode_flush
	mov esi, [esp+24h]
GetNextNonzeroInput_loop:
	mov n, WORD PTR [esi]
	add esi, 2
	dec ecx
	test n, n
	jnz GetNextNonzeroInput_exit
	inc nZeroes
	test ecx, ecx
	jg GetNextNonzeroInput_loop
GetNextNonzeroInput_exit:
	mov [esp+24h], esi
	mov [esp+28h], ecx
ENDM

FlushOutput MACRO reset
	; if (buffer_size < 4) exit
	cmp DWORD PTR [esp+30h], 4
	jl rfx_rlgr_encode_exit
	; write 4 bytes
	bswap edi
	mov ecx, [esp]
	mov DWORD PTR [ecx], edi
	sub DWORD PTR [esp+30h], 4
	add DWORD PTR [esp], 4
IF reset EQ 1
	; reset pending bits
	xor edi, edi
	mov bl, 32
ENDIF
ENDM

FlushRemainingOutput MACRO
	; if (buffer_size < 4) exit
	cmp DWORD PTR [esp+30h], 4
	jl rfx_rlgr_encode_exit
	; if (bits_avail >= 4 * 8) exit
	cmp bl, 32
	jge rfx_rlgr_encode_exit
	; write 4 bytes
	bswap edi
	mov ecx, [esp]
	mov DWORD PTR [ecx], edi
	; dst += (32 - bits_avail + 7) / 8
	mov ecx, 32 + 7
	sub cl, bl
	shr ecx, 3
	add [esp], ecx
ENDM

OutputBits MACRO numBits, bitPattern
LOCAL OutputBits_less, OutputBits_equal, OutputBits_exit
	; if (bits_avail > numBits)
	cmp bl, numBits
	jl OutputBits_less
	je OutputBits_equal
	;   write_bits |= bitPattern << (bits_avail - numBits)
	mov cl, bl
	sub cl, numBits
	mov esi, bitPattern
	shl esi, cl
	or edi, esi
	;   bits_avail -= numBits
	sub bl, numBits
	jmp OutputBits_exit
OutputBits_less:
	; else if (bits_avail < numBits)
	;   write_bits |= bitPattern >> (numBits - bits_avail)
	mov cl, numBits
	sub cl, bl
	mov esi, bitPattern
	shr esi, cl
	or edi, esi
	mov bl, cl
	FlushOutput 0
	;   bits_avail = (32 - (numBits - bits_avail))
	;   write_bits = bitPattern << bits_avail
	neg bl
	add bl, 32
	mov cl, bl
	mov edi, bitPattern
	shl edi, cl
	jmp OutputBits_exit
OutputBits_equal:
	; else // bits_avail == numBits
	;   write_bits |= bitPattern
	or edi, bitPattern
	FlushOutput 1
OutputBits_exit:
ENDM

OutputRemainingBitsOne MACRO
	mov esi, -1
	mov cl, 32
	sub cl, bl
	shr esi, cl
	or edi, esi
	FlushOutput 1
ENDM

OutputBitsOne MACRO count
LOCAL OutputBitsOne_loop, OutputBitsOne_greater, OutputBitsOne_equal, OutputBitsOne_exit
	; do
OutputBitsOne_loop:
	;   if (bits_avail < count)
	movzx eax, bl
	cmp eax, count
	jg OutputBitsOne_greater
	je OutputBitsOne_equal
	;     output bits_avail bits
	OutputRemainingBitsOne
	;     count -= bits_avail
	sub count, eax
	; while (count > 0)
	jmp OutputBitsOne_loop
OutputBitsOne_greater:
	; output count bits
	cmp bl, 32
	setl al
	movzx esi, al
	mov cl, bl
	shl esi, cl
	mov eax, 1
	sub ecx, count
	shl eax, cl
	sub esi, eax
	or edi, esi
	; bits_avail -= count
	sub ebx, count
	jmp OutputBitsOne_exit
OutputBitsOne_equal:
	OutputRemainingBitsOne
OutputBitsOne_exit:
ENDM

OutputBitZero MACRO
LOCAL OutputBitZero_exit
	; bits_avail--
	dec bl
	jnz OutputBitZero_exit
	FlushOutput 1
OutputBitZero_exit:
ENDM

OutputBitOne MACRO
LOCAL OutputBitZero_exit
	; output one bit
	mov cl, bl
	dec cl
	mov esi, 1
	shl esi, cl
	or edi, esi
	; bits_avail--
	dec bl
	jnz OutputBitZero_exit
	FlushOutput 1
OutputBitZero_exit:
ENDM

CodeGR MACRO
LOCAL CodeGR_1, CodeGR_2, CodeGR_3, CodeGR_exit
	mov [esp+04h], ebp
	; kr = *krp >> LSGR
	mov cl, dh
	shr cl, 3
	mov bh, cl
	; vk = (val) >> kr
	shr ebp, cl
	; if (vk > 1)
	cmp ebp, 1
	jl CodeGR_2
	je CodeGR_1
	;   UpdateParam(*krp, vk, kr)
	UpdateParam dh, bp
CodeGR_1:
	;   // vk >= 1
	;   OutputBit(vk, 1)
	;   OutputBit(1, 0)
	OutputBitsOne ebp
	OutputBitZero
	jmp CodeGR_3
CodeGR_2:
	; else // vk == 0
	;   UpdateParam(*krp, -2, kr)
	UpdateParam dh, -2
	;   OutputBit(1, 0)
	OutputBitZero
CodeGR_3:
	;   if (kr)
	;     OutputBits(kr, val & ((1 << kr) - 1))
	test bh, bh
	jz CodeGR_exit
	mov ebp, [esp+04h]
	mov esi, 1
	mov cl, bh
	shl esi, cl
	dec esi
	and ebp, esi
	OutputBits bh, ebp
CodeGR_exit:
ENDM

Get2MagSign MACRO value
LOCAL Get2MagSign_exit
	shl value, 1
	jnc Get2MagSign_exit
	neg value
	dec value
Get2MagSign_exit:
ENDM

rfx_rlgr_encode PROC
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
	UpdateParam dl, 4
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
	UpdateParam dl, -6
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
	UpdateParam dl, -3
	jmp rfx_rlgr_encode_loop
rfx_rlgr_encode_grmode_2:
	;   else
	;     UpdateParam(kp, UQ_GR, k)
	UpdateParam dl, 3
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
	UpdateParam dl, -6
	jmp rfx_rlgr_encode_loop
	;   else if (!twoMs1 && !twoMs2)
rfx_rlgr_encode_grmode_4:
	test ebp, ebp
	jnz rfx_rlgr_encode_loop
	;     UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParam dl, 6
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

rfx_rlgr_encode ENDP

END
