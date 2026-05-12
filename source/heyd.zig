const std = @import("std");
const linux = std.os.linux;
const process = std.process;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const SOCKET_PATH = "/var/run/hey.sock";
const TIOCGWINSZ: u32 = 0x5413;

const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

const SockAddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

const Registry = std.StringHashMap([]const u8);

/// Convert a syscall return value (usize) into an error or the value.
fn ok(rc: usize) !usize {
    if (@as(isize, @bitCast(rc)) < 0) return error.SyscallFailed;
    return rc;
}

/// Retrieve the terminal width for a given TTY path, defaults to 80.
fn getTerminalWidth(io: Io, tty_path: []const u8) usize {
    const file = Dir.openFileAbsolute(io, tty_path, .{ .mode = .read_only }) catch return 80;
    defer File.close(file, io);
    var ws: Winsize = undefined;
    const rc = linux.ioctl(file.handle, TIOCGWINSZ, @intFromPtr(&ws));
    if (@as(isize, @bitCast(rc)) >= 0 and ws.col > 0) return ws.col;
    return 80;
}

/// Word-wrap text at a given width, appending lines to the provided list.
fn wrapText(text: []const u8, width: usize, gpa: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |para| {
        if (para.len == 0) {
            lines.append(gpa, "") catch return;
            continue;
        }
        var remaining = para;
        while (remaining.len > width) {
            var cut: usize = width;
            if (std.mem.lastIndexOfScalar(u8, remaining[0..width], ' ')) |space| {
                cut = space + 1;
            }
            lines.append(gpa, std.mem.trim(u8, remaining[0..cut], " ")) catch return;
            remaining = std.mem.trim(u8, remaining[cut..], " ");
        }
        if (remaining.len > 0 or (lines.items.len > 0 and lines.getLast().?.len == 0)) {
            lines.append(gpa, remaining) catch return;
        }
    }
}

/// Try to find the HEY_NAME environment variable of the process that owns
/// the given TTY by scanning /proc. Returns "unknown" on failure.
fn getDisplayNameFallback(io: Io, tty_path: []const u8, alloc: std.mem.Allocator) []const u8 {
    const proc_dir = Dir.openDirAbsolute(io, "/proc", .{}) catch return "unknown";
    defer Dir.close(proc_dir, io);

    var pid_buf: [64]u8 = undefined;
    var link_buf: [256]u8 = undefined;
    var env_buf: [4096]u8 = undefined;

    var iter = Dir.iterate(proc_dir);
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (name.len == 0 or !std.ascii.isDigit(name[0])) continue;
        var all_digits = true;
        for (name) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;

        const link_path = std.fmt.bufPrint(&pid_buf, "{s}/fd/0", .{name}) catch continue;
        const link = Dir.readLink(proc_dir, io, link_path, &link_buf) catch continue;
        if (!std.mem.eql(u8, link_buf[0..link], tty_path)) continue;

        const env_path = std.fmt.bufPrint(&pid_buf, "{s}/environ", .{name}) catch continue;
        const env = Dir.readFile(proc_dir, io, env_path, &env_buf) catch continue;
        var env_iter = std.mem.splitScalar(u8, env, @as(u8, 0));
        while (env_iter.next()) |env_var| {
            if (std.mem.startsWith(u8, env_var, "HEY_NAME=")) {
                const val = env_var["HEY_NAME=".len..];
                return alloc.dupe(u8, val) catch "unknown";
            }
        }
        break;
    }
    return "unknown";
}

/// Resolve a display name for a TTY, using the registry cache first.
fn resolveDisplayName(io: Io, registry: *Registry, tty_path: []const u8) []const u8 {
    if (registry.get(tty_path)) |name| return name;
    const name = getDisplayNameFallback(io, tty_path, registry.allocator);
    if (!std.mem.eql(u8, name, "unknown")) {
        registry.put(
            registry.allocator.dupe(u8, tty_path) catch return name,
            registry.allocator.dupe(u8, name) catch return name,
        ) catch {};
    }
    return name;
}

