#!/usr/bin/env bash
# Configure traditional Fedora systems. Run: sudo bash fedora-dnf-setup.sh
set -Eeuo pipefail
trap 'printf "Setup failed at line %s. See the error above; backups are in /var/backups/fedora-maintenance/.\n" "$LINENO" >&2' ERR

if (( EUID != 0 )); then
    printf 'Run this script with sudo: sudo bash %q\n' "$0" >&2
    exit 1
fi
if [[ $# != 0 ]]; then
    printf 'Usage: sudo bash %q\n' "$0" >&2
    exit 1
fi
source /etc/os-release
if [[ ${ID:-} != fedora ]]; then
    printf 'This script requires Fedora. Detected: %s\n' "${PRETTY_NAME:-unknown}" >&2
    exit 1
fi
if [[ -e /run/ostree-booted || -e /usr/lib/bootc/install ]]; then
    printf 'Atomic/OSTree/bootc editions require image-based updates rather than this DNF setup.\n' >&2
    exit 1
fi
if [[ ! -d /run/systemd/system ]]; then
    printf 'A running systemd system is required.\n' >&2
    exit 1
fi

# Follow the default dnf binary, even when both DNF generations are installed.
dnf_path=$(command -v dnf)
dnf_real=$(readlink -f "$dnf_path")
if [[ ${dnf_real##*/} == dnf5* ]]; then
    manager=dnf5
    automatic_package=dnf5-plugin-automatic
    plugin_package=dnf5-plugins
    timer=dnf5-automatic.timer
elif dnf --version | /usr/bin/grep -qE '^dnf5 version|^5\.'; then
    manager=dnf5
    automatic_package=dnf5-plugin-automatic
    plugin_package=dnf5-plugins
    timer=dnf5-automatic.timer
else
    manager=dnf
    automatic_package=dnf-automatic
    plugin_package=dnf-plugins-core
    timer=dnf-automatic.timer
fi
printf 'Detected %s; using %s. Installing update and desktop-prompt dependencies...\n' "$PRETTY_NAME" "$manager"
"$manager" install -y "$automatic_package" "$plugin_package" flatpak python3 zenity libnotify

export FEDORA_MAINTENANCE_MANAGER="$manager"
export FEDORA_MAINTENANCE_TIMER="$timer"
python3 - <<'PY'
import datetime
import os
from pathlib import Path
import re
import shutil
import tempfile

backup = Path('/var/backups/fedora-maintenance') / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
backup.mkdir(parents=True, mode=0o700)
manager = os.environ['FEDORA_MAINTENANCE_MANAGER']
timer = os.environ['FEDORA_MAINTENANCE_TIMER']
manifest = []

def write(path, text, mode=0o644):
    p = Path(path)
    if p.is_symlink():
        raise RuntimeError(f'Refusing to replace symlink: {p}')
    if p.exists() and p.read_text() == text and (p.stat().st_mode & 0o777) == mode:
        return
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        dest = backup / str(p).lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dest)
        manifest.append(f'REPLACED {p}')
    else:
        manifest.append(f'CREATED {p}')
    fd, tmp = tempfile.mkstemp(prefix='.' + p.name + '.', dir=p.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def update_ini(path, settings):
    # Edit only managed keys; preserve comments, other options and other sections.
    p = Path(path)
    lines = p.read_text().splitlines(keepends=True) if p.exists() else []
    result = []
    section = None
    seen_sections = set()
    written = set()

    def finish():
        if section in settings:
            for key, value in settings[section].items():
                if (section, key) not in written:
                    result.append(f'{key}={value}\n')
                    written.add((section, key))

    for line in lines:
        match = re.match(r'^\s*\[([^]]+)\]', line)
        if match:
            finish()
            section = match[1].strip()
            seen_sections.add(section)
        key = re.match(r'^\s*([^#;\s=]+)\s*=', line)
        if key and section in settings and key[1].lower() in settings[section]:
            name = key[1].lower()
            if (section, name) not in written:
                result.append(f'{name}={settings[section][name]}\n')
                written.add((section, name))
        else:
            result.append(line if line.endswith('\n') else line + '\n')
    finish()
    for name, values in settings.items():
        if name not in seen_sections:
            result.append(f'\n[{name}]\n')
            result.extend(f'{k}={v}\n' for k, v in values.items())
    write(path, ''.join(result))

update_ini('/etc/dnf/dnf.conf', {'main': {
    'max_parallel_downloads': '10',
    'fastestmirror': 'False',
    'defaultyes': 'True',
}})
update_ini('/etc/dnf/automatic.conf', {
    'commands': {
        'upgrade_type': 'default', 'download_updates': 'True',
        'apply_updates': 'True', 'random_sleep': '0',
        'network_online_timeout': '120', 'reboot': 'never',
    },
    'emitters': {'emit_via': 'stdio'},
})

write(f'/etc/systemd/system/{timer}.d/90-fedora-maintenance.conf', '''[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true
''')

write('/usr/local/libexec/fedora-maintenance-reboot-check', f'''#!/usr/bin/env bash
set -uo pipefail
mkdir -p /run/fedora-maintenance
chmod 755 /run/fedora-maintenance
{manager} needs-restarting -r
status=$?
case "$status" in
    0) rm -f /run/fedora-maintenance/reboot-required ;;
    1) touch /run/fedora-maintenance/reboot-required
       chmod 644 /run/fedora-maintenance/reboot-required ;;
    *) printf 'Reboot check failed (exit %s); preserving previous state.\\n' "$status" >&2
       exit "$status" ;;
esac
''', 0o755)

write('/etc/systemd/system/fedora-maintenance-reboot-check.service', '''[Unit]
Description=Check whether Fedora package updates require a reboot
After=dnf-automatic.service dnf5-automatic.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/fedora-maintenance-reboot-check
''')
write('/etc/systemd/system/fedora-maintenance-reboot-check.timer', '''[Unit]
Description=Periodically check for a required reboot

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
''')
# Also check immediately following a successful automatic-update run.
service = timer.removesuffix('.timer') + '.service'
write(f'/etc/systemd/system/{service}.d/90-fedora-maintenance.conf', '''[Service]
ExecStartPost=/usr/local/libexec/fedora-maintenance-reboot-check
''')

write('/etc/systemd/system/fedora-flatpak-update.service', '''[Unit]
Description=Update system-wide Flatpak apps and runtimes
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --system --noninteractive --assumeyes
Nice=10
''')
write('/etc/systemd/system/fedora-flatpak-update.timer', '''[Unit]
Description=Daily system-wide Flatpak updates

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
''')
write('/etc/systemd/user/fedora-flatpak-user-update.service', '''[Unit]
Description=Update this user's Flatpak apps and runtimes

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak update --user --noninteractive --assumeyes
Nice=10
''')
write('/etc/systemd/user/fedora-flatpak-user-update.timer', '''[Unit]
Description=Daily per-user Flatpak updates

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
''')

write('/usr/local/libexec/fedora-maintenance-reboot-prompt', '''#!/usr/bin/python3
"""Run inside the desktop session; never approve a reboot implicitly."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import time

def run(args, **kwargs):
    try:
        return subprocess.run(args, check=False, **kwargs).returncode
    except OSError:
        return 127

runtime = os.environ.get('XDG_RUNTIME_DIR')
if not runtime or not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
    raise SystemExit(0)
lock = open(Path(runtime) / 'fedora-maintenance-reboot-prompt.lock', 'w')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(0)

state = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'fedora-maintenance'
state.mkdir(parents=True, exist_ok=True)
snooze = state / 'reboot-prompt-time'
flag = Path('/run/fedora-maintenance/reboot-required')
desktop = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
time.sleep(60)  # Give the desktop time to finish logging in.
while True:
    try:
        last = snooze.stat().st_mtime if snooze.exists() else 0
        # A reboot clears /run and the snooze; declining prompts again in 24h.
        if not flag.exists():
            snooze.unlink(missing_ok=True)
        elif time.time() - last >= 86400:
            text = ('Fedora updates require a reboot to finish applying changes. '
                    'Save your work before choosing Reboot now.')
            snooze.touch()
            if 'kde' in desktop and shutil.which('kdialog'):
                answer = run(['kdialog', '--title', 'Fedora updates', '--defaultno', '--yesno', text,
                              '--yes-label', 'Reboot now', '--no-label', 'Later'])
            elif shutil.which('zenity'):
                answer = run(['zenity', '--question', '--title=Fedora updates',
                              '--text=' + text, '--ok-label=Reboot now',
                              '--cancel-label=Later', '--default-cancel', '--no-wrap'])
            else:
                run(['notify-send', 'Fedora updates', text + ' Reboot when convenient.'])
                answer = 1
            if answer == 0:
                # logind/polkit handles authorization and application inhibitors.
                if run(['systemctl', 'reboot']) != 0:
                    run(['notify-send', 'Reboot was not completed',
                         'Use your desktop power menu to reboot when ready.'])
    except OSError as error:
        print(f'Reboot prompt: {error}', flush=True)
    time.sleep(900)
''', 0o755)
write('/etc/xdg/autostart/fedora-maintenance-reboot.desktop', '''[Desktop Entry]
Type=Application
Name=Fedora update reboot approval
Comment=Ask before rebooting to finish applying Fedora updates
Exec=/usr/local/libexec/fedora-maintenance-reboot-prompt
TryExec=/usr/local/libexec/fedora-maintenance-reboot-prompt
Terminal=false
X-GNOME-Autostart-enabled=true
''')

(backup / 'manifest.txt').write_text('\n'.join(manifest) + '\n')
print(f'Configuration backups and changed-file manifest: {backup}')
PY

# Restore the standard SELinux labels after atomically replacing files.
if command -v restorecon >/dev/null; then
    restorecon -R /usr/local/libexec/fedora-maintenance-* \
        /etc/dnf/dnf.conf /etc/dnf/automatic.conf \
        /etc/systemd/system /etc/systemd/user \
        /etc/xdg/autostart/fedora-maintenance-reboot.desktop
fi

systemctl daemon-reload
# Stop other DNF automatic timers to avoid duplicate or contradictory schedules.
for other in dnf-automatic.timer dnf-automatic-download.timer \
    dnf-automatic-install.timer dnf-automatic-notifyonly.timer dnf5-automatic.timer; do
    if [[ $other != "$timer" ]] && systemctl cat "$other" >/dev/null 2>&1; then
        systemctl disable --now "$other"
    fi
done
systemctl enable --now "$timer" fedora-flatpak-update.timer fedora-maintenance-reboot-check.timer
systemctl enable --global fedora-flatpak-user-update.timer

# Activate the user timer immediately for the invoking logged-in user, if any.
login_user=${SUDO_USER:-}
if [[ -n $login_user && $login_user != root ]]; then
    login_uid=$(id -u "$login_user")
    if [[ -S /run/user/$login_uid/bus ]]; then
        if ! runuser -u "$login_user" -- env \
            XDG_RUNTIME_DIR="/run/user/$login_uid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$login_uid/bus" \
            bash -c 'systemctl --user daemon-reload && systemctl --user enable --now fedora-flatpak-user-update.timer'; then
            printf 'User timer will become active at the next login.\n' >&2
        fi
    fi
fi

printf '\nSetup complete. DNF confirmations now default to [Y/n].\n'
printf 'Daily updates: DNF at 04:00–05:00; Flatpak at 05:00–06:00 (local time).\n'
printf 'Persistent timers may catch up on missed updates shortly after activation.\n'
printf 'Log out and back in to start desktop reboot prompts and user timers for all desktop users.\n'
printf 'A reboot happens only after explicit desktop approval.\n\n'
systemctl list-timers "$timer" fedora-flatpak-update.timer fedora-maintenance-reboot-check.timer --no-pager
