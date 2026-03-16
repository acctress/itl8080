const std = @import("std");

const MEMORY_SIZE = 65536;
const REGISTER_COUNT = 8;

const REG_A = 0x7;
const REG_B = 0x0;
const REG_C = 0x1;
const REG_D = 0x2;
const REG_E = 0x3;
const REG_H = 0x4;
const REG_L = 0x5;

const FLAG_ZERO: u8 = 0x1 << 0x6;
const FLAG_CARRY: u8 = 0x1 << 0x0;
const FLAG_SIGN: u8 = 0x1 << 0x7;
const FLAG_PARITY: u8 = 0x1 << 0x2;
const FLAG_AUXILIARY: u8 = 0x1 << 0x4;

pub const itl8080 = struct {
    memory: [MEMORY_SIZE]u8,
    registers: [REGISTER_COUNT]u8,
    ports: [256]u8,
    flags: u8,
    pc: u16,
    sp: u16,
    halted: bool,
    interrupts_enabled: bool,

    pub fn init(data: []const u8) itl8080 {
        var memory: [MEMORY_SIZE]u8 = std.mem.zeroes([MEMORY_SIZE]u8);
        @memcpy(memory[0x0..data.len], data);

        return .{
            .memory = memory,
            .registers = std.mem.zeroes([REGISTER_COUNT]u8),
            .ports = std.mem.zeroes([256]u8),
            .flags = 0,
            .pc = 0,
            .sp = 0,
            .halted = false,
            .interrupts_enabled = false,
        };
    }

    pub fn step(self: *itl8080) void {
        if (self.halted) return;

        const opcode = self.memory[self.pc];
        self.pc += 1;

        switch (opcode >> 6) {
            // control, 0x00 <-> 0x3F
            0x0 => self.control(opcode),
            // data transfer, 0x40 <-> 0x7F, (exclude x76 hlt)
            0x1 => self.transfer(opcode),
            // arithmetic & logical, 0x80 <-> 0xBF
            0x2 => self.arithmetic(opcode),
            // branch, stack, i/o, 0xC0 <-> 0xFF
            0x3 => self.branch(opcode),
            else => {},
        }
    }

    fn control(self: *itl8080, opcode: u8) void {
        switch (opcode) {
            // stc
            0x37 => {
                self.flags |= FLAG_CARRY;
                return;
            },
            // cmc
            0x3F => {
                self.flags ^= FLAG_CARRY;
                return;
            },
            // cma
            0x2F => {
                self.registers[REG_A] = ~self.registers[REG_A];
                return;
            },
            // rlc
            0x07 => {
                const bit7 = (self.registers[REG_A] >> 0x7) & 0x1;
                self.registers[REG_A] <<= 0x1;
                self.registers[REG_A] |= bit7;
                if (bit7 != 0) self.flags |= FLAG_CARRY else self.flags &= ~FLAG_CARRY;
                return;
            },
            // rrc
            0x0F => {
                const bit0 = self.registers[REG_A] & 0x1;
                self.registers[REG_A] >>= 0x1;
                self.registers[REG_A] |= (bit0 << 7);
                if (bit0 != 0) self.flags |= FLAG_CARRY else self.flags &= ~FLAG_CARRY;
                return;
            },
            // ral
            0x17 => {
                const bit7 = (self.registers[REG_A] >> 0x7) & 0x1;
                const old_carry = self.flags & FLAG_CARRY;
                self.registers[REG_A] <<= 0x1;
                self.registers[REG_A] |= old_carry;
                if (bit7 != 0) self.flags |= FLAG_CARRY else self.flags &= ~FLAG_CARRY;
                return;
            },
            // rar
            0x1F => {
                const bit0 = self.registers[REG_A] & 0x1;
                const old_carry = self.flags & FLAG_CARRY;
                self.registers[REG_A] >>= 0x1;
                self.registers[REG_A] |= old_carry << 0x7;
                if (bit0 != 0) self.flags |= FLAG_CARRY else self.flags &= ~FLAG_CARRY;
                return;
            },
            else => {},
        }

        const inst = opcode & 0xF;

        switch (inst) {
            0x6, 0xE => self.mvi(opcode),
            0xB => self.dcx(opcode),
            0x3 => self.inx(opcode),
            0x4, 0xC => self.inr(opcode),
            0x5, 0xD => self.dcr(opcode),
            0x1 => self.lxi(opcode),
            else => {},
        }
    }

    fn transfer(self: *itl8080, opcode: u8) void {
        if (opcode == 0x76) { // hlt
            self.halted = true;
        } else {
            self.mov(opcode);
        }
    }

    fn arithmetic(self: *itl8080, opcode: u8) void {
        const inst = (opcode >> 3) & 0x7;

        switch (inst) {
            0x0 => self.add(opcode),
            0x1 => self.adc(opcode),
            0x2 => self.sub(opcode),
            0x3 => self.sbb(opcode),
            0x4 => self.ana(opcode),
            0x5 => self.xra(opcode),
            0x6 => self.ora(opcode),
            0x7 => self.cmp(opcode),
            else => {},
        }
    }

    fn branch(self: *itl8080, opcode: u8) void {
        switch (opcode) {
            0xE9 => {
                self.pc = (@as(u16, self.registers[REG_H]) << 8) | self.registers[REG_L];
                return;
            }, // pchl
            0xCD => {
                self.callIf(true);
                return;
            }, // call
            0xDB => {
                const port = self.memory[self.pc];
                self.registers[REG_A] = self.ports[port];
                self.pc += 1;
                return;
            }, // input
            0xD3 => {
                const port = self.memory[self.pc];
                self.ports[port] = self.registers[REG_A];
                self.pc += 1;
                return;
            }, // output
            0xEB => {
                const th = self.registers[REG_H];
                const tl = self.registers[REG_L];
                self.registers[REG_H] = self.registers[REG_D];
                self.registers[REG_L] = self.registers[REG_E];
                self.registers[REG_D] = th;
                self.registers[REG_E] = tl;
                return;
            }, // xchg
            0xF3 => {
                self.interrupts_enabled = false;
                return;
            }, // di
            0xFB => {
                self.interrupts_enabled = true;
                return;
            }, // di
            0xF9 => {
                const hl = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];
                self.sp = hl;
                return;
            }, // sphl
            0xE6 => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) & @as(u16, source_value);

                self.flags &= ~FLAG_CARRY;
                if ((self.registers[REG_A] | source_value) & 0x08 != 0) {
                    self.flags |= FLAG_AUXILIARY;
                } else {
                    self.flags &= ~FLAG_AUXILIARY;
                }

                self.registers[REG_A] = @truncate(result);
                self.setSign(@truncate(result));
                self.setZero(@truncate(result));
                self.setParity(@truncate(result));
                self.pc += 1;

                return;
            }, // ani
            0xF6 => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) | @as(u16, source_value);

                self.setSign(@truncate(result));
                self.setZero(@truncate(result));
                self.setParity(@truncate(result));

                self.flags &= ~FLAG_CARRY;
                self.flags &= ~FLAG_AUXILIARY;

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;

                return;
            }, // ori
            0xEE => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) ^ @as(u16, source_value);

                self.setSign(@truncate(result));
                self.setZero(@truncate(result));
                self.setParity(@truncate(result));

                self.flags &= ~FLAG_CARRY;
                self.flags &= ~FLAG_AUXILIARY;

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;

                return;
            }, // xri
            0xFE => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) -% @as(u16, source_value);

                self.setZero(@truncate(result));
                self.setSign(@truncate(result));
                self.setParity(@truncate(result));
                self.setCarry(result);
                self.setAuxCarry(false, self.registers[REG_A], source_value);
                self.pc += 1;

                return;
            }, // cpi
            0xC6 => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) + @as(u16, source_value);

                self.setZero(@truncate(result));
                self.setSign(@truncate(result));
                self.setParity(@truncate(result));
                self.setCarry(result);
                self.setAuxCarry(true, self.registers[REG_A], source_value);

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;
                return;
            }, // adi
            0xD6 => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) -% @as(u16, source_value);

                self.setZero(@truncate(result));
                self.setSign(@truncate(result));
                self.setParity(@truncate(result));
                self.setCarry(result);
                self.setAuxCarry(false, self.registers[REG_A], source_value);

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;
                return;
            }, // sui
            0xCE => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) + @as(u16, source_value) + (self.flags & FLAG_CARRY);

                self.setZero(@truncate(result));
                self.setSign(@truncate(result));
                self.setParity(@truncate(result));
                self.setCarry(result);
                self.setAuxCarry(true, self.registers[REG_A], source_value);

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;
                return;
            }, // aci
            0xDE => {
                const source_value = self.memory[self.pc];
                const result: u16 = @as(u16, self.registers[REG_A]) -% @as(u16, source_value) -% (self.flags & FLAG_CARRY);

                self.setZero(@truncate(result));
                self.setSign(@truncate(result));
                self.setParity(@truncate(result));
                self.setCarry(result);
                self.setAuxCarry(false, self.registers[REG_A], source_value);

                self.registers[REG_A] = @truncate(result);
                self.pc += 1;
                return;
            }, // sbi
            else => {},
        }

        const inst = opcode & 0x7;
        switch (inst) {
            // Returns
            0x0 => {
                const condition = (opcode >> 3) & 0x7;
                switch (condition) {
                    0b000 => self.rnz(),
                    0b001 => self.rz(),
                    0b010 => self.rnc(),
                    0b011 => self.rc(),
                    0b100 => self.rpo(),
                    0b101 => self.rpe(),
                    0b110 => self.rp(),
                    0b111 => self.rm(),
                    else => {},
                }
            },
            // Pops
            0x1 => self.pop(opcode),
            // Pushes
            0x5 => self.push(opcode),
            // Jumps
            0x3 => self.jumpIf(true), // jmp
            0x2 => {
                const condition = (opcode >> 3) & 0x7;
                switch (condition) {
                    0b000 => self.jumpIf(self.flags & FLAG_ZERO == 0), // jnz
                    0b001 => self.jumpIf(self.flags & FLAG_ZERO != 0), // jz
                    0b010 => self.jumpIf(self.flags & FLAG_CARRY == 0), // jnc
                    0b011 => self.jumpIf(self.flags & FLAG_CARRY != 0), // jc
                    0b100 => self.jumpIf(self.flags & FLAG_PARITY == 0), // jpo
                    0b101 => self.jumpIf(self.flags & FLAG_PARITY != 0), // jpe
                    0b110 => self.jumpIf(self.flags & FLAG_SIGN == 0), // jp
                    0b111 => self.jumpIf(self.flags & FLAG_SIGN != 0), // jm
                    else => {},
                }
            },
            // Calls
            0x4 => {
                const condition = (opcode >> 3) & 0x7;
                switch (condition) {
                    0b000 => self.callIf(self.flags & FLAG_ZERO == 0), // cnz
                    0b010 => self.callIf(self.flags & FLAG_CARRY == 0), // cnc
                    0b100 => self.callIf(self.flags & FLAG_PARITY == 0), // cpo
                    0b110 => self.callIf(self.flags & FLAG_SIGN == 0), // cp
                    0b001 => self.callIf(self.flags & FLAG_ZERO != 0), // cz
                    0b011 => self.callIf(self.flags & FLAG_CARRY != 0), // cc
                    0b101 => self.callIf(self.flags & FLAG_PARITY != 0), // cpe
                    0b111 => self.callIf(self.flags & FLAG_SIGN != 0), // cm
                    else => {},
                }
            },
            else => {},
        }
    }

    fn pop(self: *itl8080, opcode: u8) void {
        const condition = (opcode >> 4) & 0x3;
        //            POP B   0xC1
        //                    110000001
        //                      ^^
        // read bits 5-4
        switch (condition) {
            0b00 => self.popPair(REG_B, REG_C), // pop b
            0b01 => self.popPair(REG_D, REG_E), // pop d
            0b10 => self.popPair(REG_H, REG_L), // pop h
            0b11 => self.popPSW(), // pop psw
            else => {},
        }
    }

    fn push(self: *itl8080, opcode: u8) void {
        const condition = (opcode >> 4) & 0x3;
        switch (condition) {
            0b00 => self.pushPair(REG_B, REG_C), // push b
            0b01 => self.pushPair(REG_D, REG_E), // push d
            0b10 => self.pushPair(REG_H, REG_L), // push h
            0b11 => self.pushPSW(), // push psw
            else => {},
        }
    }

    fn mvi(self: *itl8080, opcode: u8) void {
        const destination = (opcode >> 3) & 0x7;
        const imm = self.memory[self.pc];

        if (destination == 0x6) {
            const addr = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];
            self.memory[addr] = imm;
        } else {
            self.registers[destination] = imm;
        }

        self.pc += 1;
    }

    fn dcx(self: *itl8080, opcode: u8) void {
        const reg_pair = (opcode >> 4) & 0x3;

        // handle stack pointer
        if (reg_pair == 0b11) {
            const dec = self.sp -% 1;
            self.sp = dec;
        } else {
            const first_reg, const second_reg = self.getRegister16(reg_pair);
            const low_byte = self.registers[second_reg];
            const high_byte = self.registers[first_reg];
            const value = (@as(u16, high_byte) << 8 | low_byte) - 1;
            const new_high: u8 = @truncate(value >> 8);
            const new_low: u8 = @truncate(value & 0xFF);

            self.registers[first_reg] = new_high;
            self.registers[second_reg] = new_low;
        }
    }

    fn inx(self: *itl8080, opcode: u8) void {
        const reg_pair = (opcode >> 4) & 0x3;

        // handle stack pointer
        if (reg_pair == 0b11) {
            self.sp += 1;
        } else {
            const first_reg, const second_reg = self.getRegister16(reg_pair);
            const low_byte = self.registers[second_reg];
            const high_byte = self.registers[first_reg];
            const value = (@as(u16, high_byte) << 8 | low_byte) + 1;
            const new_high: u8 = @truncate(value >> 8);
            const new_low: u8 = @truncate(value & 0xFF);

            self.registers[first_reg] = new_high;
            self.registers[second_reg] = new_low;
        }
    }

    fn inr(self: *itl8080, opcode: u8) void {
        const dest = (opcode >> 3) & 0x7;
        if (dest == 0x6) {
            const addr = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];
            const value = self.memory[addr] +% 1;
            self.memory[addr] = value;
            self.setAuxCarry(true, self.memory[addr], 1);
            self.setParity(value);
            self.setSign(value);
            self.setZero(value);
        } else {
            const value = self.registers[dest] +% 1;
            self.setAuxCarry(true, self.registers[dest], 1);
            self.setParity(value);
            self.setSign(value);
            self.setZero(value);

            self.registers[dest] = value;
        }
    }

    fn dcr(self: *itl8080, opcode: u8) void {
        const dest = (opcode >> 3) & 0x7;
        if (dest == 0x6) {
            const addr = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];
            const value = self.memory[addr] -% 1;

            self.setAuxCarry(false, self.memory[addr], 1);
            self.setParity(value);
            self.setSign(value);
            self.setZero(value);

            self.memory[addr] = value;
        } else {
            const value = self.registers[dest] -% 1;
            self.setAuxCarry(false, self.registers[dest], 1);
            self.setParity(value);
            self.setSign(value);
            self.setZero(value);

            self.registers[dest] = value;
        }
    }

    fn lxi(self: *itl8080, opcode: u8) void {
        const low_byte = self.memory[self.pc];
        const high_byte = self.memory[self.pc + 1];
        const value = @as(u16, high_byte) << 8 | low_byte;
        const reg_pair = (opcode >> 4) & 0x3;

        // handle stack pointer
        if (reg_pair == 0b11) {
            self.sp = value;
        } else {
            const first_reg, const second_reg = self.getRegister16(reg_pair);
            self.registers[first_reg] = high_byte;
            self.registers[second_reg] = low_byte;
        }

        self.pc += 2;
    }

    fn mov(self: *itl8080, opcode: u8) void {
        const destination = (opcode >> 3) & 0x7;
        const source = opcode & 0x7;

        // MOV
        if (destination == 0x6 or source == 0x6) {
            const addr = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];

            if (destination == 0x6) self.memory[addr] = self.registers[source];
            if (source == 0x6) self.registers[destination] = self.memory[addr];
        } else {
            self.registers[destination] = self.registers[source];
        }
    }

    fn add(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) + @as(u16, source_value);

        self.setZero(@truncate(result));
        self.setSign(@truncate(result));
        self.setParity(@truncate(result));
        self.setCarry(result);
        self.setAuxCarry(true, self.registers[REG_A], source_value);

        self.registers[REG_A] = @truncate(result);
    }

    fn adc(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) + @as(u16, source_value) + (self.flags & FLAG_CARRY);

        self.setZero(@truncate(result));
        self.setSign(@truncate(result));
        self.setParity(@truncate(result));
        self.setCarry(result);
        self.setAuxCarry(true, self.registers[REG_A], source_value);

        self.registers[REG_A] = @truncate(result);
    }

    fn sub(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const A = self.registers[REG_A];
        const result: u16 = @as(u16, A) -% @as(u16, source_value);

        self.setZero(@truncate(result));
        self.setSign(@truncate(result));
        self.setParity(@truncate(result));

        if (A < source_value) {
            self.flags |= FLAG_CARRY;
        } else {
            self.flags &= ~FLAG_CARRY;
        }

        self.setAuxCarry(false, self.registers[REG_A], source_value);
        self.registers[REG_A] = @truncate(result);
    }

    fn sbb(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) -% @as(u16, source_value) -% (self.flags & FLAG_CARRY);

        self.setZero(@truncate(result));
        self.setSign(@truncate(result));
        self.setParity(@truncate(result));
        self.setCarry(result);
        self.setAuxCarry(false, self.registers[REG_A], source_value);

        self.registers[REG_A] = @truncate(result);
    }

    fn ana(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) & @as(u16, source_value);

        self.flags &= ~FLAG_CARRY;
        if ((self.registers[REG_A] | source_value) & 0x08 != 0) {
            self.flags |= FLAG_AUXILIARY;
        } else {
            self.flags &= ~FLAG_AUXILIARY;
        }

        self.registers[REG_A] = @truncate(result);
        self.setSign(@truncate(result));
        self.setZero(@truncate(result));
        self.setParity(@truncate(result));
    }

    fn xra(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) ^ @as(u16, source_value);

        self.setSign(@truncate(result));
        self.setZero(@truncate(result));
        self.setParity(@truncate(result));

        self.flags &= ~FLAG_CARRY;
        self.flags &= ~FLAG_AUXILIARY;

        self.registers[REG_A] = @truncate(result);
    }

    fn ora(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) | @as(u16, source_value);

        self.setSign(@truncate(result));
        self.setZero(@truncate(result));
        self.setParity(@truncate(result));

        self.flags &= ~FLAG_CARRY;
        self.flags &= ~FLAG_AUXILIARY;

        self.registers[REG_A] = @truncate(result);
    }

    fn cmp(self: *itl8080, opcode: u8) void {
        const source_value = self.getSourceValueRM(opcode);
        const result: u16 = @as(u16, self.registers[REG_A]) -% @as(u16, source_value);

        self.setZero(@truncate(result));
        self.setSign(@truncate(result));
        self.setParity(@truncate(result));
        self.setCarry(result);
        self.setAuxCarry(false, self.registers[REG_A], source_value);
    }

    fn rnz(self: *itl8080) void {
        if (self.flags & FLAG_ZERO == 0) self.popStack();
    }

    fn rz(self: *itl8080) void {
        if (self.flags & FLAG_ZERO != 0) self.popStack();
    }

    fn rc(self: *itl8080) void {
        if (self.flags & FLAG_CARRY != 0) self.popStack();
    }

    fn rnc(self: *itl8080) void {
        if (self.flags & FLAG_CARRY == 0) self.popStack();
    }

    fn rpo(self: *itl8080) void {
        if (self.flags & FLAG_PARITY == 0) self.popStack();
    }

    fn rpe(self: *itl8080) void {
        if (self.flags & FLAG_PARITY != 0) self.popStack();
    }

    fn rp(self: *itl8080) void {
        if (self.flags & FLAG_SIGN == 0) self.popStack();
    }

    fn rm(self: *itl8080) void {
        if (self.flags & FLAG_SIGN != 0) self.popStack();
    }

    fn getSourceValueRM(self: *itl8080, opcode: u8) u8 {
        return if (opcode & 0x7 == 0x6) v: {
            const addr = @as(u16, self.registers[REG_H]) << 8 | self.registers[REG_L];
            break :v self.memory[addr];
        } else v: {
            break :v self.registers[opcode & 0x7];
        };
    }

    fn jumpIf(self: *itl8080, condition: bool) void {
        const low_byte = self.memory[self.pc];
        const high_byte = self.memory[self.pc + 1];
        const addr = @as(u16, high_byte) << 8 | low_byte;

        if (condition) {
            self.pc = addr;
        } else {
            self.pc += 2;
        }
    }

    fn callIf(self: *itl8080, condition: bool) void {
        const low_byte = self.memory[self.pc];
        const high_byte = self.memory[self.pc + 1];
        const addr = @as(u16, high_byte) << 8 | low_byte;

        if (condition) {
            self.pushStack(self.pc + 2);
            self.pc = addr;
        } else {
            self.pc += 2;
        }
    }

    fn popStack(self: *itl8080) void {
        const low_byte = self.memory[self.sp];
        const high_byte = self.memory[self.sp + 1];
        const addr = @as(u16, high_byte) << 8 | low_byte;
        self.pc = addr;
        self.sp = self.sp +% 2;
    }

    fn pushStack(self: *itl8080, value: u16) void {
        const low_byte = value & 0xFF;
        const high_byte = value >> 8;
        self.sp = self.sp -% 2;
        self.memory[self.sp] = @truncate(low_byte);
        self.memory[self.sp + 1] = @truncate(high_byte);
    }

    fn popPair(self: *itl8080, high_reg: u8, low_reg: u8) void {
        const high = self.memory[self.sp + 1];
        const low = self.memory[self.sp];
        self.registers[high_reg] = high;
        self.registers[low_reg] = low;
        self.sp += 2;
    }

    fn popPSW(self: *itl8080) void {
        self.flags = self.memory[self.sp];
        self.registers[REG_A] = self.memory[self.sp + 1];
        self.sp += 2;
    }

    fn pushPair(self: *itl8080, high_reg: u8, low_reg: u8) void {
        self.sp -= 2;
        self.memory[self.sp + 1] = self.registers[high_reg];
        self.memory[self.sp] = self.registers[low_reg];
    }

    fn pushPSW(self: *itl8080) void {
        self.sp -= 2;
        self.memory[self.sp + 1] = self.registers[REG_A];
        self.memory[self.sp] = self.flags;
    }

    fn getRegister16(self: *itl8080, reg_pair_id: u8) struct { u8, u8 } {
        _ = self;
        switch (reg_pair_id) {
            0b00 => return .{ REG_B, REG_C },
            0b01 => return .{ REG_D, REG_E },
            0b10 => return .{ REG_H, REG_L },
            // 0b11 is for stack pointer, just return REG_A for now
            else => return .{ REG_A, REG_A },
        }
    }

    fn setZero(self: *itl8080, result: u8) void {
        if (result == 0) {
            self.flags |= FLAG_ZERO;
        } else {
            self.flags &= ~FLAG_ZERO;
        }
    }

    fn setSign(self: *itl8080, result: u8) void {
        // if most sig bit is 1, set sign flag
        if (result & 0x80 != 0) {
            self.flags |= FLAG_SIGN;
        } else {
            self.flags &= ~FLAG_SIGN;
        }
    }

    fn setParity(self: *itl8080, result: u8) void {
        if (@popCount(result) % 2 == 0) {
            self.flags |= FLAG_PARITY;
        } else {
            self.flags &= ~FLAG_PARITY;
        }
    }

    fn setCarry(self: *itl8080, result: u16) void {
        if (result > 0xFF) {
            self.flags |= FLAG_CARRY;
        } else {
            self.flags &= ~FLAG_CARRY;
        }
    }

    fn setAuxCarry(self: *itl8080, adding: bool, a: u8, b: u8) void {
        if (adding) {
            if (((a & 0xF) + (b & 0xF)) > 0xF) {
                self.flags |= FLAG_AUXILIARY;
            } else {
                self.flags &= ~FLAG_AUXILIARY;
            }
        } else {
            if (((a & 0xF) < (b & 0xF))) {
                self.flags |= FLAG_AUXILIARY;
            } else {
                self.flags &= ~FLAG_AUXILIARY;
            }
        }
    }
};

