// Build Cmd: zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
// TODOS's:
//    cli args
//    config file and options
//    support for daemonizing
//    ipc to ensure only one instance is running
//    documentation
//    better handling for terminal pause interrupts
//    more todo's ;)

const std = @import("std");
const meta = @import("src/meta.zig");
const setup = @import("src/setup.zig");
const Operations = @import("src/operations.zig");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer {
    const leaks = gpa.deinit();
    if (leaks == .leak) {
      @panic("Memory leak detected");
    }
  }
  const allocator = gpa.allocator();

  const Logger = @import("src/logging.zig").ScopedLogger(.main);
  const cliArgs = std.os.argv;
  if (cliArgs.len == 0) {
    Logger.log(.err, "Argument length is zero", .{});
    Operations.printUsageAndExit();
  } else if (cliArgs.len == 1) {
    Logger.log(.err, "No Cli args provided", .{});
    Operations.printUsageAndExit();
  } else if (cliArgs.len > 3) {
    Logger.log(.err, "Too many arguments provided", .{});
    Operations.printUsageAndExit();
  }

  const firstArg: [:0]const u8 = std.mem.sliceTo(cliArgs[1], 0);
  const secondArg: ?[:0]const u8 = if (cliArgs.len > 2) std.mem.sliceTo(cliArgs[2], 0) else null;

  switch (firstArg.len) {
    4 => switch (meta.asUint(4, firstArg)) {
      meta.arrAsUint("help") => {
        if (secondArg) |arg| Logger.log(.warn, "Unknown argument: {s}", .{arg});
        Operations.printUsageAndExit();
      },
      meta.arrAsUint("stop") => try Operations.stop(allocator, secondArg),
      else => {},
    },
    5 => switch (meta.asUint(5, firstArg)) {
      meta.arrAsUint("start") => try Operations.start(allocator, secondArg),
      else => {},
    },
    6 => switch (meta.asUint(6, firstArg)) {
      meta.arrAsUint("enable") => try Operations.enable(allocator, secondArg),
      meta.arrAsUint("status") => try Operations.status(allocator, secondArg),
      else => {},
    },
    7 => switch (meta.asUint(7, firstArg)) {
      meta.arrAsUint("version") => {
        if (secondArg) |arg| Logger.log(.warn, "Unknown argument: {s}", .{arg});
        printVersionAndExit();
      },
      meta.arrAsUint("install") => try Operations.install(allocator, secondArg),
      meta.arrAsUint("disable") => try Operations.disable(allocator, secondArg),
      else => {},
    },
    9 => switch (meta.asUint(9, firstArg)) {
      meta.arrAsUint("uninstall") => try Operations.uninstall(allocator, secondArg),
      else => {},
    },
    else => {},
  }

  Logger.log(.err, "Unknown argument: {s}", .{firstArg});
  Operations.printUsageAndExit();
}

pub fn printVersionAndExit() noreturn {
  const stdout = std.io.getStdOut().writer();
  stdout.print(setup.VERSION ++ "\n", .{}) catch {};
  std.posix.exit(0);
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

