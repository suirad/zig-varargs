const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;
const print = std.debug.print;

const arch = if (builtin.cpu.arch == .x86_64)
    @import("x86_64.zig")
else
    @compileError("Unimplemented for this architecture");

pub const VA_Errors = arch.VA_Errors;
pub const VAList = arch.VAList;
pub const callVarArgs = arch.callVarArgs;

test "valist integers" {
    const testfn = @ptrCast(*const fn () callconv(.C) void, &intTest);
    const ret = callVarArgs(usize, testfn, .{
        @as(u64, 7), // count
        @as(u16, 2), // arg1
        @as(u24, 2), // arg2
        @as(u32, 2), // arg3
        @as(u8, 2), // arg4
        @as(u64, 2), // arg5
        @as(u64, 2), // arg6 -- is on the stack
        @as(u64, 2), // arg7 -- is on the stack
    });

    //print("ret is: {}\n", .{ret});
    assert(ret == 14);
}

fn intTest() callconv(.C) usize {
    var valist = VAList.init();
    const count = valist.next(u64) catch unreachable; // first arg is guaranteed

    valist.count = count;

    var ret: usize = 0;

    while (valist.next(u64)) |num| {
        ret += num;
    } else |e| {
        switch (e) {
            error.NoMoreArgs => {},
            error.CountUninitialized => unreachable,
        }
    }

    return ret;
}

test "valist floats" {
    const testfn = @ptrCast(*const fn () callconv(.C) void, &floatTest);
    const ret = callVarArgs(usize, testfn, .{
        @as(u64, 8), // count
        @as(f32, 2), // arg1
        @as(f64, 2), // arg2
        @as(f32, 2), // arg3
        @as(f64, 2), // arg4
        @as(f32, 2), // arg5
        @as(f64, 2), // arg6
        @as(f32, 2), // arg7
        @as(f64, 2), // arg8
    });

    //print("ret is: {}\n", .{ret});
    assert(ret == 16);
}

fn floatTest() callconv(.C) usize {
    var valist = VAList.init();
    const count = valist.next(u64) catch unreachable; // first arg is guaranteed

    valist.count = count;

    var ret: f64 = 0;

    while (valist.next(f64)) |num| {
        ret += num;
    } else |e| {
        switch (e) {
            error.NoMoreArgs => {},
            error.CountUninitialized => unreachable,
        }
    }

    return @floatToInt(usize, ret);
}
