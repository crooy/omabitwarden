import QtQuick
import Quickshell.Io
import qs.Ui

// Bar lock icon for the omabitwarden vault panel.
//
// Left click toggles the vault panel, right click locks. The vault state
// (locked/busy) lives in Panel.qml; the bar only mirrors `locked` here for
// the glyph and the IPC status readback.
//
// Glyph: padlock-closed \uF023 while locked, padlock-open \uF09C while
// unlocked, painted by BarIconButton — the kit's WidgetButton+OpticalGlyph
// icon button, so sizing/centering follow every other bar icon (no bespoke
// sizing). Locked is shown dimmed via the button's own `dimmed` flag
// (kit-wide 0.45 opacity); unlocked runs at full foreground.
//
// Shape contract for shell summon/hide/toggle routing (clock precedent):
// Bar.findPanelWidget requires open/close/opened on the bar-widget root,
// and Bar.requestPopout prefers closeForPopoutSwitch over close while
// KeyboardPanel reads popoutSwitchClosing back off its owner.
BarWidget {
  id: root
  moduleName: "crooy.omabitwarden"

  readonly property bool locked: panelLoader.item ? panelLoader.item.locked : true

  // ---- Shape contract for shell popout routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function lock() {
    if (panelLoader.item) panelLoader.item.lockVault(true)
  }


  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity, same as the clock widget.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // IPC target is the short id "omabitwarden", matching the standalone
  // shell's keybind muscle memory (was "bw" there). The widget owns the
  // handler; the panel runs with manageIpc:false (clock precedent).
  IpcHandler {
    target: "omabitwarden"

    function toggle(): void { root.togglePanel() }

    function lock(): void { root.lock() }

    function status(): string {
      return root.locked ? "locked" : "unlocked"
    }

    function setPlacement(mode: string): string {
      if (panelLoader.item && panelLoader.item.setPlacement(mode)) return "placement: " + mode
      return "error: placement must be icon|centered|window"
    }

    function getPlacement(): string {
      return panelLoader.item ? panelLoader.item.placement : "window"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.locked ? "\uF023" : "\uF09C"
    dimmed: root.locked
    tooltipText: "Bitwarden"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.lock()
      else root.togglePanel()
    }
  }
}
