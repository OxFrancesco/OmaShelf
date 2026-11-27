import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Ui" as ShelfUi

// A file shelf in the bar, after BuddyFiles in BuddyMac. Files stay where
// they live; the shelf keeps references. Drop or paste things in, drag them
// out into any app. shelf.py owns the store and prints the shelf after every
// command; each bar instance watches the manifest so all monitors agree.
Panel {
  id: root
  moduleName: "omashelf"
  ipcTarget: "omashelf"
  manageIpc: false

  property var files: []
  property var selected: []
  property int cursor: -1
  property int anchorIndex: -1
  property string error: ""
  property string query: ""
  property bool cardDragOver: false
  property bool iconDragOver: false
  property bool draggingOut: false
  property bool confirmClear: false
  property var queue: []

  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("shelf.py").toString().replace(/^file:\/\//, ""))
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")
  readonly property string manifestPath: dataHome + "/omashelf/shelf.json"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int columns: 4
  readonly property bool searchable: files.length > 8
  readonly property var shown: {
    var needle = query.toLowerCase()
    if (needle === "") return files
    return files.filter(function(file) { return file.name.toLowerCase().indexOf(needle) >= 0 })
  }
  readonly property bool hasSelection: selected.length > 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- store ---------------------------------------------------------------

  function run(args) {
    queue = queue.concat([args])
    pump()
  }

  function pump() {
    if (helper.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    helper.command = ["python3", "-I", helperPath].concat(next)
    helper.running = true
  }

  function refresh() {
    for (var i = 0; i < queue.length; i++) if (queue[i][0] === "list") return
    run(["list"])
  }

  function accept(next) {
    files = next
    selected = selected.filter(function(path) { return next.some(function(file) { return file.path === path }) })
    if (cursor >= shown.length) cursor = shown.length - 1
  }

  function showError(text) {
    error = text
    errorTimer.restart()
  }

  function addValues(values) {
    var list = values.filter(function(value) { return String(value).trim() !== "" })
    if (list.length) run(["add"].concat(list))
  }

  function dropValues(drop) {
    if (drop.hasUrls && drop.urls.length) return drop.urls.map(function(url) { return url.toString() })
    if (drop.hasText) return [drop.text]
    return []
  }

  function paste() { run(["paste"]) }
  function choose() { run(["choose"]) }
  function targets() { return selected.length ? selected : (cursor >= 0 && cursor < shown.length ? [shown[cursor].path] : []) }
  function openPaths(paths) { if (paths.length) run(["open"].concat(paths)) }
  function copyPaths(paths) { if (paths.length) run(["copy"].concat(paths)) }
  function revealPaths(paths) { if (paths.length) run(["reveal"].concat(paths)) }
  function removePaths(paths) {
    if (!paths.length) return
    selected = selected.filter(function(path) { return paths.indexOf(path) < 0 })
    run(["remove"].concat(paths))
  }
  function clearShelf() {
    if (!confirmClear) { confirmClear = true; clearTimer.restart(); return }
    confirmClear = false
    selected = []
    run(["clear"])
  }

  function toUri(path) {
    return "file://" + path.split("/").map(encodeURIComponent).join("/")
  }

  // --- selection -----------------------------------------------------------

  function isSelected(path) { return selected.indexOf(path) >= 0 }

  function selectAt(index, modifiers) {
    var path = shown[index].path
    if (modifiers & Qt.ShiftModifier && anchorIndex >= 0) {
      var from = Math.min(anchorIndex, index), to = Math.max(anchorIndex, index)
      var range = shown.slice(from, to + 1).map(function(file) { return file.path })
      selected = modifiers & Qt.ControlModifier ? Array.from(new Set(selected.concat(range))) : range
    } else if (modifiers & Qt.ControlModifier) {
      selected = isSelected(path) ? selected.filter(function(p) { return p !== path }) : selected.concat([path])
      anchorIndex = index
    } else {
      selected = [path]
      anchorIndex = index
    }
    cursor = index
  }

  function moveCursor(dx, dy) {
    if (shown.length === 0) return
    var next = cursor < 0 ? 0 : Math.max(0, Math.min(shown.length - 1, cursor + dx + dy * columns))
    selectAt(next, 0)
    scrollTileIntoView(next)
  }

  function scrollTileIntoView(index) {
    var content = panel.loadedContent
    if (!content || !content.grid || index < 0 || index >= content.grid.children.length) return
    var flick = content.flick
    var item = content.grid.children[index]
    Qt.callLater(function() {
      var top = item.mapToItem(flick.contentItem, 0, 0).y
      if (top < flick.contentY) flick.contentY = top
      else if (top + item.height > flick.contentY + flick.height) flick.contentY = top + item.height - flick.height
    })
  }

  // --- process -------------------------------------------------------------

  Process {
    id: helper
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return
        try { root.accept(JSON.parse(raw)) } catch (e) {}
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.showError(message.split("\n").pop())
      }
    }
    onExited: Qt.callLater(root.pump)
  }

  FileView {
    path: root.manifestPath
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); syncTimer.restart() }
  }

  Timer { id: syncTimer; interval: 120; onTriggered: if (!helper.running) root.refresh() }
  Timer { id: errorTimer; interval: 5000; onTriggered: root.error = "" }
  Timer { id: clearTimer; interval: 3000; onTriggered: root.confirmClear = false }
  Timer { id: hoverOpen; interval: 280; onTriggered: if (root.iconDragOver) root.open() }

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    } else {
      query = ""
      confirmClear = false
    }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function paste(): string { root.paste(); return "ok" }
    function add(path: string): string { root.addValues([path]); return "ok" }
  }

  // --- bar icon ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // tray, tray-full, tray-plus
    text: root.iconDragOver ? "\u{F1298}" : root.files.length ? "\u{F1296}" : "\u{F1294}"
    active: root.iconDragOver
    activeColor: root.accent
    tooltipText: root.opened ? "" : "Shelf"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.paste()
      else root.toggle()
    }

    DropArea {
      anchors.fill: parent
      z: 1000
      onEntered: function(drag) {
        if (root.draggingOut) { drag.accepted = false; return }
        drag.accept(Qt.CopyAction)
        root.iconDragOver = true
        hoverOpen.restart()
      }
      onExited: { root.iconDragOver = false; hoverOpen.stop() }
      onDropped: function(drop) {
        root.iconDragOver = false
        hoverOpen.stop()
        root.addValues(root.dropValues(drop))
        drop.accept(Qt.CopyAction)
      }
    }
  }

  // --- popup ---------------------------------------------------------------

  ShelfUi.KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Hands the pointer to the windows below while a file is dragged out, so
    // the drop lands in the app under the cursor instead of this overlay.
    yielding: root.draggingOut
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(392))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      id: keys
      property alias flick: flick
      property alias grid: grid
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      blocked: search.activeFocus

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.openPaths(root.targets())
      onDeleteRequested: root.removePaths(root.targets())
      onCloseRequested: root.hasSelection ? root.selected = [] : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t, modifiers) {
        if (!(modifiers & Qt.ControlModifier)) {
          if (t === "/" && root.searchable) search.forceActiveFocus()
          return
        }
        var key = t.length === 1 && t.charCodeAt(0) < 27 ? String.fromCharCode(t.charCodeAt(0) + 96) : t.toLowerCase()
        if (key === "v") root.paste()
        else if (key === "c") root.copyPaths(root.targets())
        else if (key === "a") root.selected = root.shown.map(function(file) { return file.path })
        else if (key === "o") root.choose()
      }

      DropArea {
        anchors.fill: parent
        z: 1000
        onEntered: function(drag) {
          if (root.draggingOut) { drag.accepted = false; return }
          drag.accept(Qt.CopyAction)
          root.cardDragOver = true
        }
        onExited: root.cardDragOver = false
        onDropped: function(drop) {
          root.cardDragOver = false
          root.addValues(root.dropValues(drop))
          drop.accept(Qt.CopyAction)
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          RowLayout {
            width: parent.width
            spacing: Style.space(4)

            Item {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.spacing.controlHeight
              visible: root.searchable

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.foreground, root.accent)
              }

              TextInput {
                id: search
                anchors.fill: parent
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.controlPaddingX
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                selectionColor: Qt.alpha(root.accent, 0.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                clip: true
                text: root.query
                onTextEdited: root.query = text
                Keys.onEscapePressed: { root.query = ""; keys.forceActiveFocus() }
                Keys.onDownPressed: { keys.forceActiveFocus(); root.moveCursor(0, 0) }
                Keys.onReturnPressed: { keys.forceActiveFocus(); if (root.shown.length) root.openPaths([root.shown[0].path]) }

                Text {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  visible: search.text === ""
                  text: "Find a file"
                  color: root.dim
                  font: search.font
                }
              }
            }

            Item { Layout.fillWidth: true; visible: !root.searchable; Layout.preferredHeight: 1 }

            Action { glyph: "\u{F0192}"; tip: "Paste  Ctrl+V"; shown: !root.hasSelection; onTriggered: root.paste() }
            Action { glyph: "\u{F0415}"; tip: "Add files  Ctrl+O"; shown: !root.hasSelection; onTriggered: root.choose() }
            Action {
              glyph: "\u{F01B4}"
              tip: root.confirmClear ? "Click again to clear" : "Clear shelf"
              shown: !root.hasSelection && root.files.length > 0
              danger: root.confirmClear
              onTriggered: root.clearShelf()
            }
            Action { glyph: "\u{F0770}"; tip: "Show in folder"; shown: root.hasSelection; onTriggered: root.revealPaths(root.selected) }
            Action { glyph: "\u{F018F}"; tip: "Copy  Ctrl+C"; shown: root.hasSelection; onTriggered: root.copyPaths(root.selected) }
            Action { glyph: "\u{F0156}"; tip: "Remove from shelf  Del"; shown: root.hasSelection; onTriggered: root.removePaths(root.selected) }
          }

          Item {
            id: emptyState
            visible: root.shown.length === 0
            width: parent.width
            height: Style.space(150)

            Column {
              anchors.centerIn: parent
              spacing: Style.space(10)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\u{F1294}"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.query !== "" ? "No matching files" : "Drop files here or press Ctrl+V"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Flow {
            id: grid
            visible: root.shown.length > 0
            width: parent.width
            spacing: Style.space(6)
            readonly property real tileWidth: Math.floor((width - spacing * (root.columns - 1)) / root.columns)

            move: Transition {
              NumberAnimation { properties: "x,y"; duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }

            Repeater {
              model: root.shown
              Tile {
                required property var modelData
                required property int index
                file: modelData
                tileIndex: index
                width: grid.tileWidth
              }
            }
          }

          Text {
            visible: root.error !== ""
            width: parent.width
            text: root.error
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }

      // Drop target highlight over the whole card.
      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Qt.tint(Commons.Color.popups.background, Qt.alpha(root.accent, 0.10))
        border.color: root.accent
        border.width: Math.max(1, Style.space(1))
        opacity: root.cardDragOver ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

        Text {
          anchors.centerIn: parent
          text: "\u{F1298}  Drop to add"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }
      }
    }
  }

  component Action: PanelActionButton {
    id: action
    property string glyph: ""
    property string tip: ""
    property bool shown: true
    property bool danger: false
    property bool tipVisible: false
    signal triggered()
    visible: shown
    iconText: glyph
    foreground: danger ? root.urgent : root.foreground
    fontFamily: root.fontFamily
    Layout.alignment: Qt.AlignVCenter
    onClicked: action.triggered()
    onHovered: function(isHovered) { action.tipVisible = isHovered }

    PanelToolTip {
      visible: action.tipVisible && action.tip !== ""
      text: action.tip
      fontFamily: root.fontFamily
    }
  }

  component Tile: CursorSurface {
    id: tile
    property var file: ({})
    property int tileIndex: 0
    readonly property bool chosen: root.isSelected(file.path)
    readonly property string glyph: ({
      image: "\u{F02E9}", video: "\u{F0567}", audio: "\u{F075A}", pdf: "\u{F0226}",
      text: "\u{F0219}", folder: "\u{F024B}", archive: "\u{F05C4}"
    })[file.kind] || "\u{F0214}"
    readonly property string dragUris: (chosen ? root.selected : [file.path]).map(root.toUri).join("\r\n")

    Drag.dragType: Drag.Automatic
    Drag.supportedActions: Qt.CopyAction
    Drag.mimeData: {
      "text/uri-list": dragUris,
      "text/plain": dragUris
    }
    Drag.active: dragOutHandler.active
    Drag.imageSource: file.thumb ? root.toUri(file.thumb) : ""
    Drag.imageSourceSize: Qt.size(Style.space(96), Style.space(96))
    Drag.hotSpot.x: Style.space(24)
    Drag.hotSpot.y: Style.space(24)
    Drag.onDragStarted: root.draggingOut = true
    Drag.onDragFinished: function(action) {
      root.draggingOut = false
      if (action !== Qt.IgnoreAction)
        root.close()
    }

    hasCursor: hoverHandler.hovered || (root.cursor === tileIndex && !chosen)
    current: chosen
    foreground: root.foreground
    implicitHeight: content.implicitHeight + Style.space(12)
    opacity: file.exists ? 1 : 0.45
    scale: 0.94

    Component.onCompleted: appear.start()
    ParallelAnimation {
      id: appear
      NumberAnimation { target: tile; property: "scale"; to: 1; duration: Style.duration(200); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    Column {
      id: content
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - Style.space(12)
      spacing: Style.space(6)

      Item {
        id: preview
        width: parent.width
        height: width

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: Qt.alpha(root.foreground, 0.06)
          visible: thumb.status !== Image.Ready
        }

        Image {
          id: thumb
          anchors.fill: parent
          source: tile.file.thumb ? root.toUri(tile.file.thumb) : ""
          sourceSize.width: Math.round(width * 2)
          sourceSize.height: Math.round(height * 2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          smooth: true
          opacity: status === Image.Ready ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(140) } }
        }

        Text {
          anchors.centerIn: parent
          visible: thumb.status !== Image.Ready
          text: tile.glyph
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }

        Text {
          visible: tile.file.kind === "video" && thumb.status === Image.Ready
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(4)
          text: "\u{F040A}"
          color: "white"
          style: Text.Outline
          styleColor: Qt.alpha("black", 0.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }

        Rectangle {
          id: removeBadge
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(3)
          width: Style.space(18)
          height: width
          radius: width / 2
          color: removeArea.containsMouse ? root.urgent : Qt.alpha(Commons.Color.popups.background, 0.85)
          opacity: hoverHandler.hovered || removeArea.containsMouse ? 1 : 0
          visible: opacity > 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(100) } }

          Text {
            anchors.centerIn: parent
            text: "\u{F0156}"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: removeArea
            anchors.fill: parent
            anchors.margins: -Style.space(2)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.removePaths([tile.file.path])
          }
        }
      }

      Text {
        width: parent.width
        text: tile.file.name
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideMiddle
      }
    }

    HoverHandler {
      id: hoverHandler
    }

    TapHandler {
      id: tapHandler
      acceptedButtons: Qt.LeftButton
      cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

      onPressedChanged: {
        if (!pressed) return
        var modifiers = point.modifiers
        if (!tile.chosen || (modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
          root.selectAt(tile.tileIndex, modifiers)
      }
      onTapped: function(eventPoint, button) {
        if (button !== Qt.LeftButton || root.draggingOut) return
        if (!(eventPoint.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) && root.selected.length > 1)
          root.selectAt(tile.tileIndex, 0)
      }
      onDoubleTapped: function(eventPoint, button) {
        if (button === Qt.LeftButton) root.openPaths([tile.file.path])
      }
    }

    DragHandler {
      id: dragOutHandler
      target: null
      enabled: tile.file.exists
    }
  }
}