test "mvi b, 0xa" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_B]);
}

test "mvi b, 0xa mov c, b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA, 0x48 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_B]);
    try std.testing.expectEqual(0xA, cpu.registers[REG_C]);
}

test "lxi b, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x01, 0x34, 0x12 });
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_B]);
    try std.testing.expectEqual(0x34, cpu.registers[REG_C]);
}

test "lxi d, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x11, 0x34, 0x12 });
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_D]);
    try std.testing.expectEqual(0x34, cpu.registers[REG_E]);
}

test "lxi h, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x21, 0x34, 0x12 });
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_H]);
    try std.testing.expectEqual(0x34, cpu.registers[REG_L]);
}

test "lxi sp, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x31, 0x34, 0x12 });
    cpu.step();

    try std.testing.expectEqual(0x1234, cpu.sp);
}

test "lxi b, d16 inx b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x01, 0x34, 0x12, 0x03 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_B]);
    try std.testing.expectEqual(0x35, cpu.registers[REG_C]);
}

test "lxi d, d16 inx d" {
    var cpu: itl8080 = .init(&[_]u8{ 0x11, 0x34, 0x12, 0x13 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_D]);
    try std.testing.expectEqual(0x35, cpu.registers[REG_E]);
}

test "lxi h, d16 inx h" {
    var cpu: itl8080 = .init(&[_]u8{ 0x21, 0x34, 0x12, 0x23 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_H]);
    try std.testing.expectEqual(0x35, cpu.registers[REG_L]);
}

