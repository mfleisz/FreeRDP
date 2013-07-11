section .data

XmmZero dd 0, 0, 0, 0

section .code

; rax  - temp & return
; rdx  - data
; r8d  - data_size
; r9   - buffer
; r10d - buffer_size
; r11  - dst
; bl   - bits_left
; bh   - sign
; r12  - read_bits
; r13d - kp
; r14  - temp
; r15d - krp
; edi  - temp
; esi  - mode
; ebp  - mag

; read 32 bits into read_bits if bits_left < nBits
%macro ReadBits 1 ; %1:nBits
	; if (bits_left >= nBits) break
	cmp bl, %1
	jge %%ReadBits_exit
	; if (data_size <= 0) exit
	test r8d, r8d
	jle rfx_rlgr_decode_exit
	; r14 = first 4 bytes in [data] in big-endian order
	xor r14, r14
	mov r14d, [rdx]
	bswap r14d
	; r14 <<= 32 - bits_left
	mov cl, 32
	sub cl, bl
	shl r14, cl
	; read_bits |= r14
	or r12, r14
	; r = min(4, data_size)
	mov rcx, 4
	cmp ecx, r8d
	cmovg ecx, r8d
	; data += r
	; data_size -= r
	add rdx, rcx
	sub r8d, ecx
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
	; result = read_bits >> (64 - nBits)
	mov %2, r12
	mov cl, 64
	sub cl, %1
	shr %2, cl
	; read_bits <<= nBits
	mov cl, %1
	shl r12, cl
	; bits_left -= nBits
	sub bl, %1
%%GetBits_exit:
%endmacro

%macro GetBit 1 ; %1:result
	ReadBits 1
	; read_bits <<= 1 (first bit shifted out to carry flag)
	shl r12, 1
	; result = carry flag
	setc %1
	; bits_left--
	dec bl
%%GetBit_exit:
%endmacro

%macro WriteValue 1 ; %1:value
	; if (buffer_size <= 0) exit
	test r10d, r10d
	jle rfx_rlgr_decode_exit
	; *buffer++ = value;
	mov WORD [r11], %1
	add r11, 2
	dec r10d
%endmacro

%macro WriteZeroes 1 ; %1:nZeroes
%%WriteZeroes_loop:
	cmp r10d, 8
	jl %%WriteZeroes_loop2
	cmp %1, 8
	jl %%WriteZeroes_loop2
	movdqu [r11], xmm1
	add r11, 16
	sub r10d, 8
	sub %1, 8
	jmp %%WriteZeroes_loop
%%WriteZeroes_loop2:
	cmp r10d, 1
	jl rfx_rlgr_decode_exit
	je %%WriteZeroes_last
	cmp %1, 1
	jl %%WriteZeroes_exit
	je %%WriteZeroes_lastx
	mov DWORD [r11], 0
	add r11, 4
	sub r10d, 2
	sub %1, 2
	jmp %%WriteZeroes_loop2
%%WriteZeroes_last:
	test %1, %1
	je %%WriteZeroes_exit
%%WriteZeroes_lastx:
	mov WORD [r11], 0
	add r11, 2
	dec r10d
%%WriteZeroes_exit:
%endmacro


%macro UpdateParam 2 ; %1:param, %2:deltaP
	add %1, %2
	; if (param > KPMAX) param = KPMAX
	mov ecx, 80
	cmp %1, ecx
	cmovg %1, ecx
	; if (param < 0) param = 0
	xor ecx, ecx
	cmp %1, ecx
	cmovl %1, ecx
	; k = (param >> LSGR)
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
	mov r14, r12
	not r14
	bsr rax, r14
	; if not found goto next
	jz %%GetOneBits_next
	; if (bits_left < 64 - eax) goto next
	mov ecx, 64
	sub ecx, eax
	cmp bl, cl
	jl %%GetOneBits_next
	; result = ecx - 1
	add %1, ecx
	dec %1
	; read_bits <<= cl
	shl r12, cl
	; bits_left -= cl
	sub bl, cl
	jmp %%GetOneBits_exit
%%GetOneBits_next:
	; result += bits_left
	movzx ecx, bl
	add %1, ecx
	; read_bits = 0
	; bits_left = 0
	xor r12, r12
	xor bl, bl
	jmp %%GetOneBits_loop
%%GetOneBits_exit:
%endmacro

