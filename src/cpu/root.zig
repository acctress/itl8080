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

const FLAG_ZERO = 0x1 << 0x6;
const FLAG_CARRY = 0x1 << 0x0;
const FLAG_SIGN = 0x1 << 0x7;
const FLAG_PARITY = 0x1 << 0x2;
const FLAG_AUXILIARY = 0x1 << 0x4;

pub const itl8080 = struct {
    memory: [MEMORY_SIZE]u8,
    registers: [REGISTER_COUNT]u8,
    flags: u8,
    pc: u16,
    sp: u16,

    pub fn init(data: []const u8) itl8080 {
        var memory: [MEMORY_SIZE]u8 = std.mem.zeroes([MEMORY_SIZE]u8);
        @memcpy(memory[0x0..data.len], data);

        return .{
            .memory = memory,
            .registers = std.mem.zeroes([REGISTER_COUNT]u8),
            .flags = 0,
            .pc = 0,
            .sp = 0,
        };
    }

    pub fn step(self: *itl8080) !void {
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
        const inst = opcode & 0x7;

        switch (inst) {
            // MVI
            0x6 => {
                const destination = (opcode >> 3) & 0x7;
                const imm = self.memory[self.pc];
                self.registers[destination] = imm;
                self.pc += 1;
            },

            // LXI
            0x1 => {
                const low_byte = self.memory[self.pc];
                const high_byte = self.memory[self.pc + 1];
                const value = @as(u16, high_byte) << 8 | low_byte;
                const reg_pair = (opcode >> 4) & 0x3;

                switch (reg_pair) {
                    // B
                    0b00 => {
                        self.registers[REG_B] = high_byte;
                        self.registers[REG_C] = low_byte;
                    },
                    // D
                    0b01 => {
                        self.registers[REG_D] = high_byte;
                        self.registers[REG_E] = low_byte;
                    },
                    // H
                    0b10 => {
                        self.registers[REG_H] = high_byte;
                        self.registers[REG_L] = low_byte;
                    },
                    // SP
                    0b11 => {
                        self.sp = value;
                    },

                    else => {},
                }

                self.pc += 2;
            },

            else => {},
        }
    }

    fn transfer(self: *itl8080, opcode: u8) void {
        if (opcode == 0x76) return; // HLT, handle properly

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

    fn arithmetic(self: *itl8080, opcode: u8) void {
        _ = self;
        _ = opcode;
    }

    fn branch(self: *itl8080, opcode: u8) void {
        _ = self;
        _ = opcode;
    }
};

test "mvi b, 0xa" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA });
    try cpu.step();
    try cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_B]);
}

test "mvi b, 0xa mov c, b" {
    var cpu: itl8080 = .init(&[_]u8{ 0x06, 0xA, 0x48 });
    try cpu.step();
    try cpu.step();

    try std.testing.expectEqual(0xA, cpu.registers[REG_B]);
    try std.testing.expectEqual(0xA, cpu.registers[REG_C]);
}

test "lxi b, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x01, 0x34, 0x12 });
    try cpu.step();

    try std.testing.expectEqual(0x12, cpu.registers[REG_B]);
    try std.testing.expectEqual(0x34, cpu.registers[REG_C]);
}

test "lxi sp, d16" {
    var cpu: itl8080 = .init(&[_]u8{ 0x31, 0x34, 0x12 });
    try cpu.step();

    try std.testing.expectEqual(0x1234, cpu.sp);
}
