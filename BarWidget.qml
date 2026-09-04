import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Camera bar widget. Talks only to a local go2rtc instance (127.0.0.1:1984
// for snapshots, the stream list, and adding/removing cameras; 127.0.0.1:8554
// for the re-streamed RTSP mpv uses for live view) — never to any camera's
// own protocol directly, so credentials live only in go2rtc, not in this
// plugin's own settings.
//
// Cameras aren't configured via plugin settings — they're discovered from
// whatever go2rtc currently has in `streams:` (via its /api/streams
// endpoint), and can be added or removed straight from the popup below,
// which calls go2rtc's own API to persist the change into go2rtc.yaml. A
// fresh install of this plugin starts with zero cameras and the popup opens
// straight to the "add a camera" form. Streams named `<name>_main` /
// `<name>_sub` are paired into one camera entry (sub for the bar/popup
// thumbnail, main for the live-view launch); a camera added with only one
// URL is stored as `<name>_main` and used for both.
BarWidget {
  id: root
  moduleName: "io.github.alanone.cameras"

  readonly property string go2rtcHost: root.setting("go2rtcHost", "127.0.0.1:1984")
  readonly property string go2rtcRtspHost: root.setting("go2rtcRtspHost", "127.0.0.1:8554")
  readonly property int refreshSeconds: root.setting("refreshSeconds", 30)

  property bool popupOpen: false
  property bool showAddForm: false

  // PopupCard's outside-click dismissal calls owner.close() when present,
  // falling back to mutating its own `open` property directly otherwise —
  // which would silently break the `open: root.popupOpen` binding below and
  // leave popupOpen (and the icon's active/red state) stuck true forever.
  function close() { root.popupOpen = false }
  property int refreshTick: 0
  property var cameras: []
  property string selectedCameraKey: ""
  property string pendingSelectKey: ""
  property int pendingMutations: 0
  property string mutationError: ""

  readonly property var selectedCamera: {
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].key === selectedCameraKey) return cameras[i]
    }
    return cameras.length > 0 ? cameras[0] : null
  }
  readonly property string snapshotUrl: selectedCamera
    ? "http://" + go2rtcHost + "/api/frame.jpeg?src=" + selectedCamera.snapshotStream + "&_t=" + refreshTick
    : ""
  readonly property bool connected: selectedCamera !== null && snapshot.status === Image.Ready

  implicitWidth: barSize
  implicitHeight: barSize

  // Groups go2rtc's flat stream-name list into cameras, pairing
  // `<name>_main`/`<name>_sub` and falling back to a single stream otherwise.
  // mainRaw/subRaw keep the exact go2rtc stream names so removeCamera() can
  // delete precisely what addCamera() created.
  function groupStreams(names) {
    var groups = {}
    var order = []
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var key = name
      var role = "full"
      if (name.length > 5 && name.slice(-5) === "_main") {
        key = name.slice(0, -5)
        role = "main"
      } else if (name.length > 4 && name.slice(-4) === "_sub") {
        key = name.slice(0, -4)
        role = "sub"
      }
      if (!groups[key]) {
        groups[key] = { key: key, main: null, sub: null }
        order.push(key)
      }
      if (role === "main") groups[key].main = name
      else if (role === "sub") groups[key].sub = name
      else if (!groups[key].main) groups[key].main = name
    }

    var list = []
    for (var j = 0; j < order.length; j++) {
      var g = groups[order[j]]
      var label = g.key.length > 0 ? g.key.charAt(0).toUpperCase() + g.key.slice(1) : g.key
      list.push({
        key: g.key,
        displayName: label.replace(/_/g, " "),
        snapshotStream: g.sub || g.main,
        liveStream: g.main || g.sub,
        mainRaw: g.main,
        subRaw: g.sub
      })
    }
    list.sort(function(a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0) })
    return list
  }

  function slugify(name) {
    var s = String(name || "").toLowerCase().trim()
    s = s.replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "")
    return s.length > 0 ? s : "camera"
  }

  function uniqueSlug(base) {
    var existing = {}
    for (var i = 0; i < root.cameras.length; i++) existing[root.cameras[i].key] = true
    if (!existing[base]) return base
    var n = 2
    while (existing[base + "_" + n]) n++
    return base + "_" + n
  }

  function refreshCameraList() {
    if (!streamsProc.running) streamsProc.running = true
  }

  function onMutationSettled() {
    root.pendingMutations = Math.max(0, root.pendingMutations - 1)
    if (root.pendingMutations === 0) root.refreshCameraList()
  }

  function addCamera() {
    var name = nameField.text.trim()
    var mainUrl = mainUrlField.text.trim()
    var subUrl = subUrlField.text.trim()
    if (name === "" || mainUrl === "") {
      root.mutationError = "Name and a stream URL are required."
      return
    }

    root.mutationError = ""
    var slug = root.uniqueSlug(root.slugify(name))
    root.pendingSelectKey = slug

    root.pendingMutations++
    addMainProc.command = ["curl", "-fsS", "-X", "PUT",
      "http://" + root.go2rtcHost + "/api/streams?name=" + slug + "_main&src=" + encodeURIComponent(mainUrl)]
    addMainProc.running = true

    if (subUrl !== "") {
      root.pendingMutations++
      addSubProc.command = ["curl", "-fsS", "-X", "PUT",
        "http://" + root.go2rtcHost + "/api/streams?name=" + slug + "_sub&src=" + encodeURIComponent(subUrl)]
      addSubProc.running = true
    }

    nameField.text = ""
    mainUrlField.text = ""
    subUrlField.text = ""
    root.showAddForm = false
  }

  function removeCamera(camera) {
    if (!camera) return
    root.mutationError = ""
    if (camera.mainRaw) {
      root.pendingMutations++
      deleteMainProc.command = ["curl", "-fsS", "-X", "DELETE",
        "http://" + root.go2rtcHost + "/api/streams?src=" + encodeURIComponent(camera.mainRaw)]
      deleteMainProc.running = true
    }
    if (camera.subRaw) {
      root.pendingMutations++
      deleteSubProc.command = ["curl", "-fsS", "-X", "DELETE",
        "http://" + root.go2rtcHost + "/api/streams?src=" + encodeURIComponent(camera.subRaw)]
      deleteSubProc.running = true
    }
  }

  Process {
    id: streamsProc
    command: ["curl", "-fsS", "--max-time", "5", "http://" + root.go2rtcHost + "/api/streams"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          var list = root.groupStreams(Object.keys(parsed || {}))
          root.cameras = list

          if (root.pendingSelectKey !== "" && list.some(function(c) { return c.key === root.pendingSelectKey })) {
            root.selectedCameraKey = root.pendingSelectKey
            root.pendingSelectKey = ""
          } else if (list.length === 0) {
            root.selectedCameraKey = ""
          } else if (!list.some(function(c) { return c.key === root.selectedCameraKey })) {
            root.selectedCameraKey = list[0].key
          }
        } catch (e) {
          // go2rtc unreachable or returned something unexpected — keep the
          // last-known camera list and try again on the next tick.
        }
      }
    }
  }

  Process {
    id: addMainProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.mutationError = "Couldn't add camera — check the stream URL and that go2rtc is reachable."
      root.onMutationSettled()
    }
  }

  Process {
    id: addSubProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.mutationError = "Couldn't add the lower-res stream — the main stream may still have been added."
      root.onMutationSettled()
    }
  }

  Process {
    id: deleteMainProc
    onExited: function(exitCode) { root.onMutationSettled() }
  }

  Process {
    id: deleteSubProc
    onExited: function(exitCode) { root.onMutationSettled() }
  }

  Component.onCompleted: refreshCameraList()

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refreshTick++
      root.refreshCameraList()
    }
  }

  // Loaded invisibly in the bar just to track connection status for the
  // glyph color; the popup has its own visible copy so it always shows the
  // freshest frame at the moment it's opened, not whatever the bar last saw.
  Image {
    id: snapshot
    source: root.snapshotUrl
    visible: false
    asynchronous: true
    cache: false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰞮"
    slotSize: Style.bar.statusSlot
    active: root.popupOpen
    foreground: root.connected ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.8)
    tooltipText: root.selectedCamera
      ? (root.connected ? root.selectedCamera.displayName : root.selectedCamera.displayName + " unreachable")
      : "No cameras — click to add one"

    onPressed: function(b) { root.popupOpen = !root.popupOpen }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    onOpenChanged: if (open) root.refreshCameraList()

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Flow {
        width: parent.width
        spacing: Style.space(6)
        visible: root.cameras.length > 1

        Repeater {
          model: root.cameras

          Button {
            required property var modelData
            text: modelData.displayName
            selected: modelData.key === root.selectedCameraKey
            foreground: root.bar.foreground
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.space(4)
            onClicked: root.selectedCameraKey = modelData.key
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.selectedCamera !== null

        Text {
          width: parent.width - removeButton.width - parent.spacing
          textFormat: Text.PlainText
          text: root.selectedCamera ? root.selectedCamera.displayName : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Button {
          id: removeButton
          text: "Remove"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.space(4)
          onClicked: root.removeCamera(root.selectedCamera)
        }
      }

      BorderSurface {
        width: parent.width
        height: width * 9 / 16
        radius: Style.spacing.labelGap
        visible: root.cameras.length > 0
        color: Style.normalFillFor(root.bar.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

        Image {
          id: popupSnapshot
          anchors.fill: parent
          anchors.margins: Style.space(2)
          source: root.popupOpen ? root.snapshotUrl : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          visible: status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          visible: popupSnapshot.status !== Image.Ready
          textFormat: Text.PlainText
          text: !root.selectedCamera ? "No camera" : (popupSnapshot.status === Image.Loading ? "Loading…" : "Camera unreachable")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Button {
        text: "Open live view"
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        visible: root.cameras.length > 0
        enabled: root.selectedCamera !== null
        onClicked: {
          if (!root.selectedCamera) return
          Quickshell.execDetached(["mpv", "rtsp://" + root.go2rtcRtspHost + "/" + root.selectedCamera.liveStream])
          root.popupOpen = false
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        visible: root.cameras.length > 0
        color: Qt.darker(root.bar.foreground, 4)
      }

      Button {
        text: root.showAddForm ? "Cancel" : "+ Add camera"
        visible: root.cameras.length > 0
        foreground: root.bar.foreground
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.space(4)
        onClicked: {
          root.showAddForm = !root.showAddForm
          root.mutationError = ""
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.showAddForm || root.cameras.length === 0

        Text {
          textFormat: Text.PlainText
          text: root.cameras.length === 0 ? "Add your first camera" : "Add a camera"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Paste the camera's stream URL (RTSP, ONVIF, or anything else go2rtc supports — credentials go right in the URL). The lower-res URL is optional; leave it blank if the camera only has one stream."
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextField {
          id: nameField
          width: parent.width
          placeholderText: "Name (e.g. Front door)"
        }

        TextField {
          id: mainUrlField
          width: parent.width
          placeholderText: "Stream URL — rtsp://user:pass@host:port/path"
        }

        TextField {
          id: subUrlField
          width: parent.width
          placeholderText: "Lower-res URL (optional)"
        }

        Text {
          width: parent.width
          visible: root.mutationError !== ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: root.mutationError
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          text: root.pendingMutations > 0 ? "Adding…" : "Add"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.pendingMutations === 0
          onClicked: root.addCamera()
        }
      }
    }
  }
}