%macro GetGRCode 0
	GetOneBits edi
	; GetBits(kr, mag)
	mov eax, r15d
	shr eax, 3
	GetBits al, rbp
	; mag |= (vk << kr)
	mov cl, al
	mov eax, edi
	shl eax, cl
	or ebp, eax
	; if (!vk)
	test edi, edi
	jne %%GetGRCode_1
	;   UpdateParam(krp, -2, kr)
	UpdateParam r15d, -2
	jmp %%GetGRCode_exit
%%GetGRCode_1:
	; else if (vk != 1)
	cmp edi, 1
	je %%GetGRCode_exit
	;   UpdateParam(krp, vk, kr)
	UpdateParam r15d, edi
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
	mov r10d, [rsp+28h]
	push rbx
	push r12
	push r13
	push r14
	push r15
	push rdi
	push rsi
	push rbp
	mov esi, ecx
	xor rax, rax
	xor r12, r12	
	lea rcx, [rel XmmZero]	
	movdqu xmm1, [rcx]

	; bits_used = 0
	xor rbx,rbx
	; dst = buffer
	mov r11, r9
	; k = 1
	; kp = k << LSGR
	mov r13d, 8
	; kr = 1
	; krp = kr << LSGR
	mov r15d, 8

rfx_rlgr_decode_loop:
	; if (k) RL MODE
	test r13d, 0FFFFFFF8h
	je rfx_rlgr_decode_grmode

rfx_rlgr_decode_rlmode:
	;   do
	;     GetBit r
	GetBit al
	;     if (r) break
	test al, al
	jne rfx_rlgr_decode_rlmode_1
	;     WriteZeroes(1 << k)
	mov rax, 1
	mov ecx, r13d
	shr ecx, 3
	shl rax, cl
	WriteZeroes rax
	;     UpdateParam(kp, UP_GR, k)
	UpdateParam r13d, 4
	;   loop
	jmp rfx_rlgr_decode_rlmode
rfx_rlgr_decode_rlmode_1:
	;   GetBits(k, run)
	mov edi, r13d
	shr edi, 3
	GetBits dil, rax
	;   WriteZeroes(run)
	test eax, eax
	je rfx_rlgr_decode_rlmode_2
	WriteZeroes rax
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
	UpdateParam r13d, -6
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_grmode:
	; else GR MODE
	;   GetGRCode(krp, kr, vk, mag)
	GetGRCode
	;   if (mode == RLGR1)
	test esi, esi
	jne rfx_rlgr_decode_grmode_1
	;     if (!mag)
	test ebp, ebp
	jne rfx_rlgr_decode_grmode_2
	;       WriteValue(0)
	WriteValue 0
	;       UpdateParam(kp, UQ_GR, k)
	UpdateParam r13d, 3
	jmp rfx_rlgr_decode_loop
rfx_rlgr_decode_grmode_2:
	;     else // mag != 0
	;       WriteValue(GetIntFrom2MagSign(mag))
	GetIntFrom2MagSign ebp
	WriteValue bp
	;       UpdateParam(kp, -DQ_GR, k)
	UpdateParam r13d, -3
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_grmode_1:
	;   else // mode == RLGR3
	;     GetMinBits(mag, nIdx)
	GetMinBits ebp, eax
	;     GetBits(nIdx, val1)
	GetBits al, rdi
	;     val2 = mag - val1
	sub ebp, edi
	;     if (val1 && val2)
	test edi, edi
	je rfx_rlgr_decode_grmode_3
	test ebp, ebp
	je rfx_rlgr_decode_grmode_5
	;       UpdateParam(kp, -2 * DQ_GR, k)
	UpdateParam r13d, -6
	jmp rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_3:
	;     else if (!val1 && !val2)
	test ebp, ebp
	jne rfx_rlgr_decode_grmode_5
rfx_rlgr_decode_grmode_4:
	;       UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParam r13d, 6
rfx_rlgr_decode_grmode_5:
	; WriteValue(GetIntFrom2MagSign(val1))
	GetIntFrom2MagSign di
	WriteValue di
	; WriteValue(GetIntFrom2MagSign(val2))
	GetIntFrom2MagSign bp
	WriteValue bp
	jmp rfx_rlgr_decode_loop

rfx_rlgr_decode_exit:
	; return dst - buffer
	mov rax, r11
	sub rax, r9
	shr eax, 1
	pop rbp
	pop rsi
	pop rdi
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret



; ----------------------------------------------------------------------------


; rax  - temp & return
; rbx  - bl:bits_avail bh:temp 0xFF000000:mode
; rdx  - data
; r8d  - data_size
; r9   - buffer
; r10d - buffer_size
; r11  - dst
; r12  - write_bits
; r13d - kp
; r14  - temp
; r15d - krp
; edi  - temp
; esi  - temp
; ebp  - mag

