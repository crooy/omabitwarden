import QtQuick
import Quickshell.Io

// Clipboard: writes a secret to the Wayland clipboard via stdin only
// (wl-copy --sensitive), then auto-clears it after 45s — but only if the
// clipboard still holds that exact secret (wl-paste --no-newline compare).
// Interface: copy(secret). No rendering; the caller toasts.
Item {
  id: root

  function copy(secret) {
    copyProc.stdinEnabled = true;
    copyProc.exec({ command: ["wl-copy", "--sensitive"] });
    copyProc.write(secret);
    copyProc.stdinEnabled = false; // EOF: wl-copy forks its serving child
    clearProc.environment = ({ S: secret });
    clearProc.exec(["/bin/sh", "-c", "sleep 45; [ \"$(wl-paste --no-newline)\" = \"$S\" ] && exec wl-copy --clear"]);
  }

  Process {
    id: copyProc
  }

  Process {
    id: clearProc
  }
}