/// Return a list of currently online TTY device paths by parsing `who`.
fn getOnlineTTYs(io: Io, alloc: std.mem.Allocator, gpa: std.mem.Allocator) std.ArrayList([]const u8) {
    var ttys: std.ArrayList([]const u8) = .empty;

    const result = process.run(gpa, io, .{ .argv = &[_][]const u8{"who"} }) catch return ttys;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return ttys;

    var line_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const tty_name = fields.next() orelse continue;
        const path = std.fmt.allocPrint(alloc, "/dev/{s}", .{tty_name}) catch continue;
        ttys.append(alloc, path) catch {};
    }
    return ttys;
}

/// Write a formatted message to a TTY, preserving cursor position.
fn sendToTTY(gpa: std.mem.Allocator, io: Io, tty_path: []const u8, message: []const u8) void {
    const width = getTerminalWidth(io, tty_path);
    var lines: std.ArrayList([]const u8) = .empty;
    wrapText(message, width, gpa, &lines);
    defer lines.deinit(gpa);

    const file = Dir.openFileAbsolute(io, tty_path, .{ .mode = .write_only }) catch {
        std.log.err("Failed to open TTY: {s}", .{tty_path});
        return;
    };
    defer File.close(file, io);

    File.writeStreamingAll(file, io, "\x1b7") catch return;
    if (lines.items.len > 0) {
        var buf: [32]u8 = undefined;
        const esc = std.fmt.bufPrint(&buf, "\x1b[{d}L", .{lines.items.len}) catch unreachable;
        File.writeStreamingAll(file, io, esc) catch return;
    }
    File.writeStreamingAll(file, io, "\x1b[32m") catch return;
    for (lines.items, 0..) |line, i| {
        if (i > 0) File.writeStreamingAll(file, io, "\n") catch return;
        File.writeStreamingAll(file, io, line) catch return;
    }
    File.writeStreamingAll(file, io, "\n\x1b[0m") catch return;
    File.writeStreamingAll(file, io, "\x1b8") catch return;
    if (lines.items.len > 0) {
        var buf: [32]u8 = undefined;
        const esc = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{lines.items.len}) catch unreachable;
        File.writeStreamingAll(file, io, esc) catch return;
    }
}

