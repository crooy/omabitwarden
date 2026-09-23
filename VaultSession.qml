import QtQuick
import Quickshell.Io

// Vault session: the Unlock state machine. Derives the Session Key from the
// master password, loads the Vault's login Items with one `bw list items`
// child, and exposes the result as state. Owns no rendering: the panel binds
// to phase/items/statusText and forwards user actions.
//
// Interface:
//   unlock(password)  — one attempt; watch `phase` and `statusText`
//   lock()            — drop key + Items, kill children
//   clearStatus()     — panel calls this on reopen so an old failure
//                       message does not greet the next attempt
//   sync()            — ready only: `bw sync`, then re-list Items; watch
//                       `syncing`/`syncFailed` (stale Items survive a
//                       failed refresh — the vault never locks on sync)
//   items             — login Items: {id, name, username, password, totp}
//   statusText        — stage message or last failure ("" when none)
//   phase             — "locked" | "unlocking" | "ready"
//
// Implementation (all hidden from the panel):
// - bw is resolved on PATH at mount (~/.local/bin here), never hardcoded.
// - an inherited desktop BW_SESSION is scrubbed (null removes it) before
//   `bw unlock`; secrets travel via env/stdin, never argv.
// - a failed item load retries once, then lands on a clean locked state;
//   a hung child never holds "unlocking" past its watchdog, and the
//   watchdog's own SIGTERM completion is swallowed, not counted as failure.
Item {
  id: root

  property string phase: "locked" // "locked" | "unlocking" | "ready"
  property var items: []
  property string statusText: ""
  property int listAttempts: 0
  property bool listKilled: false // our own watchdog SIGTERM's exited(15) is not a failure
  property bool listBusy: false // a list child is in flight (unlock load or sync refresh)
  property bool listIsRefresh: false // refresh failures keep the vault open with stale Items
  property bool syncing: false
  property bool syncFailed: false
  property bool bwFound: false
  property string sessionKey: "" // memory only, never argv/URL/disk
  property string bwPath: "/usr/bin/bw" // corrected at mount; this install's bw lives in ~/.local/bin
  property int listTimeoutMs: 60000 // overridable so a stub-bw test can exercise the watchdog fast

  Component.onCompleted: {
    portKillProc.running = true; // orphaned serve from the old design (or foreign) dies by port
    bwLocateProc.running = true; // PATH-lookup beats a hardcoded prefix
  }

  function unlock(password) {
    if (root.phase === "unlocking") return;
    if (!root.bwFound) { // locate already knows bw is absent; no 60s watchdog for that
      root.statusText = "bw not found — install the Bitwarden CLI";
      return;
    }
    root.statusText = "unlocking — deriving key…";
    root.phase = "unlocking";
    unlockProc.environment = ({ BW_PANEL_PW: password, BW_SESSION: null }); // null removes any inherited desktop session
    unlockWatchdog.restart();
    unlockProc.running = true;
  }

  function clearStatus() {
    if (root.phase === "locked") root.statusText = "";
  }

  function lock() {
    root.phase = "locked";
    root.items = [];
    root.sessionKey = ""; // key lives only for the bw calls it serves
    root.syncing = false;
    root.listBusy = false;
    unlockProc.running = false; // a stale completion must never be consumed by the next attempt
    syncProc.running = false;
    listProc.running = false; // SIGTERM; a dead session's answer is refused by the busy guard
    listWatchdog.stop();
    listRetryTimer.stop();
    syncWatchdog.stop();
    root.statusText = "";
  }

  function sync() {
    if (root.phase !== "ready" || root.syncing || root.listBusy) return;
    root.syncing = true;
    root.syncFailed = false;
    syncWatchdog.restart();
    syncProc.running = true;
  }

  function unlockFinished(exitCode, out) {
    if (root.phase !== "unlocking") return; // abandoned attempt (lock or watchdog)
    unlockWatchdog.stop();
    const key = (out || "").trim();
    console.log("omabitwarden: bw unlock exit=" + exitCode + " keylen=" + key.length);
    if (!/^[A-Za-z0-9+/=_-]{32,}$/.test(key)) {
      root.statusText = "wrong master password — try again";
      root.phase = "locked";
      return;
    }
    root.sessionKey = key;
    root.listAttempts = 0;
    root.statusText = "unlocking — loading vault…";
    root.openVault();
  }

  function openVault() {
    root.listBusy = true;
    root.listIsRefresh = false;
    listProc.environment = ({ BW_SESSION: root.sessionKey });
    listWatchdog.restart();
    listProc.running = true;
  }

  function onListFinished(exitCode, out) {
    if (root.listKilled) { root.listKilled = false; return; } // our watchdog SIGTERM's exited(15)
    if (!root.listBusy) return; // stale answer: lock landed, child killed, or nobody waiting
    listWatchdog.stop();
    console.log("omabitwarden: bw list exit=" + exitCode + " len=" + (out || "").length);
    if (exitCode !== 0) { root.listFailed("bw exited " + exitCode); return; }
    let arr = null;
    try { arr = JSON.parse(out); } catch (e) {}
    if (!Array.isArray(arr)) { root.listFailed("unparsable item list (len " + (out || "").length + ")"); return; }
    root.items = arr
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
    root.listBusy = false;
    if (root.listIsRefresh) {
      root.listIsRefresh = false; // phase stays "ready": the panel keeps its list position
      root.syncing = false; // the sync run ends here; syncFailed stays false
      return;
    }
    root.statusText = "";
    root.phase = "ready";
  }

  function listFailed(err) {
    // Refresh: fail soft — keep the vault open with the stale Items.
    if (root.listIsRefresh) {
      root.listBusy = false;
      root.listIsRefresh = false;
      root.syncFailed = true; // set BEFORE syncing=false: syncingChanged observers must see settled state
      root.syncing = false;
      console.warn("omabitwarden: vault sync failed: " + err);
      return;
    }
    // Unlock load: one clean retry, then a clean locked state — never a
    // stuck busy card.
    root.listAttempts++;
    if (root.listAttempts < 2) { listRetryTimer.restart(); return; }
    lock(); // clears statusText; the failure message is set after
    root.statusText = "vault did not load — unlock again";
    console.warn("omabitwarden: item list failed: " + err);
  }

  Process {
    id: bwLocateProc
    command: ["sh", "-c", "command -v bw || true"]
    stdout: StdioCollector {
      onStreamFinished: {
        const p = text.trim();
        if (p) { root.bwPath = p; root.bwFound = true; }
        else console.warn("omabitwarden: bw not found on PATH — unlock will fail");
      }
    }
  }

  Process {
    id: portKillProc
    // Mount-time sweep only: with no serve of our own, anything on :8087 is
    // an orphan from the old design (or foreign) and holds the vault open.
    // fuser (port match, not cmdline) so this never pkills its own shell.
    command: ["/bin/sh", "-c", "fuser -k 8087/tcp >/dev/null 2>&1 || true"]
  }

  Process {
    id: unlockProc
    command: [root.bwPath, "unlock", "--passwordenv", "BW_PANEL_PW", "--raw"]
    // waitForEnd + onExited: stdout EOF can beat the recorded exit code,
    // so onStreamFinished would race a stale 0 into unlockFinished.
    stdout: StdioCollector {
      id: unlockStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      onStreamFinished: console.log("bw unlock stderr: " + text)
    }
    onExited: function (exitCode) {
      root.unlockFinished(exitCode, unlockStdout.text);
    }
  }

  Process {
    id: syncProc
    command: [root.bwPath, "sync", "--nointeraction"]
    environment: ({ BW_SESSION: root.sessionKey })
    stderr: StdioCollector {
      onStreamFinished: console.log("bw sync stderr: " + text)
    }
    onExited: function (exitCode) {
      console.log("omabitwarden: bw sync exit=" + exitCode);
      if (!root.syncing) return; // lock or watchdog landed first
      syncWatchdog.stop();
      if (exitCode !== 0) {
        root.syncFailed = true; // set BEFORE syncing=false: syncingChanged observers must see consistent state
        root.syncing = false;
        return;
      }
      root.listAttempts = 0; // fresh ladder for the post-sync re-list
      root.openVault();
      root.listIsRefresh = true; // openVault clears it; set after
    }
  }

  Process {
    id: listProc
    command: [root.bwPath, "list", "items", "--nointeraction"]
    stdout: StdioCollector {
      id: listStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      onStreamFinished: console.log("bw list stderr: " + text)
    }
    onExited: function (exitCode) {
      root.onListFinished(exitCode, listStdout.text);
    }
  }

  Timer {
    id: listWatchdog
    interval: root.listTimeoutMs
    onTriggered: {
      console.log("omabitwarden: bw list watchdog fired (busy=" + root.listBusy + ")");
      if (!root.listBusy) return;
      root.listKilled = true; // the SIGTERM below still fires onExited(15) — swallow it
      listProc.running = false;
      root.listFailed("timed out");
    }
  }

  Timer {
    id: listRetryTimer
    interval: 1000
    onTriggered: if (root.listBusy) root.openVault()
  }

  Timer {
    id: syncWatchdog
    interval: 120000 // bw sync hits the network; twice the list budget
    onTriggered: {
      if (!root.syncing) return;
      syncProc.running = false;
      root.syncFailed = true; // set BEFORE syncing=false: same observer-ordering rule as the exit path
      root.syncing = false;
    }
  }

  Timer {
    id: unlockWatchdog
    interval: 60000 // bw unlock (Argon2 KDF) is seconds-scale; a hung child is an error
    onTriggered: {
      if (root.phase !== "unlocking") return;
      unlockProc.running = false; // kill a hung bw unlock; its late callback is guarded
      root.statusText = "unlock timed out — try again";
      root.phase = "locked";
    }
  }
}