test "lxi sp, d16 inx sp" {
    var cpu: itl8080 = .init(&[_]u8{ 0x31, 0x34, 0x12, 0x33 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x1235, cpu.sp);
}

test "lxi b, d16 dcx b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x01, 0x34, 0x12, 0x0B });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_B]);
    try std.testing.expectEqual(0x33, cpu.registers[REG_C]);
}

test "lxi d, d16 dcx d" {
    var cpu: itl8080 = .init(&[_]u8{ 0x11, 0x34, 0x12, 0x1B });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_D]);
    try std.testing.expectEqual(0x33, cpu.registers[REG_E]);
}

test "lxi h, d16 dcx h" {
    var cpu: itl8080 = .init(&[_]u8{ 0x21, 0x34, 0x12, 0x2B });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_H]);
    try std.testing.expectEqual(0x33, cpu.registers[REG_L]);
}

test "lxi sp, d16 dcx sp" {
    var cpu: itl8080 = .init(&[_]u8{ 0x31, 0x34, 0x12, 0x3B });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x1233, cpu.sp);
}

test "mvi b, add b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA, 0x80 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi c, add c" {
    var cpu: itl8080 = .init(&[_]u8{ 0x0E, 0xA, 0x81 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi d, add d" {
    var cpu: itl8080 = .init(&[_]u8{ 0x16, 0xA, 0x82 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi e, add e" {
    var cpu: itl8080 = .init(&[_]u8{ 0x1E, 0xA, 0x83 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi b, adc b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA, 0x88 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi c, adc c" {
    var cpu: itl8080 = .init(&[_]u8{ 0x0E, 0xA, 0x89 });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi d, adc d" {
    var cpu: itl8080 = .init(&[_]u8{ 0x16, 0xA, 0x8A });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi e, adc e" {
    var cpu: itl8080 = .init(&[_]u8{ 0x1E, 0xA, 0x8B });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_A]);
}

test "mvi a, 0xa, mvi c, 0x5, sub c" {
    var cpu: itl8080 = .init(&[_]u8{ 0x3E, 0xA, 0x0E, 0x5, 0x91 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x5, cpu.registers[REG_A]);
}

test "mvi a, 0xa, mvi c, 0x5, sbb c" {
    var cpu: itl8080 = .init(&[_]u8{ 0x3E, 0xA, 0x0E, 0x5, 0x99 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(0x5, cpu.registers[REG_A]);
}

test "rnz should return when zero flag is not set" {
    var cpu = itl8080.init(&[_]u8{0xC0});
    cpu.sp = 0xFFFE;
    cpu.memory[0xFFFE] = 0x34;
    cpu.memory[0xFFFF] = 0x12;

    cpu.flags &= ~FLAG_ZERO;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.sp);
}

test "rnz should not return when zero flag is set" {
    var cpu = itl8080.init(&[_]u8{0xC0});
    cpu.sp = 0xFFFE;
    cpu.memory[0xFFFE] = 0x34;
    cpu.memory[0xFFFF] = 0x12;

    cpu.flags |= FLAG_ZERO;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x0001), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xFFFE), cpu.sp);
}

test "rpe should return when parity is evem" {
    var cpu = itl8080.init(&[_]u8{0xE8});
    cpu.sp = 0xFFFE;
    cpu.memory[0xFFFE] = 0xBC;
    cpu.memory[0xFFFF] = 0x9A;

    cpu.flags |= FLAG_PARITY;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x9ABC), cpu.pc);
}

test "rm should return when sign flag is set" {
    var cpu = itl8080.init(&[_]u8{0xF8});
    cpu.sp = 0xFFFE;
    cpu.memory[0xFFFE] = 0x00;
    cpu.memory[0xFFFF] = 0x44;

    cpu.flags |= FLAG_SIGN;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x4400), cpu.pc);
}

