> [!WARNING]
> [Offlining cpu cores may ?NOT save power](https://www.reddit.com/r/linuxquestions/comments/112t4x2/will_disabling_some_cpu_cores_save_power/)

# Compilation

```bash
zig build-exe main.zig -OReleaseFast -fstrip -fsingle-threaded -fincremental -flto -mno-red-zone
```

# Install
Run
```bash
sudo ./main install
```
to install / update binary + systemd service

# Uninstall
Run
```bash
sudo ./main uninstall
```
or
```bash
sudo auto_preempt uninstall
```

to uninstall binary + systemd service

# Help

run `auto_preempt help` to see help

```txt
Usage: auto_preempt [options] [mode]

A service to automatically offline un-needed cpu cores
NOTE: This is just a personal project

Options:
  help             Display this help message and exit.
  version          Output version information and exit.

  status           Show status of running services

  start            Star in auto mode
  start [mode]     Start this program, program MUST be installed first
    mode:
      auto         Automatically detact and run in daemon / systemd mode
      normal       Start this program normal mode (stay connected to terminal)
                   NO need to install first
      daemon       Start in daemon mode (not associated with systemd or any other system)
      systemd      Start in systemd mode, sys
  stop             Stop this program / daemon running in background

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
  disable          Disable in auto mode
  disable [mode]   Disable this program, no-op if not installed / enabled
    mode:
      auto         Automatically detect and disable. If not installed / already disabled, no-op
      systemd      Disable autostart using systemd


Source code available at <https://github.com/ItsMeSamey/auto_preempt>.
Report bugs to <https://github.com/ItsMeSamey/auto_preempt/issues>.

This is free software; see the source for copying conditions. There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
```

