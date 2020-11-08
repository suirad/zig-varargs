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
pub const VAFunc = arch.VAFunc;

test "valist integers" {
    const testfn = @ptrCast(VAFunc, &intTest);
    var ret = callVarArgs(usize, testfn, .{
        @as(u64, 7), // count
        @as(u24, 2), // arg1
        @as(u16, 2), // arg2
        @as(u8, 2), // arg3
        @as(u64, 2), // arg4
        @as(u64, 2), // arg5
        @as(u64, 2), // arg6 -- is on the stack
        @as(u64, 2), // arg7 -- is on the stack
    });

    assert(ret == 14);
}

export fn intTest() callconv(.C) usize {
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
    const testfn = @ptrCast(VAFunc, &floatTest);
    const ret = callVarArgs(usize, testfn, .{
        @as(u64, 8), // count
        @as(f64, 2), // arg1
        @as(f32, 2), // arg2
        @as(f64, 2), // arg3
        @as(f32, 2), // arg4
        @as(f64, 2), // arg5
        @as(f32, 2), // arg6
        @as(f64, 2), // arg7
        @as(f64, 2), // arg8
    });

    assert(ret == 16);
}

fn floatTest() callconv(.C) usize {
    var valist = VAList.init();
    const count = valist.next(u64) catch unreachable; // first arg is guaranteed

    valist.count = count;

    var ret: f64 = 0;

    while (valist.next(f32)) |num| {
        ret += num;
    } else |e| {
        switch (e) {
            error.NoMoreArgs => {},
            error.CountUninitialized => unreachable,
        }
    }

    return @floatToInt(usize, ret);
}

test "valist pointers" {
    if (true)
        return;
    const testfn = @ptrCast(VAFunc, &optionalPointerTest);
    var val: u64 = 2;
    var ret = callVarArgs(usize, testfn, .{
        @as(u64, 2), // count
        &val,
        &val,
        &val,
        &val,
        &val,
        &val,
        &val,
        &val,
    });

    assert(ret == 16);
}

fn optionalPointerTest() callconv(.C) usize {
    var valist = VAList.init();
    const count = valist.next(u64) catch unreachable; // first arg is guaranteed

    valist.count = count;

    var ret: usize = 0;
    while (valist.next(?*u64)) |num| {
        ret += num.?.*;
    } else |e| {
        switch (e) {
            error.NoMoreArgs => {},
            error.CountUninitialized => unreachable,
        }
    }

    return ret;
}

const libc = @cImport(@cInclude("stdio.h"));
test "call libc snprintf" {
    if (!builtin.link_libc)
        return;

    const snprintf = @ptrCast(VAFunc, &libc.snprintf);

    const in = "Test: %d";
    var out = [_:0]u8{0} ** (in.len);

    _ = callVarArgs(c_int, snprintf, .{ &out, out.len + 1, in, 69 });

    const expected = "Test: 69";
    assert(std.mem.eql(u8, out[0..], expected));
    print("out: {} | len: {}\nexp: {} | len: {}", .{ out, out.len, expected, expected.len });
}
