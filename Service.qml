import QtQuick
import Quickshell
import Quickshell.Io

// Keeps the fcitx5 candidate-box theme in sync with the current Omarchy theme.
//
// Watching the theme state lets this service react live, without polling, and
// without requiring the theme-set hook (the hook remains a fallback for headless
// theme sets where the shell is not running).
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string themeNamePath: home + "/.local/state/omarchy/current/theme.name"
  readonly property string generator: home + "/.config/omarchy/plugins/gmaxxxie.fcitx5-theme/fcitx5-classicui-theme.sh"

  // Watch the current theme's *name* file, not colors.toml.
  //
  // `omarchy theme set` stages the new theme and then swaps it in with:
  //
  //     rm -rf  current/theme
  //     mv      current/next-theme current/theme
  //     echo "$THEME_NAME" > current/theme.name
  //
  // so every file below current/theme gets a new inode on every theme switch.
  // inotify watches an inode rather than a path, so a watch on colors.toml is
  // left pointing at a deleted file after the first switch and never fires
  // again — the candidate box silently keeps the theme it was generated with.
  //
  // theme.name is rewritten in place (shell truncation keeps the inode) and is
  // written *after* current/theme is swapped in, which makes it both a stable
  // watch target and a correct completion signal: by the time it changes, the
  // new colors.toml is already in place for the generator to read.
  FileView {
    id: themeWatcher
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.sync()
    onLoadFailed: {} // state not present yet; watcher re-fires when it appears
  }

  // Fallback: ensure a sync shortly after shell start even if the state file
  // existed before the shell came up and no change event is guaranteed.
  Timer {
    interval: 5000
    running: true
    repeat: false
    onTriggered: root.sync()
  }

  Process {
    id: syncProc
    command: ["/bin/bash", root.generator, "current", "--quiet"]
    onFailed: console.warn("fcitx5-theme", "sync failed")
  }

  function sync() {
    if (syncProc.running) return
    syncProc.running = true
  }
}
