# itl8080
An emulator for the Intel 8080 CPU Instruction Set

# Recent Change
Implemented the MOV and MVI instructions:
```zig
{ 0x06, 0xA, 0x48 }
```
Equivalent to
```asm
MVI B, 0xA
MOV C, B
```

`MVI B, 0xA` loads the immediate value `0xA` into register `B`.

`MOV C, B` copies register `B` into register `C` (`MOV DEST, SRC`).

# Specs & Mental Logs
### Registers
A static RAM array organised into six 16-bit registers.
It contains:
* Program counter (PC)
* Stack pointer (SP)
* Six 8-bit general purpose registers arranged in pairs, referred to as B, C; D, E; and H, L
* A temporary register pair called W,Z

The PC (program counter) is responsible for holding the memory address of the current program instruction, and is incremented automatically during every instruction fetch.

The SP (stack pointer) is responsible for holding the memory address of the next available stack location in memory, it can be initialised to use any portion of read-write memory as a stack.

When data is "pushed" onto the stack, the SP is decremented; when data is "popped" from the stack, the SP is incremented. Because the stack grows downwards.

The six general purpose registers can be used either as single registers (8-bit) or as register pairs (16-bit).

*The temporary register pair, W,Z is not program addressable and is only used for the internal execution of instructions.*

Eight bit data bytes can be transferred between the internal bus and the register array via the register select multiplexer. Sixteen bit transfers can proceed between the register array and the address latch or the incrementer/decrementer circuit. The address latch receives data from any of the three register pairs and drives the 16 address output buffers (A0-A15), as well as the incrementer/decrementer circuit. The IC/DC circuit receives data from the address latch and sends it to the register array. The 16 bit data can be incremented or decremented or simply transferred between registers.

![functional block diagram](images/functional_block_diagram.png)

### Arithmetic & Logic Unit
The ALU contains the following registers:
* An 8-bit accumulator
* An 8-bit temporary accumulator (ACT)
* A 5-bit flag register: zero, carry, sign, parity, and auxiliary carry
* An 8-bit temporary register (TMP)

Arithmetic, logical, and rotate operations are performed in the ALU. The ALU is fed by the TMP and the ACT and carry flip-flop. The result of the operation can be transferred to the internal bus or to the accumulator; the ALU also feeds the flag register.

The TMP receives information from the internal bus and can send all or portions of it to the ALU, the flag register and the internal bus.

The ACC (accumulator) can be loaded from the ALU and the internal bus and can transfer data to the temporary accumulator ACT and the internal bus. The contents of the ACC and the auxiliary carry flip-flop can be tested for decimal correction during the execution of the DAA instruction.

### Instruction Register and Control
During an instruction fetch, the first byte of an instruction (containing the opcode) is transferred from the internal bus to the 8-bit instruction register.

The contents of the instruction register are, in turn, available to the instruction decoder. The output of the decoder, combined with various timing signals, provides the control signals for the register array, ALU and data buffer blocks. In addition, the outputs from the instruction decoder and external control signals feed the timing and state control section which generates the state and cycle timing signals.

I noticed when looking at the opcode table, I was able to easily categorise opcodes. I discovered a pattern when right shifting the opcode by six, for example:
```
0x40 >> 6 = 0b1, 0x1, 1
0x80 >> 6 = 0b10, 0x2, 2
0xA0 >> 6 = 0b10, 0x2, 2
0xC0 >> 6 = 0b11, 0x3, 3
0x00 >> 6 = 0b0, 0x0, 0
```