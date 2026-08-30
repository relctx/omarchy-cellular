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
  property double absentSince: 0
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
  property string sessionArg: ""
  property var sessionLines: []

  function sessionStart() {
    if (sessionProc.running) return
    // The queue is left alone: the click that starts the session has
    // usually already queued the command it wants run.
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
    root.sessionArg = cmd.indexOf(" ") > 0 ? cmd.substring(cmd.indexOf(" ") + 1) : ""
    root.sessionLines = []
    root.profilesLoading = true
    // A mutation takes the eUICC several seconds; show a busy label in the
    // status line, not only inside the Manage box.
    if (root.sessionVerb === "enable") root.busyLabel = "Switching profile…"
    else if (root.sessionVerb !== "list" && root.sessionVerb !== "chipinfo")
      root.busyLabel = "Updating the eSIM…"
    sessionProc.write(cmd + "\n")
  }

  function sessionLine(line) {
    if (line.indexOf("euicc_free=") === 0) {
      var b = parseFloat(line.substring(11))
      root.euiccFree = isNaN(b) || b <= 0 ? "" : root.formatBytes(b) + " free"
      return
    }
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
    var arg = root.sessionArg
    var lines = root.sessionLines
    root.sessionVerb = ""
    root.sessionLines = []
    root.profilesLoading = false
    if (verb !== "list" && verb !== "chipinfo") root.busyLabel = ""

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
    // The change landed. The authoritative list costs nothing now, and the
    // main feed re-reads so the card list and identity follow immediately
    // instead of waiting out the poll interval.
    root.sessionSend("list")
    // Enabling through the session switches the card but skips the switch
    // bookkeeping. `settle` runs it: config follows the card, NetworkManager
    // reapplies its settings, and the connection is brought back up.
    if (verb === "enable" && arg !== "")
      root.runAction([root.cli, "settle", arg])
    root.opened ? root.refreshDetails() : root.refresh()
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

  // The published 3GPP quality tiers, as carrier field guides print them.
  // A lookup table, not judgment: the label sits beside the number.
  function sigTier(kind, raw) {
    var v = parseFloat(raw)
    if (isNaN(v)) return ""
    if (kind === "rsrp")
      return v >= -80 ? "excellent" : v >= -90 ? "good" : v >= -100 ? "fair"
           : v >= -110 ? "poor" : "cell edge"
    if (kind === "rsrq")
      return v >= -10 ? "good" : v >= -15 ? "fair" : v >= -20 ? "poor" : "cell edge"
    if (kind === "snr")
      return v > 20 ? "excellent" : v >= 13 ? "good" : v >= 0 ? "fair" : "poor"
    if (kind === "rssi")
      return v >= -65 ? "excellent" : v >= -75 ? "good" : v >= -85 ? "fair"
           : v >= -95 ? "poor" : "weak"
    return ""
  }
  // Color carries the tier tables' judgment: red where the link is in
  // trouble, plain otherwise, matching how the ping rows already behave.
  function sigColor(kind, raw) {
    var t = sigTier(kind, raw)
    return (t === "poor" || t === "cell edge" || t === "weak") ? urgent : barForeground
  }

  // Strength history for the sparkline, fed by whatever updates the feed —
  // events while closed, the stats cadence while open. Five minutes. RSRP
  // when the modem reports it, RSSI when that is all there is; the two never
  // share a line, so a metric change restarts the history.
  property var rsrpHistory: []
  property string sparkMetric: ""
  property double sparkGapStart: 0
  function recordStrength(rsrp, rssi) {
    var now = Date.now()
    // Sticky metric: the modem alternates which strength field it reports
    // sample to sample, and switching on every alternation wiped the
    // history and blinked the chart. Stay on the current metric through
    // gaps; a sample without it is skipped, and only a sustained absence
    // (45s) switches to whatever is still reporting.
    var metric = sparkMetric || (rsrp ? "RSRP" : rssi ? "RSSI" : "")
    if (metric === "") return
    var raw = metric === "RSRP" ? rsrp : rssi
    if (!raw) {
      if (sparkGapStart === 0) { sparkGapStart = now; return }
      if (now - sparkGapStart < 45000) return
      var alt = rsrp ? "RSRP" : rssi ? "RSSI" : ""
      if (alt === "") return
      metric = alt
      raw = metric === "RSRP" ? rsrp : rssi
      rsrpHistory = []
    }
    sparkGapStart = 0
    var v = parseFloat(raw)
    if (isNaN(v)) return
    var h = sparkMetric === metric ? rsrpHistory.slice() : []
    sparkMetric = metric
    if (h.length > 0 && now - h[h.length - 1].t < 2000) return
    h.push({ t: now, v: v })
    while (h.length > 0 && now - h[0].t > 300000) h.shift()
    rsrpHistory = h
  }

  // Which management box is open: "", "device", "sim" or "apn". One at a
  // time; the chip row at the bottom drives it.
  property string mgmtView: ""
  function toggleMgmt(v) {
    mgmtView = (mgmtView === v) ? "" : v
    if (mgmtView === "apn") carrierExpanded = true
    if (mgmtView === "device") deviceExpanded = true
    if (mgmtView !== "sim" && esimExpanded) {
      esimExpanded = false
      sessionStop()
    }
  }

  // The active identity, named for the summary line.
  readonly property string activeSimName: {
    for (var i = 0; i < sims.length; i++) {
      if (sims[i].active !== "yes") continue
      var n = sims[i].name || sims[i].provider || ""
      if (sims[i].provider && sims[i].provider !== sims[i].name)
        n += "  ·  " + sims[i].provider
      return n
    }
    return simLabel
  }

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

  // The card list, parsed from the same feed as everything else.
  property var sims: []

  // Every modem present. The Device box shows a picker only when there is
  // more than one.
  property var devices: []

  // Text messages: loaded when the box opens and when one arrives. The
  // Messaging.Added signal rides the same event feed as everything else.
  property string euiccFree: ""
  property var smsList: []
  property var smsSeen: null
  property string smsOpen: ""
  // A reload requested mid-read runs again when the read finishes: the
  // trigger was an event this read may have started too early to see.
  property bool smsReloadQueued: false
  function loadSms() {
    if (smsProc.running) { smsReloadQueued = true; return }
    smsProc.running = true
  }

  // Carrier browser: the provider database, staged country -> carrier ->
  // APN, all unprivileged reads of the shipped database.
  property bool apnBrowse: false
  property string browseCc: ""
  property string browseCcName: ""
  property string browseProv: ""
  property var browseRows: []

  function browseLoad() {
    browseRows = []
    var cmd = [cli, "carrier", "list"]
    if (browseCc !== "") cmd.push(browseCc)
    if (browseProv !== "") cmd.push(browseProv)
    browseProc.running = false
    browseProc.command = cmd
    browseProc.running = true
  }

  // Runs in root scope: a row click rebuilds the list model, which destroys
  // the delegate whose handler is still executing — state changes made there
  // are lost mid-statement. The delegate hands its row here and does nothing
  // else.
  function browsePick(m) {
    browseFilter.text = ""
    if (m.kind === "back") {
      if (browseProv !== "") browseProv = ""
      else { browseCc = ""; browseCcName = "" }
      browseLoad()
    } else if (m.kind === "country") {
      browseCc = m.c0
      browseCcName = m.label
      browseLoad()
    } else if (m.kind === "provider") {
      browseProv = m.c0
      browseLoad()
    } else {
      apnBrowse = false
      runAction([cli, "carrier", "set", browseCc, browseProv, m.c0],
                [cli, "apply"])
    }
  }

  // Diagnostics: read on demand behind one authorization, never polled.
  property var diagCells: []
  property var diagServing: ({})
  property bool diagLoading: false

  property var diagCa: []

  // One model for the table: the carriers actually in use lead it — primary
  // then activated secondaries, each with its width — then everything else
  // the radio hears. Measured cells merge with carriers by band and cell id.
  readonly property var diagRows: {
    var out = []
    var claimed = {}
    for (var i = 0; i < diagCells.length; i++) {
      var c = diagCells[i]
      var isServing = c.pci === diagServing.pci
      var bandNum = String(c.band || "").replace(/^[bn]/, "")
      var role = isServing ? "P" : ""
      var w = isServing ? (diagServing.width || "") : ""
      for (var k = 0; k < diagCa.length; k++) {
        var a = diagCa[k]
        if (a.band === bandNum && a.pci === c.pci) {
          role = a.role
          w = a.width || w
          claimed[k] = true
          break
        }
      }
      out.push({
        serving: isServing || role === "P",
        role: role,
        gen: String(c.band || "").charAt(0) === "n" ? "5G" : "LTE",
        band: bandNum + (c.name && c.name !== "5G NR" ? " " + c.name : ""),
        ch: (isServing ? (diagServing.channel || c.chan) : c.chan) || "—",
        id: c.pci,
        width: w,
        rsrp: c.rsrp,
        rssi: c.rssi || ""
      })
    }
    // Carriers in use that no measured row matched still belong in the list.
    for (k = 0; k < diagCa.length; k++) {
      if (claimed[k]) continue
      a = diagCa[k]
      out.push({
        serving: a.role === "P",
        role: a.role,
        gen: "LTE",
        band: a.band,
        ch: a.chan && a.chan !== "0" ? a.chan : "—",
        id: a.pci,
        width: a.width,
        rsrp: "",
        rssi: ""
      })
    }
    out.sort(function (a, b) {
      var r = function (x) { return x.role === "P" ? 0 : x.role === "S" ? 1 : 2 }
      return r(a) - r(b)
    })
    // The camped cell is not always in the measured list; add a row for it
    // when missing.
    if (diagServing.band !== undefined && (out.length === 0 || !out[0].serving)) {
      out.unshift({
        serving: true,
        gen: String(diagServing.band || "").indexOf("nr5g") === 0 ? "5G" : "LTE",
        band: String(diagServing.band || "").replace(/^eutran-|^nr5g-|^b/, "")
              + (diagServing.name ? " " + diagServing.name : ""),
        ch: diagServing.channel || "—",
        id: diagServing.pci || "—",
        width: diagServing.width || "",
        rsrp: "",
        rssi: ""
      })
    }
    return out
  }

  readonly property var diagServingCell: {
    for (var i = 0; i < diagCells.length; i++)
      if (diagCells[i].pci === diagServing.pci) return diagCells[i]
    return null
  }
  readonly property var diagOtherCells: {
    var out = []
    for (var i = 0; i < diagCells.length; i++)
      if (diagCells[i].pci !== diagServing.pci) out.push(diagCells[i])
    return out
  }

  // Radio jargon translated: which generation, which numbered band, and the
  // spectrum a person might recognize.
  function bandLabel(band, name) {
    var b = String(band || "")
    var nrFreq = { 25: "1900 MHz", 41: "2.5 GHz", 66: "AWS", 71: "600 MHz",
                   77: "3.7 GHz", 78: "3.5 GHz", 260: "mmWave", 261: "mmWave" }
    var m = b.match(/^nr5g-(\d+)$|^n(\d+)$/)
    if (m) {
      var n = m[1] || m[2]
      return "5G · band " + n + (nrFreq[n] ? " (" + nrFreq[n] + ")" : "")
    }
    m = b.match(/^eutran-(\d+)$|^b(\d+)$/)
    if (m) {
      var e = m[1] || m[2]
      return "LTE · band " + e + (name ? " (" + name + ")" : "")
    }
    return b
  }

  function parseServing(text) {
    var out = {}
    var lines = (text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^serving\.([a-z]+)=(.*)$/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  function parseIndexed(text, prefix) {
    var byIndex = {}
    var lines = (text || "").split("\n")
    var re = new RegExp("^" + prefix + "\\.(\\d+)\\.([a-z]+)=(.*)$")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(re)
      if (!m) continue
      if (!byIndex[m[1]]) byIndex[m[1]] = {}
      byIndex[m[1]][m[2]] = m[3]
    }
    var out = []
    var keys = Object.keys(byIndex).sort(function (a, b) { return a - b })
    for (var k = 0; k < keys.length; k++) out.push(byIndex[keys[k]])
    return out
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
  property string busyVerb: ""
  // The last failed action's own words, shown where the chips are until the
  // next action clears it. The CLI already notifies; this is for the panel
  // that was open when it happened.
  function notifyError(msg) {
    Quickshell.execDetached(["omarchy-notification-send", "-u", "critical", "Cellular", msg])
  }
  function maskId(v) {
    if (!v) return "—"
    return detailsRevealed ? v : v.slice(0, 4) + "•".repeat(Math.max(0, v.length - 4))
  }
  // Defaults to the empty cellular outline until the first read lands.
  readonly property string icon: info.icon || "󰢿"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)

  // The switch flips instantly on click; while the toggle is in flight it
  // shows the target state, not the current one.
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
  // The modem's report of the active slot outranks the configured one; the
  // config can lag a switch made through a profile enable.
  readonly property bool esimSelected: (info.active_slot || info.slot) === esimSlot
  readonly property string physicalSlot: esimSlot === "1" ? "2" : "1"
  function slotHasCard(slot) { return info["slot" + slot + "_sim"] !== "no" }
  readonly property real usedFraction: limitBytes > 0 ? Math.min(1, usedBytes / limitBytes) : 0
  // Where "today" sits in the billing cycle. Usage left of this tick is
  // under pace; right of it is burning ahead of the calendar.
  readonly property real cycleFraction: {
    var st = Date.parse(info.period_start || "")
    var en = Date.parse(info.next_reset || "")
    if (isNaN(st) || isNaN(en) || en <= st) return -1
    return Math.min(1, Math.max(0, (Date.now() - st) / (en - st)))
  }
  readonly property string nextResetLabel: {
    if (!info.next_reset) return ""
    var d = new Date(info.next_reset + "T00:00:00")
    if (isNaN(d.getTime())) return ""
    return "Resets " + Qt.formatDate(d, "MMM d")
  }
  // When the meter began counting, distinct from when the period began.
  // Shown as the CLI records it: a timestamp of the moment the reset
  // control was used.
  readonly property string startedLabel:
    info.counting_since ? "Started " + info.counting_since : ""

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
    // Same policy for a modem that momentarily left the bus (ModemManager
    // re-enumerates it during profile and slot operations): every field
    // reads empty, not changed. Hold the last real state briefly; a modem
    // that stays gone gets reported honestly.
    if (next.state === "absent" && next.hw === "yes"
        && info.state && info.state !== "absent" && info.state !== "disabled") {
      if (absentSince === 0) absentSince = Date.now()
      if (Date.now() - absentSince < 75000) return
    }
    absentSince = 0
    updateStats(next)
    info = next
    // A poll that races modem re-enumeration reads the modem object before
    // its SIM slots repopulate: zero cards, everything else healthy. Keep
    // the tiles; a modem with genuinely no cards reports nosim or absent.
    var freshSims = parseIndexed(raw, "sim")
    if (freshSims.length > 0 || sims.length === 0
        || next.state === "nosim" || next.state === "absent" || next.hw !== "yes")
      sims = freshSims
    devices = parseIndexed(raw, "dev")
    recordStrength(next.sig_rsrp, next.sig_rssi)
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
    if (verb === "use") return "Switching SIM…"
    if (verb === "mode") return "Setting radio mode…"
    if (verb === "settle") return "Reconnecting…"
    if (verb === "device") return "Switching modem…"
    if (verb === "apply") return "Applying…"
    if (verb === "carrier") return cmd[2] === "auto" ? "Detecting carrier…" : "Setting carrier…"
    if (verb === "autoconnect") return "Saving…"
    if (verb === "profile") return "Updating the eSIM…"
    if (verb === "-c") return "Detecting carrier…"
    return "Working…"
  }

  // Returns false when another action is already running, so callers that
  // clear their own input can keep it instead of losing it.
  property var actionFollow: []
  function runAction(cmd, follow) {
    if (actionProc.running) return false
    root.actionFollow = follow || []
    root.busyLabel = root.labelFor(cmd)
    root.busyVerb = cmd[1] === "sh" ? "" : (cmd[1] || "")
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

  // Copy without closing the panel, since the copied value is usually still
  // being read. Masked fields copy the hidden value, not the dots.
  function copyValue(v) {
    if (!v) return
    Quickshell.execDetached(["wl-copy", "--", v])
    root.copied = v
    copiedTimer.restart()
  }
  property string copied: ""

  onOpenedChanged: if (!opened) {
    resetStats()
    // Close the elevated session when the panel closes.
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
      var doneVerb = root.busyVerb
      root.busyLabel = ""
      root.busyVerb = ""
      // The list is updated before the command runs, so a failure has to put
      // it back or the change appears to take and then revert.
      if (code !== 0 && root.profilesUndo.length > 0) {
        root.profiles = root.profilesUndo
        root.profileError = (actionErr.text || "").trim() || "That did not work."
      } else if (code !== 0) {
        root.notifyError((actionErr.text || "").trim().split("\n")[0]
          || (doneVerb ? "The " + doneVerb + " command failed." : "That did not work."))
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
      // A finished sms action owns the authoritative re-read; reading during
      // the delete catches the object mid-teardown.
      if (doneVerb === "sms") root.loadSms()
      // A queued follow-up runs as its own argv — never through a shell —
      // and the refresh waits for the end of the chain.
      var follow = root.actionFollow
      root.actionFollow = []
      if (code === 0 && follow.length > 0) { root.runAction(follow); return }
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
      if (root.sessionVerb !== "" && root.sessionVerb !== "list" && root.sessionVerb !== "chipinfo"
          && !actionProc.running) root.busyLabel = ""
      root.sessionVerb = ""
      root.sessionQueue = []
      root.profilesLoading = false
      if (code !== 0 && root.esimExpanded) {
        var e = (sessionErr.text || "").trim()
        if (e !== "") root.profileError = e
      }
    }
  }

  Process {
    id: smsProc
    command: [root.cli, "sms", "feed"]
    stdout: StdioCollector { id: smsOut; waitForEnd: true }
    onExited: function (code) {
      if (root.smsReloadQueued) {
        root.smsReloadQueued = false
        Qt.callLater(root.loadSms)
      }
      if (code !== 0) return
      var list = root.parseIndexed(smsOut.text, "sms")
      // Notify once per message we have never seen, received ones only.
      // Keyed on content: paths renumber when the modem re-enumerates, and
      // the backlog present at first read stays quiet.
      var first = root.smsSeen === null
      var seen = first ? {} : root.smsSeen
      for (var i = 0; i < list.length; i++) {
        var m = list[i]
        var key = (m.number || "") + "|" + (m.time || "") + "|" + (m.text || "").slice(0, 40)
        // Notify only for unseen, received, recent messages: a modem
        // re-enumeration replays Added for the whole store, and a partial
        // read during the churn can make old messages look new, so the age
        // check is the backstop.
        var fresh = false
        if (m.time) {
          var t = Date.parse(m.time.replace(" ", "T"))
          fresh = !isNaN(t) && Date.now() - t < 600000
        }
        if (!first && !seen[key] && m.kind === "received" && fresh
            && root.setting("smsNotify", true)) {
          Quickshell.execDetached(["omarchy-notification-send", "-g", "󰍡",
            "Text from " + (m.number || "unknown"),
            (m.text || "").slice(0, 120)])
        }
        seen[key] = true
      }
      root.smsSeen = seen
      root.smsList = list
    }
  }

  Process {
    id: browseProc
    stdout: StdioCollector { id: browseOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      var out = []
      var lines = (browseOut.text || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        if (lines[i] === "") continue
        var c = lines[i].split("\t")
        out.push({ c0: c[0] || "", c1: c[1] || "", c2: c[2] || "", c3: c[3] || "" })
      }
      root.browseRows = out
    }
  }

  Process {
    id: diagProc
    command: [root.cli, "cells"]
    stdout: StdioCollector { id: diagOut; waitForEnd: true }
    stderr: StdioCollector { id: diagErr; waitForEnd: true }
    onExited: function (code) {
      root.diagLoading = false
      if (code === 0) {
        root.diagServing = root.parseServing(diagOut.text)
        root.diagCells = root.parseIndexed(diagOut.text, "cell")
        root.diagCa = root.parseIndexed(diagOut.text, "ca")
      } else {
        root.notifyError((diagErr.text || "").trim().split("\n")[0] || "Could not read the cells.")
      }
    }
  }



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

  // ------------------------------------------------------------ event feed
  // ModemManager and NetworkManager broadcast every state change as a D-Bus
  // signal, and gdbus monitor subscribes with ordinary match rules -- no
  // privilege, unlike busctl's root-only monitor mode. Each signal schedules
  // one debounced refresh, so a burst (a profile enable emits a dozen) costs
  // one CLI run. Polling below survives only as a slow fallback.
  function busEvent(line) {
    // Non-signal chatter: the two header lines, name-owner notices.
    if (line.length === 0 || line[0] !== "/") return

    // A SIM switch takes the better part of a minute, almost all of it the
    // modem's own re-enumeration. The stages pass through here anyway;
    // narrate them instead of holding one label over the whole wait.
    if ((busyVerb === "sim" || busyVerb === "use") && line.indexOf("/Modem") !== -1) {
      if (line.indexOf("InterfacesRemoved") !== -1)
        busyLabel = "Switching SIM — modem restarting…"
      else if (line.indexOf("InterfacesAdded") !== -1)
        busyLabel = "Switching SIM — modem initializing…"
      else if (line.indexOf("{'State': <8>}") !== -1)
        busyLabel = "Switching SIM — registered, connecting…"
      else if (line.indexOf("{'State': <11>}") !== -1)
        busyLabel = "Switching SIM — connected"
    }
    // Signal-strength samples arrive every few seconds while polling is
    // armed. They only matter when the panel is open; refreshing the bar
    // for each would out-poll the polling this feed replaces.
    if (line.indexOf(".Signal',") !== -1 || line.indexOf("SignalQuality") !== -1) {
      if (root.opened) eventDebounce.restart()
      return
    }
    if (line.indexOf(".Messaging.Added") !== -1) loadSms()
    eventDebounce.restart()
  }

  Timer {
    id: eventDebounce
    interval: 300
    onTriggered: root.opened ? root.refreshDetails() : root.refresh()
  }

  // component MonitorProc is not possible for Process; two literal blocks.
  Process {
    id: mmMonitor
    command: ["gdbus", "monitor", "-y", "-d", "org.freedesktop.ModemManager1"]
    running: true
    stdout: SplitParser { onRead: function (line) { root.busEvent(line) } }
    onExited: monitorRestart.restart()
  }

  Process {
    id: nmMonitor
    command: ["gdbus", "monitor", "-y", "-d", "org.freedesktop.NetworkManager"]
    running: true
    stdout: SplitParser { onRead: function (line) { root.busEvent(line) } }
    onExited: monitorRestart.restart()
  }

  // A monitor that died missed events; resync fully when it returns.
  Timer {
    id: monitorRestart
    interval: 2000
    onTriggered: {
      if (!mmMonitor.running) mmMonitor.running = true
      if (!nmMonitor.running) nmMonitor.running = true
      root.opened ? root.refreshDetails() : root.refresh()
    }
  }

  // Fallback only: the event feed above does the real work, and this catches
  // whatever a dead monitor or a missed signal left behind. It is also the
  // usage meter's heartbeat, so it stays regular rather than rare.
  Timer {
    interval: Math.max(30, root.setting("interval", 60)) * 1000
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

        // ---------- Active identity ----------
        PanelSeparator { foreground: root.barForeground }

        // The active identity, presented like the card it is: glyph, name,
        // ICCID tail, and the APN it rides on.
        Item {
          width: parent.width
          implicitHeight: idCol.implicitHeight

          readonly property var activeSim: {
            for (var i = 0; i < root.sims.length; i++)
              if (root.sims[i].active === "yes") return root.sims[i]
            return null
          }

          Text {
            textFormat: Text.PlainText
            id: idGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: parent.activeSim && parent.activeSim.kind === "esim" ? "󱤓" : "󰒧"
            color: root.barForeground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.body * 1.6)
          }

          Column {
            id: idCol
            anchors.left: idGlyph.right
            anchors.leftMargin: Style.space(8)
            anchors.right: idTail.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: {
                var a = idCol.parent.activeSim
                return (a && (a.provider || a.name)) || root.simLabel || "No SIM"
              }
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.DemiBold
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              elide: Text.ElideRight
              text: "APN  " + (root.info.apn || "automatic")
              color: root.barForeground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: idTail
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              visible: text !== ""
              text: {
                var a = idTail.parent.activeSim
                return a && a.provider && a.name && a.provider !== a.name ? a.name : ""
              }
              color: root.barForeground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              text: idTail.parent.activeSim
                    ? "····" + String(idTail.parent.activeSim.iccid || "").slice(-4) : ""
              color: root.barForeground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Focus mode: opening a management box folds the midsection away,
        // leaving the hero and identity as the basic strip with the chips
        // risen beneath them. Closing unfolds it. Pure height animation; the
        // sections inside are untouched.
        Item {
          clip: true
          width: parent.width
          height: root.mgmtView === "" ? midFoldA.implicitHeight : 0
          opacity: root.mgmtView === "" ? 1 : 0
          Behavior on height { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 150 } }

          Column {
            id: midFoldA
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(14)

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
            InfoPair { label: "Signal"; value: (root.info.signal || "0") + "%"; valueColor: parseInt(root.info.signal || "0") < 25 ? root.urgent : root.barForeground }
            InfoPair { label: "RSSI"; value: root.info.sig_rssi || "—"; valueColor: root.sigColor("rssi", root.info.sig_rssi) }
            InfoPair { label: "RSRQ"; value: root.info.sig_rsrq || "—"; valueColor: root.sigColor("rsrq", root.info.sig_rsrq) }
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
            InfoPair { label: "RSRP"; value: root.info.sig_rsrp || "—"; valueColor: root.sigColor("rsrp", root.info.sig_rsrp) }
            InfoPair { label: "SNR"; value: root.info.sig_snr || "—"; valueColor: root.sigColor("snr", root.info.sig_snr) }
            InfoPair {
              label: "Packet Loss"
              value: root.formatLoss(root.packetLoss)
              valueColor: root.packetLoss > 0 ? root.urgent : root.barForeground
            }
            InfoPair { label: "Sending"; value: root.hasTransferStats ? root.formatRate(root.uploadRate) : "--" }
            InfoPair { label: "Uploaded"; value: root.hasTransferStats ? root.formatBytes(parseFloat(root.info.tx_bytes || "0")) : "--" }
          }
        }

          }
        }

        // RSRP over the last five minutes: a thin line showing whether the
        // signal is degrading and whether moving helped, which the
        // instantaneous number cannot.
        Column {
          id: sparkCol
          // Stays visible once a metric exists: an empty chart during a
          // sample gap beats the whole section reflowing in and out.
          visible: root.hwPresent && root.setting("sparkline", true)
                   && (root.rsrpHistory.length >= 2 || root.sparkMetric !== "")
          width: parent.width
          spacing: Style.space(2)

          readonly property real histLo: {
            var h = root.rsrpHistory
            if (h.length === 0) return 0
            var lo = h[0].v
            for (var i = 1; i < h.length; i++) if (h[i].v < lo) lo = h[i].v
            return lo
          }
          readonly property real histHi: {
            var h = root.rsrpHistory
            if (h.length === 0) return 0
            var hi = h[0].v
            for (var i = 1; i < h.length; i++) if (h[i].v > hi) hi = h[i].v
            return hi
          }

          Item {
            width: parent.width
            implicitHeight: sparkTitle.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: sparkTitle
              anchors.left: parent.left
              text: (root.sparkMetric || "RSRP") + " · LAST 5 MIN"
              color: root.barForeground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.baseline: sparkTitle.baseline
              text: {
                var h = root.rsrpHistory
                if (h.length === 0) return ""
                var sum = 0
                for (var i = 0; i < h.length; i++) sum += h[i].v
                return "avg " + (sum / h.length).toFixed(0) + " dBm"
              }
              visible: root.mgmtView === ""
              color: root.barForeground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item {
            width: parent.width
            // Tall enough for the focus-mode stat rows in both modes, so
            // entering focus changes only the chart's width, not its height.
            height: Math.max(Style.space(28), sparkStats.implicitHeight)

            // Focus mode narrows the chart to make room for the live numbers
            // the folded stats grid would otherwise show.
            Item {
              id: sparkChart
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: root.mgmtView === "" ? parent.width : Math.round(parent.width * 0.55)
              Behavior on width { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }

            // A subtle background and border mark the chart area, in theme
            // tones.
            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.04)
              border.color: root.barForeground
              border.width: 1
              opacity: 0.5
            }

            Canvas {
              id: rsrpSpark
              anchors.fill: parent
              anchors.margins: 3
              onWidthChanged: requestPaint()
              property var pts: root.rsrpHistory
              // The theme's accent is the pen; everything else stays neutral.
              property color line: Color.accent
              onPtsChanged: requestPaint()
              onLineChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var h = pts
                if (!h || h.length < 2) return
                // Autoscaled to the window so whatever movement exists
                // fills the height; the deltas matter more than the absolute
                // level. A 1 dB floor guards a flat window.
                var lo = sparkCol.histLo, hi = sparkCol.histHi
                if (hi - lo < 1) { var mid = (hi + lo) / 2; lo = mid - 0.5; hi = mid + 0.5 }
                var t0 = h[0].t, t1 = h[h.length - 1].t
                var span = Math.max(1, t1 - t0)
                // Soft fill under the line first, then the line itself.
                ctx.beginPath()
                for (var i = 0; i < h.length; i++) {
                  var x = (h[i].t - t0) / span * (width - 2) + 1
                  var y = height - 2 - (h[i].v - lo) / (hi - lo) * (height - 4)
                  i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
                }
                ctx.lineTo(x, height)
                ctx.lineTo(1, height)
                ctx.closePath()
                ctx.fillStyle = Qt.rgba(line.r, line.g, line.b, 0.10)
                ctx.fill()

                ctx.strokeStyle = Qt.rgba(line.r, line.g, line.b, 0.9)
                ctx.lineWidth = 1.5
                ctx.beginPath()
                for (i = 0; i < h.length; i++) {
                  x = (h[i].t - t0) / span * (width - 2) + 1
                  y = height - 2 - (h[i].v - lo) / (hi - lo) * (height - 4)
                  i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
                }
                ctx.stroke()
                ctx.fillStyle = line
                ctx.beginPath()
                ctx.arc(x, y, 2, 0, Math.PI * 2)
                ctx.fill()
              }
            }
            }

            Column {
              id: sparkStats
              anchors.left: sparkChart.right
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)
              visible: root.mgmtView !== "" || opacity > 0
              opacity: root.mgmtView === "" ? 0 : 1
              Behavior on opacity { NumberAnimation { duration: 150 } }

              InfoPair { size: Style.font.caption; label: "RSRP"; value: root.info.sig_rsrp || "—"; valueColor: root.sigColor("rsrp", root.info.sig_rsrp) }
              InfoPair { size: Style.font.caption; label: "RSSI"; value: root.info.sig_rssi || "—"; valueColor: root.sigColor("rssi", root.info.sig_rssi) }
              InfoPair { size: Style.font.caption; label: "SNR"; value: root.info.sig_snr || "—"; valueColor: root.sigColor("snr", root.info.sig_snr) }
              InfoPair { size: Style.font.caption; label: "Tech"; value: root.info.tech || "—" }
            }
          }
        }

        // The fold resumes below the sparkline; it and the strip above it
        // stay through focus mode.
        Item {
          clip: true
          width: parent.width
          height: root.mgmtView === "" ? midFoldB.implicitHeight : 0
          opacity: root.mgmtView === "" ? 1 : 0
          Behavior on height { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 150 } }

          Column {
            id: midFoldB
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(14)

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

            // A link, like Reset counter below: the section's controls are
            // deliberately quiet, and a bordered button looked too prominent
            // here.
            Text {
              textFormat: Text.PlainText
              id: planButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.limitEditing ? "Done" : (root.limitBytes > 0 ? "Change" : "Set limit")
              color: root.barForeground
              opacity: planArea.containsMouse || root.limitEditing ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: planArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.limitEditing = !root.limitEditing
                  if (root.limitEditing) root.seedLimitFields()
                }
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
              color: root.usedFraction >= 0.9 ? root.urgent : Color.accent
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }

            // The calendar's position in the cycle: fill short of the tick
            // means usage is under pace.
            Rectangle {
              visible: root.cycleFraction >= 0
              x: Math.min(planTrack.width - width, planTrack.width * root.cycleFraction)
              anchors.verticalCenter: planTrack.verticalCenter
              width: 3
              height: planTrack.height + Style.space(6)
              radius: 1
              color: root.barForeground
              opacity: 0.9
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
                    placeholderText: "5G, 500M — blank turns it off"
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



              SwitchRow {
                width: parent.width
                visible: root.limitBytes > 0
                label: "STOP DATA AT LIMIT"
                tip: "Off, it only warns; re-arms when the period resets"
                checked: !root.limitAck
                onFlipped: root.runAction([root.cli, "limit", "cutoff",
                                           root.limitAck ? "on" : "off"])
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
                  visible: root.startedLabel !== ""
                  text: root.startedLabel
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

          }
        }

        // ---------- Management chips ----------
        PanelSeparator { foreground: root.barForeground }

        Row {
          id: mgmtChips
          spacing: Style.space(6)
          // Square chips, sized to their glyph; the row does not fill the
          // panel. Button.implicitWidth includes padding, so the size is
          // explicit.
          readonly property real cell: Math.round(Style.font.body * 2.2)

          Button {
            width: mgmtChips.cell
            height: mgmtChips.cell
            fontSize: Style.font.caption
            iconSize: Style.font.body
            iconText: "󰄜"
            tooltipText: "Device details"
            bordered: true
            active: root.mgmtView === "device"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: root.toggleMgmt("device")
          }

          Button {
            width: mgmtChips.cell
            height: mgmtChips.cell
            fontSize: Style.font.caption
            iconSize: Style.font.body
            iconText: "󰒧"
            tooltipText: "SIM cards and eSIM profiles"
            bordered: true
            active: root.mgmtView === "sim"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: root.toggleMgmt("sim")
          }

          Button {
            width: mgmtChips.cell
            height: mgmtChips.cell
            fontSize: Style.font.caption
            iconSize: Style.font.body
            iconText: "󰖟"
            tooltipText: "APN and carrier"
            bordered: true
            active: root.mgmtView === "apn"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: root.toggleMgmt("apn")
          }

          Button {
            width: mgmtChips.cell
            height: mgmtChips.cell
            fontSize: Style.font.caption
            iconSize: Style.font.body
            iconText: "󱄙"
            tooltipText: "Cell diagnostics"
            bordered: true
            active: root.mgmtView === "diag"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: root.toggleMgmt("diag")
          }

          Button {
            width: mgmtChips.cell
            height: mgmtChips.cell
            fontSize: Style.font.caption
            iconSize: Style.font.body
            iconText: "󰍡"
            tooltipText: "Text messages"
            bordered: true
            active: root.mgmtView === "sms"
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: {
              root.toggleMgmt("sms")
              if (root.mgmtView === "sms") root.loadSms()
            }
          }
        }

        // ---------- Messages (behind its chip) ----------
        PanelSeparator {
          visible: root.mgmtView === "sms"
          foreground: root.barForeground
        }

        Column {
          visible: root.mgmtView === "sms"
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MESSAGES"
            foreground: root.barForeground
            fontFamily: root.fontFamily
          }

          // One line per message, click to expand; the list scrolls past
          // six or so.
          ListView {
            id: smsView
            width: parent.width
            height: Math.min(contentHeight, Math.round(Style.font.body * 16))
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(3)
            model: root.smsList

            delegate: Item {
              id: smsCard
              required property var modelData
              readonly property bool open: root.smsOpen === modelData.path
              width: smsView.width
              implicitHeight: smsCol.implicitHeight + Style.space(5)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: smsCard.open
                       ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.05)
                       : "transparent"
                border.color: root.barForeground
                border.width: 1
                opacity: smsCard.open ? 0.6 : smsHdrArea.containsMouse ? 0.45 : 0.25
              }

              Column {
                id: smsCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  implicitHeight: smsFrom.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: smsFrom
                    anchors.left: parent.left
                    text: (smsCard.modelData.kind === "sent" ? "→ " : "")
                          + (smsCard.modelData.number || "unknown")
                    color: root.barForeground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: smsDelete.visible ? smsDelete.left : parent.right
                    anchors.rightMargin: smsDelete.visible ? Style.space(4) : 0
                    anchors.baseline: smsFrom.baseline
                    text: smsCard.modelData.time || ""
                    color: root.barForeground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: smsDelete
                    visible: smsCard.open
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰩹"
                    color: root.barForeground
                    opacity: smsDelArea.containsMouse ? 1 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall

                    MouseArea {
                      id: smsDelArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.smsOpen = ""
                        if (root.runAction([root.cli, "sms", "delete", smsCard.modelData.path]))
                          root.loadSms()
                      }
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  maximumLineCount: smsCard.open ? 100 : 1
                  elide: smsCard.open ? Text.ElideNone : Text.ElideRight
                  wrapMode: smsCard.open ? Text.WordWrap : Text.NoWrap
                  text: smsCard.modelData.text || ""
                  color: root.barForeground
                  opacity: smsCard.open ? 0.8 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: smsHdrArea
                anchors.fill: parent
                anchors.rightMargin: smsCard.open ? Style.space(24) : 0
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.smsOpen = smsCard.open ? "" : smsCard.modelData.path
                z: -1
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.smsList.length === 0
            width: parent.width
            text: "No stored messages."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Diagnostics (behind its chip) ----------
        PanelSeparator {
          visible: root.mgmtView === "diag"
          foreground: root.barForeground
        }

        Column {
          visible: root.mgmtView === "diag"
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: diagHeader.implicitHeight

            PanelSectionHeader {
              id: diagHeader
              text: "CELL DIAGNOSTICS"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: diagHeader.verticalCenter
              anchors.verticalCenterOffset: Math.round(diagHeader.topPadding / 2)
              text: root.diagLoading ? "Surveying…" : "Survey cells"
              color: root.barForeground
              opacity: diagReadArea.containsMouse || root.diagLoading ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: diagReadArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                hoverEnabled: true
                enabled: !root.diagLoading
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.diagLoading = true
                  diagProc.running = true
                }
              }

              PanelToolTip {
                visible: diagReadArea.containsMouse
                text: "Asks the modem for every cell it can hear"
                fontFamily: root.fontFamily
              }
            }
          }

          // A column-per-field table with a header row.
          Column {
            id: diagTable
            visible: root.diagRows.length > 0
            width: parent.width
            spacing: Style.space(2)

            readonly property real cId: width * 0.10
            readonly property real cGen: width * 0.12
            readonly property real cRole: width * 0.06
            readonly property real cBand: width * 0.18
            readonly property real cWidth: width * 0.13
            readonly property real cCh: width * 0.15
            readonly property real cRssi: width * 0.13

            component DiagCell: Text {
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              visible: {
                var n = 0
                for (var i = 0; i < root.diagRows.length; i++)
                  if (root.diagRows[i].role !== "") n++
                return n > 1
              }
              width: parent.width
              text: {
                var parts = [], total = 0
                for (var i = 0; i < root.diagRows.length; i++) {
                  var r = root.diagRows[i]
                  if (r.role === "" || !r.width) continue
                  parts.push(r.width)
                  total += parseInt(r.width)
                }
                return "Aggregated  " + parts.join(" + ") + " = " + total + " MHz"
              }
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              Repeater {
                model: [["ID", diagTable.cId], ["TECH", diagTable.cGen],
                        ["CA", diagTable.cRole],
                        ["BAND", diagTable.cBand], ["WIDTH", diagTable.cWidth],
                        ["CH", diagTable.cCh], ["RSSI", diagTable.cRssi]]
                DiagCell {
                  required property var modelData
                  width: modelData[1]
                  text: modelData[0]
                  opacity: 0.45
                  font.letterSpacing: 1
                }
              }
              DiagCell {
                width: diagTable.width - diagTable.cGen - diagTable.cBand
                       - diagTable.cWidth - diagTable.cCh - diagTable.cId
                       - diagTable.cRssi - diagTable.cRole
                horizontalAlignment: Text.AlignRight
                text: "RSRP"
                opacity: 0.45
                font.letterSpacing: 1
              }
            }

            Repeater {
              model: root.diagRows
              delegate: Row {
                id: diagRow
                required property var modelData
                width: diagTable.width

                DiagCell {
                  width: diagTable.cId
                  text: diagRow.modelData.id
                  opacity: diagRow.modelData.serving ? 1 : 0.7
                  font.weight: diagRow.modelData.serving ? Font.DemiBold : Font.Normal
                }
                DiagCell {
                  width: diagTable.cGen
                  text: diagRow.modelData.gen
                  opacity: diagRow.modelData.serving ? 1 : 0.7
                  font.weight: diagRow.modelData.serving ? Font.DemiBold : Font.Normal
                }
                DiagCell {
                  width: diagTable.cRole
                  text: diagRow.modelData.role
                  color: Color.accent
                  opacity: diagRow.modelData.role ? 1 : 0
                  font.weight: Font.DemiBold
                }
                DiagCell {
                  width: diagTable.cBand
                  text: diagRow.modelData.band
                  opacity: diagRow.modelData.serving ? 1 : 0.7
                  font.weight: diagRow.modelData.serving ? Font.DemiBold : Font.Normal
                }
                DiagCell {
                  width: diagTable.cWidth
                  text: diagRow.modelData.width ? diagRow.modelData.width + " MHz" : ""
                  opacity: diagRow.modelData.serving ? 1 : 0.7
                  font.weight: diagRow.modelData.serving ? Font.DemiBold : Font.Normal
                }
                DiagCell {
                  width: diagTable.cCh
                  text: diagRow.modelData.ch
                  opacity: diagRow.modelData.serving ? 1 : 0.7
                }
                DiagCell {
                  width: diagTable.cRssi
                  text: diagRow.modelData.rssi || "—"
                  color: diagRow.modelData.rssi
                         ? root.sigColor("rssi", diagRow.modelData.rssi)
                         : root.barForeground
                  opacity: diagRow.modelData.serving ? 0.9 : 0.65
                }
                DiagCell {
                  width: diagTable.width - diagTable.cGen - diagTable.cBand
                         - diagTable.cWidth - diagTable.cCh - diagTable.cId
                         - diagTable.cRssi - diagTable.cRole
                  horizontalAlignment: Text.AlignRight
                  text: diagRow.modelData.rsrp || "—"
                  color: diagRow.modelData.rsrp
                         ? root.sigColor("rsrp", diagRow.modelData.rsrp)
                         : root.barForeground
                  opacity: diagRow.modelData.serving ? 1 : 0.75
                  font.weight: diagRow.modelData.serving ? Font.DemiBold : Font.Normal
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.diagRows.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Neighbors are reported for the current radio mode only."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: root.diagCells.length === 0 && !root.diagLoading
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Nothing surveyed yet. Survey cells needs authorization."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }


        }

        // ---------- APN (behind its chip) ----------
        PanelSeparator {
          visible: root.mgmtView === "apn"
          foreground: root.barForeground
        }

        Column {
          visible: root.mgmtView === "apn"
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
              visible: false
              text: ""
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
              text: root.info.apn || "automatic"
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
                root.carrierExpanded = true
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
              onClicked: root.runAction([root.cli, "carrier", "auto"], [root.cli, "apply"])
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
              active: root.apnBrowse
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: {
                root.apnBrowse = !root.apnBrowse
                if (root.apnBrowse) {
                  root.browseCc = ""
                  root.browseCcName = ""
                  root.browseProv = ""
                  browseFilter.text = ""
                  root.browseLoad()
                  browseFilter.forceActiveFocus()
                }
              }
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

          // The provider database, staged in place: countries, then the
          // country's carriers, then that carrier's APNs; a tap applies.
          Item {
            width: parent.width
            clip: true
            height: (root.carrierExpanded && root.apnBrowse) ? browseCol.implicitHeight : 0
            Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            Column {
              id: browseCol
              width: parent.width
              spacing: Style.space(4)

              TextField {
                id: browseFilter
                width: parent.width
                font.pixelSize: Style.font.caption
                verticalPadding: Style.space(2)
                placeholderText: root.browseProv !== "" ? root.browseProv + " APNs"
                                 : root.browseCc !== "" ? "Filter carriers in " + root.browseCcName
                                 : "Filter countries"
                foreground: root.barForeground
              }

              ListView {
                id: browseList
                width: parent.width
                height: Math.min(contentHeight, Style.space(180))
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                spacing: Style.space(1)

                model: {
                  var out = []
                  if (root.browseCc !== "")
                    out.push({ kind: "back",
                               label: "‹  " + (root.browseProv !== "" ? root.browseCcName : "Countries"),
                               sub: "" })
                  var f = browseFilter.text.toLowerCase()
                  for (var i = 0; i < root.browseRows.length; i++) {
                    var r = root.browseRows[i]
                    var kind = root.browseProv !== "" ? "apn"
                             : root.browseCc !== "" ? "provider" : "country"
                    var label = kind === "country" ? r.c1 : r.c0
                    var sub = kind === "country" ? r.c0 : kind === "apn" ? r.c1 : ""
                    if (f !== "" && (label + " " + sub).toLowerCase().indexOf(f) === -1) continue
                    out.push({ kind: kind, label: label, sub: sub, c0: r.c0 })
                  }
                  return out
                }

                delegate: Item {
                  id: browseRow
                  required property var modelData
                  width: browseList.width
                  height: browseLabel.implicitHeight + Style.space(4)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.barForeground
                    opacity: browseRowArea.containsMouse ? 0.08 : 0
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: browseLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(3)
                    anchors.right: browseSub.left
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: browseRow.modelData.label
                    color: root.barForeground
                    opacity: browseRow.modelData.kind === "back" ? 0.6 : 0.85
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: browseSub
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter
                    text: browseRow.modelData.sub
                    color: root.barForeground
                    opacity: 0.4
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: browseRowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.browsePick(browseRow.modelData)
                  }
                }
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
              placeholderText: "APN — blank for automatic"
              foreground: root.barForeground
              enabled: !root.busy
              opacity: root.busy ? 0.5 : 1
              onAccepted: {
                if (!root.runAction([root.cli, "apn", text], [root.cli, "apply"]))
                  return
                root.apnEditing = false
              }
            }
          }
        }

        // ---------- Device (behind its chip) ----------
        PanelSeparator {
          visible: root.hwPresent && root.mgmtView === "device"
          foreground: root.barForeground
        }

        Column {
          visible: root.hwPresent && root.mgmtView === "device"
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
              visible: false
              text: ""
              color: root.barForeground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              id: deviceName
              visible: false
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
              onClicked: root.deviceExpanded = true
            }
          }

          // One column: ICCID is 19 digits and IMEI 15, which overflow a
          // half-width cell.
          Item {
            width: parent.width
            clip: true
            // No height animation: the panel is a layer-shell surface, so
            // animating this reconfigures the Wayland surface every frame.
            height: deviceRows.implicitHeight

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
            InfoPair { label: "Device path"; value: root.info.port ? "/dev/" + root.info.port : "—"; copyValue: root.info.port ? "/dev/" + root.info.port : "" }

            // Modem picker, only on machines with more than one. Selection
            // is exclusive; the caption below carries that meaning.
            Column {
              width: parent.width
              visible: root.devices.length > 1
              spacing: Style.space(1)

              Repeater {
                model: root.devices
                delegate: Item {
                  id: devRow
                  required property var modelData
                  width: parent.width
                  height: devLabel.implicitHeight + Style.space(4)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: root.barForeground
                    opacity: devArea.containsMouse && devRow.modelData.active !== "yes" ? 0.08 : 0
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: devLabel
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter
                    text: (devRow.modelData.active === "yes" ? "● " : "○ ")
                          + (devRow.modelData.model || "Modem")
                    color: root.barForeground
                    opacity: devRow.modelData.active === "yes" ? 1 : 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(3)
                    anchors.verticalCenter: parent.verticalCenter
                    text: devRow.modelData.port ? "/dev/" + devRow.modelData.port : ""
                    color: root.barForeground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: devArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: devRow.modelData.active === "yes" ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: if (devRow.modelData.active !== "yes")
                      root.runAction([root.cli, "device", devRow.modelData.port])
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Selecting a modem disables the others."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
          }
        }

        // ---------- SIM cards (behind its chip) ----------
        PanelSeparator {
          visible: root.mgmtView === "sim"
          foreground: root.barForeground
        }

        Column {
          visible: root.mgmtView === "sim"
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(simHeader.implicitHeight, manageLink.implicitHeight)

            PanelSectionHeader {
              id: simHeader
              text: "SIM CARD SELECTION"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              id: manageLink
              anchors.right: parent.right
              anchors.verticalCenter: simHeader.verticalCenter
              anchors.verticalCenterOffset: Math.round(simHeader.topPadding / 2)
              text: root.esimExpanded ? "Close eSIM management" : "Manage eSIM…"
              color: root.barForeground
              opacity: !root.esimSelected ? 0.35
                       : manageArea.containsMouse || root.esimExpanded ? 1 : 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: manageArea
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                // Hover stays live while the control is unavailable, so the
                // tooltip can say why; only the click is gated.
                hoverEnabled: true
                cursorShape: root.esimSelected ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (!root.esimSelected) return
                  root.esimExpanded = !root.esimExpanded
                  if (root.esimExpanded) root.loadProfiles()
                  else root.sessionStop()
                }
              }

              PanelToolTip {
                visible: manageArea.containsMouse
                text: root.esimSelected
                      ? "Rename, add, or remove eSIM profiles"
                      : "Select the eSIM first to manage its profiles"
                fontFamily: root.fontFamily
              }
            }
          }

Column {
            id: simList
            width: parent.width
            spacing: Style.space(2)
            // A switch is in flight; the list is unavailable until it lands.
            enabled: !root.busy
            opacity: root.busy ? 0.5 : 1

            Flow {
              id: simFlow
              width: parent.width
              spacing: Style.space(7)

              Repeater {
                model: root.sims
                delegate: Item {
                  id: simTile
                  required property var modelData
                  readonly property bool isActive: modelData.active === "yes"
                  width: (simFlow.width - Style.space(7)) / 2
                  height: Math.round(Style.font.body * 5.4)
                  // The bevel that makes a rectangle read as a SIM card.
                  readonly property real notch: Math.round(Style.font.body * 1.1)

                  Canvas {
                    anchors.fill: parent
                    property color line: root.barForeground
                    property bool on: simTile.isActive
                    opacity: on ? 0.9 : tileArea.containsMouse ? 0.55 : 0.3
                    onLineChanged: requestPaint()
                    onOnChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      var w = width - 1, h = height - 1
                      var r = Math.max(0, Style.cornerRadius)
                      var n = simTile.notch
                      ctx.translate(0.5, 0.5)
                      ctx.beginPath()
                      ctx.moveTo(n, 0)
                      ctx.lineTo(w - r, 0)
                      ctx.arcTo(w, 0, w, r, r)
                      ctx.lineTo(w, h - r)
                      ctx.arcTo(w, h, w - r, h, r)
                      ctx.lineTo(r, h)
                      ctx.arcTo(0, h, 0, h - r, r)
                      ctx.lineTo(0, n)
                      ctx.closePath()
                      if (on) {
                        ctx.fillStyle = Qt.rgba(line.r, line.g, line.b, 0.12)
                        ctx.fill()
                      }
                      ctx.strokeStyle = line
                      ctx.lineWidth = 1
                      ctx.stroke()
                    }
                  }

                  // With the notch top-left, the contact pad reads right:
                  // glyph bottom-right, like the real card.
                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(5)
                    text: simTile.modelData.kind === "physical" ? "󰒧" : "󱤓"
                    color: root.barForeground
                    opacity: simTile.isActive ? 0.7 : 0.35
                    font.family: root.fontFamily
                    font.pixelSize: Math.round(Style.font.body * 2)
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: tileName
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.margins: Style.space(4)
                    anchors.leftMargin: simTile.notch + Style.space(2)
                    anchors.right: tileKind.left
                    anchors.rightMargin: Style.space(3)
                    elide: Text.ElideRight
                    text: simTile.modelData.name || simTile.modelData.provider || "Unnamed"
                    color: root.barForeground
                    opacity: simTile.isActive ? 1 : 0.8
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: simTile.notch + Style.space(2)
                    anchors.top: tileName.bottom
                    anchors.topMargin: Style.space(1)
                    anchors.right: parent.horizontalCenter
                    elide: Text.ElideRight
                    visible: text !== ""
                    text: simTile.modelData.provider
                          && simTile.modelData.provider !== simTile.modelData.name
                          ? simTile.modelData.provider : ""
                    color: root.barForeground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    id: tileKind
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(4)
                    text: simTile.modelData.kind === "physical" ? "physical" : "eSIM"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(4)
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(3)
                    text: simTile.modelData.iccid
                          ? "····" + String(simTile.modelData.iccid).slice(-4)
                          : "no profiles"
                    color: root.barForeground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: tileArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: simTile.isActive ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: {
                      if (simTile.isActive) return
                      // A bare eUICC has no profile to 'use'; selecting its
                      // slot is the bootstrap that makes Manage reachable.
                      if (simTile.modelData.kind === "esim-slot")
                        root.runAction([root.cli, "sim", simTile.modelData.slot, "--force"])
                      else
                        root.runAction([root.cli, "use", simTile.modelData.iccid])
                    }
                  }

                  PanelToolTip {
                    visible: tileArea.containsMouse && !simTile.isActive
                    text: simTile.modelData.kind === "esim-slot"
                          ? "Select the eSIM slot; add profiles from Manage eSIM"
                          : "Switch to this card; the modem reconnects"
                    fontFamily: root.fontFamily
                  }
                }
              }
            }

            // The list can only name profiles a profile read has seen.
            Text {
              textFormat: Text.PlainText
              visible: root.sims.length <= 1 && root.hasEsim
              width: parent.width
              wrapMode: Text.WordWrap
              text: "eSIM profiles appear here after the first Manage eSIM visit."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Management is its own section, and the eUICC only answers
            // while it is the selected card.
            Item {
              width: parent.width
              visible: root.esimExpanded
              height: refreshLink.implicitHeight + Style.space(4)

              Text {
                textFormat: Text.PlainText
                id: refreshLink
                visible: root.esimExpanded
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                text: root.profilesStale ? "Refresh · after scan" : "Refresh"
                color: root.barForeground
                opacity: root.profilesStale ? 1
                         : refreshArea.containsMouse ? 1 : 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.profilesStale = false
                    root.profiles = []
                    root.loadProfiles()
                  }
                }

                PanelToolTip {
                  visible: refreshArea.containsMouse
                  text: root.profilesStale
                        ? "A scan ran; re-read the eSIM to see what it installed"
                        : "Re-read profiles from the eSIM"
                  fontFamily: root.fontFamily
                }
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

              PanelSeparator { foreground: root.barForeground }

              Item {
                width: parent.width
                implicitHeight: esimHeader.implicitHeight

                PanelSectionHeader {
                  id: esimHeader
                  text: "ESIM PROFILES"
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.euiccFree !== ""
                  anchors.right: parent.right
                  anchors.verticalCenter: esimHeader.verticalCenter
                  anchors.verticalCenterOffset: Math.round(esimHeader.topPadding / 2)
                  text: root.euiccFree
                  color: root.barForeground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

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
                Item {
                  id: profileCard
                  required property var modelData
                  readonly property bool isOn: root.profileEnabled(modelData)
                  width: esimCol.width
                  height: cardCol.implicitHeight + Style.space(8)

                  Rectangle {
                    anchors.fill: parent
                    // The theme's own corner treatment, like every Button.
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.color: root.barForeground
                    border.width: 1
                    opacity: profileCard.isOn ? 0.8
                             : cardArea.containsMouse ? 0.55 : 0.3
                  }

                  // Status rail: state runs vertically along the card's edge.
                  // INACTIVE does not fit two lines of card, so a quiet rail
                  // with no word is the inactive state.
                  Item {
                    id: statusRail
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: 1
                    width: Math.round(Style.font.caption * 2)

                    // The rail itself is the highlight: filled when active,
                    // near-silent when not.
                    Rectangle {
                      anchors.fill: parent
                      radius: Math.max(0, Style.cornerRadius - 1)
                      color: root.barForeground
                      opacity: profileCard.isOn ? 0.22 : 0.05
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      rotation: -90
                      // Rotated, the text's width runs along the card's height;
                      // cap it there and let the size fit, so the word never
                      // reaches the box edges.
                      width: parent.height - Style.space(8)
                      height: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      fontSizeMode: Text.HorizontalFit
                      minimumPixelSize: 6
                      text: profileCard.isOn ? "ACTIVE"
                            : profileCard.modelData.class === "test" ? "TEST" : ""
                      color: root.barForeground
                      opacity: profileCard.isOn ? 1 : 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }
                  }

                  MouseArea {
                    id: cardArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: profileCard.isOn ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: if (!profileCard.isOn) {
                      root.sessionSend("enable " + modelData.iccid)
                      root.applyProfileChange(modelData.iccid, "enable")
                    }
                  }

                  Column {
                    id: cardCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: statusRail.width + Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(2)

                    Item {
                      width: parent.width
                      height: iccidText.implicitHeight

                      Text {
                        textFormat: Text.PlainText
                        id: iccidText
                        anchors.left: parent.left
                        text: profileCard.modelData.iccid
                        color: root.barForeground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                    }

                    Item {
                      width: parent.width
                      height: Math.max(nameText.implicitHeight, cardActions.implicitHeight)

                      Text {
                        textFormat: Text.PlainText
                        id: nameText
                        anchors.left: parent.left
                        anchors.right: cardActions.left
                        anchors.rightMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: (profileCard.modelData.name || "Unnamed")
                              + (profileCard.modelData.provider
                                 && profileCard.modelData.provider !== profileCard.modelData.name
                                 ? "  ·  " + profileCard.modelData.provider : "")
                        color: root.barForeground
                        opacity: 0.65
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Row {
                        id: cardActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Item {
                          width: Math.round(Style.font.body * 2)
                          height: width

                          Text {
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "󰑕"
                            color: root.barForeground
                            opacity: renameArea.containsMouse ? 1 : 0.55
                            font.family: root.fontFamily
                            font.pixelSize: Math.round(Style.font.body * 1.3)
                          }

                          MouseArea {
                            id: renameArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              root.renamingIccid =
                                root.renamingIccid === profileCard.modelData.iccid
                                ? "" : profileCard.modelData.iccid
                              if (root.renamingIccid !== "") {
                                renameField.text = profileCard.modelData.name || ""
                                renameField.forceActiveFocus()
                              }
                            }
                          }

                          PanelToolTip {
                            visible: renameArea.containsMouse
                            text: "Rename"
                            fontFamily: root.fontFamily
                          }
                        }

                        Item {
                          width: Math.round(Style.font.body * 2)
                          height: width

                          Text {
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "󰩹"
                            color: root.barForeground
                            opacity: profileCard.isOn ? 0.25
                                     : deleteArea.containsMouse ? 1 : 0.55
                            font.family: root.fontFamily
                            font.pixelSize: Math.round(Style.font.body * 1.3)
                          }

                          MouseArea {
                            id: deleteArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !profileCard.isOn
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                              root.sessionSend("delete " + profileCard.modelData.iccid)
                              root.applyProfileChange(profileCard.modelData.iccid, "delete")
                            }
                          }

                          PanelToolTip {
                            visible: deleteArea.containsMouse
                            text: profileCard.isOn
                                  ? "The active profile cannot be deleted"
                                  : "Delete this profile"
                            fontFamily: root.fontFamily
                          }
                        }
                      }
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
                  width: esimCol.width
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
    property int size: Style.font.bodySmall
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
      font.pixelSize: parent.size
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
      font.pixelSize: parent.size

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
