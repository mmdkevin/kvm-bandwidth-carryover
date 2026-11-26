# v2.1.0

- Add Ubuntu host compatibility: detect cron/crond using distribution metadata and active services.
- Give apt-get/dnf dependency instructions; check required commands and the system Python path.
- Use /usr/bin/python3 consistently in the bootstrap and installed commands.
- Update read-only Doctor checks and Linux host error messages.
- Preserve the existing accounting engine, state format, quota policy and upgrade history.
- Add isolated Ubuntu 22.04/24.04 and AlmaLinux service, dependency and upgrade regression tests.
- Real Ubuntu Virtualizor host installation has not yet been tested.

# v2.0.2

- Redraw the interactive menu in the same terminal screen instead of appending copies.
- Show each action on its own page; restore the original shell screen on exit or interrupt.
- Keep command output and non-interactive logs free of terminal screen-control codes.

# v2.0.1

- Fix terminal menu on non-seekable TTY input (read-only terminal mode).
- Fall back to interactive stdin when /dev/tty is unavailable.
- Exit cleanly on EOF; do not consume a piped installer as menu input.

# v2.0.0

- Interactive management menu and the short `kvm-bw` command.
- Install, history-preserving upgrade, pause/resume, and uninstall that retains accounting data.
- Status/JSON, recent logs, read-only diagnostics, previews and backups.
- Upgrade rollback, pre-operation backups and successful-run heartbeat.
- Existing accounting state schema and reset policy retained.
