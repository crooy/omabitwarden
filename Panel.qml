import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "totp.js" as Totp

// omabitwarden: keyboard-first vault panel over `bw serve`.
// Unlock: bw unlock --passwordenv BW_PANEL_PW --raw (master password via env,
// never argv) -> session key memory-only -> managed bw serve child (BW_SESSION
// env) -> GET /status poll -> one GET /list/object/items (full items: password,
// totp seed included) -> everything else client-side. GET-only, no Origin
// header, serve dies with the panel. Clipboard: wl-copy --sensitive via stdin,
// 45s auto-clear guarded by wl-paste compare.
//
// Ported from the standalone shell (panel/shell.qml). The card used to be a
// dead-center modal over a fullscreen PanelWindow; as a plugin popout it rides
// the native KeyboardPanel mechanism instead, placed with centerOnBar: true —
// centered under the bar, the closest native positioning to the old centered
// card (no new window type invented). Outside-click dismissal and focus
// priming come from KeyboardPanel; Esc/close and the Ctrl+G/Ctrl+P/Ctrl+L
// shortcuts stay on the fields, so no PanelKeyCatcher — its Keys.BeforeItem
// priority would steal the list-arrow keys from the search field.
//
// The standalone theme.name FileView watcher is dropped: qs.Commons.Color is
// a shared singleton the shell host live-follows; the clock/audio panels
// don't watch theme files either.
Panel {
  id: root
  moduleName: "crooy.omabitwarden"

  // Orphaned bw serve from a previous shell instance dies at plugin mount:
  // it holds the vault open without any key (see checkStaleServe).
  Component.onCompleted: root.checkStaleServe()
  ipcTarget: "omabitwarden"
  manageIpc: false // IpcHandler lives in BarWidget.qml

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel (clock precedent): popout coordination identifies panels by
  // the slot item.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Vault state (ported verbatim from the standalone shell)
  property bool locked: true
  property string sessionKey: "" // memory only, never argv/URL/disk
  property var items: []
  property string query: ""
  property int expandedIndex: -1
  property int fieldSel: 1
  property var fieldNames: ["username", "password", "one-time key"]
  property int statusAttempts: 0
  property bool toastCloses: false // only copy-toasts close the panel
  property bool busy: false // unlock in flight: bar + status message

  readonly property string apiBase: "http://127.0.0.1:8087"

  readonly property var filtered: root.items.filter(function (it) {
    const q = root.query.toLowerCase();
    return !q || it.name.toLowerCase().indexOf(q) !== -1 || it.username.toLowerCase().indexOf(q) !== -1;
  })

  onQueryChanged: list.currentIndex = 0

  function open() {
    root.expandedIndex = -1;
    root.query = "";
    search.clear();
    list.currentIndex = 0;
    if (root.locked) {
      pass.clear();
      passError.text = "";
      root.checkStaleServe();
    }
    root.controller.show();
    idleTimer.restart();
    // Focus after the popout surface is fully mapped (KeyboardPanel primes
    // focus the same way); a direct forceActiveFocus before the map lands.
    Qt.callLater(function () {
      if (root.opened) (root.locked ? pass : search).forceActiveFocus();
    });
  }

  function close() {
    root.controller.hide();
  }

  function showToast(t, closes) {
    toast.text = t;
    toastCloses = closes === true;
    toastTimer.restart();
  }

  function api(path, cb) {
    const xhr = new XMLHttpRequest();
    xhr.open("GET", root.apiBase + path);
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return;
      let env = null;
      try { env = JSON.parse(xhr.responseText); } catch (e) {}
      if (xhr.status === 200 && env && env.success) cb(env.data, null);
      else cb(null, (env && env.message) ? env.message : ("http " + xhr.status));
    };
    xhr.send();
  }

  // Copy: secret reaches wl-copy via stdin only. Auto-clear after 45s only
  // if the clipboard still holds this exact secret (wl-paste --no-newline).
  function copySecret(name, secret, field) {
    copyProc.stdinEnabled = true;
    copyProc.exec({ command: ["wl-copy", "--sensitive"] });
    copyProc.write(secret);
    copyProc.stdinEnabled = false; // EOF: wl-copy forks its serving child
    clearProc.environment = ({ S: secret });
    clearProc.exec(["/bin/sh", "-c", "sleep 45; [ \"$(wl-paste --no-newline)\" = \"$S\" ] && exec wl-copy --clear"]);
    showToast("copied \u2713 " + name + (field ? " \u00b7 " + field : ""), true);
  }

  function copyField(name) {
    const it = root.filtered[list.currentIndex];
    if (!it) return;
    const label = root.fieldNames[root.fieldSel];
    let secret = "";
    if (root.fieldSel === 0) secret = it.username;
    else if (root.fieldSel === 1) secret = it.password;
    else secret = it.totp ? Totp.code(it.totp) : "";
    if (!secret) {
      showToast("no " + label + " on " + name);
      return;
    }
    root.copySecret(name, secret, label);
  }

  function expandOrCopy() {
    if (root.expandedIndex < 0) {
      root.fieldSel = 1;
      root.expandedIndex = list.currentIndex;
    } else {
      root.copyField(root.filtered[list.currentIndex].name);
    }
  }

  function generate(kind) {
    genProc.environment = (kind === "phrase")
      ? { A: "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789", N: "10" }
      : { A: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*_=+?-", N: "20" };
    genProc.running = true;
  }

  // real entry: submit password from the field
  function submitUnlock() {
    const pw = pass.text;
    pass.text = "";
    root.busy = true;
    passError.text = "unlocking — deriving key…";
    unlockProc.environment = ({ BW_PANEL_PW: pw });
    showToast("unlocking…");
    unlockProc.running = true;
  }

  function unlockFinished(exitCode, out) {
    const key = (out || "").trim();
    if (!/^[A-Za-z0-9+/=_-]{32,}$/.test(key)) {
      passError.text = "wrong master password — try again";
      pass.forceActiveFocus();
      root.busy = false;
      return;
    }
    root.sessionKey = key;
    serveProc.environment = ({ BW_SESSION: key });
    root.statusAttempts = 0;
    passError.text = "unlocking — starting vault…";
    serveProc.running = true;
    statusTimer.restart();
  }

  function pollStatus() {
    root.statusAttempts++;
    if (root.statusAttempts > 200) {
      statusTimer.stop();
      root.busy = false;
      passError.text = "bw serve failed to start — try again";
      showToast("bw serve did not come up on :8087");
      return;
    }
    root.api("/status", function (data) {
      if (data && data.template && data.template.status === "unlocked") {
        statusTimer.stop();
        root.openVault();
      }
    }); // transport errors while starting: keep polling
  }

  function openVault() {
    root.api("/list/object/items", function (data, err) {
      if (err || !data || !data.data) {
        showToast("item list failed: " + (err || "empty"));
        return;
      }
      root.items = data.data
        .filter(function (it) { return it.type === 1 && it.login; })
        .map(function (it) {
          return {
            id: it.id,
            name: it.name || "(unnamed)",
            username: it.login.username || "",
            password: it.login.password || "",
            totp: it.login.totp || ""
          };
        })
        .sort(function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
      root.busy = false;
      root.locked = false;
      root.expandedIndex = -1;
      root.query = "";
      search.clear();
      list.currentIndex = 0;
      search.forceActiveFocus();
    });
  }

  function checkStaleServe() {
    // The panel owns :8087. Any bw serve answering while we are locked is
    // stale (orphaned by a shell restart, or foreign) and still holds the
    // vault open without any key — kill it, then show the unlock card.
    root.api("/status", function (data, err) {
      if (err) return; // port free -> normal unlock path
      showToast("stale bw serve on :8087 killed — unlock to continue");
      portKillProc.running = true;
    });
  }

  function lockVault(hide) {
    root.locked = true;
    root.items = [];
    root.query = "";
    root.expandedIndex = -1;
    root.sessionKey = ""; // key gone with the serve child
    serveProc.running = false; // SIGTERM; managed child must never outlive the key
    portKillProc.running = true; // orphans (shell restarted under us) die by port
    root.busy = false;
    if (hide) root.close();
    else { pass.clear(); pass.forceActiveFocus(); }
  }

  Process {
    id: copyProc
  }

  Process {
    id: clearProc
  }

  Process {
    id: unlockProc
    command: ["/usr/bin/bw", "unlock", "--passwordenv", "BW_PANEL_PW", "--raw"]
    stdout: StdioCollector {
      onStreamFinished: root.unlockFinished(unlockProc.exitCode, text)
    }
    stderr: StdioCollector {
      onStreamFinished: console.log("bw unlock stderr: " + text)
    }
  }

  Process {
    id: serveProc
    command: ["/usr/bin/bw", "serve", "--hostname", "127.0.0.1", "--port", "8087", "--disable-origin-protection"]
    onExited: {
      if (!root.locked) {
        root.showToast("bw serve exited — locking");
        root.lockVault(false);
      }
    }
  }


  Process {
    id: portKillProc
    // fuser (port match, not cmdline) so this never pkills its own shell.
    command: ["/bin/sh", "-c", "fuser -k 8087/tcp >/dev/null 2>&1 || true"]
  }
  Process {
    id: genProc
    command: ["/bin/sh", "-c", "tr -dc \"$A\" < /dev/urandom | head -c \"$N\""]
    stdout: StdioCollector {
      onStreamFinished: {
        const label = genProc.environment.N === "10" ? "generated phrase" : "generated password";
        const secret = text.trim();
        if (secret.length > 0) root.copySecret(label, secret, "");
      }
    }
  }

  Timer {
    id: statusTimer
    interval: 300
    repeat: true
    onTriggered: root.pollStatus()
  }

  Timer {
    id: idleTimer // 15 min idle -> lock
    interval: 900000
    onTriggered: root.lockVault(false)
  }
  Timer {
    id: toastTimer
    interval: 900

    onTriggered: {
      toast.text = "";
      if (root.toastCloses) root.close(); // close-on-copy
      root.toastCloses = false;
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // The standalone panel was a dead-center modal over a fullscreen
    // PanelWindow; the popout equivalent is the kit's centerOnBar placement:
    // card centered on the bar axis, below it. No new window type invented.
    centerOnBar: true
    focusTarget: root.locked ? pass : search
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(Style.space(420))

    Column {
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        id: title
        text: "omarchy - bitwarden"
        color: Color.accent
        font.pixelSize: 13
        font.weight: Font.DemiBold
        font.letterSpacing: 1.5
      }

      TextField {
        id: pass
        width: parent.width
        visible: root.locked
        password: true
        placeholderText: "master password…"
        onTextChanged: passError.text = ""

        Keys.onPressed: (event) => {
          if ((event.key === Qt.Key_G) && (event.modifiers & Qt.ControlModifier)) {
            root.generate("password");
            event.accepted = true;
          } else if ((event.key === Qt.Key_P) && (event.modifiers & Qt.ControlModifier)) {
            root.generate("phrase");
            event.accepted = true;
          }
        }
        Keys.onReturnPressed: root.submitUnlock()
        Keys.onEnterPressed: root.submitUnlock()
        Keys.onEscapePressed: root.close()
      }

      Text {
        id: passError
        width: parent.width
        visible: root.locked && text.length > 0
        text: ""
        color: root.busy ? Color.foreground : Color.urgent
        font.pixelSize: 12
      }

      Rectangle {
        id: unlockBar
        width: parent.width
        height: 3
        radius: 1.5
        visible: root.locked && root.busy
        color: Qt.alpha(Color.muted, 0.2)
        clip: true

        Rectangle {
          id: unlockBarFill
          width: parent.width * 0.3
          height: parent.height
          radius: 1.5
          color: Color.accent

          SequentialAnimation on x {
            running: root.locked && root.busy
            loops: Animation.Infinite

            NumberAnimation { from: -unlockBarFill.width; to: unlockBar.width; duration: 900 }
            PauseAnimation { duration: 150 }
          }
        }
      }

      Text {
        width: parent.width
        visible: root.locked
        text: "vault locked · enter unlocks · ctrl+g/ctrl+p generate · esc closes"
        color: Color.muted
        font.pixelSize: 12
      }

      TextField {
        id: search
        visible: !root.locked
        width: parent.width
        placeholderText: "search items…  ·  ctrl+l locks · ctrl+g/ctrl+p generate"

        onTextChanged: root.query = text

        Keys.onPressed: (event) => {
          idleTimer.restart();
          if ((event.key === Qt.Key_L) && (event.modifiers & Qt.ControlModifier)) {
            root.lockVault(true);
            event.accepted = true;
          } else if ((event.key === Qt.Key_G) && (event.modifiers & Qt.ControlModifier)) {
            root.generate("password");
            event.accepted = true;
          } else if ((event.key === Qt.Key_P) && (event.modifiers & Qt.ControlModifier)) {
            root.generate("phrase");
            event.accepted = true;
          }
        }

        Keys.onDownPressed: {
          root.expandedIndex = -1;
          list.incrementCurrentIndex();
        }
        Keys.onUpPressed: {
          root.expandedIndex = -1;
          list.decrementCurrentIndex();
        }
        Keys.onLeftPressed: if (root.expandedIndex >= 0 && root.fieldSel > 0) root.fieldSel--
        Keys.onRightPressed: if (root.expandedIndex >= 0 && root.fieldSel < 2) root.fieldSel++
        Keys.onReturnPressed: if (list.currentItem) root.expandOrCopy()
        Keys.onEnterPressed: if (list.currentItem) root.expandOrCopy()
        Keys.onEscapePressed: {
          if (root.expandedIndex >= 0) root.expandedIndex = -1;
          else root.close();
        }
      }

      ListView {
        id: list
        visible: !root.locked
        width: parent.width
        height: parent.height - title.height - search.height - parent.spacing * 2
        clip: true
        model: root.filtered
        currentIndex: 0
        spacing: Style.space(4)

        delegate: Rectangle {
          id: itemCard
          width: list.width
          height: root.expandedIndex === index ? 96 : 46
          radius: 8
          color: ListView.isCurrentItem ? Qt.alpha(Color.accent, 0.12) : "transparent"
          border.color: ListView.isCurrentItem ? Color.accent : Color.muted
          border.width: 1

          Behavior on height {
            NumberAnimation { duration: 80 }
          }

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(3)

            Text {
              text: modelData.name
              color: Color.foreground
              font.pixelSize: 14
              font.weight: Font.Medium
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: modelData.username || "—"
              color: Color.muted
              font.pixelSize: 12
              elide: Text.ElideRight
              width: parent.width
              visible: root.expandedIndex !== index
            }

            Text {
              visible: root.expandedIndex === index && modelData.totp !== ""
              text: "one-time key " + Totp.code(modelData.totp)
              color: Color.accent
              font.pixelSize: 13
              font.family: "monospace"
            }

            Row {
              spacing: Style.space(6)
              visible: root.expandedIndex === index

              Repeater {
                model: root.fieldNames

                delegate: Rectangle {
                  id: chip
                  property bool selected: root.fieldSel === chipIndex
                  readonly property int chipIndex: index
                  width: chipLabel.implicitWidth + Style.space(16)
                  height: 26
                  radius: 6
                  color: selected ? Color.accent : Qt.alpha(Color.muted, 0.15)

                  Text {
                    id: chipLabel
                    anchors.centerIn: parent
                    text: modelData
                    color: selected ? Color.background : Color.foreground
                    font.pixelSize: 12
                  }

                  TapHandler {
                    onTapped: {
                      root.fieldSel = chip.chipIndex;
                      root.copyField(itemCard.modelData.name);
                    }
                  }
                }
              }
            }
          }

          TapHandler {
            onTapped: {
              list.currentIndex = index;
              root.expandOrCopy();
            }
          }
        }
      }
    }

    Text {
      id: lockSwitch
      visible: !root.locked
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(14)
      text: "lock"
      color: Color.muted
      font.pixelSize: 12

      TapHandler {
        onTapped: root.lockVault(true)
      }
    }

    Text {
      id: toast
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.margins: Style.space(14)
      text: ""
      color: Color.accent
      font.pixelSize: 13
    }
  }
}
