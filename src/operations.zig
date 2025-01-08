pub fn printUsageAndExit() noreturn {
  defer std.posix.exit(1);
  const stdout = std.io.getStdOut().writer();

  var name_buf: [128]u8 = undefined;
  const my_name = blk: {
    const self_name_file = std.fs.cwd().openFileZ("/proc/self/comm", .{ .mode = .read_only }) catch |e| {
      ScopedLogger(.print_usage).log(.err, "Failed to get self exe path: {!}", .{e});
      break :blk "auto_preempt";
    };
    defer self_name_file.close();
    const name_len = self_name_file.readAll(&name_buf) catch |e| {
      ScopedLogger(.print_usage).log(.err, "Failed to read self exe name: {!}", .{e});
      break :blk "auto_preempt";
    };
    break :blk name_buf[0..name_len];
  };

  nosuspend stdout.print(
    \\Usage: {s} [options] args ...
    \\
    \\Options:
    \\  help             Display this help message and exit.
    \\  version          Output version information and exit.
    \\
    \\  install          Install this program in auto mode
    \\  install [mode]   Install this program
    \\    mode:
    \\      auto         Automatically detect and install to /bin and if possible systemd mode
    \\      bin          Install to /usr/bin only
    \\      systemd      Install to /usr/bin + as systemd service as well
    \\
    \\  uninstall        Stop and Uninstall this program, also remove any autostart entries
    \\  uninstall [mode] Stop and Uninstall this program, also remove any autostart entries
    \\
    \\  start            Start this program normal mode (stay connected to terminal)
    \\                   NO need to install first
    \\  start [mode]     Start this program, program MUST be installed first
    \\    mode:
    \\      auto         Automatically detact and run in daemon / systemd mode
    \\      daemon       Start in daemon mode (not associated with systemd or any other system)
    \\      systemd      Start in systemd mode, sys
    \\
    \\  enable [mode]    Enable this program, program must be installed first
    \\    mode:
    \\      systemd      Enable autostart using systemd
    \\
    \\  stop             Stop this program / daemon running in background
    \\
    \\Source code available at <https://github.com/ItsMeSamey/auto_preempt>.
    \\Report bugs to <https://github.com/ItsMeSamey/auto_preempt/issues>.
    \\
    \\This is free software; see the source for copying conditions. There is NO
    \\warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    \\
  , .{
    my_name,
  }) catch {};
}

const std = @import("std");
const meta = @import("meta.zig");
const setup = @import("setup.zig");
const builtin = @import("builtin");
const preamble = @import("preamble.zig");
const CpuStatus = @import("cpu_status.zig");
const CpuPressure = @import("cpu_pressure.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;
const Operations = @import("operations.zig");


pub var allCpus: CpuStatus.AllCpus = undefined;


pub fn start(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) !void {
  const Logger = ScopedLogger(.start);
  preamble.ensureRoot();
  preamble.makeOomUnkillable() catch |e| {
    Logger.fatal("Failed to make process oom unkillable: {!}", .{e});
  };

  if (sub_arg != null) @panic("Unimplemented");

  allCpus = CpuStatus.AllCpus.init(allocator) catch |e| {
    Logger.fatal("Failed to initialize cpu status: {!}", .{e});
  };

  preamble.registerSignalHandlers(@This());
  defer allCpus.deinit(allocator);
  errdefer {
    allCpus.restoreCpuState() catch |e| {
      ScopedLogger(.cpu_adjust_main).log(.err, "Cpu state restoration failed with error: {!}", .{e});
      ScopedLogger(.cpu_adjust_main).log(.warn, "Exiting", .{});
      std.os.linux.exit(1);
    };
  }

  var sub = CpuPressure.Subscription.subscribe(150_000, 500_000) catch |e| {
    Logger.fatal("Failed to register to cpu pressure event alarm: {!}", .{e});
  };

  defer CpuPressure.Subscription.close(sub);
  Logger.log(.info, "Started", .{});
  while (true) {
    const ev_count = try CpuPressure.Subscription.wait(&sub, 5_000);

    if (ev_count == 0) {
      try allCpus.adjustSleepingCpus();
      continue;
    }

    Logger.log(.debug, "Cpu pressure event received", .{});
    if (sub.revents & std.posix.POLL.ERR != 0) {
      return error.PollError;
    } else if (sub.revents & std.posix.POLL.PRI == 0) {
      return error.UnknownEvent;
    }

    try allCpus.wakeOne();
  }
}

pub fn stop(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) !void {
  _ = sub_arg;
  _ = allocator;
  @panic("Unimplemented");
}

pub fn enable(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) !void {
  _ = sub_arg;
  _ = allocator;
  @panic("Unimplemented");
}

pub fn disable(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) !void {
  _ = sub_arg;
  _ = allocator;
  @panic("Unimplemented");
}

pub fn install(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) !void {
  // TODO: restart service on install
  _ = allocator; // unused

  preamble.ensureRoot();
  const Logger = ScopedLogger(.install);

  const Installers = struct {
    pub fn systemd() void {
      Logger.log(.info, "Installing systemd service", .{});
      setup.Systemd.install() catch |e| {
        Logger.fatal("Failed to install systemd service: {!}", .{e});
      };
      Logger.log(.info, "Successfully installed systemd service", .{});
    }

    pub fn bin() setup.InstallBinResult {
      return setup.installBin() catch |e| {
        Logger.fatal("Failed to install binary: {!}", .{e});
      };
    }

    pub fn auto() void {
      _ = bin();
      if (setup.isInitSystem("systemd") catch |e| Logger.fatal("Error detecting init system: {!}", .{e})) {
        systemd();
      }
    }
  };

  if (sub_arg == null) {
    return Installers.auto();
  }

  switch (sub_arg.?.len) {
    3 => switch (meta.arrAsUint(sub_arg.?[0..3])) {
      meta.arrAsUint("bin") => {
        _ = Installers.bin();
      },
      else => {},
    },
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Installers.auto(),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Installers.systemd(),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  Operations.printUsageAndExit();
}

