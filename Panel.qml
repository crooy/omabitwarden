import QtQuick
import Quickshell
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
// Ported from the standalone shell (panel/shell.qml). Three placement modes
// (bar-layout entry settings.placement, anything else normalizes to the
// default "window"):
//   "icon"     - popout card under the widget's bar icon (KeyboardPanel).
//   "centered" - popout card centered on the bar axis (KeyboardPanel's
//                centerOnBar): the standalone dead-center modal's closest
//                native position.
//   "window"   - (default) two real toplevels built with
//                Quickshell.FloatingWindow (gallery precedent: children of
//                the panel root). The locked card lives in a small
//                temporary floating window ("omabitwarden", float + center
//                via Hyprland rules, never pinned); the unlocked vault
//                lives in its own larger window ("omabitwarden vault",
//                float + center initially, SUPER+T un-floats it, own size
//                and float state). Persistent while open - no outside-
//                click dismissal, copy toasts don't close either; Esc
//                closes, SUPER+W closes.
// Popout modes take outside-click dismissal and focus priming from
// KeyboardPanel; Esc/close and the Ctrl+G/Ctrl+P/Ctrl+L shortcuts stay on
// the fields, so no PanelKeyCatcher - its Keys.BeforeItem priority would
// steal the list-arrow keys from the search field.
//
// The standalone theme.name FileView watcher is dropped: qs.Commons.Color is
// a shared singleton the shell host live-follows; the clock/audio panels
// don't watch theme files either.
Panel {
  id: root
  moduleName: "crooy.omabitwarden"

  // Orphaned bw serve from a previous shell instance dies at plugin mount:
  // it holds the vault open without any key (see checkStaleServe).
  Component.onCompleted: {
    root.checkStaleServe();
    root.popoutHolder = contentCol.parent; // KeyboardPanel host, captured before any reparenting
    root.applyPlacement();
    root.ensureHyprRules();
  }
  ipcTarget: "omabitwarden"
  manageIpc: false // IpcHandler lives in BarWidget.qml

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel (clock precedent): popout coordination identifies panels by
  // the slot item.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  // ---- Placement modes ("icon" | "centered" | "window"; default window)
  readonly property string placement: {
    const p = String(root.setting("placement", "window"));
    return (p === "icon" || p === "centered") ? p : "window";
  }
  readonly property real winInset: Style.spacing.popupPadding + Style.space(2)
  property Item popoutHolder: null // KeyboardPanel content host, captured at mount
  property bool hyprRulesApplied: false

  onSettingsChanged: Qt.callLater(root.applyPlacement) // settings land after mount
  onLockedChanged: Qt.callLater(root.applyPlacement) // swap card between window hosts

  // Single card instance (contentCol + lockSwitch + toast) re-parented
  // between the KeyboardPanel host and the two window hosts: pwBody while
  // locked, mainBody once unlocked. One instance keeps every id/function
  // (pass, search, toast, genProc, ...) valid.
  function applyPlacement() {
    if (!root.popoutHolder) return; // captured at mount; settings may arrive first
    let target = root.popoutHolder;
    if (root.placement === "window") target = root.locked ? pwBody : mainBody;
    if (contentCol.parent === target) return;
    contentCol.parent = target;
    lockSwitch.parent = target;
    toast.parent = target;
    if (root.opened) Qt.callLater(function () {
      (root.locked ? pass : search).forceActiveFocus();
    });
  }

  // Live placement switch, persisted like the clock's persistSettings.
  function setPlacement(mode) {
    const p = (mode === "icon" || mode === "centered" || mode === "window") ? mode : "";
    if (!p) return "";
    var entry = { id: root.moduleName };
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing];
    entry.placement = p;
    root.settings = entry;
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry;
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry);
    return p;
  }

  // Floating/centered rules for both window-mode toplevels (no pin: the
  // card stays a temporary floating thing; the vault window keeps its own
  // float state), applied once per shell session; duplicate rule calls
  // across restarts are harmless.
  function ensureHyprRules() {
    if (root.hyprRulesApplied) return;
    root.hyprRulesApplied = true;
    hyprRulesProc.running = true;
  }

  // ---- Vault state (ported verbatim from the standalone shell)
  property bool locked: true
  property string sessionKey: "" // memory only, never argv/URL/disk
  property var items: []
  property string query: ""
  property int expandedIndex: -1
  property int fieldSel: 1
  property var fieldNames: ["username", "password", "one-time key"]
  property int statusAttempts: 0
  property int itemAttempts: 0 // /list/object/items retry counter after "unlocked"
  property bool toastCloses: false // only copy-toasts close the panel
  property bool busy: false // unlock in flight: bar + status message
  property bool revealPw: false // master password shown in cleartext

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
    root.revealPw = false;
    const pw = pass.text;
    pass.text = "";
    root.busy = true;
    passError.text = "unlocking — deriving key…";
    unlockProc.environment = ({ BW_PANEL_PW: pw });
    showToast("unlocking…");
    unlockWatchdog.restart();
    unlockProc.running = true;
  }

  function unlockFinished(exitCode, out) {
    if (!root.busy) return; // abandoned attempt (lock or unlock watchdog)
    unlockWatchdog.stop();
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
    root.itemAttempts = 0;
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
      if (!root.busy) return; // stale poll from an abandoned attempt
      if (data && data.template && data.template.status === "unlocked") {
        statusTimer.stop();
        root.openVault();
      }
    }); // transport errors while starting: keep polling
  }

  function openVault() {
    root.api("/list/object/items", function (data, err) {
      if (err || !data || !data.data) {
        // A cold bw serve can report "unlocked" before item queries are
        // ready: retry briefly, then land on a clean state instead of a
        // stuck busy card with the error toast already gone.
        root.itemAttempts++;
        if (root.itemAttempts > 120) {
          itemRetryTimer.stop();
          root.busy = false;
          passError.text = "vault did not load — try again";
          showToast("item list failed: " + (err || "empty"));
          root.lockVault(false);
          return;
        }
        itemRetryTimer.restart();
        return;
      }
      itemRetryTimer.stop();
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
    root.revealPw = false;
    root.items = [];
    root.query = "";
    root.expandedIndex = -1;
    root.sessionKey = ""; // key gone with the serve child
    serveProc.running = false; // SIGTERM; managed child must never outlive the key
    portKillProc.running = true; // orphans (shell restarted under us) die by port
    statusTimer.stop(); // a lock during unlock-in-flight must kill the poll
    itemRetryTimer.stop();
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
    id: itemRetryTimer
    interval: 500
    repeat: false
    onTriggered: root.openVault()
  }
  Timer {
    id: unlockWatchdog
    interval: 60000 // bw unlock (Argon2 KDF) is seconds-scale; a hung child is an error
    onTriggered: {
      if (!root.busy) return;
      unlockProc.running = false; // kill a hung bw unlock; its late callback is guarded
      root.busy = false;
      passError.text = "unlock timed out — try again";
      pass.forceActiveFocus();
    }
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
      if (root.toastCloses && root.placement !== "window") root.close(); // close-on-copy; window mode stays open
      root.toastCloses = false;
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened && root.placement !== "window"
    // Popout modes: "icon" = card under the widget's bar icon, "centered" =
    // card centered on the bar axis (the standalone dead-center modal's
    // closest native position). In "window" mode this host stays in the
    // tree but dormant; the card re-parents into the FloatingWindow.
    centerOnBar: root.placement === "centered" || !root.anchorItem
    focusTarget: root.locked ? pass : search
    contentWidth: panel.fittedContentWidth(Style.space(root.locked ? 360 : 560))
    contentHeight: panel.fittedContentHeight(root.locked ? contentCol.implicitHeight : Style.space(420))

    Column {
      id: contentCol
      anchors.fill: parent
      spacing: Style.space(8)

      PanelSectionHeader {
        id: title
        width: parent.width
        text: root.locked ? "VAULT LOCKED" : "BITWARDEN"
      }

      PanelSeparator {}

      TextField {
        id: pass
        width: parent.width
        visible: root.locked
        password: true
        enabled: !root.busy
        echoMode: root.revealPw ? TextInput.Normal : TextInput.Password
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
        id: revealLabel
        visible: root.locked
        text: root.revealPw ? "\uF06E  hide password" : "\uF06D  show password"
        color: root.revealPw ? Color.accent : Color.muted
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          anchors.margins: -8
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.revealPw = !root.revealPw;
            pass.forceActiveFocus();
          }
        }
      }
      Text {
        id: passError
        width: parent.width
        visible: root.locked && text.length > 0
        text: ""
        color: root.busy ? Color.foreground : Color.urgent
        font.pixelSize: Style.font.caption
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
        visible: root.locked && !root.busy
        text: "enter unlocks   ·   ctrl+g / ctrl+p generate   ·   esc closes"
        color: Color.muted
        font.pixelSize: Style.font.caption
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
        height: parent.height - title.height - search.height - parent.spacing * 3
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

  // Window-mode hosts (gallery precedent: children of the panel root).
  // pwWin: the locked card - a small temporary floating thing (float +
  // center rules, never pinned). mainWin: the unlocked vault - its own
  // real window: separate title, own size, own float state; starts
  // float+centered like the card, SUPER+T un-floats it for a tiled
  // session. Neither is ever pinned.
  FloatingWindow {
    id: pwWin
    visible: root.opened && root.placement === "window" && root.locked
    title: "omabitwarden"
    color: Color.popups.background
    implicitWidth: Style.space(360) + 2 * root.winInset
    implicitHeight: contentCol.implicitHeight + 2 * root.winInset

    // Propagate only a real user close (SUPER+W killactive): during the
    // locked<->unlocked swap the other window is already taking the card.
    onClosed: Qt.callLater(function () {
      if (!pwWin.visible && !mainWin.visible) root.close();
    })

    onVisibleChanged: Qt.callLater(function () {
      if (pwWin.visible && root.locked) pass.forceActiveFocus();
    })

    // Inset host for the re-parented card so lockSwitch/toast (14px
    // margins inside the inset area) keep the popout look.
    Item {
      id: pwBody
      anchors.fill: parent
      anchors.margins: root.winInset
    }
  }

  FloatingWindow {
    id: mainWin
    visible: root.opened && root.placement === "window" && !root.locked
    title: "omabitwarden vault"
    color: Color.popups.background
    implicitWidth: Style.space(560) + 2 * root.winInset
    implicitHeight: Style.space(420) + 2 * root.winInset

    onClosed: Qt.callLater(function () {
      if (!pwWin.visible && !mainWin.visible) root.close();
    })

    onVisibleChanged: Qt.callLater(function () {
      if (mainWin.visible && !root.locked) search.forceActiveFocus();
    })

    Item {
      id: mainBody
      anchors.fill: parent
      anchors.margins: root.winInset
    }
  }

  // The windowrules command run by ensureHyprRules(): Hyprland 0.56+ takes
  // dynamic rules via hl.window_rule through hyprctl eval (legacy
  // windowrulev2 keyword syntax is rejected there). Absent or older
  // hyprctl the window still opens and simply spawns tiled.
  Process {
    id: hyprRulesProc
    command: ["/bin/sh", "-c", "command -v hyprctl >/dev/null 2>&1 || exit 0; for spec in 'omabitwarden' 'omabitwarden vault'; do for r in float center; do hyprctl eval \"hl.window_rule({ match = { title = '$spec' }, $r = true })\" >/dev/null 2>&1; done; done"]
  }
}