test "jmp uncondtionally setting pc to imm address" {
    var cpu: itl8080 = .init(&[_]u8{ 0xC3, 0x34, 0x12 });
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
}

test "jnz jump when zero flag is clear" {
    var cpu: itl8080 = .init(&[_]u8{ 0xC2, 0x66, 0x55 });
    cpu.flags &= ~FLAG_ZERO;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x5566), cpu.pc);
}

test "jnz no jump when zero flag is set" {
    var cpu: itl8080 = .init(&[_]u8{ 0xC2, 0x66, 0x55 });
    cpu.flags |= FLAG_ZERO;
    cpu.step();

    // 0x0003 because at pc 1, we read jnz, for all jump instructions except jmp,
    // if the condition is false, then increment the pc by 2 as the size of
    // jmp instructions is 3 bytes, minus 1 byte for the opcode.
    try std.testing.expectEqual(@as(u16, 0x0003), cpu.pc);
}

test "jc jump when carry flag is set" {
    var cpu: itl8080 = .init(&[_]u8{ 0xDA, 0x00, 0x10 });
    cpu.flags |= FLAG_CARRY;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1000), cpu.pc);
}

test "jpo jump when parity is clear (odd)" {
    var cpu: itl8080 = .init(&[_]u8{ 0xE2, 0x00, 0x20 });
    cpu.flags &= ~FLAG_PARITY;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x2000), cpu.pc);
}

