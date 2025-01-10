fn myName() []const u8 {
  const Static = struct {
    var buf: [64]u8 = undefined;
    var len: u8 = 0;
  };
  if (Static.len != 0) return Static.buf[0..Static.len];

  const self_name_file = std.fs.cwd().openFileZ("/proc/self/comm", .{ .mode = .read_only }) catch |e| {
    ScopedLogger(.print_usage).log(.err, "Failed to get self exe path: {!}", .{e});
    return "auto_preempt";
  };
  defer self_name_file.close();
  Static.len = @intCast(self_name_file.readAll(&Static.buf) catch |e| {
    ScopedLogger(.print_usage).log(.err, "Failed to read self exe name: {!}", .{e});
    return "auto_preempt";
  });
  if (Static.buf[Static.len - 1] == '\n') Static.len -= 1;

  return Static.buf[0..Static.len];
}

pub fn printUsageAndExit() noreturn {
  defer std.posix.exit(1);
  const stdout = std.io.getStdOut().writer();

  const my_name = myName();

  nosuspend stdout.print(
    \\Usage: {s} [options] [mode]
    \\
    \\Options:
    \\  help             Display this help message and exit.
    \\  version          Output version information and exit.
    \\
    \\  status           Show status of running services
    \\
    \\  start            Start this program normal mode (stay connected to terminal)
    \\                   NO need to install first
    \\  start [mode]     Start this program, program MUST be installed first
    \\    mode:
    \\      auto         Automatically detact and run in daemon / systemd mode
    \\      daemon       Start in daemon mode (not associated with systemd or any other system)
    \\      systemd      Start in systemd mode, sys
    \\  stop             Stop this program / daemon running in background
    \\
    \\  install          Install this program in auto mode
    \\  install [mode]   Install this program
    \\    mode:
    \\      auto         Automatically detect and install to /bin and if possible systemd service
    \\      bin          Install to /usr/bin
    \\      systemd      Install to /usr/bin + as systemd service as well
    \\  uninstall        Uninstall this program
    \\  uninstall [mode] Uninstall this program, also remove any autostart entries
    \\    mode:
    \\      bin          Remove from /usr/bin + remove all services (does not stop running services)
    \\      systemd      Remove systemd service
    \\
    \\  enable           Enable in auto mode
    \\  enable [mode]    Enable this program, program must be installed first
    \\    mode:
    \\      auto         Automatically detect and enable. If not installed / already enable, no-op
    \\      systemd      Enable autostart using systemd
    \\  disable          Disable in auto mode
    \\  disable [mode]   Disable this program, no-op if not installed / enabled
    \\    mode:
    \\      auto         Automatically detect and disable. If not installed / already disabled, no-op
    \\      systemd      Disable autostart using systemd
    \\
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
const ipc = @import("ipc.zig");
const meta = @import("meta.zig");
const setup = @import("setup.zig");
const builtin = @import("builtin");
const preamble = @import("preamble.zig");
const daemonize = @import("daemonize.zig");
const CpuStatus = @import("cpu_status.zig");
const CpuPressure = @import("cpu_pressure.zig");
const ScopedLogger = @import("logging.zig").ScopedLogger;

pub var allCpus: CpuStatus.AllCpus = undefined;

const NoError = error{NoError};

pub fn start(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  // TODO: enable ipc checking
  const StartLogger = ScopedLogger(.start);
  preamble.ensureRoot();

  if (ipc.checkProcessExistence() catch |e| StartLogger.fatal("Error detecting if process already exists: {!}", .{e})) {
    StartLogger.fatal("Process already exists", .{});
  }

  const Op = struct {
    pub fn systemd() void {
      StartLogger.log(.info, "Starting systemd service", .{});
      setup.Systemd.start() catch |e| {
        StartLogger.fatal("Failed to start systemd service: {!}", .{e});
      };
      StartLogger.log(.info, "Successfully started systemd service", .{});
      std.posix.exit(0);
    }

    pub fn auto() void {
      const my_name = myName();
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
  } else switch (sub_arg.?.len) {
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

  switch (ipc.createPidFile() catch |e| StartLogger.fatal("Failed to create pid file: {!}", .{e})) {
    .exists => StartLogger.fatal("Pid file already exists", .{}),
    .created => {},
  }
  defer ipc.removePidFile() catch |e| StartLogger.log(.err, "Failed to remove pid file: {!}", .{e});

  allCpus = CpuStatus.AllCpus.init(allocator) catch |e| {
    ipc.removePidFile() catch |e_1| StartLogger.log(.err, "Failed to remove pid file: {!}", .{e_1});
    StartLogger.fatal("Failed to initialize cpu status: {!}", .{e});
  };
  preamble.registerSignalHandlers(@This());
  defer allCpus.deinit(allocator);

  const Logger = struct {
    pub const log = StartLogger.log;
    pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
      ipc.removePidFile() catch |e| StartLogger.log(.err, "Failed to remove pid file: {!}", .{e});
      allCpus.restoreCpuState() catch |e| {
        ScopedLogger(.cpu_adjust_main).log(.err, "Cpu state restoration failed with error: {!}", .{e});
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
  _ = allocator; // unused
  const Logger = ScopedLogger(.stop);
  preamble.ensureRoot();

  if (sub_arg) |sub| {
    Logger.log(.err, "Unrecognized argument: {s}", .{sub});
    printUsageAndExit();
  }

  if (setup.Systemd.check() catch |e| blk: {
    Logger.log(.err, "Failed to check if systemd service exists: {!}", .{e});
    break :blk false;
  }) {
    Logger.log(.info, "Trying to stop systemd service", .{});
    setup.Systemd.stop() catch |e| switch (e) {
      setup.ExecError.BadExitStatus => Logger.log(.warn, "systemctl exited with bad exit status", .{}),
      else => Logger.log(.err, "Failed to stop systemd service: {!}", .{e}),
    };
  }

  ipc.killExistingProcess() catch |e| Logger.fatal("Failed to kill existing process: {s}", .{@errorName(e)});
  Logger.log(.info, "Success", .{});
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
        Logger.log(.warn, "Systemd detected, installing systemd service as well", .{});
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
        return;
      },
      else => {},
    },
    4 => switch (meta.arrAsUint(sub_arg.?[0..4])) {
      meta.arrAsUint("auto") => return Op.auto(),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => return Op.systemd(),
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
      if (setup.Systemd.check() catch |e| Logger.fatal("Error detecting if systemd service is present: {!}", .{e})) {
        setup.Systemd.uninstall() catch |e| {
          Logger.fatal("Failed to uninstall systemd service: {!}", .{e});
        };
      } else {
        Logger.log(.warn, "Systemd service not present no-op", .{});
      }
    }

    pub fn bin() void {
      setup.uninstallBin() catch |e| {
        Logger.fatal("Failed to install binary: {!}", .{e});
      };
      systemd();
    }
  };

  if (sub_arg == null) {
    return Op.bin();
  }
  switch (sub_arg.?.len) {
    3 => switch (meta.arrAsUint(sub_arg.?[0..3])) {
      meta.arrAsUint("bin") => return Op.bin(),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => return Op.systemd(),
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
      const my_name = myName();
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
      meta.arrAsUint("auto") => return Op.auto(sub_arg),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => return Op.systemd(sub_arg),
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
      const my_name = myName();
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
      meta.arrAsUint("auto") => return Op.auto(sub_arg),
      else => {},
    },
    7 => switch (meta.arrAsUint(sub_arg.?[0..7])) {
      meta.arrAsUint("systemd") => return Op.systemd(sub_arg),
      else => {},
    },
    else => {},
  }
  Logger.log(.err, "Unknown argument: {s}", .{sub_arg.?});
  printUsageAndExit();
}

pub fn status(allocator: std.mem.Allocator, sub_arg: ?[:0]const u8) NoError!void {
  _ = allocator;
  const Logger = ScopedLogger(.status);

  if (sub_arg) |sub| {
    Logger.log(.err, "Unrecognized argument: {s}", .{sub});
    printUsageAndExit();
  }

  if (ipc.getExistingProcessId() catch |e| Logger.fatal("Failed to get existing process id: {!}", .{e})) |pid| {
    Logger.log(.info, "Running in background with pid {d}", .{pid});
  } else {
    Logger.log(.info, "No running process detected", .{});
  }
}

