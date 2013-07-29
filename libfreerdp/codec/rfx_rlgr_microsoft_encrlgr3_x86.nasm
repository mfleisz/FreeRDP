; DO NOT USE THIS CODE IN A RELEASE -  IT IS COPYRIGHTED BY MS
; ONLY TO BE USED FOR INTERNAL PERFORMANCE TESTS !!!!!!!!!!!!
;
; Ripped from Windows 8 x86 rdpcorets.dll (6.2.9200.16465)
; See CacEncoding::encrlgr3 and CacDecoding::decrlgr3

; Disassembled using distorm for python:
; Get distorm3-3.win-amd64.exe from https://code.google.com/p/distorm/downloads/list
; See https://code.google.com/p/distorm/wiki/Python
; 
;	from distorm3 import Decode, Decode16Bits, Decode32Bits, Decode64Bits
;	f = open ('c:\\tmp\\rdpcorets-x86-6.2.9200.16465.dll', 'rb')
;	f.seek(0x1AAFD0)
;	data = f.read(0x9A6)
;	f.close()
;	
;	l = Decode(0, data, Decode32Bits)
;	jumpinstructions = ['JMP','JO','JNO','JS','JNS','JE','JZ','JNE','JNZ','JB','JNAE','JC','JNB','JAE','JNC','JBE','JNA','JA','JNBE','JL','JNGE','JGE','JNL','JLE','JNG','JG','JNLE','JP','JPE','JNP','JPO','JCXZ','JECXZ']
;	
;	lables = []
;	for i in l:
;		j = i[2].split(' ')
;		if j[0] in jumpinstructions:
;			lables.append(int(j[1],0))
;	
;	for i in l:
;		if i[0] in lables:
;			print '\nloc_%08X:' % (i[0])
;		j = i[2].split(' ')
;		if j[0] in jumpinstructions:
;			print '\t%s loc_%08X' % (j[0], int(j[1],0))
;		else:
;			print '\t%s' % (i[2])

; ENCODER INFORMATION:
; In Microsoft's source this was probably defined like this
; int CacEncoding::encrlgr3(struct CacEncoding::RLGRstate2 *, unsigned char *, int, short *, int, int, int)
; However this function is not exported and only called from one location and therefore the compiler simplified it to:
; int CacEncoding::encrlgr3(unsigned char* buffer, const short* data, int data_size);
; the 4th required parameter (buffer_size) was optimized away and gets passed via eax and so I added it again
; -> see "BEGIN CODE MODIFICATIONS" in encoder assembly below
; 
;
; msrlgr encoder reads beyond data_size and requires the data do be terminated with 8 WORDS: 1 0 0 0 0 0 0 0
; this was also confirmed by analyzing the data used in Windows 8 when it calls CacEncoding::encrlgr3
; and msrlgr encoder expects the signed data words to be in "(2 * magnitude - sign)" representation
; -> see "BEGIN CODE MODIFICATIONS" in encoder assembly below
;
; Parameters 
; [ebp+08h]:		data			(input: const)
; [ebp+0ch]:		data_size		
; [ebp+10h]:		buffer			(output)
; [ebp+14h]:		buffer_size


section .text


%ifdef WIN32
%define microsoft_cacencoding_encrlgr3 _microsoft_cacencoding_encrlgr3
%endif


%macro Get2MagSign 1
	shl %1, 1
	jnc %%done
	neg %1
	dec %1
	%%done:
%endmacro

global microsoft_cacencoding_encrlgr3

microsoft_cacencoding_encrlgr3:
	MOV EDI, EDI
	PUSH EBP
	MOV EBP, ESP
	SUB ESP, 0x34

; BEGIN CODE MODIFICATIONS -----------------------------------------------------------

	; fix the parameters: 
	; <<<<  buffer, data,      data_size, buffer_size_erased_by_optimizer_passed_via_eax
	; >>>>  data,   data_size, buffer,    buffer_size

	mov eax, [ebp+08h]
	push eax
	mov eax, [ebp+0ch]
	push eax
	mov eax, [ebp+10h]
	
	mov [ebp+08h], eax      ; code expects buffer -> param 1
	pop eax			
	mov [ebp+10h], eax      ; code expects data_size in param 3 
	pop eax                 
	mov [ebp+0ch], eax      ; code expects data in param 2
	
	mov eax, [ebp+0x14]     ; code expects param 4 in eax


; END CODE MODIFICATIONS -----------------------------------------------------------

	MOV ECX, [EBP+0x8]
	SHR EAX, 0x2
	LEA EAX, [ECX+EAX*4]
	PUSH EBX
	MOV EBX, [EBP+0xc]
	MOV [EBP-0x8], ECX
	MOV ECX, [EBP+0x10]
	PUSH ESI
	LEA ECX, [EBX+ECX*2]
	XOR ESI, ESI
	MOV EDX, 0x1
	MOV [EBP-0x10], EAX
	MOV [EBP-0x34], ECX
	PUSH EDI
	MOV [EBP-0x4], ESI
	LEA EAX, [ESI+0x20]
	MOV [EBP-0x30], EDX
	MOV DWORD [EBP-0x18], 0x8
	MOV DWORD [EBP-0xc], 0x8
	MOV ECX, EBX

; BEGIN CODE MODIFICATIONS -----------------------------------------------------------

	; 1) terminate data with 8 WORDS: 1 0 0 0 0 0 0 0

	mov ebx, [ebp-34h]		; [ebp-34h] has stored the end address of data 
	
	mov word [ebx+00h], 1
	mov word [ebx+02h], 0
	mov word [ebx+04h], 0
	mov word [ebx+06h], 0
	mov word [ebx+08h], 0
	mov word [ebx+0Ah], 0
	mov word [ebx+0Ch], 0
	mov word [ebx+0Eh], 0

	; 2) msrlgr encoder expects the signed data words to be in "(2* magnitude - sign)" representation

	; save registers in use
	push eax	
	push ecx	

convert_data:
	movsx eax, word [ecx]
	Get2MagSign eax
	mov word [ecx], ax
	add ecx, 2
	cmp ecx, ebx
	jl convert_data

	; restore registers
	pop ecx
	pop eax


; END CODE MODIFICATIONS -----------------------------------------------------------


loc_00000046:
	MOVSX ECX, WORD [ECX]			; XXX added WORD
	XOR EBX, EBX
	MOV [EBP-0x24], ECX
	TEST ECX, ECX
	MOV ECX, [EBP+0xc]
	MOV [EBP-0x2c], EBX
	JNZ loc_0000006D

loc_00000058:
	MOVSX EDX, WORD [ECX+0x2]		; XXX added WORD
	ADD ECX, 0x2
	INC EBX
	MOV [EBP-0x24], EDX
	TEST EDX, EDX
	JZ loc_00000058
	MOV EDX, [EBP-0x30]
	MOV [EBP-0x2c], EBX

loc_0000006D:
	ADD ECX, 0x2
	MOV [EBP+0xc], ECX
	MOV ECX, EDX
	MOV DWORD [EBP+0x10], 0x1
	SHL DWORD [EBP+0x10], CL		; XXX added DWORD
	MOV ECX, [EBP+0x10]
	MOV DWORD [EBP-0x28], 0x0
	CMP EBX, ECX
	JL loc_000000C7
	MOV EDI, [EBP-0x28]
	MOV ESI, [EBP-0x18]

loc_00000093:
	ADD ESI, 0x4
	INC EDI
	SUB EBX, ECX
	CMP ESI, 0x50
	JLE loc_000000A3
	MOV ESI, 0x50

loc_000000A3:
	MOV EDX, ESI
	SAR EDX, 0x3
	MOV ECX, EDX
	MOV DWORD [EBP+0x10], 0x1
	SHL DWORD [EBP+0x10], CL		; XXX added DWORD
	MOV ECX, [EBP+0x10]
	CMP EBX, ECX
	JGE loc_00000093
	MOV [EBP-0x18], ESI
	MOV ESI, [EBP-0x4]
	MOV [EBP-0x28], EDI
	MOV [EBP-0x2c], EBX

loc_000000C7:
	MOV ECX, EDX
	MOV EBX, 0x1
	SHL EBX, CL
	MOV ECX, [EBP-0x24]
	AND ECX, 0x1
	OR EBX, [EBP-0x2c]
	ADD EBX, EBX
	OR EBX, ECX
	MOV ECX, [EBP-0x28]
	ADD ECX, 0x2
	ADD EDX, ECX
	MOV ECX, [EBP-0x24]
	INC ECX
	SAR ECX, 0x1
	DEC ECX
	MOV [EBP+0x10], EDX
	MOV [EBP-0x24], ECX
	JZ loc_0000042C
	MOV ECX, [EBP-0xc]
	MOV EDI, [EBP-0x24]
	SAR ECX, 0x3
	MOV [EBP-0x14], EDI
	SAR DWORD [EBP-0x14], CL		; XXX added DWORD
	MOV [EBP+0x10], ECX
	MOV EDI, [EBP+0x10]
	MOV ECX, [EBP-0x14]
	INC EDI
	ADD ECX, EDI
	CMP DWORD [EBP-0x14], 0x2
	MOV EDI, [EBP-0x8]
	JGE loc_000001E6
	ADD ECX, EDX
	MOV [EBP-0x30], ECX
	CMP ECX, 0x20
	JG loc_000001E6
	MOV ECX, [EBP-0x14]
	MOV EDX, 0x1
	SHL EDX, CL
	MOV ECX, [EBP+0x10]
	INC ECX
	DEC EDX
	SHL EDX, CL
	MOV ECX, [EBP+0x10]
	MOV [EBP-0x2c], EDX
	MOV EDX, 0x1
	SHL EDX, CL
	DEC EDX
	AND EDX, [EBP-0x24]
	OR [EBP-0x2c], EDX
	MOV EDX, [EBP-0x14]
	INC EDX
	ADD ECX, EDX
	MOV EDX, [EBP-0x2c]
	SHL EBX, CL
	OR EDX, EBX
	LEA EBX, [EDI+0x4]
	CMP EBX, [EBP-0x10]
	JB loc_0000017C
	MOV ECX, [EBP-0x14]
	MOV EDX, [EBP-0xc]
	MOV EDI, EBX
	DEC ECX
	MOV [EBP-0x8], EDI
	LEA ECX, [EDX+ECX*2]
	JMP loc_0000053B

loc_0000017C:
	SUB EAX, [EBP-0x30]
	TEST EAX, EAX
	JLE loc_0000019B
	MOV ECX, EAX
	SHL EDX, CL
	MOV ECX, [EBP-0x14]
	OR ESI, EDX
	MOV EDX, [EBP-0xc]
	DEC ECX
	MOV [EBP-0x4], ESI
	LEA ECX, [EDX+ECX*2]
	JMP loc_0000053B

loc_0000019B:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EDX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_000001CE
	MOV ECX, [EBP-0x14]
	MOV EDX, [EBP-0xc]
	XOR ESI, ESI
	DEC ECX
	MOV [EBP-0x4], ESI
	LEA ECX, [EDX+ECX*2]
	JMP loc_0000053B

loc_000001CE:
	MOV ESI, EDX
	MOV EDX, [EBP-0xc]
	MOV ECX, EAX
	SHL ESI, CL
	MOV ECX, [EBP-0x14]
	DEC ECX
	LEA ECX, [EDX+ECX*2]
	MOV [EBP-0x4], ESI
	JMP loc_0000053B

loc_000001E6:
	LEA ECX, [EDI+0x4]
	MOV [EBP-0x30], ECX
	CMP ECX, [EBP-0x10]
	JB loc_000001F8
	MOV EDI, ECX
	MOV [EBP-0x8], EDI
	JMP loc_00000233

loc_000001F8:
	SUB EAX, EDX
	TEST EAX, EAX
	JLE loc_00000206
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_00000230

loc_00000206:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EDI, [EBP-0x30]
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_0000022A
	XOR ESI, ESI
	JMP loc_00000230

loc_0000022A:
	MOV ESI, EBX
	MOV ECX, EAX
	SHL ESI, CL

loc_00000230:
	MOV [EBP-0x4], ESI

loc_00000233:
	MOV EDX, [EBP-0x14]
	MOV [EBP-0x1c], EDX
	CMP EDX, 0x20
	JL loc_000002A1
	MOV EBX, EDX
	SHR EBX, 0x5
	MOV ECX, EBX
	SHL ECX, 0x5
	SUB EDX, ECX
	MOV ECX, [EBP-0x10]
	MOV [EBP-0x1c], EDX

loc_00000250:
	LEA EDX, [EDI+0x4]
	CMP EDX, ECX
	JB loc_0000025B
	MOV EDI, EDX
	JMP loc_00000298

loc_0000025B:
	ADD EAX, -0x20
	TEST EAX, EAX
	JLE loc_0000026D
	OR EDX, -0x1
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_00000295

loc_0000026D:
	NEG EAX
	MOV ECX, EAX
	OR EAX, -0x1
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EDX
	CMP EAX, 0x20
	JNZ loc_0000028E
	XOR ESI, ESI
	JMP loc_00000295

loc_0000028E:
	OR ESI, -0x1
	MOV ECX, EAX
	SHL ESI, CL

loc_00000295:
	MOV ECX, [EBP-0x10]

loc_00000298:
	DEC EBX
	JNZ loc_00000250
	MOV [EBP-0x8], EDI
	MOV [EBP-0x4], ESI

loc_000002A1:
	MOV ECX, [EBP+0x10]
	MOV EDX, [EBP-0x1c]
	INC ECX
	ADD ECX, EDX
	CMP ECX, 0x20
	JG loc_00000335
	MOV ECX, EDX
	MOV EBX, 0x1
	SHL EBX, CL
	MOV ECX, [EBP+0x10]
	INC ECX
	MOV EDX, 0x1
	DEC EBX
	SHL EBX, CL
	MOV ECX, [EBP+0x10]
	SHL EDX, CL
	DEC EDX
	AND EDX, [EBP-0x24]
	OR EBX, EDX
	LEA EDX, [EDI+0x4]
	MOV [EBP-0x30], EDX
	CMP EDX, [EBP-0x10]
	JB loc_000002E8
	MOV EDI, EDX
	MOV [EBP-0x8], EDI
	JMP loc_000003F7

loc_000002E8:
	MOV EDI, [EBP-0x1c]
	MOV ECX, [EBP+0x10]
	MOV EDX, [EBP-0x30]
	INC EDI
	ADD ECX, EDI
	MOV EDI, [EBP-0x8]
	SUB EAX, ECX
	TEST EAX, EAX
	JLE loc_00000308
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_000003F4

loc_00000308:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EDX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_0000032E
	XOR ESI, ESI
	JMP loc_000003F4

loc_0000032E:
	MOV ESI, EBX
	JMP loc_000003F0

loc_00000335:
	MOV EDX, [EBP-0x10]
	LEA EBX, [EDI+0x4]
	CMP EBX, EDX
	JB loc_00000346
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	JMP loc_0000039D

loc_00000346:
	MOV ECX, [EBP-0x1c]
	MOV EDI, [EBP-0x8]
	MOV EDX, 0x1
	SHL EDX, CL
	INC ECX
	SUB EAX, ECX
	LEA EDX, [EDX*2-0x2]
	TEST EAX, EAX
	JLE loc_0000036E
	MOV ECX, EAX
	SHL EDX, CL
	OR EDX, ESI
	MOV ESI, EDX
	MOV [EBP-0x4], EDX
	JMP loc_0000039A

loc_0000036E:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EDX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_00000391
	XOR ESI, ESI
	JMP loc_00000397

loc_00000391:
	MOV ESI, EDX
	MOV ECX, EAX
	SHL ESI, CL

loc_00000397:
	MOV [EBP-0x4], ESI

loc_0000039A:
	MOV EDX, [EBP-0x10]

loc_0000039D:
	MOV ECX, [EBP+0x10]
	TEST ECX, ECX
	JZ loc_000003F7
	LEA EBX, [EDI+0x4]
	CMP EBX, EDX
	JB loc_000003B2
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	JMP loc_000003F7

loc_000003B2:
	MOV EDX, 0x1
	SHL EDX, CL
	SUB EAX, ECX
	DEC EDX
	AND EDX, [EBP-0x24]
	TEST EAX, EAX
	JLE loc_000003CB
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_000003F4

loc_000003CB:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EDX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_000003EE
	XOR ESI, ESI
	JMP loc_000003F4

loc_000003EE:
	MOV ESI, EDX

loc_000003F0:
	MOV ECX, EAX
	SHL ESI, CL

loc_000003F4:
	MOV [EBP-0x4], ESI

loc_000003F7:
	MOV ECX, [EBP-0x14]
	MOV EBX, [EBP-0xc]
	CMP ECX, 0x2
	JGE loc_00000414
	LEA EBX, [EBX+ECX*2]
	ADD EBX, -0x2
	MOV ECX, EBX
	SAR ECX, 0x1f
	NOT ECX
	JMP loc_00000542

loc_00000414:
	ADD EBX, ECX
	MOV [EBP-0xc], EBX
	CMP EBX, 0x50
	JLE loc_00000547
	MOV EBX, 0x50
	JMP loc_00000544

loc_0000042C:
	MOV EDX, [EBP-0xc]
	MOV EDI, [EBP+0x10]
	INC EDI
	SAR EDX, 0x3
	ADD EDI, EDX
	MOV [EBP-0x30], EDI
	CMP EDI, 0x20
	MOV EDI, [EBP-0x8]
	LEA ECX, [EDI+0x4]
	JG loc_0000049D
	MOV [EBP+0x10], ECX
	CMP ECX, [EBP-0x10]
	JB loc_00000458
	MOV EDI, ECX
	MOV [EBP-0x8], EDI
	JMP loc_00000535

loc_00000458:
	SUB EAX, [EBP-0x30]
	LEA ECX, [EDX+0x1]
	SHL EBX, CL
	TEST EAX, EAX
	JLE loc_0000046F
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_00000532

loc_0000046F:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EDI, [EBP+0x10]
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_00000496
	XOR ESI, ESI
	JMP loc_00000532

loc_00000496:
	MOV ESI, EBX
	JMP loc_0000052E

loc_0000049D:
	CMP ECX, [EBP-0x10]
	MOV [EBP-0x30], ECX
	MOV ECX, [EBP+0x10]
	JB loc_000004B0
	MOV EDI, [EBP-0x30]
	MOV [EBP-0x8], EDI
	JMP loc_000004EB

loc_000004B0:
	SUB EAX, ECX
	TEST EAX, EAX
	JLE loc_000004BE
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_000004E8

loc_000004BE:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EDI, [EBP-0x30]
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_000004E2
	XOR ESI, ESI
	JMP loc_000004E8

loc_000004E2:
	MOV ESI, EBX
	MOV ECX, EAX
	SHL ESI, CL

loc_000004E8:
	MOV [EBP-0x4], ESI

loc_000004EB:
	LEA ECX, [EDX+0x1]
	LEA EDX, [EDI+0x4]
	CMP EDX, [EBP-0x10]
	JB loc_000004FD
	MOV EDI, EDX
	MOV [EBP-0x8], EDI
	JMP loc_00000535

loc_000004FD:
	SUB EAX, ECX
	TEST EAX, EAX
	JLE loc_0000050D
	XOR EDX, EDX
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_00000532

loc_0000050D:
	NEG EAX
	MOV ECX, EAX
	XOR EAX, EAX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EDX
	XOR ESI, ESI
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JZ loc_00000532

loc_0000052E:
	MOV ECX, EAX
	SHL ESI, CL

loc_00000532:
	MOV [EBP-0x4], ESI

loc_00000535:
	MOV ECX, [EBP-0xc]
	ADD ECX, -0x2

loc_0000053B:
	MOV EBX, ECX
	SAR EBX, 0x1f
	NOT EBX

loc_00000542:
	AND EBX, ECX

loc_00000544:
	MOV [EBP-0xc], EBX

loc_00000547:
	MOV EDX, [EBP-0x18]
	SUB EDX, 0x6
	MOV ECX, EDX
	SAR ECX, 0x1f
	NOT ECX
	AND EDX, ECX
	MOV ECX, [EBP+0xc]
	MOV [EBP-0x18], EDX
	SAR EDX, 0x3
	MOV [EBP-0x30], EDX
	CMP ECX, [EBP-0x34]
	JAE loc_00000947
	TEST EDX, EDX
	JNZ loc_00000046

loc_00000573:
	XOR ECX, ECX
	MOV [EBP-0x30], ECX

loc_00000578:
	MOV EDX, [EBP+0xc]
	MOVSX EDI, WORD [EDX+0x2]		; XXX added WORD
	MOVSX ECX, WORD [EDX]
	ADD EDX, 0x4
	MOV [EBP-0x2c], EDI
	MOV EDI, [EBP-0x8]
	MOV [EBP+0xc], EDX
	MOV EDX, [EBP-0x2c]
	MOV [EBP-0x14], ECX
	TEST ECX, ECX
	JNZ loc_000005A0
	TEST EDX, EDX
	JZ loc_0000086D

loc_000005A0:
	ADD ECX, EDX
	MOV EDX, EBX
	SAR EDX, 0x3
	MOV EBX, ECX
	MOV [EBP-0x28], ECX
	MOV ECX, EDX
	SAR EBX, CL
	MOV ECX, [EBP-0x28]
	MOV [EBP+0x10], EDX
	MOV [EBP-0x24], EBX
	TEST ECX, ECX
	JZ loc_000005C9
	BSR ECX, ECX
	MOV [EBP-0x20], ECX
	INC ECX
	MOV [EBP-0x20], ECX
	JMP loc_000005D0

loc_000005C9:
	MOV DWORD [EBP-0x20], 0x0

loc_000005D0:
	CMP EBX, 0x1
	JG loc_0000066A
	MOV ECX, [EBP-0x24]
	MOV EBX, 0x1
	SHL EBX, CL
	LEA ECX, [EDX+0x1]
	MOV EDX, 0x1
	DEC EBX
	SHL EBX, CL
	MOV ECX, [EBP+0x10]
	SHL EDX, CL
	DEC EDX
	AND EDX, [EBP-0x28]
	OR EBX, EDX
	MOV EDX, [EBP-0x20]
	MOV ECX, EDX
	SHL EBX, CL
	MOV ECX, [EBP-0x24]
	ADD ECX, EDX
	MOV EDX, [EBP+0x10]
	OR EBX, [EBP-0x14]
	INC EDX
	ADD ECX, EDX
	LEA EDX, [EDI+0x4]
	CMP EDX, [EBP-0x10]
	JB loc_0000061B
	MOV [EBP-0x8], EDX
	JMP loc_00000650

loc_0000061B:
	SUB EAX, ECX
	TEST EAX, EAX
	JLE loc_00000629
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_00000650

loc_00000629:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	MOV [EBP-0x8], EDX
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	CMP EAX, 0x20
	JNZ loc_0000064A
	XOR ESI, ESI
	JMP loc_00000650

loc_0000064A:
	MOV ESI, EBX
	MOV ECX, EAX
	SHL ESI, CL

loc_00000650:
	MOV ECX, [EBP-0xc]
	MOV EDX, [EBP-0x24]
	LEA ECX, [ECX+EDX*2]
	ADD ECX, -0x2
	MOV EBX, ECX
	SAR EBX, 0x1f
	NOT EBX
	AND EBX, ECX
	JMP loc_0000084D

loc_0000066A:
	MOV EDX, [EBP-0x24]
	MOV [EBP-0x1c], EBX
	CMP EDX, 0x20
	JL loc_000006D8
	MOV EBX, EDX
	SHR EBX, 0x5
	MOV ECX, EBX
	SHL ECX, 0x5
	SUB EDX, ECX
	MOV ECX, [EBP-0x10]
	MOV [EBP-0x1c], EDX

loc_00000687:
	LEA EDX, [EDI+0x4]
	CMP EDX, ECX
	JB loc_00000692
	MOV EDI, EDX
	JMP loc_000006CF

loc_00000692:
	ADD EAX, -0x20
	TEST EAX, EAX
	JLE loc_000006A4
	OR EDX, -0x1
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_000006CC

loc_000006A4:
	NEG EAX
	MOV ECX, EAX
	OR EAX, -0x1
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EDX
	CMP EAX, 0x20
	JNZ loc_000006C5
	XOR ESI, ESI
	JMP loc_000006CC

loc_000006C5:
	OR ESI, -0x1
	MOV ECX, EAX
	SHL ESI, CL

loc_000006CC:
	MOV ECX, [EBP-0x10]

loc_000006CF:
	DEC EBX
	JNZ loc_00000687
	MOV EBX, [EBP-0x1c]
	MOV [EBP-0x8], EDI

loc_000006D8:
	MOV EDX, [EBP-0x20]
	MOV ECX, [EBP+0x10]
	ADD EDX, EBX
	INC ECX
	ADD ECX, EDX
	MOV [EBP-0x4], ECX
	CMP ECX, 0x20
	JG loc_0000073A
	MOV ECX, [EBP-0x1c]
	MOV EBX, 0x1
	SHL EBX, CL
	MOV ECX, [EBP+0x10]
	INC ECX
	MOV EDX, 0x1
	DEC EBX
	SHL EBX, CL
	MOV ECX, [EBP+0x10]
	SHL EDX, CL
	MOV ECX, [EBP-0x20]
	DEC EDX
	AND EDX, [EBP-0x28]
	OR EBX, EDX
	SHL EBX, CL
	LEA EDX, [EDI+0x4]
	OR EBX, [EBP-0x14]
	CMP EDX, [EBP-0x10]
	JB loc_00000724
	MOV [EBP-0x8], EDX
	JMP loc_0000083A

loc_00000724:
	SUB EAX, [EBP-0x4]
	TEST EAX, EAX
	JLE loc_00000813
	MOV ECX, EAX
	SHL EBX, CL
	OR ESI, EBX
	JMP loc_0000083A

loc_0000073A:
	MOV EDX, [EBP-0x10]
	LEA EBX, [EDI+0x4]
	CMP EBX, EDX
	JB loc_0000074B
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	JMP loc_0000079A

loc_0000074B:
	MOV ECX, [EBP-0x1c]
	MOV EDI, [EBP-0x8]
	MOV EDX, 0x1
	SHL EDX, CL
	INC ECX
	SUB EAX, ECX
	LEA EDX, [EDX*2-0x2]
	TEST EAX, EAX
	JLE loc_0000076E
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_00000797

loc_0000076E:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EDX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_00000791
	XOR ESI, ESI
	JMP loc_00000797

loc_00000791:
	MOV ESI, EDX
	MOV ECX, EAX
	SHL ESI, CL

loc_00000797:
	MOV EDX, [EBP-0x10]

loc_0000079A:
	MOV ECX, [EBP+0x10]
	TEST ECX, ECX
	JZ loc_000007F1
	LEA EBX, [EDI+0x4]
	CMP EBX, EDX
	JB loc_000007AF
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	JMP loc_000007F1

loc_000007AF:
	MOV EDX, 0x1
	SHL EDX, CL
	SUB EAX, ECX
	DEC EDX
	AND EDX, [EBP-0x28]
	TEST EAX, EAX
	JLE loc_000007C8
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_000007F1

loc_000007C8:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EDX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EBX
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_000007EB
	XOR ESI, ESI
	JMP loc_000007F1

loc_000007EB:
	MOV ESI, EDX
	MOV ECX, EAX
	SHL ESI, CL

loc_000007F1:
	LEA EDX, [EDI+0x4]
	CMP EDX, [EBP-0x10]
	JB loc_000007FE
	MOV [EBP-0x8], EDX
	JMP loc_0000083A

loc_000007FE:
	SUB EAX, [EBP-0x20]
	TEST EAX, EAX
	JLE loc_00000810
	MOV EDX, [EBP-0x14]
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	JMP loc_0000083A

loc_00000810:
	MOV EBX, [EBP-0x14]

loc_00000813:
	NEG EAX
	MOV ECX, EAX
	MOV EAX, EBX
	SHR EAX, CL
	MOV [EBP-0x8], EDX
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	CMP EAX, 0x20
	JNZ loc_00000834
	XOR ESI, ESI
	JMP loc_0000083A

loc_00000834:
	MOV ECX, EAX
	MOV ESI, EBX
	SHL ESI, CL

loc_0000083A:
	MOV EBX, [EBP-0xc]
	ADD EBX, [EBP-0x24]
	MOV [EBP-0xc], EBX
	CMP EBX, 0x50
	JLE loc_00000850
	MOV EBX, 0x50

loc_0000084D:
	MOV [EBP-0xc], EBX

loc_00000850:
	CMP DWORD [EBP-0x14], 0x0
	JZ loc_00000578
	CMP DWORD [EBP-0x2c], 0x0
	JZ loc_00000578
	ADD DWORD [EBP-0x30], 0x6
	JMP loc_00000578

loc_0000086D:
	MOV ECX, EBX
	SAR ECX, 0x3
	MOV [EBP-0x4], ESI
	TEST ECX, ECX
	JZ loc_000008C8
	LEA EDX, [EDI+0x4]
	INC ECX
	CMP EDX, [EBP-0x10]
	JB loc_00000886
	MOV EDI, EDX
	JMP loc_000008F6

loc_00000886:
	SUB EAX, ECX
	TEST EAX, EAX
	JLE loc_00000899
	XOR EDX, EDX
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	MOV [EBP-0x4], ESI
	JMP loc_000008F9

loc_00000899:
	NEG EAX
	MOV ECX, EAX
	XOR EAX, EAX
	SHR EAX, CL
	OR EAX, ESI
	BSWAP EAX
	MOV [EDI], EAX
	MOV EAX, 0x20
	SUB EAX, ECX
	MOV EDI, EDX
	XOR ESI, ESI
	MOV [EBP-0x8], EDI
	CMP EAX, 0x20
	JNZ loc_000008BF
	MOV [EBP-0x4], ESI
	JMP loc_000008F9

loc_000008BF:
	MOV ECX, EAX
	SHL ESI, CL
	MOV [EBP-0x4], ESI
	JMP loc_000008F9

loc_000008C8:
	LEA EBX, [EDI+0x4]
	CMP EBX, [EBP-0x10]
	JAE loc_000008F1
	DEC EAX
	XOR EDX, EDX
	MOV ECX, EAX
	SHL EDX, CL
	OR ESI, EDX
	MOV [EBP-0x4], ESI
	TEST EAX, EAX
	JZ loc_000008E5
	MOV EBX, [EBP-0xc]
	JMP loc_000008F9

loc_000008E5:
	BSWAP ESI
	MOV [EDI], ESI
	XOR ESI, ESI
	MOV [EBP-0x4], ESI
	LEA EAX, [ESI+0x20]

loc_000008F1:
	MOV EDI, EBX
	MOV EBX, [EBP-0xc]

loc_000008F6:
	MOV [EBP-0x8], EDI

loc_000008F9:
	MOV EDX, [EBP-0x18]
	SUB EDX, [EBP-0x30]
	LEA ECX, [EBX-0x2]
	MOV EBX, ECX
	SAR EBX, 0x1f
	NOT EBX
	AND EBX, ECX
	MOV ECX, EDX
	SAR ECX, 0x1f
	NOT ECX
	AND ECX, EDX
	ADD ECX, 0x6
	MOV [EBP-0xc], EBX
	MOV [EBP-0x18], ECX
	CMP ECX, 0x50
	JLE loc_0000092A
	MOV ECX, 0x50
	MOV [EBP-0x18], ECX

loc_0000092A:
	MOV EDX, ECX
	MOV ECX, [EBP+0xc]
	SAR EDX, 0x3
	MOV [EBP-0x30], EDX
	CMP ECX, [EBP-0x34]
	JAE loc_00000947
	TEST EDX, EDX
	JZ loc_00000573
	JMP loc_00000046

loc_00000947:
	MOV EBX, EDI
	SUB EBX, [EBP+0x8]
	SAR EBX, 0x2
	ADD EBX, EBX
	ADD EBX, EBX
	CMP EAX, 0x20
	JZ loc_0000099B
	MOV EDX, ESI
	AND EDX, 0xff0000
	MOV ECX, ESI
	SHR ECX, 0x10
	OR EDX, ECX
	MOV ECX, ESI
	SHL ECX, 0x10
	AND ESI, 0xff00
	OR ECX, ESI
	SHR EDX, 0x8
	SHL ECX, 0x8
	OR EDX, ECX
	MOV ECX, 0x27
	SUB ECX, EAX
	MOV [EDI], EDX
	MOV EAX, ECX
	CDQ
	AND EDX, 0x7
	ADD EAX, EDX
	POP EDI
	SAR EAX, 0x3
	POP ESI
	ADD EAX, EBX
	POP EBX
	MOV ESP, EBP
	POP EBP
; BEGIN CODE MODIFICATIONS -----------------------------------------------------------
	RET ; 0xc	; we define this as _cdecl
; END CODE MODIFICATIONS -----------------------------------------------------------

loc_0000099B:
	POP EDI
	POP ESI
	MOV EAX, EBX
	POP EBX
	MOV ESP, EBP
	POP EBP
; BEGIN CODE MODIFICATIONS -----------------------------------------------------------
	RET ; 0xc	; we define this as _cdecl
; END CODE MODIFICATIONS -----------------------------------------------------------
