import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cellular (WWAN) bar widget with an anchored popup panel. All state comes from
// `omarchy-cellular panel`, one process spawn per refresh.
Panel {
  id: root
  moduleName: "relctx.cellular"
  ipcTarget: "relctx.cellular"

  property var info: ({})
  readonly property string wwanState: info.state || "absent"
  readonly property bool hwPresent: info.hw === "yes"
  readonly property bool installed: info.installed === "yes"
  readonly property bool connected: wwanState === "connected"
  readonly property bool busy: actionProc.running
  readonly property bool roaming: info.roaming === "yes"
  readonly property string modesAllowed: info.modes_allowed || ""
  readonly property string modesPreferred: info.modes_preferred || ""
  // Chips come from what the modem actually has: a 5G part may lack 2g, an
  // older one 5g. Fastest first, with Auto in front.
  readonly property var modeChips: {
    var gens = (info.modes_supported || "").split(",").filter(function (g) { return g })
    var order = ["5g", "4g", "3g", "2g"]
    var out = [{ id: "auto", label: "Auto", match: gens.join(",") }]
    for (var i = 0; i < order.length; i++)
      if (gens.indexOf(order[i]) !== -1)
        out.push({ id: order[i], label: order[i].toUpperCase(), match: order[i] })
    return out
  }
  // Number, IMEI, ICCID and EID identify you or the hardware. A bar panel gets
  // screenshotted and screen-shared, so they start hidden.
  property bool detailsRevealed: false
  // Reference material, so the section starts folded away.
  property bool deviceExpanded: false
  property bool apnEditing: false
  property bool limitEditing: false
  property bool carrierExpanded: false
  // Profiles cannot be polled: reading them stops ModemManager and needs
  // pkexec, so they load once when the section is opened and stay until asked
  // for again.
  property bool esimExpanded: false
  property bool profilesLoading: false
  property var profiles: []
  property bool addingProfile: false
  property string profileError: ""
  // Which profile is being renamed, by iccid; empty when none.
  property string renamingIccid: ""
  // The list as it was before an optimistic change, so a failed one can be put
  // back. Empty means nothing is pending.
  property var profilesUndo: []
  // A scan runs detached, so the panel never hears whether it installed
  // anything. Mark the list as possibly out of date instead of guessing.
  property bool profilesStale: false

  // One authorization covers a whole eSIM session: the CLI keeps the elevated
  // half open and feeds it commands, so every action after the first costs
  // nothing. The session lives only while the profile list is on screen.
  property bool sessionReady: false
  property var sessionQueue: []
  property string sessionVerb: ""
  property var sessionLines: []

  function sessionStart() {
    if (sessionProc.running) return
    // The queue is the callers': the click that starts the session has
    // usually just queued the command the session exists to run.
    root.sessionReady = false
    root.sessionVerb = ""
    root.sessionLines = []
    sessionProc.command = [root.cli, "esim-session"]
    sessionProc.running = true
  }

  function sessionStop() {
    if (!sessionProc.running) return
    sessionProc.write("quit\n")
    sessionProc.running = false
    root.sessionReady = false
    root.sessionVerb = ""
    root.sessionQueue = []
  }

  function sessionSend(cmd) {
    var q = root.sessionQueue.slice()
    q.push(cmd)
    root.sessionQueue = q
    if (!sessionProc.running) { sessionStart(); return }
    root.sessionPump()
  }

  function sessionPump() {
    if (!root.sessionReady || root.sessionVerb !== "") return
    if (root.sessionQueue.length === 0) return
    var q = root.sessionQueue.slice()
    var cmd = q.shift()
    root.sessionQueue = q
    root.sessionVerb = cmd.split(" ")[0]
    root.sessionLines = []
    root.profilesLoading = true
    sessionProc.write(cmd + "\n")
  }

  function sessionLine(line) {
    if (line === "session=ready") {
      root.sessionReady = true
      root.sessionPump()
      return
    }
    if (line.indexOf("===END ") === 0) {
      root.sessionDone(root.sessionVerb, line.replace("===END ", "").replace("===", ""))
      return
    }
    if (line.indexOf("profile.") === 0) {
      var l = root.sessionLines.slice()
      l.push(line)
      root.sessionLines = l
    } else if (line.indexOf("error=") === 0) {
      root.profileError = line.substring(6)
    }
  }

  function sessionDone(verb, rc) {
    var lines = root.sessionLines
    root.sessionVerb = ""
    root.sessionLines = []
    root.profilesLoading = false

    if (verb === "list") {
      root.profiles = root.parseProfiles(lines.join("\n"))
      root.profilesStale = false
      if (root.profiles.length === 0 && root.profileError === "")
        root.profileError = "Could not read the eSIM."
      root.sessionPump()
      return
    }

    if (rc !== "0") {
      // The row was changed before the command ran, so put it back.
      if (root.profilesUndo.length > 0) root.profiles = root.profilesUndo
      root.profilesUndo = []
      if (root.profileError === "") root.profileError = "That did not work."
      root.sessionPump()
      return
    }

    root.profilesUndo = []
    // The change landed. The authoritative list costs nothing now.
    root.sessionSend("list")
  }

  function loadProfiles() {
    root.profileError = ""
    root.sessionSend("list")
  }

  // Button sizes to its content, so a long profile name pushes the action chips
  // off the panel.
  // The last four ICCID digits, always. Issuers reuse one profileName across
  // every profile they sell -- two Airalo plans both read "WEBBING · Airalo" --
  // and the ICCID is the only thing that differs. Showing it always means the
  // row you click is the row you meant, without renaming anything first.
  function shortLabel(name, provider, iccid) {
    var n = name || "Unnamed"
    if (n.length > 18) n = n.slice(0, 17) + "…"
    var tail = iccid ? String(iccid).slice(-4) : ""
    if (provider && provider !== n)
      n += "  ·  " + (provider.length > 10 ? provider.slice(0, 9) + "…" : provider)
    return tail ? n + "  ·  " + tail : n
  }

  // Apply the change to the local list; reloading costs a second authorization
  // prompt for an outcome already known. Refresh re-reads from the eSIM.
  // Editable fields are seeded, never bound: a binding to root.info is
  // re-evaluated on every status poll and overwrites what is being typed.
  // NetworkManager penalizes a default route by 20000 until its connectivity
  // check confirms the link, so the old link carries traffic for a few seconds
  // after the toggle.
  readonly property string routeLabel: {
    // Shown by a shared tooltip that renders AutoText, so constrain it.
    var via = (info.route_via || "").replace(/[^A-Za-z0-9._-]/g, "")
    var onCellular = via !== "" && via.indexOf("ww") === 0
    if (info.prefer_cellular === "yes")
      return onCellular ? "Traffic is on cellular" : "Switching\u2026 traffic is still on " + (via || "another link")
    return onCellular ? "Traffic is on cellular (nothing else is up)"
                  : "Traffic is on " + (via || "another link")
  }

  // The provider ModemManager reports for the card. No authorization, no cache.
  readonly property string simLabel: info.sim_operator || ""

  function seedLimitFields() {
    limitField.text = (info.limit && info.limit !== "off") ? info.limit : ""
    resetDayField.text = info.reset_day || ""
    periodDaysField.text = info.period_days || ""
  }

  function applyProfileChange(iccid, kind, value) {
    profilesUndo = JSON.parse(JSON.stringify(profiles))
    var out = []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      if (kind === "delete" && p.iccid === iccid) continue
      if (kind === "rename" && p.iccid === iccid) p.name = value
      if (kind === "enable") p.state = (p.iccid === iccid) ? "enabled" : "disabled"
      out.push(p)
    }
    profiles = out
  }

  // The CLI ships beside this file, so the panel works straight from
  // `omarchy plugin add` with nothing on PATH.
  readonly property string cli: String(Qt.resolvedUrl("../bin/omarchy-cellular")).replace("file://", "")

  // lpac reports profileState as "enabled"/"disabled" in some builds and as
  // the SGP.22 enum (1/0) in others. Compare through here, never directly.
  function profileEnabled(p) {
    var st = String((p && p.state) !== undefined ? p.state : "").toLowerCase()
    return st === "enabled" || st === "1" || st === "true"
  }

  function parseProfiles(text) {
    var byIndex = {}
    var lines = (text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^profile\.(\d+)\.([a-z]+)=(.*)$/)
      if (!m) continue
      if (!byIndex[m[1]]) byIndex[m[1]] = {}
      byIndex[m[1]][m[2]] = m[3]
    }
    var out = []
    Object.keys(byIndex).sort().forEach(function (k) { out.push(byIndex[k]) })
    return out
  }
  // What the panel is doing right now; the hero otherwise shows the last polled
  // state, which during a connect reads as if nothing happened.
  property string busyLabel: ""
  function maskId(v) {
    if (!v) return "—"
    return detailsRevealed ? v : v.slice(0, 4) + "•".repeat(Math.max(0, v.length - 4))
  }
  // Defaults to the empty cellular outline until the first read lands.
  readonly property string icon: info.icon || "󰢿"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)

  // The switch throws instantly on click; while the toggle is in flight it
  // shows where we are going, not where we still are.
  property bool desired: false
  readonly property bool switchChecked: busy ? desired : connected

  // Rates are deltas between successive --verbose samples. Ping keeps a rolling
  // window in which a timed-out probe counts as a lost packet.
  property real prevRxBytes: 0
  property real prevTxBytes: 0
  property real prevSampleTime: 0
  property string prevIface: ""
  property real downloadRate: 0
  property real uploadRate: 0
  property var pingSamples: []
  property real pingLatency: -1
  property int packetLoss: 0
  readonly property int pingHistoryWindow: 24
  readonly property int pingAverageWindow: 5
  readonly property bool hasPingSamples: pingSamples.length > 0
  readonly property bool hasTransferStats: info.rx_bytes !== undefined
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : "#cc6666"

  // Data-plan meter, fed by the CLI's persistent usage accounting.
  readonly property real usedBytes: parseFloat(info.used_bytes || "0")
  readonly property real limitBytes: parseFloat(info.limit_bytes || "0")
  readonly property bool limitAck: info.limit_ack === "1"

  // Which slot carries the eUICC is the CLI's finding, not an assumption: it
  // is the slot whose SIM reports an EID. The other one is the physical card.
  readonly property string esimSlot: info.esim_slot || "2"
  readonly property bool hasEsim: (info.esim_slot || "") !== ""
  readonly property bool esimSelected: info.slot === esimSlot
  readonly property string physicalSlot: esimSlot === "1" ? "2" : "1"
  function slotHasCard(slot) { return info["slot" + slot + "_sim"] !== "no" }
  readonly property real usedFraction: limitBytes > 0 ? Math.min(1, usedBytes / limitBytes) : 0
  readonly property string nextResetLabel: {
    if (!info.next_reset) return ""
    var d = new Date(info.next_reset + "T00:00:00")
    if (isNaN(d.getTime())) return ""
    return "Resets " + Qt.formatDate(d, "MMM d")
  }

  function capitalise(v) { return v ? v.charAt(0).toUpperCase() + v.slice(1) : v }

  readonly property string statusText: {
    if (busyLabel) return busyLabel
    switch (wwanState) {
    case "connected": return (info.operator || "Connected") + (info.tech ? " · " + info.tech : "")
    case "registered": return (info.operator || "Registered")
      + (info.reason ? " — " + info.reason : " — not connected")
    // Prefer the network's stated reason; a modem that is genuinely still
    // looking reports none.
    case "searching": return info.reason ? capitalise(info.reason) : "Searching for network"
    case "nosim": return info.active_slot === root.esimSlot
      ? "eSIM is empty — no profile"
      : "SIM slot " + (info.active_slot || "?") + " is empty"
    case "locked": return "SIM locked — PIN required"
    case "disabled": return "Cellular off"
    default: return "Modem starting…"
    }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshDetails() {
    if (!detailsProc.running) detailsProc.running = true
  }

  function updateInfo(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq > 0) next[lines[i].slice(0, eq)] = lines[i].slice(eq + 1)
    }
    // Keep the last known state across a transient empty read, so the widget
    // never blinks out while the CLI is briefly unavailable.
    if (Object.keys(next).length === 0) return
    updateStats(next)
    info = next
  }

  function updateStats(next) {
    var iface = next.iface || ""
    var now = Date.now() / 1000

    if (next.rx_bytes === undefined || iface !== prevIface || prevSampleTime === 0) {
      // First sample after open, or the modem moved interface: a delta here
      // would manufacture a spike.
      downloadRate = 0
      uploadRate = 0
    } else {
      var dt = now - prevSampleTime
      if (dt > 0) {
        downloadRate = Math.max(0, (parseFloat(next.rx_bytes) - prevRxBytes) / dt)
        uploadRate = Math.max(0, (parseFloat(next.tx_bytes) - prevTxBytes) / dt)
      }
    }
    prevIface = iface
    prevRxBytes = parseFloat(next.rx_bytes || "0")
    prevTxBytes = parseFloat(next.tx_bytes || "0")
    prevSampleTime = next.rx_bytes === undefined ? 0 : now

    if (next.ping_ms === undefined) return
    var v = parseFloat(next.ping_ms)
    var samples = pingSamples.slice()
    samples.push(isFinite(v) && v >= 0 ? v : null)
    while (samples.length > pingHistoryWindow) samples.shift()
    pingSamples = samples

    var total = 0, count = 0
    for (var i = Math.max(0, samples.length - pingAverageWindow); i < samples.length; i++) {
      if (typeof samples[i] === "number") { total += samples[i]; count++ }
    }
    pingLatency = count > 0 ? total / count : -1

    var lost = 0
    for (var j = 0; j < samples.length; j++) if (samples[j] === null) lost++
    packetLoss = Math.round((lost / samples.length) * 100)
  }

  function resetStats() {
    prevSampleTime = 0
    prevIface = ""
    downloadRate = 0
    uploadRate = 0
    pingSamples = []
    pingLatency = -1
    packetLoss = 0
  }

  function formatBytes(bytes) {
    var n = Number(bytes)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
    return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
  }

  function formatRate(bytesPerSec) {
    return formatBytes(bytesPerSec) + "/s"
  }

  function formatPing(ms) {
    if (!hasPingSamples) return "--"
    var v = parseFloat(ms)
    if (!isFinite(v) || v < 0) return "Timeout"
    return v.toFixed(v > 0 && v < 10 ? 1 : 0) + " ms"
  }

  function formatLoss(percent) {
    if (!hasPingSamples) return "--"
    var v = parseInt(percent, 10)
    return (!v || v < 0 ? 0 : v) + "%"
  }

  // The panel renders its own busy and failure state; suppress the toasts.
  function labelFor(cmd) {
    var verb = cmd[1] || ""
    if (verb === "connect") return "Connecting…"
    if (verb === "disconnect") return "Disconnecting…"
    if (verb === "toggle") return root.connected ? "Disconnecting…" : "Connecting…"
    if (verb === "sim") return "Switching SIM…"
    if (verb === "mode") return "Setting radio mode…"
    if (verb === "autoconnect") return "Saving…"
    if (verb === "profile") return "Updating the eSIM…"
    if (verb === "-c") return "Detecting carrier…"
    return "Working…"
  }

  // Returns false when another action holds the slot, so callers that clear
  // their own input can keep it instead of dropping it on the floor.
  function runAction(cmd) {
    if (actionProc.running) return false
    root.busyLabel = root.labelFor(cmd)
    actionProc.command = ["env", "OMARCHY_CELLULAR_QUIET=1"].concat(cmd)
    actionProc.running = true
    return true
  }

  function toggleData() {
    if (busy) return
    desired = !connected
    runAction([root.cli, "toggle"])
  }

  // Flows that open their own UI (menu pickers, floating terminals); the panel
  // gets out of the way first.
  function runDetached(cmd) {
    root.close()
    if (root.bar) root.bar.run(cmd)
  }

  // Copy without closing the panel: you are usually reading the value you just
  // copied. Masked fields copy what they are hiding, not the dots.
  function copyValue(v) {
    if (!v) return
    copyProc.command = ["wl-copy", "--", v]
    copyProc.running = true
    root.copied = v
    copiedTimer.restart()
  }
  property string copied: ""

  onOpenedChanged: if (!opened) {
    resetStats()
    // Nothing elevated outlives the panel.
    root.esimExpanded = false
    root.sessionStop()
  }

  visible: hwPresent
  implicitWidth: hwPresent ? button.implicitWidth : 0
  implicitHeight: hwPresent ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: [root.cli, "panel"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  // The verbose feed adds byte counters and an interface-bound ping; the ping
  // can burn its full 1s timeout, so only the open panel pays for it.
  Process {
    id: detailsProc
    command: [root.cli, "panel", "--verbose"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (code) {
      root.busyLabel = ""
      // The list is updated before the command runs, so a failure has to put
      // it back or the change appears to take and then revert.
      if (code !== 0 && root.profilesUndo.length > 0) {
        root.profiles = root.profilesUndo
        root.profileError = (actionErr.text || "").trim() || "That did not work."
      } else if (code === 0) {
        // A profile command returns the refreshed list from inside the same
        // authorization. When it does, it replaces the optimistic guess and
        // no second prompt is needed.
        var fresh = root.parseProfiles(actionOut.text || "")
        if (fresh.length > 0) {
          root.profiles = fresh
          root.profilesStale = false
        }
      }
      root.profilesUndo = []
      root.opened ? root.refreshDetails() : root.refresh()
    }
  }

  Process {
    id: sessionProc
    stdinEnabled: true
    stdout: SplitParser { onRead: function (line) { root.sessionLine(line) } }
    stderr: StdioCollector { id: sessionErr; waitForEnd: true }
    onExited: function (code) {
      root.sessionReady = false
      root.sessionVerb = ""
      root.sessionQueue = []
      root.profilesLoading = false
      if (code !== 0 && root.esimExpanded) {
        var e = (sessionErr.text || "").trim()
        if (e !== "") root.profileError = e
      }
    }
  }

  Process { id: copyProc }

  Process {
    id: profileProc
    stdout: StdioCollector { id: profileOut; waitForEnd: true }
    stderr: StdioCollector { id: profileErr; waitForEnd: true }
    onExited: function (code) {
      root.profilesLoading = false
      root.profiles = root.parseProfiles(profileOut.text)
      // An empty list and a failed read look identical otherwise.
      root.profileError = (root.profiles.length === 0)
        ? ((profileErr.text || "").trim() || (code !== 0 ? "Could not read the eSIM." : ""))
        : ""
    }
  }

  Timer {
    id: copiedTimer
    interval: 1200
    onTriggered: root.copied = ""
  }

  // Background poll for the bar icon; the open panel has its own cadence.
  Timer {
    interval: Math.max(2, root.setting("interval", 10)) * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Same rhythm as the Wi-Fi panel's stats poll.
  Timer {
    interval: 1500
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDetails()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    // Powered but not carrying traffic reads as a dimmed glyph.
    opacity: root.connected ? 1 : 0.5
    slotSize: Style.bar.statusSlot
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleData()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.hwPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · title/status · on-off switch ----------
        PanelHero {
          width: parent.width
          title: "Cellular"
          meta: root.statusText
          foreground: root.barForeground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.icon
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              visible: root.installed
              checked: root.switchChecked
              busy: root.busy
              foreground: root.barForeground
              onToggled: root.toggleData()
            }
          }
        }

        // ---------- Connection stats ----------
        // Label/value pairs in two columns; ping rows turn urgent as soon as a
        // probe is lost.
        Row {
          visible: root.connected
          width: parent.width
          spacing: Style.space(20)

          // Paired by row: Receiving/Sending and Downloaded/Uploaded belong
          // together, and a missing field cannot shift the rows below it.
          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Operator"; value: root.info.operator || "—" }
            InfoPair { label: "Signal"; value: (root.info.signal || "0") + "%" }
            InfoPair { label: "RSSI"; value: root.info.sig_rssi || "—" }
            InfoPair { label: "RSRQ"; value: root.info.sig_rsrq || "—" }
            InfoPair {
              label: "Ping"
              value: root.formatPing(root.pingLatency)
              valueColor: root.packetLoss > 0 ? root.urgent : root.barForeground
            }
            InfoPair { label: "Receiving"; value: root.hasTransferStats ? root.formatRate(root.downloadRate) : "--" }
            InfoPair { label: "Downloaded"; value: root.hasTransferStats ? root.formatBytes(parseFloat(root.info.rx_bytes || "0")) : "--" }
            InfoPair { label: "IP"; value: (root.info.ip || "—").split("/")[0]; copyValue: (root.info.ip || "").split("/")[0] }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Technology"; value: root.info.tech || "—" }
            InfoPair {
              label: "Roaming"
              value: root.roaming ? "Yes" : "No"
              valueColor: root.roaming ? root.urgent : root.barForeground
            }
            InfoPair { label: "RSRP"; value: root.info.sig_rsrp || "—" }
            InfoPair { label: "SNR"; value: root.info.sig_snr || "—" }
            InfoPair {
              label: "Packet Loss"
              value: root.formatLoss(root.packetLoss)
              valueColor: root.packetLoss > 0 ? root.urgent : root.barForeground
            }
            InfoPair { label: "Sending"; value: root.hasTransferStats ? root.formatRate(root.uploadRate) : "--" }
            InfoPair { label: "Uploaded"; value: root.hasTransferStats ? root.formatBytes(parseFloat(root.info.tx_bytes || "0")) : "--" }
          }
        }

        // ---------- Switches ----------
        // Header rows: settings you flip rarely and read often belong beside
        // their label.
        PanelSeparator {
          visible: root.installed
          foreground: root.barForeground
        }

        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.space(8)

          SwitchRow {
            width: parent.width
            label: "PRIORITIZE CELLULAR"
            visible: root.hwPresent
            checked: root.info.prefer_cellular === "yes"
            // The route metric behind this is computed, not typed. The tooltip
            // reports the link actually carrying traffic, from `ip route get`.
            tip: root.routeLabel
            onFlipped: root.runAction([root.cli, "prefer",
                                       root.info.prefer_cellular === "yes" ? "wifi" : "cellular"])
          }

          SwitchRow {
            width: parent.width
            label: "METERED"
            checked: root.info.metered === "yes"
            tip: root.info.metered === "yes"
              ? "Apps that honor it defer downloads and updates"
              : "Nothing defers downloads; the data cap still applies"
            onFlipped: root.runAction([root.cli, "metered",
                                       root.info.metered === "yes" ? "no" : "yes"])
          }

          SwitchRow {
            width: parent.width
            label: "AUTOCONNECT"
            checked: root.info.autoconnect === "yes"
            tip: root.info.autoconnect === "yes"
              ? "Cellular comes up at boot"
              : "Cellular stays down until you connect"
            onFlipped: root.runAction([root.cli, "autoconnect",
                                       root.info.autoconnect === "yes" ? "off" : "on"])
          }
        }

        // ---------- Data plan ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(planHeader.implicitHeight, planButton.implicitHeight)

            PanelSectionHeader {
              id: planHeader
              text: "DATA USAGE"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Button {
              id: planButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.limitBytes > 0 ? "Change" : "Set limit"
              fontSize: Style.font.caption
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              active: root.limitEditing
              onClicked: {
                root.limitEditing = !root.limitEditing
                if (root.limitEditing) root.seedLimitFields()
              }
            }
          }

          // Turns urgent at 90% so the cutoff does not surprise you.
          Item {
            visible: root.limitBytes > 0
            width: parent.width
            implicitHeight: Style.space(8)

            Rectangle {
              id: planTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)
            }

            Rectangle {
              anchors.left: planTrack.left
              anchors.verticalCenter: planTrack.verticalCenter
              height: planTrack.height
              radius: planTrack.radius
              width: Math.max(planTrack.height, planTrack.width * root.usedFraction)
              color: root.usedFraction >= 0.9 ? root.urgent : root.barForeground
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }

          // Edited inline, beside the usage it is setting a ceiling for.
          Item {
            width: parent.width
            clip: true
            height: root.limitEditing ? limitCol.implicitHeight : 0
            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

            Column {
              id: limitCol
              width: parent.width
              spacing: Style.space(6)

              // Monthly renews on a date; prepaid bundles run N days from
              // purchase. Neither expresses the other.
              Row {
                id: limitPeriods
                width: parent.width
                spacing: Style.space(4)
                readonly property real cell: (width - spacing * 2) / 3
                readonly property real buttonHeight: monthlyBtn.implicitHeight

                Button {
                  id: monthlyBtn
                  width: limitPeriods.cell
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  text: "Monthly"
                  bordered: true
                  active: root.info.period === "monthly" || !root.info.period
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: root.runAction([root.cli, "limit", "period", "monthly"])
                }

                Button {
                  width: limitPeriods.cell
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  text: "Daily"
                  bordered: true
                  active: root.info.period === "daily"
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: root.runAction([root.cli, "limit", "period", "daily"])
                }

                Button {
                  width: limitPeriods.cell
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  text: "N days"
                  tooltipText: "A fixed-length bundle, counted from the day you bought it"
                  bordered: true
                  active: root.info.period === "days"
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: root.runAction([root.cli, "limit", "days",
                                             root.info.period_days || "30"])
                }
              }

              // Two short numbers do not each need a full-width box.
              Row {
                width: parent.width
                spacing: Style.space(6)
                readonly property bool paired: root.info.period !== "daily"
                readonly property real cell: paired ? (width - spacing) / 2 : width

                Column {
                  width: parent.cell
                  spacing: Style.space(4)

                  PanelSectionHeader {
                    text: "LIMIT"
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                  }

                  TextField {
                    id: limitField
                    width: parent.width
                    height: limitPeriods.buttonHeight
                    font.pixelSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    // Seeded on open, not bound: a binding to root.info is
                    // re-asserted on every status poll and overwrites typing.
                    placeholderText: "5G, 500M; blank for off"
                    foreground: root.barForeground
                    onAccepted: {
                      var v = text.trim()
                      if (!root.runAction([root.cli, "limit", v === "" ? "off" : v]))
                        return
                      root.limitEditing = false
                    }
                  }
                }

                Column {
                  visible: parent.paired
                  width: parent.cell
                  spacing: Style.space(4)

                  PanelSectionHeader {
                    text: root.info.period === "days" ? "LENGTH" : "RENEWAL DAY"
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                  }

                  TextField {
                    id: resetDayField
                    visible: root.info.period !== "days"
                    width: parent.width
                    height: limitPeriods.buttonHeight
                    font.pixelSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    placeholderText: "1-31"
                    foreground: root.barForeground
                    onAccepted: root.runAction([root.cli, "limit", "day", text.trim()])
                  }

                  TextField {
                    id: periodDaysField
                    visible: root.info.period === "days"
                    width: parent.width
                    height: limitPeriods.buttonHeight
                    font.pixelSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    placeholderText: "days, from today"
                    foreground: root.barForeground
                    onAccepted: root.runAction([root.cli, "limit", "days", text.trim()])
                  }
                }
              }



              // Zeroes the counter, and on a fixed-length bundle restarts the
              // window: topping up buys new days as well as new bytes.
              Item {
                width: parent.width
                implicitHeight: resetLink.implicitHeight

                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.info.period === "days" && root.info.period_start
                  text: "Started " + root.info.period_start
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  id: resetLink
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.info.period === "days" ? "Reset and restart" : "Reset counter"
                  color: root.barForeground
                  opacity: resetArea.containsMouse ? 1 : 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: resetArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.runAction([root.cli, "limit", "reset"])
                      root.limitEditing = false
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: planUsed.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: planUsed
              anchors.left: parent.left
              text: root.limitBytes > 0
                // The limit is stored as typed, so "3g" comes back lowercase.
                ? root.formatBytes(root.usedBytes) + " of "
                  + ((root.info.limit || root.formatBytes(root.limitBytes)).toUpperCase())
                  + (root.limitAck ? "  ·  cutoff off" : "")
                : "Used: " + root.formatBytes(root.usedBytes)
              color: root.usedFraction >= 1 ? root.urgent : root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              text: root.nextResetLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // NetworkManager down: say what is wrong instead of showing dead controls.
        Text {
          textFormat: Text.PlainText
          visible: !root.installed
          width: parent.width
          wrapMode: Text.WordWrap
          text: "NetworkManager is not running — it owns the cellular connection."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Radio mode ----------
        // Generation, not band: this modem reports 64 bands, and 3g/4g/5g is
        // the choice that matters when 5G is flaky.
        PanelSeparator {
          visible: root.hwPresent
          foreground: root.barForeground
        }

        // Label and pills on one line, like the switch rows.
        Item {
          visible: root.hwPresent
          width: parent.width
          implicitHeight: Math.max(modeLabel.implicitHeight, modeRow.implicitHeight)

          PanelSectionHeader {
            id: modeLabel
            text: "RADIO MODE"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          Row {
            id: modeRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            // Whatever the label leaves, less a gap so the two never touch.
            readonly property real avail: Math.max(0, parent.width - modeLabel.implicitWidth - Style.space(10))
            readonly property real cellWidth: (avail - spacing * (root.modeChips.length - 1)) / Math.max(1, root.modeChips.length)
            enabled: !root.busy
            opacity: root.busy ? 0.5 : 1

            Repeater {
              model: root.modeChips
              Button {
                required property var modelData
                width: modeRow.cellWidth
                // Sized to sit with the switch rows above; a set-once
                // preference, not a primary control.
                fontSize: Style.font.caption
                verticalPadding: Style.space(2)
                text: modelData.label
                bordered: true
                active: root.modesAllowed === modelData.match
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: if (root.modesAllowed !== modelData.match)
                             root.runAction([root.cli, "mode", modelData.id])
              }
            }
          }
        }

        // ---------- APN ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          // Label left, current value right, whole row clickable. Three ways to
          // set an APN is a lot of panel for something set once.
          Item {
            width: parent.width
            implicitHeight: Math.max(apnLabel.implicitHeight, apnValue.implicitHeight)

            PanelSectionHeader {
              id: apnLabel
              text: "APN"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
              opacity: apnArea.containsMouse ? 0.7 : 1
            }

            Text {
              textFormat: Text.PlainText
              id: apnChevron
              anchors.right: parent.right
              anchors.verticalCenter: apnLabel.verticalCenter
              anchors.verticalCenterOffset: Math.round(apnLabel.topPadding / 2)
              text: root.carrierExpanded ? "󰅀" : "󰅂"
              color: root.barForeground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              id: apnValue
              anchors.right: apnChevron.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: apnLabel.verticalCenter
              anchors.verticalCenterOffset: Math.round(apnLabel.topPadding / 2)
              width: Math.max(0, parent.width - apnLabel.implicitWidth
                                 - apnChevron.implicitWidth - Style.space(16))
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              text: root.info.apn || "from network"
              color: root.barForeground
              opacity: root.info.apn ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: apnArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.carrierExpanded = !root.carrierExpanded
                if (!root.carrierExpanded) root.apnEditing = false
              }
            }
          }

          Row {
            id: carrierRow
            visible: root.carrierExpanded
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * 2) / 3

            Button {
              width: carrierRow.cellWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󰐷"
              text: "Detect"
              tooltipText: "Read the carrier off the SIM and apply its APN"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              // Needs no input and the panel shows the result, so it runs in
              // place.
              onClicked: root.runAction(["sh", "-c", JSON.stringify(root.cli) + " carrier auto && " + JSON.stringify(root.cli) + " apply"])
            }

            Button {
              width: carrierRow.cellWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󰇧"
              text: "Lookup"
              tooltipText: "Find your carrier's APN in the provider database"
              bordered: true
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.runDetached(root.cli + " carrier choose")
            }

            Button {
              width: carrierRow.cellWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󰑪"
              text: "APN"
              tooltipText: "Type an APN by hand"
              bordered: true
              active: root.apnEditing
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: {
                root.apnEditing = !root.apnEditing
                if (root.apnEditing) apnField.text = root.info.apn || ""
                if (root.apnEditing) apnField.forceActiveFocus()
              }
            }

          }

          // Inline; the panel already takes keyboard focus for its own
          // navigation. Collapsed to zero height when unused.
          Item {
            width: parent.width
            clip: true
            height: (root.carrierExpanded && root.apnEditing) ? apnField.implicitHeight : 0

            TextField {
              id: apnField
              font.pixelSize: Style.font.caption
              verticalPadding: Style.space(2)
              width: parent.width
              placeholderText: "APN — blank lets the network choose"
              foreground: root.barForeground
              enabled: !root.busy
              opacity: root.busy ? 0.5 : 1
              onAccepted: {
                if (!root.runAction(["sh", "-c", JSON.stringify(root.cli) + " apn " + JSON.stringify(text) + " && " + JSON.stringify(root.cli) + " apply"]))
                  return
                root.apnEditing = false
              }
            }
          }
        }

        // ---------- Device ----------
        PanelSeparator {
          visible: root.hwPresent
          foreground: root.barForeground
        }

        Column {
          visible: root.hwPresent
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: detailsHeader.implicitHeight

            PanelSectionHeader {
              id: detailsHeader
              text: "DEVICE"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              opacity: headerArea.containsMouse ? 0.7 : 1
            }

            // The modem is named beside the chevron while collapsed. Expanded,
            // the name is in the rows below and the space goes to the reveal
            // toggle.
            Text {
              textFormat: Text.PlainText
              id: chevron
              anchors.right: parent.right
              anchors.verticalCenter: detailsHeader.verticalCenter
              anchors.verticalCenterOffset: Math.round(detailsHeader.topPadding / 2)
              text: root.deviceExpanded ? "󰅀" : "󰅂"
              color: root.barForeground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              id: deviceName
              visible: !root.deviceExpanded
              anchors.right: chevron.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: detailsHeader.verticalCenter
              anchors.verticalCenterOffset: Math.round(detailsHeader.topPadding / 2)
              width: Math.max(0, parent.width - detailsHeader.implicitWidth
                                 - chevron.implicitWidth - Style.space(16))
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              text: root.info.model || ""
              color: root.barForeground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              id: revealButton
              visible: root.deviceExpanded
              anchors.right: chevron.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: detailsHeader.verticalCenter
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: root.detailsRevealed ? "󰈉" : "󰛐"
              tooltipText: root.detailsRevealed ? "Hide identifiers" : "Reveal identifiers"
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.detailsRevealed = !root.detailsRevealed
            }

            MouseArea {
              id: headerArea
              anchors.left: parent.left
              anchors.right: root.deviceExpanded ? revealButton.left : chevron.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.deviceExpanded = !root.deviceExpanded
            }
          }

          // One column: ICCID is 19 digits and IMEI 15, which overflow a
          // half-width cell.
          Item {
            width: parent.width
            clip: true
            // No height animation: the panel is a layer-shell surface, so
            // animating this reconfigures the Wayland surface every frame.
            height: root.deviceExpanded ? deviceRows.implicitHeight : 0

          Column {
            id: deviceRows
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Number"; value: root.maskId(root.info.number); copyValue: root.info.number || "" }
            InfoPair { label: "IMEI"; value: root.maskId(root.info.imei); copyValue: root.info.imei || "" }
            // A physical card has an ICCID; an unprovisioned eUICC has only an
            // EID. Showing both means one is always blank.
            InfoPair {
              visible: !!root.info.iccid
              label: "ICCID"
              value: root.maskId(root.info.iccid)
              copyValue: root.info.iccid || ""
            }
            // Only present on an eUICC; a physical card has no EID.
            InfoPair {
              visible: !!root.info.eid
              label: "EID"
              value: root.maskId(root.info.eid)
              copyValue: root.info.eid || ""
            }
            InfoPair { label: "Carrier"; value: root.info.carrier_config || "—" }
            InfoPair { label: "Modem"; value: root.info.model || "—" }
            InfoPair { label: "Firmware"; value: root.info.firmware || "—" }
          }
          }
        }

        // ---------- SIM slot ----------
        PanelSeparator { foreground: root.barForeground }

        Column {
          width: parent.width
          spacing: Style.space(10)

          // What is in the slot, beside the title. The card's provider, not the
          // network operator: an Airalo profile roaming on Verizon reads
          // "Airalo" here and "Verizon Wireless" in the hero.
          Item {
            width: parent.width
            implicitHeight: Math.max(simHeader.implicitHeight, simWho.implicitHeight)

            PanelSectionHeader {
              id: simHeader
              text: "SIM CARD"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              id: simWho
              anchors.right: parent.right
              anchors.verticalCenter: simHeader.verticalCenter
              anchors.verticalCenterOffset: Math.round(simHeader.topPadding / 2)
              width: Math.max(0, parent.width - simHeader.implicitWidth - Style.space(10))
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              text: root.simLabel
              color: root.barForeground
              opacity: text === "" ? 0 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            id: simRow
            width: parent.width
            spacing: Style.space(6)
            // Three cells only when the eSIM is selected, and not equal thirds:
            // "eSIM Profiles" is twice the label the slots carry.
            readonly property int cells: root.hasEsim ? 3 : 2
            readonly property real usable: width - spacing * (cells - 1)
            readonly property real cellWidth: cells === 3 ? usable * 0.28 : usable / 2
            readonly property real wideWidth: usable - cellWidth * 2
            // A slot switch is in flight; the row is unavailable until it lands.
            enabled: !root.busy
            opacity: root.busy ? 0.5 : 1

            Button {
              width: simRow.cellWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󰒧"
              text: root.slotHasCard(root.physicalSlot) ? "Physical" : "Physical · empty"
              tooltipText: root.slotHasCard(root.physicalSlot) ? "" : "No card in the slot"
              opacity: root.slotHasCard(root.physicalSlot) ? 1 : 0.55
              bordered: true
              active: root.info.slot === root.physicalSlot
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: if (root.info.slot !== root.physicalSlot)
                           root.runAction([root.cli, "sim", root.physicalSlot])
            }

            Button {
              width: simRow.cellWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󱤓"
              text: root.slotHasCard(root.esimSlot) ? "eSIM" : "eSIM · empty"
              tooltipText: root.slotHasCard(root.esimSlot) ? "" : "No profile installed on the eSIM"
              opacity: root.slotHasCard(root.esimSlot) ? 1 : 0.55
              bordered: true
              active: root.info.slot === root.esimSlot
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: if (root.info.slot !== root.esimSlot)
                           root.runAction([root.cli, "sim", root.esimSlot])
            }

            // The lock glyph says the click costs an authorization prompt.
            // Present whenever the modem has an eUICC, but only usable while
            // that eUICC is the selected card: it cannot answer otherwise, and
            // selecting it drops the connection, which is the user's call.
            Button {
              visible: root.hasEsim
              enabled: root.esimSelected
              opacity: root.esimSelected ? 1 : 0.5
              width: simRow.wideWidth
              fontSize: Style.font.caption
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              iconText: "󰌾"
              text: "eSIM Profiles"
              tooltipText: !root.esimSelected
                           ? "Select the eSIM first to manage its profiles"
                           : root.info.esim_transport === "mbim"
                             ? "Reads the eSIM over MBIM; data keeps running"
                             : "Needs lpac built with the mbim driver"
              bordered: true
              active: root.esimExpanded
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: {
                root.esimExpanded = !root.esimExpanded
                // The one authorization is spent here, on opening the list.
                // Closing it ends the elevated half rather than leaving it.
                if (root.esimExpanded) root.loadProfiles()
                else root.sessionStop()
              }
            }
          }
        }


          // Collapsed until asked for; listing profiles stops ModemManager and
          // needs a prompt.
          Item {
            width: parent.width
            clip: true
            height: root.esimExpanded ? esimCol.implicitHeight : 0

            Column {
              id: esimCol
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                visible: root.profilesLoading
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Reading the eSIM…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                visible: !root.profilesLoading && root.profiles.length === 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.profileError
                  ? root.profileError + "  Try Refresh."
                  : "No profiles installed on this eSIM."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.profiles
                Row {
                  id: profileRow
                  required property var modelData
                  width: esimCol.width
                  spacing: Style.space(4)
                  // Explicit chip width: Button.implicitWidth includes its
                  // horizontal padding, so `width: height` does not actually
                  // make a square and the last chip lands off the panel.
                  readonly property real chip: Style.font.body * 2

                  Button {
                    id: profileName
                    width: profileRow.width - profileRow.spacing * 2 - profileRow.chip * 2
                    height: addBtn.height
                    fontSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    text: root.shortLabel(modelData.name, modelData.provider,
                                          modelData.iccid)
                    tooltipText: (root.profileEnabled(modelData)
                      ? "Active profile" : "Switch to this profile")
                      + (modelData.class === "test" ? " (test profile)" : "")
                    bordered: true
                    active: root.profileEnabled(modelData)
                    // Never dim the enabled one; stacked with the selected fill
                    // it cancels the highlight out.
                    opacity: modelData.class === "test"
                      && !root.profileEnabled(modelData) ? 0.6 : 1
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                    onClicked: if (!root.profileEnabled(modelData)) {
                      root.sessionSend("enable " + modelData.iccid)
                      root.applyProfileChange(modelData.iccid, "enable")
                    }
                  }

                  Button {
                    width: profileRow.chip
                    height: addBtn.height
                    iconSize: Style.font.caption
                    fontSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    horizontalPadding: Style.space(2)
                    iconText: "󰑕"
                    tooltipText: "Rename"
                    bordered: true
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                    onClicked: {
                      root.renamingIccid = root.renamingIccid === modelData.iccid
                        ? "" : modelData.iccid
                      if (root.renamingIccid !== "") {
                        renameField.text = modelData.name || ""
                        renameField.forceActiveFocus()
                      }
                    }
                  }

                  Button {
                    width: profileRow.chip
                    height: addBtn.height
                    iconSize: Style.font.caption
                    fontSize: Style.font.caption
                    verticalPadding: Style.space(2)
                    horizontalPadding: Style.space(2)
                    iconText: "󰩹"
                    tooltipText: root.profileEnabled(modelData)
                      ? "Can't delete the active profile — switch to another first"
                      : "Delete this profile"
                    bordered: true
                    opacity: root.profileEnabled(modelData) ? 0.4 : 1
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                    onClicked: if (!root.profileEnabled(modelData)) {
                      root.sessionSend("delete " + modelData.iccid)
                      root.applyProfileChange(modelData.iccid, "delete")
                    }
                  }
                }
              }

              Item {
                width: parent.width
                clip: true
                height: root.renamingIccid !== "" ? renameField.implicitHeight : 0

                TextField {
                  id: renameField
                  font.pixelSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  width: parent.width
                  placeholderText: "New name — Esc to cancel"
                  foreground: root.barForeground
                  Keys.onEscapePressed: { root.renamingIccid = ""; text = "" }
                  onAccepted: {
                    var target = root.renamingIccid
                    if (target !== "" && text.trim() !== "") {
                      root.sessionSend("nickname " + target + " " + text.trim())
                      root.applyProfileChange(target, "rename", text.trim())
                    }
                    root.renamingIccid = ""
                    text = ""
                  }
                }
              }

              Row {
                width: esimCol.width
                spacing: Style.space(4)

                Button {
                  // The height every other control in this area matches. Left
                  // to size itself; a formula misses the border reserve.
                  id: addBtn
                  width: (esimCol.width - Style.space(4)) / 2
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  iconText: "󰐕"
                  text: "Add profile"
                  tooltipText: "Install a new eSIM from an activation code"
                  bordered: true
                  active: root.addingProfile
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.addingProfile = !root.addingProfile
                    if (root.addingProfile) codeField.forceActiveFocus()
                  }
                }

                Button {
                  width: (esimCol.width - Style.space(4)) / 2
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(2)
                  iconText: "󰑐"
                  text: root.profilesStale ? "Refresh · after scan" : "Refresh"
                  tooltipText: root.profilesStale
                    ? "A scan ran; re-read the eSIM to see what it installed"
                    : "Re-read profiles from the eSIM"
                  bordered: true
                  active: root.profilesStale
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  onClicked: {
                    root.profilesStale = false
                    root.profiles = []
                    root.loadProfiles()
                  }
                }
              }

              Item {
                width: parent.width
                clip: true
                height: root.addingProfile ? addRow.implicitHeight : 0

                Row {
                  id: addRow
                  width: parent.width
                  spacing: Style.space(4)
                  readonly property real chip: Style.font.body * 2

                  Button {
                    width: parent.chip
                    height: codeField.height
                    fontSize: Style.font.caption
                    verticalPadding: Style.space(3)
                    horizontalPadding: Style.space(2)
                    iconSize: Style.font.caption
                    iconText: "󰐫"
                    tooltipText: "Scan a QR code off the screen"
                    bordered: true
                    foreground: root.barForeground
                    fontFamily: root.fontFamily
                    // Detached: slurp puts up its own layer-shell surface, and
                    // as a child of the shell process it lands beneath the
                    // panel, running but invisible.
                    onClicked: {
                      root.addingProfile = false
                      root.runDetached(root.cli + " profile scan")
                      root.profilesStale = true
                    }
                  }

                TextField {
                  id: codeField
                  font.pixelSize: Style.font.caption
                  verticalPadding: Style.space(3)
                  width: parent.width - parent.chip - parent.spacing
                  placeholderText: "Paste code, or scan →"
                  foreground: root.barForeground
                  Keys.onEscapePressed: {
                    root.addingProfile = false
                    text = ""
                  }
                  onAccepted: {
                    if (text.trim() !== "") {
                      root.sessionSend("download " + text.trim())
                      root.profileError = "Downloading…"
                    }
                    root.addingProfile = false
                    text = ""
                  }
                }
                }
              }
            }
          }


      }
    }
  }

  // Label left, switch right. Centered on the label's glyphs, not its box:
  // PanelSectionHeader carries topPadding for Nerd Font overshoot, which a
  // plain verticalCenter would follow and sit the switch high.
  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property string tip: ""
    property bool checked: false
    signal flipped()

    implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)

    PanelSectionHeader {
      id: rowLabel
      text: switchRow.label
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.barForeground
      fontFamily: root.fontFamily
    }

    ToggleSwitch {
      id: rowSwitch
      anchors.right: parent.right
      trackHeight: Math.round(rowLabel.font.pixelSize * 1.2)
      cursorPad: Style.space(3)
      anchors.verticalCenter: rowLabel.verticalCenter
      anchors.verticalCenterOffset: Math.round(rowLabel.topPadding / 2)
      checked: switchRow.checked
      busy: root.busy
      foreground: root.barForeground
      onToggled: switchRow.flipped()

      PanelToolTip {
        visible: rowSwitch.containsMouse && switchRow.tip !== ""
        text: switchRow.tip
        fontFamily: root.fontFamily
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property string copyValue: ""
    property color valueColor: root.barForeground
    readonly property bool copyable: copyValue !== ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      id: labelText
      text: parent.label
      color: root.barForeground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Right-aligned in whatever the label leaves, and elided: operator names
    // are long and this modem truncates them at 20 characters already.
    Text {
      textFormat: Text.PlainText
      id: valueText
      width: Math.max(0, parent.width - labelText.implicitWidth - parent.spacing)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
      text: root.copied !== "" && root.copied === parent.copyValue ? "copied" : parent.value
      color: parent.valueColor
      opacity: copyArea.containsMouse ? 0.7 : 1
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        id: copyArea
        anchors.fill: parent
        enabled: valueText.parent.copyable
        hoverEnabled: enabled
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copyValue(valueText.parent.copyValue)
      }
    }
  }
}
