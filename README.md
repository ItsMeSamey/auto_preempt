# Compilation

```bash
zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
```

# Help

```txt
Usage: ./main [options] [mode]

Options:
  help             Display this help message and exit.
  version          Output version information and exit.

  start            Start this program normal mode (stay connected to terminal)
                   NO need to install first
  start [mode]     Start this program, program MUST be installed first
    mode:
      auto         Automatically detact and run in daemon / systemd mode
      daemon       Start in daemon mode (not associated with systemd or any other system)
      systemd      Start in systemd mode, sys
  install          Install this program in auto mode
  install [mode]   Install this program
    mode:
      auto         Automatically detect and install to /bin and if possible systemd service
      bin          Install to /usr/bin
      systemd      Install to /usr/bin + as systemd service as well
  uninstall        Uninstall this program
  uninstall [mode] Uninstall this program, also remove any autostart entries
    mode:
      bin          Remove from /usr/bin + remove all services (does not stop running services)
      systemd      Remove systemd service
  enable           Enable in auto mode
  enable [mode]    Enable this program, program must be installed first
    mode:
      auto         Automatically detect and enable. If not installed / already enable, no-op
      systemd      Enable autostart using systemd
  disable         Disable in auto mode
  disable [mode]   Disable this program, no-op if not installed / enabled
    mode:
      auto         Automatically detect and disable. If not installed / already disabled, no-op
      systemd      Disable autostart using systemd
  status           Show status of running services

```

