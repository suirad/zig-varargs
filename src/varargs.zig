const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;
const print = std.debug.print;

const VA_Errors = error{
    CountUninitialized,
    NoMoreArgs,
};

const VA_List = if (builtin.cpu.arch == .x86_64)
    VA_List_x64
else
    @compileError("Unimplemented for this architecture");

const VA_List_x64 = struct {
    first_arg: bool = true,
    count: ?usize = null,
    fpcount: usize = 0,
    gp_offset: u8 = 0,
    fp_offset: u8 = 0,
    gp_regs: [6]u64 = undefined,
    fp_regs: [8]f64 = undefined,
    overflow: [*]const u64 = undefined,

    const Self = @This();

    /// This needs to be done first thing by the function that uses it
    pub inline fn init() Self {
        // Get all gen purpose registers one at a time because initializing
        //   any var(even set as undefined) would cause register mutation.
        // You can see this by adding any var above these and seeing rdi+ changing
        const fpcount = asm volatile (""
            : [ret] "={rax}" (-> usize)
        );
        const rdi = asm volatile (""
            : [ret] "={rdi}" (-> usize)
        );
        const rsi = asm volatile (""
            : [ret] "={rsi}" (-> usize)
        );
        const rdx = asm volatile (""
            : [ret] "={rdx}" (-> usize)
        );
        const rcx = asm volatile (""
            : [ret] "={rcx}" (-> usize)
        );
        const r8 = asm volatile (""
            : [ret] "={r8}" (-> usize)
        );
        const r9 = asm volatile (""
            : [ret] "={r9}" (-> usize)
        );

        var self = Self{};
        self.fpcount = fpcount;
        self.gp_regs[0] = rdi;
        self.gp_regs[1] = rsi;
        self.gp_regs[2] = rdx;
        self.gp_regs[3] = rcx;
        self.gp_regs[4] = r8;
        self.gp_regs[5] = r9;
        // save fp registers
        self.fp_regs[0] = asm volatile (""
            : [ret] "={xmm0}" (-> f64)
        );
        self.fp_regs[1] = asm volatile (""
            : [ret] "={xmm1}" (-> f64)
        );
        self.fp_regs[2] = asm volatile (""
            : [ret] "={xmm2}" (-> f64)
        );
        self.fp_regs[3] = asm volatile (""
            : [ret] "={xmm3}" (-> f64)
        );
        self.fp_regs[4] = asm volatile (""
            : [ret] "={xmm4}" (-> f64)
        );
        self.fp_regs[5] = asm volatile (""
            : [ret] "={xmm5}" (-> f64)
        );
        self.fp_regs[6] = asm volatile (""
            : [ret] "={xmm6}" (-> f64)
        );
        self.fp_regs[7] = asm volatile (""
            : [ret] "={xmm7}" (-> f64)
        );

        // ----find stack area of overflow args
        // use ret addr as a reference point
        const ret_addr = @returnAddress();

        var stack_addr = @ptrCast([*]const u64, &ret_addr);

        stack_addr += 1;

        // iterate aligned values off of the stack until we find the return address
        while (stack_addr[0] != ret_addr) : (stack_addr += 1) {} else {
            self.overflow = stack_addr + 1;
        }

        // Debug stuff
        //print("\n", .{});
        for (self.gp_regs) |r, i| {
            //print("GReg {}: {}\n", .{ i, r });
        }
        for (self.fp_regs) |i, r| {
            //print("FReg {}: {}\n", .{ i, r });
        }
        return self;
    }

    pub fn next(self: *Self, comptime T: type) VA_Errors!T {
        // Getting the first argument is always successful per spec
        // Any further args need a proper count
        if (self.first_arg) {
            self.first_arg = false;
            const ret = self.handleType(T);
            return ret;
        } else if (self.count == null) {
            return error.CountUninitialized;
        } else if (self.count.? == 0) {
            return error.NoMoreArgs;
        }

        self.count.? -= 1;
        return self.handleType(T);
    }

    fn handleType(self: *Self, comptime T: type) T {
        const info = @typeInfo(T);

        // switch on type; need to adjust for float, int <= 64, and structs
        switch (info) {
            .Int => {
                if (@bitSizeOf(T) > @bitSizeOf(usize))
                    @compileError("Arg type is bigger than usize: " ++ @typeName(T));

                var ret: T = undefined;
                if (self.gp_offset < self.gp_regs.len) {
                    ret = self.gp_regs[self.gp_offset];
                } else {
                    ret = self.overflow[self.gp_offset - self.gp_regs.len];
                }
                self.gp_offset += 1;
                return ret;
            },
            .Optional => {
                const child = info.Optional.child;
                const opinfo = @typeInfo(child);
                switch (opinfo) {
                    .Pointer => {
                        var ret: T = null;
                        if (self.gp_offset < self.gp_regs.len) {
                            ret = @intToPtr(T, self.gp_regs[self.gp_offset]);
                        } else {
                            ret = @intToPtr(T, self.overflow[self.gp_offset - self.gp_regs.len]);
                        }
                        self.gp_offset += 1;
                        return ret;
                    },
                    else => @compileError("Unsupported optional type: " ++ @typeName(child)),
                }
            },
            .Float => @compileError("Todo"),
            .Struct => @compileError("Todo"),

            .Pointer => @compileError("Pointers need to be optional"),
            else => @compileError("Unsupported next arg type: " ++ @typeName(T)),
        }
    }
};

test "valist integer test" {
    const ret = call_int_test(
        @as(u64, 7), // count
        @as(u16, 2), // arg1
        @as(u24, 2), // arg2
        @as(u32, 2), // arg3
        @as(u8, 2), // arg4
        @as(u64, 2), // arg5
        @as(u64, 2), // arg6 -- is on the stack
        @as(u64, 2), // arg7 -- is on the stack
    );

    assert(ret == 14);
}

extern fn call_int_test(a: u64, ...) callconv(.C) usize;

comptime {
    @export(intTest, .{ .name = "call_int_test", .linkage = .Strong });
}

fn intTest() callconv(.C) usize {
    var valist = VA_List.init();
    const count = valist.next(u64) catch unreachable; // first arg is guaranteed
    if (count > 99) {
        for (valist.gp_regs) |r, i| {
            print("\n", .{});
            print("GReg {}: {}\n", .{ i, r });
        }
        @panic("Count is messed up, Registers are probably scrambled. F");
    }

    valist.count = count;

    var ret: usize = 0;

    while (valist.next(u64)) |num| {
        ret += num;
        //print("ret is: {}\n", .{ret});
    } else |e| {
        switch (e) {
            error.NoMoreArgs => {},
            error.CountUninitialized => unreachable,
        }
    }

    return ret;
}
