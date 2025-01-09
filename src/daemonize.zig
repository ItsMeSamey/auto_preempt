const std = @import("std");
const ScopedLogger = @import("logging.zig").ScopedLogger;

fn clearFile(file: [*:0]const u8) std.fs.File.OpenError!void {
  var file_handle = try std.fs.cwd().createFileZ(file, .{ .truncate = true });
  defer file_handle.close();
}

pub const SysV = struct {
  const DaemonizeError = error {
    SetsidFailed,
  } || std.mem.Allocator.Error || std.posix.ForkError || std.fs.File.OpenError || std.posix.ReadError || std.posix.WriteError;
  // Old style daemonize when systemd wasn't found
  pub fn daemonize() DaemonizeError!void {
    // Steps acc to: https://man7.org/linux/man-pages/man7/daemon.7.html
    // 1. Closing all file descriptors -> we dont have any open so no problem
    // 2. Reset Signal handlers -> we dont have any set yet (hopefully zig's root function didnt either)
    // 3. Reset sigprocmask -> we didnt change it (hopefully zig's root function didnt either)
    const Logger = ScopedLogger(.daemonize);

    // 4. Sanitize the environment block -> no need, we dont care about it enough to error
    clearFile("/proc/self/environ") catch |e| {
      Logger.log(.warn, "Failed to clear /proc/self/environ: {!}", .{e});
    };
    clearFile("/proc/self/cmdline") catch |e| {
      Logger.log(.warn, "Failed to clear /proc/self/cmdline: {!}", .{e});
    };

    const pipe_pair = try std.posix.pipe();

    // 5. Call fork()
    const pid_1 = std.posix.fork() catch |e| {
      Logger.log(.err, "Failed to fork: {!}", .{e});
      return e;
    };

    if (pid_1 != 0) {
      std.posix.close(pipe_pair[1]); // Close write end
      var data_buf: [32]u8 = undefined;
      const len = try std.posix.read(pipe_pair[0], &data_buf);
      Logger.log(.warn, "{s}", .{data_buf[0..len]});

      // 15. Call exit() in the original process
      std.posix.exit(0); // Parent exits
    }
    // First child
    
    std.posix.close(pipe_pair[0]); // Close the write end of the pipe
    // 6. Call setsid() to detach from the terminal
    if (std.os.linux.setsid() == -1) {
      _ = std.posix.write(pipe_pair[1], "FATAL: setsid failed") catch |write_err| @panic(@errorName(write_err));
      return DaemonizeError.SetsidFailed;
    }

    // 7. Call fork() again to detach from the parent process
    const pid_2 = std.posix.fork() catch |e| {
      _ = std.posix.write(pipe_pair[1], "FATAL: Fork failed") catch |write_err| @panic(@errorName(write_err));
      return e;
    };
    // 8. Call exit() in the first child
    if (pid_2 != 0) std.posix.exit(0); // First child exits
    // Second child

    // 9. In the daemon process, connect /dev/null to standard input, output, and error
    // But we never take input, so we close stdin instead
    const null_fd = try std.posix.open("/dev/null", std.os.linux.O{ .ACCMODE = .RDWR }, 0);
    std.posix.close(std.posix.STDIN_FILENO);
    std.posix.dup2(std.posix.STDOUT_FILENO, null_fd) catch |e| {
      _ = std.posix.write(pipe_pair[1], "FATAL: dup2 failed for stdout") catch |write_err| @panic(@errorName(write_err));
      return e;
    };
    std.posix.dup2(std.posix.STDERR_FILENO, null_fd) catch |e| {
      _ = std.posix.write(pipe_pair[1], "FATAL: dup2 failed for stderr") catch |write_err| @panic(@errorName(write_err));
      return e;
    };
    std.posix.close(null_fd);

    // 10. In the daemon process, reset the umask to 0
    _ = std.os.linux.syscall1(.umask, 0); // Ignored returned old_mask

    // 11. In the daemon process, change the current directory
    // We do this in the Operations.start already, so no need to do it here

    // TODO: write pid to file
    // 12. In the daemon process, write the daemon PID

    // NOT applicable
    // 13. In the daemon process, drop privileges

    // 14. From the daemon process, notify the original process started
    _ = std.posix.write(pipe_pair[1], "Daemon started") catch |write_err| @panic(@errorName(write_err));
    std.posix.close(pipe_pair[1]);
  }
};

// const Systemd = struct {
//   const systemd = @cImport({
//     @cInclude("systemd/sd-daemon.h");
//   });
//
//   // if notify fails, it's between user and systemd, i dint do noting wrong
//
//   pub fn notifyStart() void {
//     _ = systemd.sd_notify(0, "READY=1");
//   }
//
//   pub fn notifyStop() void {
//     _ = systemd.sd_notify(0, "STOPPING=1");
//   }
//
//   pub fn notifyStatus(comptime status: anytype) void {
//     _ = systemd.sd_notify(0, "STATUS=" ++ status);
//   }
//
//   pub fn systemdDaemonize() !void {
//     // Steps acc to: https://man7.org/linux/man-pages/man7/daemon.7.html
//
//   }
// };


