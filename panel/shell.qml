import QtQuick
import QtQuick.Controls.Basic
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "file:/usr/share/omarchy/shell/Commons"
import "totp.js" as Totp

// omabitwarden: keyboard-first vault panel over `bw serve`.
// Toggle: `qs -p <this dir> ipc call bw toggle`
// Unlock: bw unlock --passwordenv BW_PANEL_PW --raw (master password via env,
// never argv) -> session key memory-only -> managed bw serve child (BW_SESSION
// env) -> GET /status poll -> one GET /list/object/items (full items: password,
// totp seed included) -> everything else client-side. GET-only, no Origin
// header, serve dies with the shell. Clipboard: wl-copy --sensitive via stdin,
// 45s auto-clear guarded by wl-paste compare.

ShellRoot {
    id: root

    property bool locked: true
    property bool attached: false // serve we did NOT spawn (pre-running); never killed by us
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

    function checkAttach() {
        // A serve already answering unlocked on :8087 (user-started, or panel
        // reloaded mid-session): adopt it. We never kill a serve we didn't spawn.
        root.api("/status", function (data, err) {
            if (err) return; // no serve -> normal unlock path
            if (data && data.template && data.template.status === "unlocked") {
                root.attached = true;
                root.openVault();
            } else {
                showToast("another bw serve holds :8087 (locked) — kill it first");
            }
        });
    }

    function lockVault(hide) {
        root.locked = true;
        root.attached = false;
        root.items = [];
        root.query = "";
        root.expandedIndex = -1;
        root.sessionKey = ""; // key gone with the serve child
        serveProc.running = false; // SIGTERM; managed child must never outlive the key
        root.busy = false;
        if (hide) panel.visible = false;
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
            if (!root.locked && !root.attached) {
                root.showToast("bw serve exited — locking");
                root.lockVault(false);
            }
        }
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

    IpcHandler {
        target: "bw"

        function toggle(): void {
            panel.visible = !panel.visible;
        }

        function lock(): void {
            root.lockVault(true);
        }

        function status(): string {
            return root.locked ? "locked" : "unlocked";
        }
    }

    // Omarchy theme switcher replaces the whole current/theme dir (kills any
    // watch under it) and pushes new colors via IPC to the bar instance only.
    // It does rewrite current/theme.name in place — watch that instead.
    FileView {
        path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            Color.colorsFile.reload();
            Color.shellFile.reload();
        }
        onLoadFailed: {}
    }

    PanelWindow {
        id: panel
        visible: false
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusiveZone: -1
        color: "transparent"
        // Vault overlay appears on the focused monitor, not the launch-time default.
        screen: {
            const m = Hyprland.focusedMonitor;
            const l = Quickshell.screens;
            for (let i = 0; i < l.length; i++) if (l[i].name === (m ? m.name : "")) return l[i];
            return null;
        }

        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "omabitwarden"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        onVisibleChanged: {
            if (!visible) return;
            idleTimer.restart();
            root.expandedIndex = -1;
            root.query = "";
            search.clear();
            list.currentIndex = 0;
            if (root.locked) {
                pass.clear();
                passError.text = "";
                pass.forceActiveFocus();
                root.checkAttach();
            } else {
                search.forceActiveFocus();
            }
        }

        Rectangle {
            anchors.fill: parent
            color: "transparent"

            TapHandler {
                onTapped: panel.visible = false
            }
        }

        Rectangle {
            id: card
            anchors.centerIn: parent
            width: 560
            height: 420
            radius: 12
            color: Color.background
            border.color: Color.muted
            border.width: 1

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

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
                    placeholderText: "master password…"
                    echoMode: TextInput.Password
                    font.pixelSize: 16
                    color: Color.foreground
                    placeholderTextColor: Color.muted
                    onTextChanged: passError.text = ""
                    background: Rectangle {
                        radius: 8
                        color: Qt.alpha(Color.muted, 0.15)
                        border.color: passError.text.length > 0 ? Color.urgent : (pass.activeFocus ? Color.accent : Color.muted)
                        border.width: 1
                    }

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
                    Keys.onEscapePressed: panel.visible = false
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
                    font.pixelSize: 16
                    color: Color.foreground
                    placeholderTextColor: Color.muted
                    background: Rectangle {
                        radius: 8
                        color: Qt.alpha(Color.muted, 0.15)
                        border.color: search.activeFocus ? Color.accent : Color.muted
                        border.width: 1
                    }

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
                        else panel.visible = false;
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
                    spacing: 4

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
                            anchors.margins: 8
                            spacing: 3

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
                                spacing: 6
                                visible: root.expandedIndex === index

                                Repeater {
                                    model: root.fieldNames

                                    delegate: Rectangle {
                                        id: chip
                                        property bool selected: root.fieldSel === chipIndex
                                        readonly property int chipIndex: index
                                        width: chipLabel.implicitWidth + 16
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

                        HoverHandler {
                            id: hover
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
                anchors.margins: 14
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
                anchors.margins: 14
                text: ""
                color: Color.accent
                font.pixelSize: 13
            }

            Timer {
                id: toastTimer
                interval: 900
                onTriggered: {
                    toast.text = "";
                    if (root.toastCloses) panel.visible = false; // close-on-copy
                    root.toastCloses = false;
                }
            }
        }
    }

    onQueryChanged: list.currentIndex = 0
}
