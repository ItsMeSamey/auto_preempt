const std = @import("std");
const ScopedLogger = @import("logging.zig").ScopedLogger;

pub fn ensureRoot() void {
  if (std.os.linux.geteuid() != 0) {
    ScopedLogger(.ensure_root_user).log(.err, "This command must be run as root", .{});
    std.posix.exit(1);
  }
}

pub const MakeOomUnkillableError = std.fs.File.OpenError || std.fs.File.WriteError;
pub fn makeOomUnkillable() MakeOomUnkillableError!void {
  var file = try std.fs.cwd().openFileZ("/proc/self/oom_score_adj", .{ .mode = .write_only });
  defer file.close();
  try file.writeAll("-1000\n");
}

/// Convert a signal number to a string
fn signalName(signal: i32) [20]u8 {
  const decls = @typeInfo(std.posix.SIG).@"struct".decls;
  inline for (decls) |decl| {
    const decl_val = @field(std.posix.SIG, decl.name);
    const decl_type_info = @typeInfo(@TypeOf(decl_val));
    if (decl_type_info != .int and decl_type_info != .comptime_int) continue;
    comptime if (std.mem.eql(u8, decl.name, "BLOCK") or std.mem.eql(u8, decl.name, "UNBLOCK") or std.mem.eql(u8, decl.name, "SETMASK")) continue;

    if (signal == decl_val) {
      const retval = "SIG" ++ decl.name ++ "\x00";
      const padding = [_]u8{undefined} ** (20 - retval.len);
      return (retval ++ padding).*;
    }
  }

  var buf: [20]u8 = undefined;
  _ = std.fmt.bufPrint(&buf, "UNKNOWN({d})\x00", .{signal}) catch unreachable;
  return buf;
}

/// Register signal handlers to catch kill signals and restore the state of all the Cpu's at exit
/// and to ignore terminal pause interrupts (Ctrl+Z)
pub fn registerSignalHandlers(allCpuContainer: type) void {
  const handle_killaction: std.posix.Sigaction = std.posix.Sigaction{
    .handler = .{
      .handler = struct {
        fn handler(signal: i32) callconv(.C) void {
          const Logger = ScopedLogger(.signal_handler);

          const signal_name = signalName(signal);
          Logger.log(.warn, "Caught {s}", .{@as([*:0]const u8, @ptrCast(&signal_name))});
          Logger.log(.warn, "Restoring state of all the Cpu's", .{});
          allCpuContainer.allCpus.restoreCpuState() catch |e| {
            Logger.log(.err, "Cpu state restore failed with error: {!}", .{e});
            std.posix.exit(1);
          };
          Logger.log(.warn, "Exiting", .{});
          std.posix.exit(0);
        }
      }.handler,
    },
    .mask = std.posix.filled_sigset, // Block all signals
    .flags = 0, // std.os.linux.SA.
  };
  const killers = [_]comptime_int{
    std.posix.SIG.HUP,
    std.posix.SIG.INT,
    std.posix.SIG.QUIT,
    std.posix.SIG.ILL,
    std.posix.SIG.TRAP,
    std.posix.SIG.ABRT,
    std.posix.SIG.IOT,
    std.posix.SIG.BUS,
    std.posix.SIG.FPE,
    std.posix.SIG.SEGV,
    std.posix.SIG.PIPE,
    std.posix.SIG.TERM,
    std.posix.SIG.XCPU,
    std.posix.SIG.STKFLT,
  };
  inline for (killers) |signal| {
    std.posix.sigaction(signal, &handle_killaction, null);
  }

  const ignore_action: std.posix.Sigaction = std.posix.Sigaction{
    .handler = .{
      .handler = std.posix.SIG.IGN,
    },
    .flags = 0,
    .mask = std.posix.empty_sigset,
  };
  const ignorables = [_]comptime_int{
    std.posix.SIG.TSTP,
  };
  inline for (ignorables) |signal| {
    std.posix.sigaction(signal, &ignore_action, null);
  }
}

