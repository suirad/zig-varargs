const builtin = @import("builtin");
const std = @import("std");

const print = std.debug.print;

const VA_Errors = error{
    CountUninitialized,
    NoMoreArgs,
};

pub const VAFunc = *const opaque {};

pub const VAList = struct {
    first_arg: bool = true,
    count: ?usize = null,
    gp_offset: u8 = 0,
    fp_offset: u8 = 0,
    gp_regs: [6]u64 = undefined,
    fp_regs: [8]f64 = undefined,
    overflow: [*]const u64 = undefined,

    const Self = @This();

    /// This needs to be done first thing by the function that uses it
    pub inline fn init() Self {
        if (builtin.link_libc and builtin.mode == .Debug)
            @compileError("Cannot use this build mode for var args");
        // Get all gen purpose registers one at a time because initializing
        //   any var(even set as undefined) would cause register mutation.
        // You can see this by adding any var above these and seeing rdi+ changing
        const fp_count: usize = asm volatile (""
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

        var self = VAList{};
        self.gp_regs[0] = rdi;
        self.gp_regs[1] = rsi;
        self.gp_regs[2] = rdx;
        self.gp_regs[3] = rcx;
        self.gp_regs[4] = r8;
        self.gp_regs[5] = r9;
        // save fp registers if fp_count != 0
        if (fp_count != 0) {
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
        }

        // ----find stack area of overflow args
        // use ret addr as an aligned reference point
        var ret_addr: usize = rdi;
        ret_addr = @returnAddress();

        var stack_addr = @ptrCast([*]const u64, &ret_addr);
        stack_addr += 1;

        // iterate aligned values off of the stack until we find the return address
        while (stack_addr[0] != ret_addr) {
            stack_addr += 1;
        } else {
            self.overflow = stack_addr + 1;
        }

        // Debug stuff
        //print("\n", .{});
        //print("fpcount: {}\n", .{fpcount});
        //for (self.gp_regs) |r, i| {
        //print("GReg {}: {}\n", .{ i, r });
        //}
        //for (self.fp_regs) |r, i| {
        //print("FReg {}: {}\n", .{ i, r });
        //}
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
            .Float => {
                var ret: f64 = undefined;
                if (self.fp_offset < self.fp_regs.len) {
                    ret = self.fp_regs[self.fp_offset];
                } else {
                    @panic("TODO: stack floats");
                }
                self.fp_offset += 1;
                return @floatCast(T, ret);
            },
            .Struct => @compileError("Todo"),

            .Pointer => @compileError("Pointers need to be optional"),
            else => @compileError("Unsupported next arg type: " ++ @typeName(T)),
        }
    }
};

// TODO: try anytype for func argument
// might be able to do comptime checks on comptime known fns
// AND still be able to take runtime fn pointers

pub inline fn callVarArgs(comptime T: type, func: VAFunc, args: anytype) T {
    // comptime: validate args
    comptime {
        if (@bitSizeOf(T) > @bitSizeOf(usize)) {
            @compileError("Return type is larger than usize: " ++ @typeName(T));
        }
        const args_info = @typeInfo(@TypeOf(args));
        if (args_info != .Struct or args_info.Struct.is_tuple == false) {
            @compileError("Expected args to be a tuple");
        }
        if (args.len == 0) {
            @compileError("Tuple needs to have at least one arg");
        }
    }

    // comptime: accounting
    // count number of fp and gp args so we can push them on the stack
    //      if needed and in reverse order
    // also do type checking
    comptime var gp_args = 0;
    comptime var fp_args = 0;

    comptime {
        var index = args.len;
        while (index > 0) : (index -= 1) {
            const arg_type = @TypeOf(args[index - 1]);
            const arg_info = @typeInfo(arg_type);
            switch (arg_info) {
                .Int, .ComptimeInt, .Optional, .Pointer => {
                    if (@bitSizeOf(arg_type) > @bitSizeOf(usize)) {
                        @compileError("Arg type is larger than usize: " ++ @typeName(arg_type));
                    } else if (arg_info == .Optional) {
                        const child = arg_info.Optional.child;
                        const child_info = @typeInfo(child);
                        if (child_info != .Pointer) {
                            @compileError("Optional args should only be pointers");
                        }
                    }

                    gp_args += 1;
                },

                .Float => fp_args += 1,

                else => @compileError("Unsupported arg type: " ++ @typeName(arg_type)),
            }
        }
    }

    const fp_total: usize = fp_args;
    comptime var stack_growth: usize = 0;
    comptime var index = args.len;

    // reverse loop of args so you can push later args onto the stack in order
    inline while (index > 0) : (index -= 1) {
        const varg = args[index - 1];
        const arg_info = @typeInfo(@TypeOf(varg));
        switch (arg_info) {
            .Int, .ComptimeInt, .Optional, .Pointer => {
                const arg: usize = if (arg_info == .Optional or arg_info == .Pointer)
                    @as(usize, @ptrToInt(varg))
                else
                    @as(usize, varg);

                pushInt(gp_args, arg);
                if (gp_args > 6)
                    stack_growth += @sizeOf(usize);
                gp_args -= 1;
            },

            .Float => {
                const arg = @floatCast(f64, varg);
                pushFloat(fp_args, arg);
                fp_args -= 1;
            },

            else => @compileError("Unsupported arg type: " ++ @typeName(arg)),
        }
    }

    // call fn
    asm volatile ("call *(%%r10)"
        :
        : [func] "{r10}" (func),
          [fp_total] "{rax}" (fp_total)
    );

    // realign stack
    if (stack_growth > 0) {
        asm volatile ("add %%r10, %%rsp"
            :
            : [stack_growth] "{r10}" (stack_growth)
        );
    }

    // handle return type
    if (T == void) {
        return;
    }

    const ret = asm volatile (""
        : [ret] "={rax}" (-> T)
    );

    return ret;
}

inline fn pushInt(comptime index: usize, arg: usize) void {
    switch (index) {
        1 => asm volatile (""
            :
            : [arg] "{rdi}" (arg)
        ),
        2 => asm volatile (""
            :
            : [arg] "{rsi}" (arg)
        ),
        3 => asm volatile (""
            :
            : [arg] "{rdx}" (arg)
        ),
        4 => asm volatile (""
            :
            : [arg] "{rcx}" (arg)
        ),
        5 => asm volatile (""
            :
            : [arg] "{r8}" (arg)
        ),
        6 => asm volatile (""
            :
            : [arg] "{r9}" (arg)
        ),
        else => {
            asm volatile ("push %%r10"
                :
                : [arg] "{r10}" (arg)
            );
        },
    }
}

inline fn pushFloat(comptime index: usize, arg: f64) void {
    switch (index) {
        1 => asm volatile (""
            :
            : [arg] "{xmm0}" (arg)
        ),
        2 => asm volatile (""
            :
            : [arg] "{xmm1}" (arg)
        ),
        3 => asm volatile (""
            :
            : [arg] "{xmm2}" (arg)
        ),
        4 => asm volatile (""
            :
            : [arg] "{xmm3}" (arg)
        ),
        5 => asm volatile (""
            :
            : [arg] "{xmm4}" (arg)
        ),
        6 => asm volatile (""
            :
            : [arg] "{xmm5}" (arg)
        ),
        7 => asm volatile (""
            :
            : [arg] "{xmm6}" (arg)
        ),
        8 => asm volatile (""
            :
            : [arg] "{xmm7}" (arg)
        ),
        else => @panic("TODO: stack floats"),
    }
}
