#!/usr/bin/env python3
# Note: there's another file that has "pgrep --full --exact", which expects the line above to be "python3"

import subprocess
import sys
from pathlib import Path

import dbus  # type: ignore[import]

# Reference: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/blob/master/gnome-settings-daemon/org.gnome.SessionManager.xml#L102
INHIBIT_APP_ID = "tamborgmatic"
INHIBIT_REASON = "Running backup"
INHIBIT_SUSPEND_FLAG = 4
INHIBIT_TOPLEVEL_XID = 0


def inhibit_suspend():
    """
    A long backup (no files cache) failed when the computer went to sleep.

    Maybe it shouldn't have slept while disk was active, maybe it slept anyway
    because disk was inactive while "Remote: Compacting segments".

    Anyway, disable suspend while borgmatic is running.

    One option is to use systemd-inhibit but it doesn't play well with Desktop Environments.
    In Cinnamon, it had to be run with sudo for it to work, and then when the inhibit was released,
    Cinnamon stayed stuck in an "Authentication is required" prompt (required to suspend),
    so it didn't automatically suspend afterwards.

    This systemd-inhibit approach was suggested and tested according to
    https://askubuntu.com/questions/805243/prevent-suspend-before-completion-of-command-run-from-terminal
    (using `org>cinnamon>settings` instead of `org>gnome>settings`)

    Note that inhibitors are automatically released when the process exits
    (https://stackoverflow.com/questions/17478532/powermanagement-inhibit-works-with-dbus-python-but-not-dbus-send),
    so that's why this wrapper is Python with subprocess, instead of Bash or a borgmatic hook.

    So according to https://arnaudr.io/2020/09/25/inhibit-suspending-the-computer-with-gtkapplication/,
    the best and most compatible would be to use
    http://lazka.github.io/pgi-docs/#Gtk-3.0/classes/Application.html#Gtk.Application.inhibit,
    but while searching for an existing app, I got to
    https://codeberg.org/WhyNotHugo/caffeine-ng/src/tag/v4.0.2/caffeine/inhibitors.py#L66
    which works in Cinnamon so let's copy that.

    Alternative: https://wakepy.readthedocs.io
    """

    try:
        is_running_gui = subprocess.run(
            ("systemctl", "--quiet", "is-active", "display-manager"),
            check=False,
        ).returncode == 0
    except FileNotFoundError:   # No systemd
        return                  # Don't care (antiX Linux)

    if is_running_gui:
        bus = dbus.SessionBus()
        applicable = "org.gnome.SessionManager" in bus.list_names()

        if applicable:
            proxy1 = bus.get_object("org.gnome.SessionManager", "/org/gnome/SessionManager")
            proxy2 = dbus.Interface(proxy1, dbus_interface="org.gnome.SessionManager")
            proxy2.Inhibit(
                INHIBIT_APP_ID,
                dbus.UInt32(INHIBIT_TOPLEVEL_XID),
                INHIBIT_REASON,
                dbus.UInt32(INHIBIT_SUSPEND_FLAG),
            )
            # No need to store cookie or call Uninhibit, just exit script.

        else:
            print("Note: not preventing suspension")


inhibit_suspend()

cmd = (
    'sudo'
        ' SSH_AUTH_SOCK="$SSH_AUTH_SOCK"'
        ' BORG_PASSPHRASE="$BORG_PASSPHRASE"'
        ' STDERR_ABOVE_BORGMATIC="$(readlink /proc/self/fd/2)"'
        ' borgmatic create --progress --stats'
)

if len(sys.argv) > 1:
    cmd += " " + " ".join(sys.argv[1:])

subprocess.run(cmd, cwd=Path(__file__).parent, shell=True, check=True)
