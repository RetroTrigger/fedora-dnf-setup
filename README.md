# Fedora DNF and Flatpak setup

Run on a traditional (RPM-based) Fedora installation:

```bash
sudo bash ~/fedora-dnf-setup.sh
```

Then **log out and back in** to activate the desktop reboot helper. The script
installs dependencies and configures the machine on which you run it.

## What it configures

- Detects DNF4 or DNF5 from the default `dnf` command.
- Sets 10 parallel downloads, disables latency-based `fastestmirror` selection,
  and sets `defaultyes=True`: interactive DNF confirmations become `[Y/n]`.
  Repository-specific options can still override global download settings.
- Downloads and installs all available DNF updates daily at 04:00 plus up to one
  hour of random delay. Fedora release upgrades are not performed.
- Updates system-wide and per-user Flatpak apps/runtimes daily at 05:00 plus up
  to one hour of random delay, using existing remotes. Additional named
  system-wide Flatpak installations are not included.
- Uses persistent timers to catch up after downtime. Per-user timers run while
  the user's systemd manager is running, normally during login sessions; they
  catch up at login. Existing logged-in users other than the sudo caller should
  log out and in to activate their timer.
- Checks whether a reboot is recommended every 15 minutes and after successful
  automatic DNF updates. A desktop helper uses KDE's `kdialog` when available,
  otherwise `zenity` (installed by the script and usable on GNOME/KDE). A
  notification is the fallback if neither dialog program is available.
- Explicit approval is required to reboot. **Later**, closing the dialog, or
  any dialog failure leaves the system running. A declined prompt returns after
  24 hours; desktop authorization and shutdown inhibitors still apply.

The DNF automatic updater has `reboot=never`; approval happens separately in
your desktop session. On a machine without a desktop session, no reboot occurs.
Flatpak updates do not themselves trigger a machine reboot prompt.

Configuration changes are idempotent. Unrelated INI options and comments are
preserved. Replaced files are backed up beneath
`/var/backups/fedora-maintenance/<timestamp>/`, with a `manifest.txt` listing
created and replaced paths. Other DNF automatic timers are disabled to avoid
duplicate update schedules. Existing enabled services already running at setup
time are allowed to finish.

## Status and logs

Use `dnf5-automatic` on DNF5 systems or `dnf-automatic` on DNF4 systems:

```bash
systemctl list-timers --all '*automatic*' '*flatpak*'
journalctl -u dnf5-automatic.service -n 100
journalctl -u fedora-flatpak-update.service -n 100
systemctl --user status fedora-flatpak-user-update.timer
journalctl --user -u fedora-flatpak-user-update.service -n 100
journalctl -u fedora-maintenance-reboot-check.service -n 100
```

Check reboot status manually:

```bash
sudo dnf needs-restarting -r
# Exit 0: no reboot recommended; exit 1: reboot recommended.
```

You can run updates immediately with:

```bash
sudo systemctl start dnf5-automatic.service  # dnf-automatic.service on DNF4
sudo systemctl start fedora-flatpak-update.service
systemctl --user start fedora-flatpak-user-update.service
```

## Disable or restore

Disable the configured system timers (omit the DNF timer your system does not have):

```bash
sudo systemctl disable --now dnf5-automatic.timer fedora-flatpak-update.timer fedora-maintenance-reboot-check.timer
sudo systemctl disable --global fedora-flatpak-user-update.timer
systemctl --user disable --now fedora-flatpak-user-update.timer
```

To disable the global desktop prompt, remove
`/etc/xdg/autostart/fedora-maintenance-reboot.desktop`, then log out and back in.
An individual user can instead disable that startup entry in their desktop's
autostart settings.

To restore configuration, inspect the appropriate backup's `manifest.txt`, copy
the desired backed-up files to their original absolute paths, and remove only
the generated files marked `CREATED` that you want to undo. For example:

```bash
sudo cp -a /var/backups/fedora-maintenance/<timestamp>/etc/dnf/dnf.conf /etc/dnf/dnf.conf
sudo systemctl daemon-reload
systemctl --user daemon-reload
```

Timer enable/disable state is not restored by copying configuration files;
re-enable any previous timers you want to use. Installed dependency packages are
left installed.