test "pchl set pc to value in HL pair" {
    var cpu: itl8080 = .init(&[_]u8{0xE9});
    cpu.registers[REG_H] = 0xAB;
    cpu.registers[REG_L] = 0xCD;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0xABCD), cpu.pc);
}

test "call unconditionally, push return address and jump" {
    var cpu: itl8080 = .init(&[_]u8{ 0xCD, 0x34, 0x12, 0x00 });
    cpu.sp = 0xFFFF;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc); // target addr
    try std.testing.expectEqual(@as(u16, 0xFFFD), cpu.sp); // stack pointer - 2
    try std.testing.expectEqual(@as(u8, 0x03), cpu.memory[0xFFFD]); // lbyte
    try std.testing.expectEqual(@as(u8, 0x00), cpu.memory[0xFFFE]); // hbyte
}

test "cnz call when zero flag is clear" {
    var cpu = itl8080.init(&[_]u8{ 0xC4, 0x00, 0x10 });
    cpu.sp = 0xFFFF;
    cpu.flags &= ~FLAG_ZERO;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x1000), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x0003), (@as(u16, cpu.memory[0xFFFE]) << 8) | cpu.memory[0xFFFD]);
}

test "cnz not call when zero flag is set" {
    var cpu = itl8080.init(&[_]u8{ 0xC4, 0x00, 0x10 });
    cpu.sp = 0xFFFF;
    cpu.flags |= FLAG_ZERO;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x0003), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xFFFF), cpu.sp);
}

