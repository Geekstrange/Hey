const std = @import("std");
const linux = std.os.linux;
const process = std.process;
const Io = std.Io;
const Dir = Io.Dir;

const SOCKET_PATH = "/var/run/hey.sock";

const SockAddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn ok(rc: usize) !usize {
    if (@as(isize, @bitCast(rc)) < 0) return error.SyscallFailed;
    return rc;
}

fn getTTYPath(io: Io, link_buf: *[256]u8) ?[]const u8 {
    const fds = [_]i32{ 0, 1, 2 };
    for (fds) |fd| {
        var path_buf: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "/proc/self/fd/{d}", .{fd}) catch continue;
        const link = Dir.readLinkAbsolute(io, p, link_buf) catch continue;
        const path = link_buf[0..link];
        if (std.mem.startsWith(u8, path, "/dev/")) return path;
    }
    return null;
}

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    // Collect args
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    {
        var iter = process.Args.Iterator.init(init.minimal.args);
        while (iter.next()) |arg| try arg_list.append(gpa, arg);
    }
    const args = arg_list.items;

    if (args.len < 2) {
        std.debug.print(
            \\hey - CLI text messenger
            \\Usage:
            \\    hey <message>              # broadcast to all online users
            \\    hey @<username> <message>  # send to a specific user
            \\Set display name via environment variable: export HEY_NAME="YourName"
            \\
        , .{});
        return;
    }

    // Determine mode
    const mode: []const u8 = if (args[1].len > 0 and args[1][0] == '@') args[1] else "*";

    // Build message
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const message = msg_blk: {
        var m: std.ArrayList(u8) = .empty;
        defer m.deinit(gpa);
        const slice: []const []const u8 = if (std.mem.eql(u8, mode, "*")) args[1..] else args_blk: {
            if (args.len < 3) {
                std.debug.print("Usage: hey @username message\n", .{});
                process.exit(1);
            }
            break :args_blk args[2..];
        };
        for (slice, 0..) |arg, i| {
            if (i > 0) try m.append(gpa, ' ');
            try m.appendSlice(gpa, arg);
        }
        break :msg_blk try m.toOwnedSlice(gpa);
    };
    defer gpa.free(message);

    // 获取 TTY 路径，复制到堆上以防止悬垂指针
    var link_buf: [256]u8 = undefined;
    const tty_raw = getTTYPath(io, &link_buf) orelse {
        std.debug.print("Error: not attached to a terminal.\n", .{});
        process.exit(1);
    };
    const tty = gpa.dupe(u8, tty_raw) catch {
        std.debug.print("Error: Out of memory\n", .{});
        process.exit(1);
    };
    defer gpa.free(tty);

    // Get sender name from environment
    const sender_user = if (environ_map.get("HEY_NAME")) |name|
        name
    else if (environ_map.get("USER")) |user|
        user
    else
        "unknown";

    // Connect to daemon
    const sock_fd: i32 = @intCast(try ok(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0)));
    defer _ = linux.close(sock_fd);

    var addr = SockAddrUn{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    @memcpy(addr.path[0..SOCKET_PATH.len], SOCKET_PATH);
    _ = ok(linux.connect(sock_fd, @ptrCast(&addr), @sizeOf(SockAddrUn))) catch |err| {
        std.debug.print("Error: cannot connect to heyd. Is it running? ({any})\n", .{err});
        process.exit(1);
    };

    // Send protocol: sender_user \n sender_tty \n mode \n message \n
    const packet = std.fmt.allocPrint(arena_alloc, "{s}\n{s}\n{s}\n{s}\n", .{
        sender_user, tty, mode, message,
    }) catch {
        std.debug.print("Error: Out of memory\n", .{});
        process.exit(1);
    };

    _ = linux.write(sock_fd, packet.ptr, packet.len);

    // Read response
    var resp_buf: [4096]u8 = undefined;
    const n = linux.read(sock_fd, &resp_buf, resp_buf.len);
    if (@as(isize, @bitCast(n)) < 0) {
        std.debug.print("Error reading response\n", .{});
        process.exit(1);
    }
    const response = std.mem.trim(u8, resp_buf[0..n], " \n\r\t");

    if (std.mem.startsWith(u8, response, "error")) {
        std.debug.print("{s}\n", .{response});
        process.exit(1);
    } else {
        std.debug.print("{s}\n", .{response});
    }
}