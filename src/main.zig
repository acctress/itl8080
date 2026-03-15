const std = @import("std");
const itl8080 = @import("itl8080").itl8080;

pub fn main() !void {
    var cpu: itl8080 = .init();
    try cpu.step();
}
