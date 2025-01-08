// Build Cmd: zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
// TODOS's:
//    cli args
//    config file and options
//    support for daemonizing
//    ipc to ensure only one instance is running
//    documentation
//    more todo's ;)

const std = @import("std");
const builtin = @import("builtin");
const preamble = @import("src/preamble.zig");
const CpuStatus = @import("src/cpu_status.zig");
const ScopedLogger = @import("src/logging.zig").ScopedLogger;
const CpuPressure = @import("src/cpu_pressure.zig");

pub var allCpus: CpuStatus.AllCpus = undefined;

pub fn main() !void {
  preamble.ensureRoot();
  try preamble.makeOomUnkillable();

  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer {
    const leaks = gpa.deinit();
    if (leaks == .leak) {
      @panic("Memory leak detected");
    }
  }
  const allocator = gpa.allocator();

  allCpus = try CpuStatus.AllCpus.init(allocator);
  preamble.registerSignalHandlers(@This());
  defer allCpus.deinit(allocator);
  errdefer {
    allCpus.restoreCpuState() catch |e| {
      const Logger = ScopedLogger(.cpu_adjust_main);
      Logger.log(.err, "Cpu state restoration failed with error: {!}", .{e});
      Logger.log(.warn, "Exiting", .{});
      std.os.linux.exit(1);
    };
  }

  var sub = try CpuPressure.Subscription.subscribe(150_000, 500_000);
  defer CpuPressure.Subscription.close(sub);

  while (true) {
    const ev_count = try CpuPressure.Subscription.wait(&sub, 5_000);

    if (ev_count == 0) {
      try allCpus.adjustSleepingCpus();
      continue;
    }

    ScopedLogger(.main_loop).log(.debug, "Cpu pressure event received", .{});
    if (sub.revents & std.posix.POLL.ERR != 0) {
      return error.PollError;
    } else if (sub.revents & std.posix.POLL.PRI == 0) {
      return error.UnknownEvent;
    }

    try allCpus.wakeOne();
  }
}

test {
  std.testing.refAllDeclsRecursive(@This());
}