test "cc call when carry is set" {
    var cpu = itl8080.init(&[_]u8{ 0xDC, 0x50, 0x00 });
    cpu.sp = 0x1000;
    cpu.flags |= FLAG_CARRY;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x0050), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x0FFE), cpu.sp);
}

test "cpe call when parity is even" {
    var cpu = itl8080.init(&[_]u8{ 0xEC, 0x00, 0x20 });
    cpu.sp = 0xFFFF;
    cpu.flags |= FLAG_PARITY;
    cpu.step();

    try std.testing.expectEqual(@as(u16, 0x2000), cpu.pc);
}

test "ana b logical AND accumulator with register B" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0xFC, 0x06, 0x0F, 0xA0 });
    cpu.step();
    cpu.step();
    cpu.flags |= FLAG_CARRY;
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x0C), cpu.registers[REG_A]);
    try std.testing.expectEqual(@as(u8, 0), cpu.flags & FLAG_CARRY);
    try std.testing.expect(cpu.flags & FLAG_ZERO == 0);
}

test "xra a exclusive OR accumulator with itself clear a" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0xFF, 0xAF });
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x00), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_ZERO != 0);
    try std.testing.expect(cpu.flags & FLAG_PARITY != 0);
}

test "ora c logical OR accumulator with register C" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x33, 0x0E, 0xCC, 0xB1 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0xFF), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_SIGN != 0);
}
test "cmp b compare accumulator with register B" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x05, 0x06, 0x0A, 0xB8 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x05), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
    try std.testing.expect(cpu.flags & FLAG_ZERO == 0);

    var cpu2 = itl8080.init(&[_]u8{ 0x3E, 0x10, 0x06, 0x10, 0xB8 });
    cpu2.step();
    cpu2.step();
    cpu2.step();

    try std.testing.expect(cpu2.flags & FLAG_ZERO != 0);
    try std.testing.expect(cpu2.flags & FLAG_CARRY == 0);
}