%macro GetNextInput 2 ; %1:n, %2:exitIfNone
	; if (data_size <= 0) exit
	test r8d, r8d
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
	mov %1, WORD [rdx]
	add rdx, 2
	dec r8d
%%GetNextInput_exit:
%endmacro

%macro GetNextNonzeroInput 2 ; %1:nZeroes, %2:n
	xor %1, %1
	; if (data_size <= 0) exit
	test r8d, r8d
	jle rfx_rlgr_encode_flush
%%GetNextNonzeroInput_loop:
	mov %2, WORD [rdx]
	add rdx, 2
	dec r8d
	test %2, %2
	jnz %%GetNextNonzeroInput_exit
	inc %1
	test r8d, r8d
	jg %%GetNextNonzeroInput_loop
%%GetNextNonzeroInput_exit:
%endmacro

%macro FlushOutput 1 ; %1:reset
	; if (buffer_size < 8) exit
	cmp r10d, 8
	jl rfx_rlgr_encode_exit
	; write 8 bytes
	bswap r12
	mov QWORD [r11], r12
	sub r10d, 8
	add r11, 8
%if %1 = 1
	; reset pending bits
	xor r12, r12
	mov bl, 64
%endif
%endmacro

%macro FlushRemainingOutput 0
	; if (buffer_size < 8) exit
	cmp r10d, 8
	jl rfx_rlgr_encode_exit
	; if (bits_avail >= 64) exit
	cmp bl, 64
	jge rfx_rlgr_encode_exit
	; write 8 bytes
	bswap r12
	mov QWORD [r11], r12
	; r11 += (64 - bits_avail + 7) / 8
	mov rcx, 64 + 7
	sub cl, bl
	shr rcx, 3
	add r11, rcx
%endmacro

%macro OutputBits 2 ; %1:numBits, %2:bitPattern
	; if (bits_avail > numBits)
	cmp bl, %1
	jl %%OutputBits_less
	je %%OutputBits_equal
	;   write_bits |= bitPattern << (bits_avail - numBits)
	mov cl, bl
	sub cl, %1
	mov r14, %2
	shl r14, cl
	or r12, r14
	;   bits_avail -= numBits
	sub bl, %1
	jmp %%OutputBits_exit
%%OutputBits_less:
	; else if (bits_avail < numBits)
	;   write_bits |= bitPattern >> (numBits - bits_avail)
	mov cl, %1
	sub cl, bl
	mov r14, %2
	shr r14, cl
	or r12, r14
	FlushOutput 0
	;   write_bits = bitPattern << (64 - (numBits - bits_avail))
	neg cl
	add cl, 64
	mov r12, %2
	shl r12, cl
	;   bits_avail = (64 - (numBits - bits_avail))
	mov bl, cl
	jmp %%OutputBits_exit
%%OutputBits_equal:
	; else // bits_avail == numBits
	;   write_bits |= bitPattern
	or r12, %2
	FlushOutput 1
%%OutputBits_exit:
%endmacro

%macro OutputRemainingBitsOne 0
	mov r14, -1
	mov cl, 64
	sub cl, bl
	shr r14, cl
	or r12, r14
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
	cmp bl, 64
	setl r14b
	movzx r14, r14b
	mov cl, bl
	shl r14, cl
	mov rax, 1
	sub ecx, %1
	shl rax, cl
	sub r14, rax
	or r12, r14
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
	mov r14, 1
	shl r14, cl
	or r12, r14
	; bits_avail--
	dec bl
	jnz %%OutputBitZero_exit
	FlushOutput 1
%%OutputBitZero_exit:
%endmacro

%macro CodeGR 1 ; %1:value
	; kr = *krp >> LSGR
	mov cl, r15b
	shr cl, 3
	mov bh, cl
	; vk = (val) >> kr
	mov rdi, %1
	shr edi, cl
	; if (vk > 1)
	cmp edi, 1
	jl %%CodeGR_2
	je %%CodeGR_1
	;   UpdateParam(*krp, vk, kr)
	UpdateParam r15d, edi
%%CodeGR_1:
	;   // vk >= 1
	;   OutputBit(vk, 1)
	;   OutputBit(1, 0)
	OutputBitsOne edi
	OutputBitZero
	jmp %%CodeGR_3
%%CodeGR_2:
	; else // vk == 0
	;   UpdateParam(*krp, -2, kr)
	UpdateParam r15d, -2
	;   OutputBit(1, 0)
	OutputBitZero
