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
// endpoint), and can be added, edited, or removed straight from the popup
// below, which calls go2rtc's own API to persist the change into
// go2rtc.yaml. A fresh install of this plugin starts with zero cameras and
// the popup opens
// straight to the "add a camera" form. Streams named `<name>_main` /
// `<name>_sub` are paired into one camera entry (sub for the bar/popup
// thumbnail, main for the live-view launch); a camera added with only one
// URL is stored as `<name>_main` and used for both.
BarWidget {
  id: root
  moduleName: "io.github.alanone.cameras"

  readonly property string go2rtcHost: root.setting("go2rtcHost", "127.0.0.1:1984")
  readonly property string go2rtcRtspHost: root.setting("go2rtcRtspHost", "127.0.0.1:8554")
  // Floored the same way popupWidth is: a 0/negative shell.json value would
  // otherwise turn the Timer below into a tight loop spawning curl as fast
  // as the event loop allows.
  readonly property int refreshSeconds: Math.max(1, Number(root.setting("refreshSeconds", 30)) || 30)
  // Popup width in the same raw-pixel units as every other Style.space()
  // call (theme spacing scale applies on top) — the snapshot thumbnail is
  // width * 9/16, so widening this is what actually makes the live preview
  // bigger. Clamped to a sane floor so a bad value in shell.json can't
  // collapse the popup; fittedContentWidth() separately clamps the other
  // direction so it never exceeds the screen.
  readonly property real popupWidth: Math.max(200, Number(root.setting("popupWidth", 340)) || 340)

  property bool popupOpen: false
  property bool showAddForm: false
  // Empty means the form is in "add a new camera" mode; set to an existing
  // camera's key when the form is prefilled for editing that camera instead.
  property string editingKey: ""

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
  // Sticky rather than a direct `snapshot.status === Image.Ready` binding:
  // status passes through Loading on every refresh tick (source changes
  // every refreshTick), which would otherwise flicker the bar icon's color
  // and tooltip between connected/unreachable on every single refresh.
  // Only a definite Ready/Error updates it; a mid-refresh Loading leaves
  // whatever was last known standing.
  property bool stickyConnected: false
  readonly property bool connected: selectedCamera !== null && stickyConnected

  // Double-buffered so the popup preview can refresh silently: two Image
  // items ping-pong, each loading the next frame into whichever one ISN'T
  // currently on screen, so the visible one never has its source changed
  // out from under it (which is what caused the "Loading…" flash on every
  // refresh — QtQuick.Image blanks immediately when `source` changes).
  // `popupBufferKeyN` records which camera's frame buffer N currently
  // holds; `popupRequestKeyN` records which camera buffer N's in-flight
  // fetch was FOR, so a late-arriving frame for a since-abandoned camera
  // selection is never promoted onto screen.
  property int popupFrontBuffer: 0
  property string popupBufferKey0: ""
  property string popupBufferKey1: ""
  property string popupRequestKey0: ""
  property string popupRequestKey1: ""
  readonly property bool popupHasFrame: root.selectedCameraKey !== ""
    && (root.popupBufferKey0 === root.selectedCameraKey || root.popupBufferKey1 === root.selectedCameraKey)
  readonly property bool popupLoading: snapA.status === Image.Loading || snapB.status === Image.Loading

  // Kicks off loading the current snapshotUrl into whichever buffer is
  // currently OFF screen. Called whenever there's a new frame to fetch
  // (snapshotUrl changes — a refresh tick or a camera switch) or the popup
  // reopens; a no-op while the popup is closed or nothing is selected.
  function requestPopupSnapshot() {
    if (!root.popupOpen || !root.selectedCamera) return
    var url = root.snapshotUrl
    var key = root.selectedCameraKey
    if (root.popupFrontBuffer === 0) {
      root.popupRequestKey1 = key
      snapB.source = url
    } else {
      root.popupRequestKey0 = key
      snapA.source = url
    }
  }

  onPopupOpenChanged: if (root.popupOpen) root.requestPopupSnapshot()
  onSnapshotUrlChanged: root.requestPopupSnapshot()

  // Switching cameras while editing would otherwise leave the form open
  // with the previous camera's prefilled values, silently pointed at the
  // wrong one — close it instead so a save can never land on the wrong
  // camera by accident. Doesn't affect a plain "+ Add camera" (editingKey
  // is only set while actually editing), and doesn't fire from a save's own
  // reselect (editingKey is already cleared by then).
  //
  // Also resets stickyConnected: it must not carry the PREVIOUS camera's
  // connectedness into the newly selected one (popupHasFrame/popupLoading
  // don't need an equivalent reset — they're driven by key-equality checks
  // against the buffers, which already go false the moment the key differs).
  onSelectedCameraKeyChanged: {
    root.stickyConnected = false
    if (root.editingKey === "") return
    root.editingKey = ""
    root.showAddForm = false
    root.mutationError = ""
    nameField.text = ""
    mainUrlField.text = ""
    subUrlField.text = ""
  }

  implicitWidth: barSize
  implicitHeight: barSize

  // Groups go2rtc's flat stream-name list into cameras, pairing
  // `<name>_main`/`<name>_sub` and falling back to a single stream otherwise.
  // mainRaw/subRaw keep the exact go2rtc stream names so removeCamera() and
  // saveCamera() (editing) can act on precisely what addCamera() created.
  // `parsed` is the full /api/streams response (not just its keys) because
  // each stream's `producers[0].url` is the only way to recover the source
  // URL a camera was originally added with, to prefill the edit form.
  function groupStreams(parsed) {
    var names = Object.keys(parsed || {})
    function urlFor(name) {
      var s = parsed[name]
      var p = s && s.producers && s.producers[0]
      return (p && p.url) || ""
    }
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
      // The key IS the display name (underscores standing in for spaces) —
      // slugify() below preserves whatever case the name was typed in, so
      // there's nothing to re-capitalize here. Re-deriving a capitalized
      // label from a lowercased slug (the previous approach) is exactly
      // what silently lowercased every word after the first.
      list.push({
        key: g.key,
        displayName: g.key.replace(/_/g, " "),
        snapshotStream: g.sub || g.main,
        liveStream: g.main || g.sub,
        mainRaw: g.main,
        subRaw: g.sub,
        mainUrl: g.main ? urlFor(g.main) : "",
        subUrl: g.sub ? urlFor(g.sub) : ""
      })
    }
    list.sort(function(a, b) {
      var ak = a.key.toLowerCase(), bk = b.key.toLowerCase()
      return ak < bk ? -1 : (ak > bk ? 1 : 0)
    })
    return list
  }

  // Preserves the case exactly as typed — go2rtc stream names aren't
  // required to be lowercase, so there's no need to normalize case here,
  // only to strip characters that wouldn't survive as a URL query param.
  function slugify(name) {
    var s = String(name || "").trim()
    s = s.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "")
    return s.length > 0 ? s : "camera"
  }

  // excludeKey lets saveCamera() re-check a slug without the camera being
  // edited colliding with itself when its name is left unchanged.
  function uniqueSlug(base, excludeKey) {
    var existing = {}
    for (var i = 0; i < root.cameras.length; i++) {
      if (root.cameras[i].key === excludeKey) continue
      existing[root.cameras[i].key] = true
    }
    if (!existing[base]) return base
    var n = 2
    while (existing[base + "_" + n]) n++
    return base + "_" + n
  }

  function refreshCameraList() {
    if (!streamsProc.running) streamsProc.running = true
  }

  // rawName is a go2rtc stream name (e.g. "front_door_main"), not a URL —
  // no credential exposure via argv here, just bounding how long a stalled
  // go2rtc endpoint can hang this shared shell process.
  function deleteStream(proc, rawName) {
    proc.command = ["curl", "-fsS", "-X", "DELETE", "--connect-timeout", "5", "--max-time", "10",
      "http://" + root.go2rtcHost + "/api/streams?src=" + encodeURIComponent(rawName)]
    proc.running = true
  }

  // Escapes a value for embedding inside a double-quoted curl -K config
  // line (backslash and double-quote are the only characters that syntax
  // treats specially).
  function curlConfigEscape(value) {
    return String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  }

  // mainUrl/subUrl commonly carry RTSP/cloud credentials, and go2rtc's API
  // only ever reads `src` from the query string (no request-body
  // alternative) — so the credential-bearing URL can't be kept off the
  // wire. It CAN be kept off this process's argv, which is readable by any
  // local user via /proc/<pid>/cmdline or `ps` for as long as curl runs:
  // stdinEnabled + write() feeds curl the URL as a -K config line over its
  // stdin pipe instead of a command-line argument, so `command` never
  // contains anything but literal flags. A fresh Process per call (rather
  // than a reused singleton) sidesteps ambiguity in Quickshell's docs over
  // whether stdinEnabled can be safely re-enabled after being turned off
  // once on the same instance.
  function putStream(name, url, failureMessage) {
    var fullUrl = "http://" + root.go2rtcHost + "/api/streams?name=" + name + "&src=" + encodeURIComponent(url)
    streamPutComponent.createObject(root, {
      command: ["curl", "-fsS", "-X", "PUT", "--connect-timeout", "5", "--max-time", "10", "-K", "-"],
      payload: "url = \"" + root.curlConfigEscape(fullUrl) + "\"\n",
      failureMessage: failureMessage,
      running: true
    })
  }

  function onMutationSettled() {
    root.pendingMutations = Math.max(0, root.pendingMutations - 1)
    if (root.pendingMutations === 0) root.refreshCameraList()
  }

  // Handles both "add a new camera" (editingKey === "") and "edit an
  // existing one" (editingKey set to its key). Editing reuses the same
  // add/delete plumbing: PUT under the (possibly unchanged) slug always
  // saves the current form values, and if the name changed enough to
  // produce a different slug, the old stream(s) are deleted afterwards —
  // same mechanism a plain remove+add would use, just sequenced so the
  // camera never disappears from the list in between.
  function saveCamera() {
    var name = nameField.text.trim()
    var mainUrl = mainUrlField.text.trim()
    var subUrl = subUrlField.text.trim()
    if (name === "" || mainUrl === "") {
      root.mutationError = "Name and a stream URL are required."
      return
    }

    root.mutationError = ""
    var isEdit = root.editingKey !== ""
    var oldCamera = null
    if (isEdit) {
      for (var i = 0; i < root.cameras.length; i++) {
        if (root.cameras[i].key === root.editingKey) { oldCamera = root.cameras[i]; break }
      }
    }

    var slug = root.uniqueSlug(root.slugify(name), root.editingKey)
    var renamed = isEdit && oldCamera && slug !== oldCamera.key
    root.pendingSelectKey = slug

    root.pendingMutations++
    root.putStream(slug + "_main", mainUrl,
      "Couldn't save the camera — check the stream URL and that go2rtc is reachable.")

    if (subUrl !== "") {
      root.pendingMutations++
      root.putStream(slug + "_sub", subUrl,
        "Couldn't save the lower-res stream — the main stream may still have been saved.")
    }

    if (isEdit && oldCamera) {
      if (renamed) {
        if (oldCamera.mainRaw) {
          root.pendingMutations++
          root.deleteStream(deleteMainProc, oldCamera.mainRaw)
        }
        if (oldCamera.subRaw) {
          root.pendingMutations++
          root.deleteStream(deleteSubProc, oldCamera.subRaw)
        }
      } else if (oldCamera.subRaw && subUrl === "") {
        // Same camera, but the lower-res stream was cleared — the PUT
        // above only overwrote mainUrl, so the now-unwanted sub stream
        // needs an explicit delete rather than being left orphaned.
        root.pendingMutations++
        root.deleteStream(deleteSubProc, oldCamera.subRaw)
      }
    }

    nameField.text = ""
    mainUrlField.text = ""
    subUrlField.text = ""
    root.showAddForm = false
    root.editingKey = ""
  }

  function removeCamera(camera) {
    if (!camera) return
    root.mutationError = ""
    if (camera.mainRaw) {
      root.pendingMutations++
      root.deleteStream(deleteMainProc, camera.mainRaw)
    }
    if (camera.subRaw) {
      root.pendingMutations++
      root.deleteStream(deleteSubProc, camera.subRaw)
    }
  }

  Process {
    id: streamsProc
    // go2rtcHost is user-configurable and can point at a remote instance, so
    // this response is buffered into QML memory (StdioCollector) from a
    // source that isn't fully trusted. --max-filesize caps it at the curl
    // level — curl aborts the transfer once this many bytes have arrived,
    // even without a Content-Length header — so a compromised or malicious
    // endpoint can't hand back an unbounded body and exhaust this process.
    // 2 MiB comfortably fits a real /api/streams response (every stream's
    // full producer/consumer detail included) for any realistic camera
    // count; a response this large from a legitimate endpoint would itself
    // indicate something is wrong. A capped transfer exits non-zero and
    // whatever partial bytes arrived fail JSON.parse below, which the
    // existing catch already treats the same as "unreachable".
    command: ["curl", "-fsS", "--max-time", "5", "--max-filesize", "2097152", "http://" + root.go2rtcHost + "/api/streams"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          var list = root.groupStreams(parsed)
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

  // Dynamically instantiated per call by putStream() — see its comment for
  // why a reused singleton Process isn't used here.
  Component {
    id: streamPutComponent
    Process {
      stdinEnabled: true
      property string payload: ""
      property string failureMessage: ""
      onStarted: {
        write(payload)
        stdinEnabled = false
      }
      onExited: function(exitCode) {
        if (exitCode !== 0) root.mutationError = failureMessage
        root.onMutationSettled()
        destroy()
      }
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
  // Only Ready/Error update stickyConnected — a mid-refresh Loading is not
  // a verdict on connectivity, just this fetch being in flight.
  Image {
    id: snapshot
    source: root.snapshotUrl
    visible: false
    asynchronous: true
    cache: false
    onStatusChanged: {
      if (status === Image.Ready) root.stickyConnected = true
      else if (status === Image.Error) root.stickyConnected = false
    }
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

  // KeyboardPanel, not PopupCard: PopupCard is an xdg-popup, which only gets
  // real keyboard focus routed to it in limited cases and never reliably
  // grants it to a child TextField — every other panel in this shell that
  // takes typed text (network, bluetooth, audio, weather, ...) uses
  // KeyboardPanel instead, which explicitly manages WlrLayershell keyboard
  // focus. PopupCard is only safe for button/toggle-only popups (e.g. the
  // tray menu, media controls) — this widget's add/edit form needs the real
  // one. Same API otherwise (anchorItem/bar/owner/open/contentWidth/Height),
  // so this is a drop-in swap.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(root.popupWidth))
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
          width: parent.width - editButton.width - removeButton.width - parent.spacing * 2
          textFormat: Text.PlainText
          text: root.selectedCamera ? root.selectedCamera.displayName : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          elide: Text.ElideRight
        }

        Button {
          id: editButton
          text: "Edit"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.space(4)
          onClicked: {
            var c = root.selectedCamera
            if (!c) return
            root.editingKey = c.key
            nameField.text = c.displayName
            mainUrlField.text = c.mainUrl || ""
            subUrlField.text = c.subUrl || ""
            root.mutationError = ""
            root.showAddForm = true
          }
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

        // Two buffers ping-ponging (see popupFrontBuffer et al. above) so a
        // routine refresh swaps frames silently instead of blanking out to
        // "Loading…" every refreshSeconds. Each becomes visible only once
        // it holds a Ready frame for the CURRENTLY selected camera — not
        // just whichever camera it was last asked to load.
        Image {
          id: snapA
          anchors.fill: parent
          anchors.margins: Style.space(2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          visible: root.popupFrontBuffer === 0 && status === Image.Ready && root.popupBufferKey0 === root.selectedCameraKey
          onStatusChanged: {
            if (status === Image.Ready && root.popupRequestKey0 === root.selectedCameraKey) {
              root.popupBufferKey0 = root.popupRequestKey0
              root.popupFrontBuffer = 0
            }
          }
        }

        Image {
          id: snapB
          anchors.fill: parent
          anchors.margins: Style.space(2)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          visible: root.popupFrontBuffer === 1 && status === Image.Ready && root.popupBufferKey1 === root.selectedCameraKey
          onStatusChanged: {
            if (status === Image.Ready && root.popupRequestKey1 === root.selectedCameraKey) {
              root.popupBufferKey1 = root.popupRequestKey1
              root.popupFrontBuffer = 1
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: !root.popupHasFrame
          textFormat: Text.PlainText
          text: !root.selectedCamera ? "No camera" : (root.popupLoading ? "Loading…" : "Camera unreachable")
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
          root.editingKey = ""
          nameField.text = ""
          mainUrlField.text = ""
          subUrlField.text = ""
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.showAddForm || root.cameras.length === 0

        Text {
          textFormat: Text.PlainText
          text: root.editingKey !== "" ? "Edit camera" : (root.cameras.length === 0 ? "Add your first camera" : "Add a camera")
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
          text: root.pendingMutations > 0
            ? (root.editingKey !== "" ? "Saving…" : "Adding…")
            : (root.editingKey !== "" ? "Save changes" : "Add")
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.pendingMutations === 0
          onClicked: root.saveCamera()
        }
      }
    }
  }
}