test "inr register" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x01, 0x3C }); // mvi a, 1; inr a
    cpu.step();
    cpu.step();
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x02), cpu.registers[REG_A]);
}

test "inr memory" {
    var cpu = itl8080.init(&[_]u8{ 0x21, 0x00, 0x20, 0x36, 0x05, 0x34 }); // lxi h, 0x2000; mvi m, 5; inr m
    cpu.step();
    cpu.step();
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x06), cpu.memory[0x2000]);
}

test "dcr register" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x05, 0x3D }); // mvi a, 5; dcr a
    cpu.step();
    cpu.step();
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x04), cpu.registers[REG_A]);
}

test "dcr memory" {
    var cpu = itl8080.init(&[_]u8{ 0x21, 0x00, 0x20, 0x36, 0x01, 0x35 }); // lxi h, 0x2000; mvi m, 1; dcr m
    cpu.step();
    cpu.step();
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x00), cpu.memory[0x2000]);
    try std.testing.expect(cpu.flags & FLAG_ZERO != 0);
}

test "push and pop bc pair" {
    var cpu = itl8080.init(&[_]u8{ 0x01, 0x34, 0x12, 0xC5, 0x06, 0x00, 0x0E, 0x00, 0xC1 });
    cpu.sp = 0x2000;
    cpu.step();
    cpu.step();
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x12), cpu.registers[REG_B]);
    try std.testing.expectEqual(@as(u8, 0x34), cpu.registers[REG_C]);
}

