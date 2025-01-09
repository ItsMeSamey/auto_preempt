fn myName(name_buf: anytype) []const u8 {
  const self_name_file = std.fs.cwd().openFileZ("/proc/self/comm", .{ .mode = .read_only }) catch |e| {
    ScopedLogger(.print_usage).log(.err, "Failed to get self exe path: {!}", .{e});
    return "auto_preempt";
  };
  defer self_name_file.close();
  var name_len = self_name_file.readAll(name_buf) catch |e| {
    ScopedLogger(.print_usage).log(.err, "Failed to read self exe name: {!}", .{e});
    return "auto_preempt";
  };
  if (name_buf[name_len - 1] == '\n') name_len -= 1;
  return name_buf[0..name_len];
}

pub fn printUsageAndExit() noreturn {
  defer std.posix.exit(1);
  const stdout = std.io.getStdOut().writer();

  var name_buf: [64]u8 = undefined;
  const my_name = myName(&name_buf);

  nosuspend stdout.print(
    \\Usage: {s} [options] args ...
    \\
    \\Options:
    \\  help             Display this help message and exit.
    \\  version          Output version information and exit.
    \\
    \\  start            Start this program normal mode (stay connected to terminal)
    \\                   NO need to install first
    \\  start [mode]     Start this program, program MUST be installed first
    \\    mode:
    \\      auto         Automatically detact and run in daemon / systemd mode
    \\      daemon       Start in daemon mode (not associated with systemd or any other system)
    \\      systemd      Start in systemd mode, sys
    \\  stop             Stop this program / daemon running in background
    \\  install          Install this program in auto mode
    \\  install [mode]   Install this program
    \\    mode:
    \\      auto         Automatically detect and install to /bin and if possible systemd service
    \\      bin          Install to /usr/bin
    \\      systemd      Install to /usr/bin + as systemd service as well
    \\  uninstall        Stop and Uninstall this program, also remove any autostart entries
    \\  uninstall [mode] Stop and Uninstall this program, also remove any autostart entries
    \\    mode:
    \\      auto         Automatically remove from /bin and if possible systemd service
    \\      bin          Remove from /usr/bin
    \\      systemd      Remove systemd service
    \\  enable [mode]    Enable this program, program must be installed first
    \\    mode:
    \\      systemd      Enable autostart using systemd
    \\  disable [mode]   Disable this program, no-op if not installed / enabled
    \\    mode:
    \\      systemd      Disable autostart using systemd
    \\  status           Show status of running services
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
const daemonize = @import("daemonize.zig");
const CpuStatus = @import("cpu_status.zig");
const CpuPressure = @import("cpu_pressure.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;

pub var allCpus: CpuStatus.AllCpus = undefined;

const NoError = error{};

pub fn start(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  // TODO: enable ipc checking
  const StartLogger = ScopedLogger(.start);
  preamble.ensureRoot();

  const Op = struct {
    pub fn systemd() void {
      setup.Systemd.start() catch |e| {
        StartLogger.fatal("Failed to start systemd service: {!}", .{e});
      };
    }

    pub fn auto() void {
      var name_buf: [64]u8 = undefined;
      const my_name = myName(&name_buf);
      StartLogger.log(.info, "If you wanted to start connected to terminal, start with `{s} start normal`", .{ my_name });
      if (
        setup.isInitSystem("systemd") catch |e| StartLogger.fatal("Error detecting init system: {!}", .{e}) and
        setup.Systemd.check() catch |e| StartLogger.fatal("Error detecting if systemd service is present: {!}", .{e})
      ) {
        systemd();
      } else {
        StartLogger.log(.warn, "No service installed, stating in legacy (daemon) mode instead", .{});
        daemon();
      }
    }

    pub fn daemon() void {
      daemonize.SysV.daemonize() catch |e| {
        StartLogger.fatal("Failed to start daemon: {!}", .{e});
      };
    }
  };

  if (sub_arg == null) {
    Op.auto();
  }

  switch (sub_arg.?.len) {
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Op.auto(),
      else => {},
    },
    6 => switch (meta.arrAsUint(sub_arg.?[0..6])) {
      meta.arrAsUint("daemon") => Op.daemon(),
      meta.arrAsUint("normal") => {
        StartLogger.log(.info, "Starting connected to terminal", .{});
      },
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Op.systemd(),
      else => {},
    },
    else => {},
  }

  preamble.makeOomUnkillable() catch |e| {
    StartLogger.fatal("Failed to make process oom unkillable: {!}", .{e});
  };

  allCpus = CpuStatus.AllCpus.init(allocator) catch |e| {
    StartLogger.fatal("Failed to initialize cpu status: {!}", .{e});
  };
  preamble.registerSignalHandlers(@This());
  defer allCpus.deinit(allocator);

  const Logger = struct {
    pub const log = StartLogger.log;
    pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
      allCpus.restoreCpuState() catch |e| {
        ScopedLogger(.cpu_adjust_main).log(.err, "Cpu state restoration failed with error: {!}", .{e});
        ScopedLogger(.cpu_adjust_main).log(.warn, "Exiting", .{});
        std.os.linux.exit(1);
      };
      StartLogger.fatal(format, args);
    }
  };
  errdefer Logger.fatal("Exiting!!", .{});

  var sub = CpuPressure.Subscription.subscribe(150_000, 500_000) catch |e| {
    Logger.fatal("Failed to register to cpu pressure event alarm: {!}", .{e});
  };

  defer CpuPressure.Subscription.close(sub);
  Logger.log(.info, "Started", .{});
  while (true) {
    const ev_count = CpuPressure.Subscription.wait(&sub, 5_000) catch |e| {
      Logger.fatal("Error occurred wait for cpu pressure event: {!}", .{e});
    };

    if (ev_count == 0) {
      allCpus.adjustSleepingCpus() catch |e| {
        Logger.fatal("Error occurred adjusting sleeping cpus: {!}", .{e});
      };
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

pub fn stop(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  _ = sub_arg;
  _ = allocator;
  const Logger = ScopedLogger(.stop);
  preamble.ensureRoot();

  Logger.fatal("Unimplemented", .{});
}

pub fn install(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  // TODO: restart service on install
  _ = allocator; // unused

  preamble.ensureRoot();
  const Logger = ScopedLogger(.install);

  const Op = struct {
    pub fn systemd() void {
      setup.Systemd.install() catch |e| {
        Logger.fatal("Failed to install systemd service: {!}", .{e});
      };
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
    return Op.auto();
  }

  switch (sub_arg.?.len) {
    3 => switch (meta.arrAsUint(sub_arg.?[0..3])) {
      meta.arrAsUint("bin") => {
        _ = Op.bin();
      },
      else => {},
    },
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Op.auto(),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Op.systemd(),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  printUsageAndExit();
}

pub fn uninstall(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  // TODO: stop service on install
  _ = allocator; // unused

  preamble.ensureRoot();
  const Logger = ScopedLogger(.uninstall);

  const Op = struct {
    pub fn systemd() void {
      setup.Systemd.uninstall() catch |e| {
        Logger.fatal("Failed to uninstall systemd service: {!}", .{e});
      };
    }

    pub fn bin() void {
      return setup.uninstallBin() catch |e| {
        Logger.fatal("Failed to install binary: {!}", .{e});
      };
    }

    pub fn auto() void {
      bin();
      if (
        setup.isInitSystem("systemd") catch |e| Logger.fatal("Error detecting init system: {!}", .{e}) and
        setup.Systemd.check() catch |e| Logger.fatal("Error detecting if systemd service is present: {!}", .{e})
      ) {
        systemd();
      }
    }
  };

  if (sub_arg == null) {
    return Op.auto();
  }

  switch (sub_arg.?.len) {
    3 => switch (meta.arrAsUint(sub_arg.?[0..3])) {
      meta.arrAsUint("bin") => {
        _ = Op.bin();
      },
      else => {},
    },
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Op.auto(),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Op.systemd(),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  printUsageAndExit();
}

pub fn enable(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  _ = allocator; // unused

  preamble.ensureRoot();
  const Logger = ScopedLogger(.enable);

  const Op = struct {
    pub fn systemd(sub: ?[:0]const u8) void {
      setup.Systemd.enable() catch |e| {
        Logger.fatal("Failed to uninstall systemd service: {!}", .{e});
      };
      var name_buf: [64]u8 = undefined;
      const my_name = myName(&name_buf);
      // TODO: handle already running
      Logger.log(.info, "To enable service, run `{s} enable{s}{s}`", .{my_name, if (sub == null) "" else " ", sub orelse ""});
    }

    pub fn auto(sub: ?[:0]const u8) void {
      if (setup.isInitSystem("systemd") catch |e| Logger.fatal("Error detecting init system: {!}", .{e})) {
        systemd(sub);
      } else {
        Logger.log(.warn, "No compatible init system detected, no-op", .{});
      }
    }
  };

  if (sub_arg == null) {
    return Op.auto(sub_arg);
  }

  switch (sub_arg.?.len) {
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Op.auto(sub_arg),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Op.systemd(sub_arg),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  printUsageAndExit();
}

pub fn disable(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  _ = allocator; // unused

  preamble.ensureRoot();
  const Logger = ScopedLogger(.enable);

  const Op = struct {
    pub fn systemd(sub: ?[:0]const u8) void {
      _ = sub;
      setup.Systemd.disable() catch |e| {
        Logger.fatal("Failed to uninstall systemd service: {!}", .{e});
      };

      // TODO: Add context, Handle not running / running
      var name_buf: [64]u8 = undefined;
      const my_name = myName(&name_buf);
      Logger.log(.info, "To remove service, run `{s} uninstall systemd`", .{ my_name });
    }

    pub fn auto(sub: ?[:0]const u8) void {
      if (setup.isInitSystem("systemd") catch |e| Logger.fatal("Error detecting init system: {!}", .{e})) {
        systemd(sub);
      } else {
        Logger.log(.warn, "No compatible init system detected, no-op", .{});
      }
    }
  };

  if (sub_arg == null) {
    return Op.auto(sub_arg);
  }

  switch (sub_arg.?.len) {
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => Op.auto(sub_arg),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => Op.systemd(sub_arg),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  printUsageAndExit();
}

pub fn status(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  _ = sub_arg;
  _ = allocator;
  const Logger = ScopedLogger(.status);

  Logger.fatal("Unimplemented", .{});
}