%%CodeGR_3:
	;   if (kr)
	;     OutputBits(kr, val & ((1 << kr) - 1))
	test bh, bh
	jz %%CodeGR_exit
	mov rdi, %1
	mov r14, 1
	mov cl, bh
	shl r14, cl
	dec r14
	and rdi, r14
	OutputBits bh, rdi
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
	mov r10d, [rsp+28h]
	push rbx
	push r12
	push r13
	push r14
	push r15
	push rdi
	push rsi
	push rbp
	mov ebx, ecx
	bswap ebx
	xor r12, r12

	; bits_avail = 64
	mov bl, 64
	; dst = buffer
	mov r11, r9
	; k = 1
	; kp = k << LSGR
	mov r13d, 8
	; kr = 1
	; krp = kr << LSGR
	mov r15d, 8

rfx_rlgr_encode_loop:
	; if (k) RL MODE
	test r13d, 0FFFFFFF8h
	je rfx_rlgr_encode_grmode

rfx_rlgr_encode_rlmode:
	GetNextNonzeroInput rax, bp

rfx_rlgr_encode_rlmode_1:
	; runmax = 1 << k;
	; while (numZeros >= runmax)
	mov r14d, 1
	mov cl, r13b
	shr cl, 3
	mov bh, cl
	shl r14d, cl
	cmp eax, r14d
	jl rfx_rlgr_encode_rlmode_2
	;   OutputBit(1, 0)
	OutputBitZero
	;   numZeros -= runmax
	sub eax, r14d
	;   UpdateParam(kp, UP_GR, k)
	UpdateParam r13d, 4
	; loop
	jmp rfx_rlgr_encode_rlmode_1

rfx_rlgr_encode_rlmode_2:
	; OutputBit(1, 1)
	OutputBitOne
	; OutputBits(k, numZeros)
	OutputBits bh, rax
	; if (input < 0)
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
	movsx rbp, bp
	CodeGR rbp
	; UpdateParam(kp, -DN_GR, k)
	UpdateParam r13d, -6
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_grmode:
	; if (mode == RLGR1)
	test ebx, 0FF000000h
	jnz rfx_rlgr_encode_grmode_1
	;   GetNextInput(input)
	GetNextInput bp, 1
	;   twoMs = Get2MagSign(input)
	movsx rbp, bp
	Get2MagSign rbp
	;   CodeGR(&krp, twoMs)
	CodeGR rbp
	;   if (twoMs)
	test rbp, rbp
	jz rfx_rlgr_encode_grmode_2
	;     UpdateParam(kp, -DQ_GR, k)
	UpdateParam r13d, -3
	jmp rfx_rlgr_encode_loop
rfx_rlgr_encode_grmode_2:
	;   else
	;     UpdateParam(kp, UQ_GR, k)
	UpdateParam r13d, 3
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_grmode_1:
	; else // mode == RLGR3
	;   GetNextInput(input)
	GetNextInput si, 1
	;   twoMs1 = Get2MagSign(input)
	movsx rsi, si
	Get2MagSign rsi
	;   GetNextInput(input)
	GetNextInput bp, 0
	;   twoMs2 = Get2MagSign(input)
	movsx rbp, bp
	Get2MagSign rbp
	;   sum2Ms = twoMs1 + twoMs2
	add rbp, rsi
	;   CodeGR(&krp, sum2Ms)
	CodeGR rbp
	;   GetMinBits(sum2Ms, nIdx)
	bsr eax, ebp
	jz rfx_rlgr_encode_grmode_3
	inc eax
	;   OutputBits(nIdx, twoMs1)
	OutputBits al, rsi
rfx_rlgr_encode_grmode_3:
	;   if (twoMs1 && twoMs2)
	test esi, esi
	jz rfx_rlgr_encode_grmode_4
	cmp ebp, esi
	je rfx_rlgr_encode_loop
	;     UpdateParam(kp, -2 * DQ_GR, k)
	UpdateParam r13d, -6
	jmp rfx_rlgr_encode_loop
	;   else if (!twoMs1 && !twoMs2)
rfx_rlgr_encode_grmode_4:
	test ebp, ebp
	jnz rfx_rlgr_encode_loop
	;     UpdateParam(kp, 2 * UQ_GR, k)
	UpdateParam r13d, 6
	jmp rfx_rlgr_encode_loop

rfx_rlgr_encode_flush:
	FlushRemainingOutput

rfx_rlgr_encode_exit:
	; return dst - buffer
	mov rax, r11
	sub rax, r9
	pop rbp
	pop rsi
	pop rdi
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret



