; DO NOT USE THIS CODE IN A RELEASE -  IT IS COPYRIGHTED BY MS
; ONLY TO BE USED FOR INTERNAL PERFORMANCE TESTS !!!!!!!!!!!!
;
; Ripped from Windows 8 x64 rdpcorets.dll (6.2.9200.16465)
; See CacEncoding::encrlgr3 and CacDecoding::decrlgr3

; Disassembled using distorm for python:
; Get distorm3-3.win-amd64.exe from https://code.google.com/p/distorm/downloads/list
; See https://code.google.com/p/distorm/wiki/Python
; 
;	from distorm3 import Decode, Decode16Bits, Decode32Bits, Decode64Bits
;	f = open ('c:\\tmp\\rdpcorets-x64-6.2.9200.16465.dll', 'rb')
;	f.seek(0x20CB20)
;	data = f.read(0x714)
;	f.close()
;	
;	l = Decode(0, data, Decode64Bits)
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

; DECODER INFORMATION:
; In Microsoft's source this was probably defined like this
; int CacDecoding::decrlgr3(CacDecoding::RLGRstate *, uchar *, int, short *, int, int, int)
; However this function is not exported and only called from one location and therefore the compiler simplified it to:
; int CacDecoding::decrlgr3(const uchar* data, int data_size, short* buffer, int buffer_size);
;
; Debugging showed that ms always passes 8*data_size for our data_size value
; -> see "BEGIN CODE MODIFICATIONS" in decoder assembly below
;
; Parameters:
; rcx:		data		(input: const)
; rdx:		data_size
; r8:		buffer		(output)
; r9:		buffer_size


section .text

extern memcpy
extern memset

%ifdef WIN32

%define xmemset	memset
%define xmemcpy memcpy

%else

xmemset:
	; convert from MS x64 to System V AMD64 ABI calling convention
	push	rdi
	push	rsi
	mov	rdi, rcx
	mov	rsi, rdx
	mov	rdx, r8
	call	memset WRT ..plt
	pop	rsi
	pop	rdi
	ret

xmemcpy:
	; convert from MS x64 to System V AMD64 ABI calling convention
	push	rdi
	push	rsi
	mov	rdi, rcx
	mov	rsi, rdx
	mov	rdx, r8
	call 	memcpy WRT ..plt
	pop	rsi
	pop	rdi
	ret

%endif


global microsoft_cacdecoding_decrlgr3

microsoft_cacdecoding_decrlgr3:
	MOV [RSP+0x8], RBX
	MOV [RSP+0x18], R8
	PUSH RBP
	PUSH RSI
	PUSH RDI
	PUSH R12
	PUSH R13
	PUSH R14
	PUSH R15
	MOV RBP, RSP
	SUB RSP, 0x30

; BEGIN CODE MODIFICATIONS -----------------------------------------------------------

	; msrlgr decoder obviously wants our data_size as data_size * 8
	shl		edx, 3

; END CODE MODIFICATIONS -----------------------------------------------------------

	MOV R13, R8
	MOVSXD RAX, R9D
	MOV EBX, EDX
	LEA R8, [RAX+RAX]
	MOV RSI, RCX
	MOV R12D, 0x1
	LEA RAX, [R8+R13]
	MOV R15D, 0x8
	XOR EDX, EDX
	MOV RCX, R13
	MOV [RBP-0x10], R12D
	MOV [RBP+0x58], R12D
	MOV [RBP-0x8], RAX
	MOV [RBP+0x48], R15D
	CALL xmemset
	ADD EBX, -0x20
	LEA EDI, [R12+0x1f]
	JS loc_00000069
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000098

loc_00000069:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_00000093
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_00000098

loc_00000093:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000098:
	MOV R8D, 0x50
	TEST R12D, R12D
	JZ loc_00000400

loc_000000A7:
	TEST EAX, EAX
	JS loc_00000139
	LEA R14D, [RBX+0x27]
	NOP WORD [RAX+RAX+0x0]

loc_000000C0:
	MOV ECX, R12D
	ADD R15D, 0x4
	MOV EDX, 0x1
	SHL RDX, CL
	CMP R15D, 0x50
	CMOVG R15D, R8D
	LEA R13, [R13+RDX*2+0x0]
	MOV R12D, R15D
	SAR R12D, 0x3
	DEC EDI
	JZ loc_000000EB
	ADD EAX, EAX
	JMP loc_0000012E

loc_000000EB:
	MOV EDI, 0x20
	SUB R14D, EDI
	SUB EBX, EDI
	JS loc_000000FF
	MOV EAX, [RSI]
	ADD RSI, 0x4
	JMP loc_0000012C

loc_000000FF:
	LEA EAX, [R14-0x7]
	TEST EAX, EAX
	JLE loc_00000134
	MOV EAX, R14D
	LEA RCX, [RBP+0x50]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP+0x50], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP+0x50]
	MOV R8D, 0x50

loc_0000012C:
	BSWAP EAX

loc_0000012E:
	TEST EAX, EAX
	JNS loc_000000C0
	JMP loc_00000139

loc_00000134:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000139:
	LEA EDX, [R12+0x1]
	TEST EDX, EDX
	JZ loc_000001B5
	MOV ECX, 0x20
	MOV R14D, EAX
	SUB EDI, EDX
	SUB ECX, EDX
	SHR R14D, CL
	TEST EDI, EDI
	JG loc_000001AF
	ADD EDI, 0x20
	SUB EBX, 0x20
	JS loc_00000167
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000196

loc_00000167:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_00000191
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP+0x50]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP+0x50], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP+0x50]
	BSWAP EAX
	JMP loc_00000196

loc_00000191:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000196:
	CMP EDI, 0x20
	JZ loc_000001B8
	MOV EDX, EAX
	MOV ECX, EDI
	SHR EDX, CL
	MOV ECX, 0x20
	SUB ECX, EDI
	OR R14D, EDX
	SHL EAX, CL
	JMP loc_000001B8

loc_000001AF:
	MOV ECX, EDX
	SHL EAX, CL
	JMP loc_000001B8

loc_000001B5:
	XOR R14D, R14D

loc_000001B8:
	MOV ECX, R12D
	MOV EDX, 0x1
	SHL EDX, CL
	MOV ECX, R14D
	NOT EDX
	AND RDX, RCX
	LEA R13, [R13+RDX*2+0x0]
	MOV [RBP+0x50], R13
	CMP R13, [RBP-0x8]
	JAE loc_000006FD
	LEA ECX, [RDI+RBX]
	TEST ECX, ECX
	JS loc_000006F8
	XOR R13D, R13D
	TEST EAX, EAX
	SETS R13B
	DEC EDI
	JZ loc_000001F9
	ADD EAX, EAX
	JMP loc_0000023B

loc_000001F9:
	MOV EDI, 0x20
	SUB EBX, EDI
	JS loc_0000020C
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_0000023B

loc_0000020C:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_00000236
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_0000023B

loc_00000236:
	MOV EAX, 0xffffffffa5a5e1e1

loc_0000023B:
	XOR R12D, R12D
	LEA R14D, [RBX+0x27]

loc_00000242:
	MOV ECX, EAX
	NOT ECX
	TEST ECX, ECX
	JNZ loc_0000024F
	LEA EDX, [RCX+0x20]
	JMP loc_00000259

loc_0000024F:
	BSR ECX, ECX
	MOV EDX, 0x1f
	SUB EDX, ECX

loc_00000259:
	ADD R12D, EDX
	SUB EDI, EDX
	JNZ loc_000002A8
	MOV EDI, 0x20
	SUB R14D, EDI
	SUB EBX, EDI
	JS loc_00000276
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000242

loc_00000276:
	LEA EAX, [R14-0x7]
	TEST EAX, EAX
	JLE loc_000002A1
	MOV EAX, R14D
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_00000242

loc_000002A1:
	MOV EAX, 0xffffffffa5a5e1e1
	JMP loc_00000242

loc_000002A8:
	DEC EDI
	JZ loc_000002B3
	LEA ECX, [RDX+0x1]
	SHL EAX, CL
	JMP loc_000002F5

loc_000002B3:
	MOV EDI, 0x20
	SUB EBX, EDI
	JS loc_000002C6
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_000002F5

loc_000002C6:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_000002F0
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_000002F5

loc_000002F0:
	MOV EAX, 0xffffffffa5a5e1e1

loc_000002F5:
	MOV R8D, [RBP+0x58]
	TEST R8D, R8D
	JZ loc_00000378
	MOV ECX, 0x20
	MOV R14D, EAX
	SUB EDI, R8D
	SUB ECX, R8D
	SHR R14D, CL
	TEST EDI, EDI
	JG loc_00000371
	ADD EDI, 0x20
	SUB EBX, 0x20
	JS loc_00000325
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000358

loc_00000325:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_00000353
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	MOV R8D, [RBP+0x58]
	BSWAP EAX
	JMP loc_00000358

loc_00000353:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000358:
	CMP EDI, 0x20
	JZ loc_0000037B
	MOV EDX, EAX
	MOV ECX, EDI
	SHR EDX, CL
	MOV ECX, 0x20
	SUB ECX, EDI
	OR R14D, EDX
	SHL EAX, CL
	JMP loc_0000037B

loc_00000371:
	MOV ECX, R8D
	SHL EAX, CL
	JMP loc_0000037B

loc_00000378:
	XOR R14D, R14D

loc_0000037B:
	MOV R9D, [RBP+0x48]
	MOV ECX, R8D
	MOV EDX, R12D
	SHL EDX, CL
	OR EDX, R14D
	TEST R12D, R12D
	JNZ loc_00000414
	SUB R9D, 0x2
	MOV ECX, R9D
	SAR ECX, 0x1f
	NOT ECX
	AND R9D, ECX
	MOV [RBP+0x48], R9D

loc_000003A6:
	MOV R8D, 0x50

loc_000003AC:
	SUB R15D, 0x6
	SAR R9D, 0x3
	INC EDX
	MOV ECX, R15D
	MOV [RBP+0x58], R9D
	SAR ECX, 0x1f
	NOT ECX
	AND R15D, ECX
	LEA ECX, [RDI+RBX]
	MOV R12D, R15D
	SAR R12D, 0x3
	MOV [RBP-0x10], R12D
	TEST ECX, ECX
	JS loc_000006F8
	TEST R13D, R13D
	JZ loc_000003E3
	NEG DX

loc_000003E3:
	MOV R13, [RBP+0x50]
	ADD R13, 0x2
	MOV [R13-0x2], DX
	MOV [RBP+0x50], R13
	TEST R12D, R12D
	JNZ loc_000000A7
	NOP DWORD [RAX]

loc_00000400:
	XOR R13D, R13D
	LEA R14D, [RBX+0x27]

loc_00000407:
	MOV ECX, EAX
	NOT ECX
	TEST ECX, ECX
	JNZ loc_00000434
	LEA EDX, [RCX+0x20]
	JMP loc_0000043E

loc_00000414:
	CMP R12D, 0x1
	JZ loc_000003A6
	ADD R9D, R12D
	MOV R8D, 0x50
	CMP R9D, 0x50
	CMOVG R9D, R8D
	MOV [RBP+0x48], R9D
	JMP loc_000003AC

loc_00000434:
	BSR ECX, ECX
	MOV EDX, 0x1f
	SUB EDX, ECX

loc_0000043E:
	ADD R13D, EDX
	SUB EDI, EDX
	JNZ loc_00000490
	MOV EDI, 0x20
	SUB R14D, EDI
	SUB EBX, EDI
	JS loc_0000045B
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000407

loc_0000045B:
	LEA EAX, [R14-0x7]
	TEST EAX, EAX
	JLE loc_00000486
	MOV EAX, R14D
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_00000407

loc_00000486:
	MOV EAX, 0xffffffffa5a5e1e1
	JMP loc_00000407

loc_00000490:
	DEC EDI
	JZ loc_0000049B
	LEA ECX, [RDX+0x1]
	SHL EAX, CL
	JMP loc_000004DD

loc_0000049B:
	MOV EDI, 0x20
	SUB EBX, EDI
	JS loc_000004AE
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_000004DD

loc_000004AE:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_000004D8
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_000004DD

loc_000004D8:
	MOV EAX, 0xffffffffa5a5e1e1

loc_000004DD:
	MOV R8D, [RBP+0x58]
	TEST R8D, R8D
	JZ loc_00000560
	MOV ECX, 0x20
	MOV R12D, EAX
	SUB EDI, R8D
	SUB ECX, R8D
	SHR R12D, CL
	TEST EDI, EDI
	JG loc_00000559
	ADD EDI, 0x20
	SUB EBX, 0x20
	JS loc_0000050D
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000540

loc_0000050D:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_0000053B
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	MOV R8D, [RBP+0x58]
	BSWAP EAX
	JMP loc_00000540

loc_0000053B:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000540:
	CMP EDI, 0x20
	JZ loc_00000563
	MOV EDX, EAX
	MOV ECX, EDI
	SHR EDX, CL
	MOV ECX, 0x20
	SUB ECX, EDI
	OR R12D, EDX
	SHL EAX, CL
	JMP loc_00000563

loc_00000559:
	MOV ECX, R8D
	SHL EAX, CL
	JMP loc_00000563

loc_00000560:
	XOR R12D, R12D

loc_00000563:
	MOV R9D, [RBP+0x48]
	MOV ECX, R8D
	MOV R14D, R13D
	SHL R14D, CL
	OR R14D, R12D
	TEST R13D, R13D
	JNZ loc_000005D4
	SUB R9D, 0x2
	MOV ECX, R9D
	SAR ECX, 0x1f
	NOT ECX
	AND R9D, ECX
	MOV [RBP+0x48], R9D

loc_0000058B:
	MOV R12D, 0x50

loc_00000591:
	MOV ECX, R9D
	SAR ECX, 0x3
	MOV [RBP+0x58], ECX
	TEST R14D, R14D
	JZ loc_0000063F
	BSR EDX, R14D
	INC EDX
	JZ loc_0000063F
	MOV ECX, 0x20
	MOV R13D, EAX
	SUB EDI, EDX
	SUB ECX, EDX
	SHR R13D, CL
	TEST EDI, EDI
	JG loc_00000639
	ADD EDI, 0x20
	SUB EBX, 0x20
	JS loc_000005F1
	MOV EAX, [RSI]
	ADD RSI, 0x4
	BSWAP EAX
	JMP loc_00000620

loc_000005D4:
	CMP R13D, 0x1
	JZ loc_0000058B
	ADD R9D, R13D
	MOV R12D, 0x50
	CMP R9D, 0x50
	CMOVG R9D, R12D
	MOV [RBP+0x48], R9D
	JMP loc_00000591

loc_000005F1:
	LEA EAX, [RBX+0x20]
	TEST EAX, EAX
	JLE loc_0000061B
	LEA EAX, [RBX+0x27]
	LEA RCX, [RBP-0xc]
	MOV RDX, RSI
	SAR EAX, 0x3
	MOV DWORD [RBP-0xc], 0x0
	MOVSXD R8, EAX
	CALL xmemcpy
	MOV EAX, [RBP-0xc]
	BSWAP EAX
	JMP loc_00000620

loc_0000061B:
	MOV EAX, 0xffffffffa5a5e1e1

loc_00000620:
	CMP EDI, 0x20
	JZ loc_00000642
	MOV EDX, EAX
	MOV ECX, EDI
	SHR EDX, CL
	MOV ECX, 0x20
	SUB ECX, EDI
	OR R13D, EDX
	SHL EAX, CL
	JMP loc_00000642

loc_00000639:
	MOV ECX, EDX
	SHL EAX, CL
	JMP loc_00000642

loc_0000063F:
	XOR R13D, R13D

loc_00000642:
	SUB R14D, R13D
	TEST R13D, R13D
	JZ loc_0000066B
	TEST R14D, R14D
	JZ loc_00000689
	SUB R15D, 0x6
	MOV ECX, R15D
	SAR ECX, 0x1f
	NOT ECX
	AND R15D, ECX
	MOV R12D, R15D
	SAR R12D, 0x3
	MOV [RBP-0x10], R12D
	JMP loc_0000068D

loc_0000066B:
	TEST R14D, R14D
	JNZ loc_00000689
	ADD R15D, 0x6
	CMP R15D, 0x50
	CMOVG R15D, R12D
	MOV R12D, R15D
	SAR R12D, 0x3
	MOV [RBP-0x10], R12D
	JMP loc_0000068D

loc_00000689:
	MOV R12D, [RBP-0x10]

loc_0000068D:
	MOV RCX, [RBP-0x8]
	CMP [RBP+0x50], RCX
	JAE loc_000006FD
	LEA ECX, [RDI+RBX]
	TEST ECX, ECX
	JS loc_000006F8
	MOV R8D, R13D
	LEA EDX, [R13+0x1]
	MOV R13, [RBP+0x50]
	SAR EDX, 0x1
	AND R8D, 0x1
	ADD R13, 0x4
	MOVZX ECX, R8W
	MOV [RBP+0x50], R13
	NEG CX
	XOR DX, CX
	ADD DX, R8W
	MOV R8D, R14D
	MOV [R13-0x4], DX
	AND R8D, 0x1
	LEA EDX, [R14+0x1]
	SAR EDX, 0x1
	MOVZX ECX, R8W
	NEG CX
	XOR DX, CX
	ADD DX, R8W
	MOV [R13-0x2], DX
	TEST R12D, R12D
	JZ loc_00000400
	JMP loc_00000098

loc_000006F8:
	OR EAX, -0x1
	JMP loc_000006FF

loc_000006FD:
	XOR EAX, EAX

loc_000006FF:
	MOV RBX, [RSP+0x70]
	ADD RSP, 0x30
	POP R15
	POP R14
	POP R13
	POP R12
	POP RDI
	POP RSI
	POP RBP
	RET