/// Handle a single client connection: parse protocol, update registry, deliver message.
fn handleClient(gpa: std.mem.Allocator, io: Io, registry: *Registry, fd: i32) void {
    defer _ = linux.close(fd);

    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (@as(isize, @bitCast(n)) < 0 or n == 0) return;
    const data = buf[0..n];

    // Protocol: sender_user \n sender_tty \n mode \n message
    var newline_count: u3 = 0;
    var parts: [4][]const u8 = undefined;
    var start: usize = 0;
    for (data, 0..) |byte, i| {
        if (byte == '\n') {
            parts[newline_count] = data[start..i];
            newline_count += 1;
            start = i + 1;
            if (newline_count == 3) break;
        }
    }
    if (newline_count < 3) {
        _ = linux.write(fd, "error: Invalid protocol\n", 24);
        return;
    }
    parts[3] = data[start..];

    const sender_user = std.mem.trim(u8, parts[0], " \n\r\t");
    const sender_tty = std.mem.trim(u8, parts[1], " \n\r\t");
    const mode = std.mem.trim(u8, parts[2], " \n\r\t");
    const message = std.mem.trim(u8, parts[3], " \n\r\t");

    // --- Registry update logic ---
    // Safely update the sender's TTY -> name mapping.
    // 1. Try to allocate new key and value strings on the heap.
    // 2. If successful, either update an existing entry (freeing the old value)
    //    or insert a new one. If insertion/update fails, free the allocated
    //    copies and log the error without losing any existing registry data.
    const new_key = registry.allocator.dupe(u8, sender_tty) catch null;
    const new_val = if (new_key != null) registry.allocator.dupe(u8, sender_user) catch blk: {
        // Free the key if value allocation failed.
        registry.allocator.free(new_key.?);
        break :blk null;
    } else null;

    if (new_key) |k| {
        if (new_val) |v| {
            // Check if this TTY is already registered.
            if (registry.getPtr(k)) |ptr| {
                // Update the value in place, freeing the old one.
                const old = ptr.*;
                ptr.* = v;
                registry.allocator.free(old);
                // The key we allocated is a duplicate of an existing key, free it.
                registry.allocator.free(k);
            } else {
                // Key is new, insert it.
                registry.put(k, v) catch {
                    registry.allocator.free(k);
                    registry.allocator.free(v);
                    std.log.err("Failed to insert into registry", .{});
                };
            }
        }
    } else {
        std.log.err("Memory allocation failed during registry update", .{});
    }
    // --- End of registry update ---

    // Format timestamp [HH:MM]
    var ts_buf: [16]u8 = undefined;
    var tspec: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.REALTIME, &tspec);
    const now_secs: u64 = @intCast(@max(@as(isize, 0), tspec.sec));
    const epoch = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const day_secs = epoch.getDaySeconds();
    const hour = day_secs.getHoursIntoDay();
    const min = day_secs.getMinutesIntoHour();
    const timestamp = std.fmt.bufPrint(&ts_buf, "[{d:0>2}:{d:0>2}]", .{ hour, min }) catch "[00:00]";

    // Build full message using an arena (temporary allocations)
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const full_msg = std.fmt.allocPrint(arena_alloc, "{s} {s}: {s}", .{ timestamp, sender_user, message }) catch {
        _ = linux.write(fd, "error: Out of memory\n", 20);
        return;
    };

    // Determine target TTYs based on mode
    var targets: std.ArrayList([]const u8) = .empty;

    if (std.mem.eql(u8, mode, "*")) {
        // Broadcast: all online TTYs except the sender.
        const online = getOnlineTTYs(io, arena_alloc, gpa);
        for (online.items) |tty| {
            if (!std.mem.eql(u8, tty, sender_tty)) {
                targets.append(arena_alloc, tty) catch {};
            }
        }
    } else if (mode.len > 0 and mode[0] == '@') {
        // Direct message: find all TTYs registered with the given name.
        const target_name = mode[1..];
        var iter = registry.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.value_ptr.*, target_name)) {
                targets.append(arena_alloc, entry.key_ptr.*) catch {};
            }
        }
        if (targets.items.len == 0) {
            const err_msg = std.fmt.allocPrint(arena_alloc,
                "error: User '{s}' not found. Make sure the user is online and has sent at least one 'hey' message (even a broadcast) to register.\n",
                .{target_name},
            ) catch {
                _ = linux.write(fd, "error: User not found\n", 21);
                return;
            };
            _ = linux.write(fd, err_msg.ptr, err_msg.len);
            return;
        }
    } else {
        var mode_buf: [64]u8 = undefined;
        const mode_err = std.fmt.bufPrint(&mode_buf, "error: Unknown mode '{s}'\n", .{mode}) catch {
            _ = linux.write(fd, "error: Unknown mode\n", 19);
            return;
        };
        _ = linux.write(fd, mode_err.ptr, mode_err.len);
        return;
    }

    // Deliver to all targets
    var count: usize = 0;
    for (targets.items) |tty_path| {
        sendToTTY(gpa, io, tty_path, full_msg);
        count += 1;
    }

    // Send response back to client
    var resp_buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "Sent to {d} terminal(s)\n", .{count}) catch {
        _ = linux.write(fd, "ok\n", 3);
        return;
    };
    _ = linux.write(fd, resp.ptr, resp.len);
}

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Remove any leftover socket file
    _ = linux.unlink(SOCKET_PATH);

    // Create UNIX socket
    const sock_fd: i32 = @intCast(try ok(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0)));
    errdefer _ = linux.close(sock_fd);

    var addr = SockAddrUn{ .family = linux.AF.UNIX, .path = std.mem.zeroes([108]u8) };
    @memcpy(addr.path[0..SOCKET_PATH.len], SOCKET_PATH);
    _ = try ok(linux.bind(sock_fd, @ptrCast(&addr), @sizeOf(SockAddrUn)));

    // Make socket writable by everyone
    _ = linux.chmod(SOCKET_PATH, 0o666);

    _ = try ok(linux.listen(sock_fd, 5));
    std.log.info("heyd started", .{});

    var registry = Registry.init(gpa);

    // Accept loop
    while (true) {
        const client_fd: i32 = @intCast(ok(linux.accept(sock_fd, null, null)) catch continue);
        handleClient(gpa, io, &registry, client_fd);
    }
}