test "push and pop PSW" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0xAA, 0xF5, 0x3E, 0x00, 0xF1 });
    cpu.sp = 0x2000;
    cpu.flags = FLAG_ZERO | FLAG_CARRY;
    cpu.step();
    cpu.step();
    cpu.step();
    cpu.flags = 0;
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0xAA), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_ZERO != 0);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
}

test "rlc rotate accumulator left" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x85, 0x07 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x0B), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
}

test "rrc rotate accumulator right" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x01, 0x0F });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x80), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
}

test "ral rotate accumulator left through carry" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x80, 0x37, 0x17 });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x01), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
}

test "rar rotate accumulator right through carry" {
    var cpu = itl8080.init(&[_]u8{ 0x3E, 0x01, 0x37, 0x1F });
    cpu.step();
    cpu.step();
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x80), cpu.registers[REG_A]);
    try std.testing.expect(cpu.flags & FLAG_CARRY != 0);
}

test "in read from port" {
    var cpu = itl8080.init(&[_]u8{ 0xDB, 0x05 });
    cpu.ports[0x05] = 0xAA;
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0xAA), cpu.registers[REG_A]);
    try std.testing.expectEqual(@as(u16, 0x0002), cpu.pc);
}

test "out write to port" {
    var cpu = itl8080.init(&[_]u8{ 0xD3, 0x0A });
    cpu.registers[REG_A] = 0x55;
    cpu.step();

    try std.testing.expectEqual(@as(u8, 0x55), cpu.ports[0x0A]);
    try std.testing.expectEqual(@as(u16, 0x0002), cpu.pc);
}

test "xchg registers" {
    var cpu = itl8080.init(&[_]u8{0xEB});
    cpu.registers[REG_H] = 0xAA;
    cpu.registers[REG_L] = 0xBB;
    cpu.registers[REG_D] = 0x11;
    cpu.registers[REG_E] = 0x22;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x11), cpu.registers[REG_H]);
    try std.testing.expectEqual(@as(u8, 0x22), cpu.registers[REG_L]);
    try std.testing.expectEqual(@as(u8, 0xAA), cpu.registers[REG_D]);
    try std.testing.expectEqual(@as(u8, 0xBB), cpu.registers[REG_E]);
}

test "di / ei flags" {
    var cpu = itl8080.init(&[_]u8{ 0xF3, 0xFB });
    cpu.step();
    try std.testing.expectEqual(false, cpu.interrupts_enabled);
    cpu.step();
    try std.testing.expectEqual(true, cpu.interrupts_enabled);
}

test "sphl" {
    var cpu = itl8080.init(&[_]u8{0xF9});
    cpu.registers[REG_H] = 0xDE;
    cpu.registers[REG_L] = 0xAD;
    cpu.step();
    try std.testing.expectEqual(@as(u16, 0xDEAD), cpu.sp);
}

test "ani immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xE6, 0x0F });
    cpu.registers[REG_A] = 0xFF;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x0F), cpu.registers[REG_A]);
}

test "ori immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xF6, 0x01 });
    cpu.registers[REG_A] = 0xAA;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0xAB), cpu.registers[REG_A]);
}

test "xri immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xEE, 0xFF });
    cpu.registers[REG_A] = 0xAA;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x55), cpu.registers[REG_A]);
}

test "cpi immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xFE, 0x05 });
    cpu.registers[REG_A] = 0x05;
    cpu.step();
    try std.testing.expect(cpu.flags & FLAG_ZERO != 0);
}

test "adi immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xC6, 0x05 });
    cpu.registers[REG_A] = 0x05;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x0A), cpu.registers[REG_A]);
}

test "sui immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xD6, 0x02 });
    cpu.registers[REG_A] = 0x05;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x03), cpu.registers[REG_A]);
}

test "aci immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xCE, 0x01 });
    cpu.registers[REG_A] = 0x01;
    cpu.flags |= FLAG_CARRY;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x03), cpu.registers[REG_A]);
}

test "sbi immediate" {
    var cpu = itl8080.init(&[_]u8{ 0xDE, 0x01 });
    cpu.registers[REG_A] = 0x05;
    cpu.flags |= FLAG_CARRY;
    cpu.step();
    try std.testing.expectEqual(@as(u8, 0x03), cpu.registers[REG_A]);
}
