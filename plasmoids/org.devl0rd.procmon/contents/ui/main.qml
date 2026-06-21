/*
 * Linux-Process-Mon :: a searchable, sortable process tree.
 *
 * Reads the snapshot kept in tmpfs by the resident `--serve` collector (systemd
 * --user service, pinned to the E-cores) fully IN-PROCESS via XHR (file://) --
 * no process is spawned per poll. Requires QML_XHR_ALLOW_FILE_READ=1 in the
 * session (set by install.sh via environment.d).
 *
 * Each process is a row; children nest under their parent and collapse (all
 * pre-collapsed). Columns (CPU, RAM, GPU, DEC, ENC, VRAM, Disk, Threads, PID)
 * are individually toggleable; parents can roll up their whole subtree. Search
 * flattens to matches; the sort dropdown or a column header sorts.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    property string panelIcon: Plasmoid.configuration.panelIcon || "utilities-system-monitor"
    Plasmoid.icon: panelIcon
    Plasmoid.title: i18n("Process Monitor")
    Connections {
        target: Plasmoid.configuration
        function onPanelIconChanged() { root.panelIcon = Plasmoid.configuration.panelIcon || "utilities-system-monitor" }
    }

    readonly property int numColW: Kirigami.Units.gridUnit * 3.6

    // ---- columns (key matches the collector's per-row fields + a<key> aggregate) ----
    readonly property var allColumns: [
        { key: "cpu",     label: i18n("CPU"),  kind: "pct",   heat: true,  show: true },
        { key: "ram",     label: i18n("RAM"),  kind: "bytes", heat: false, show: true },
        { key: "gpu",     label: i18n("GPU"),  kind: "pct",   heat: true,  show: Plasmoid.configuration.showGpuColumn },
        { key: "dec",     label: i18n("DEC"),  kind: "pct",   heat: true,  show: Plasmoid.configuration.showDecColumn },
        { key: "enc",     label: i18n("ENC"),  kind: "pct",   heat: true,  show: Plasmoid.configuration.showEncColumn },
        { key: "vram",    label: i18n("VRAM"), kind: "bytes", heat: false, show: Plasmoid.configuration.showVramColumn },
        { key: "disk",    label: i18n("Disk"), kind: "rate",  heat: false, show: Plasmoid.configuration.showDiskColumn },
        { key: "threads", label: i18n("Thr"),  kind: "int",   heat: false, show: Plasmoid.configuration.showThreadsColumn },
        { key: "pid",     label: i18n("PID"),  kind: "int",   heat: false, show: Plasmoid.configuration.showPidColumn, noagg: true }
    ]
    readonly property var columns: allColumns.filter(function(c) { return c.show })

    // ---- data ----
    property var procs: []
    property int ncpu: 1
    property var byPid: ({})
    property var childrenOf: ({})
    property var expanded: ({})           // pid -> true when expanded (default: collapsed)
    property var visibleRows: []
    property var rowsViewRef: null        // set by the ListView so root code can read its scroll

    // per-PID metric history, accumulated for EVERY process each poll (data layer,
    // independent of what's rendered) so a row's sparkline is complete the moment
    // it scrolls into view
    property var hist: ({})               // pid -> { metric: [values...] }
    readonly property int histLen: 40
    readonly property var histKeys: ["cpu", "ram", "gpu", "dec", "enc", "vram", "disk", "threads"]
    function histFor(pid, col) { var h = root.hist[pid]; return (h && h[col]) ? h[col] : [] }
    function graphMax(col) { var c = root.colOf(col); return (c && c.kind === "pct") ? 100 : 0 }

    property string searchText: ""
    property string sortColumn: Plasmoid.configuration.sortColumn || "cpu"
    property bool sortDescending: Plasmoid.configuration.sortDescending
    property bool showKernel: Plasmoid.configuration.showKernelThreads
    property bool aggregate: Plasmoid.configuration.aggregateChildren
    property bool hideSystemd: Plasmoid.configuration.hideSystemd
    onAggregateChanged: rebuild()
    onHideSystemdChanged: rebuild()
    onColumnsChanged: rebuild()

    function colVal(p, c) {
        if (c.noagg) return p[c.key] || 0
        if (root.aggregate) { var a = p["a" + c.key]; return a === undefined ? (p[c.key] || 0) : a }
        return p[c.key] || 0
    }
    function colOf(key) { for (var i = 0; i < allColumns.length; i++) if (allColumns[i].key === key) return allColumns[i]; return null }
    function isHidden(p) { return root.hideSystemd && (p.pid === 1 || p.name === "systemd") }

    function fmtBytes(b) {
        if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB"
        if (b >= 1048576) return Math.round(b / 1048576) + " MB"
        if (b >= 1024) return Math.round(b / 1024) + " KB"
        return b + " B"
    }
    function fmtCol(p, c) {
        var v = root.colVal(p, c)
        if (c.kind === "pct") return Math.round(v) + "%"
        if (c.kind === "bytes") return v > 0 ? root.fmtBytes(v) : "—"
        if (c.kind === "rate") return v > 0 ? root.fmtBytes(v) + "/s" : "—"
        return v                                            // int
    }
    function heat(v, max) {
        if (!Plasmoid.configuration.colorizeUsage || v <= 0) return Kirigami.Theme.textColor
        var t = Math.max(0, Math.min(1, v / max))
        return Qt.hsla((1 - t) * 0.33, 0.6, 0.6, 1)        // green -> red
    }
    function colColor(p, c) { return (c.heat && c.kind === "pct") ? root.heat(root.colVal(p, c), 100) : Kirigami.Theme.textColor }

    // ---- read the tmpfs cache in-process via XHR ----
    property string cachePath: ""
    P5Support.DataSource {
        id: pathHelper
        engine: "executable"
        onNewData: function(source, d) { root.cachePath = (d.stdout || "").trim(); disconnectSource(source); root.read() }
    }
    function read() {
        if (!cachePath) return
        var xhr = new XMLHttpRequest()
        xhr.open("GET", "file://" + cachePath)
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (!xhr.responseText) return
            try { root.ingest(JSON.parse(xhr.responseText)) } catch (e) {}
        }
        xhr.send()
    }
    function ingest(d) {
        var ps = d.procs || []
        var bp = {}, ch = {}
        for (var i = 0; i < ps.length; i++) bp[ps[i].pid] = ps[i]
        for (var j = 0; j < ps.length; j++) {
            var q = ps[j]
            ;(ch[q.ppid] = ch[q.ppid] || []).push(q.pid)
        }
        root.ncpu = d.ncpu || 1
        root.procs = ps; root.byPid = bp; root.childrenOf = ch
        // accumulate history for every process (aggregate-aware), dropping dead PIDs
        var keys = root.histKeys
        var defs = keys.map(function(kk) { return root.colOf(kk) })
        var nh = {}
        for (var k = 0; k < ps.length; k++) {
            var pp = ps[k]
            var prev = root.hist[pp.pid]
            var hh = {}
            for (var m = 0; m < keys.length; m++) {
                var arr = (prev && prev[keys[m]]) ? prev[keys[m]].slice() : []
                arr.push(root.colVal(pp, defs[m]))
                if (arr.length > root.histLen) arr.shift()
                hh[keys[m]] = arr
            }
            nh[pp.pid] = hh
        }
        root.hist = nh
        rebuild()
    }
    Timer {
        interval: Math.max(500, Plasmoid.configuration.updateInterval)
        repeat: true
        running: root.expanded
        onTriggered: root.read()
    }
    onExpandedChanged: if (expanded) read()
    Component.onCompleted: {
        pathHelper.connectSource("printf %s \"$XDG_RUNTIME_DIR/Linux-Process-Mon/data.json\"")
        applyInterval()
    }
    // keep the collector's sample rate in lock-step with the refresh interval
    function applyInterval() {
        root.run("$HOME/.local/bin/procmon-collect --set-interval "
            + (Math.max(500, Plasmoid.configuration.updateInterval) / 1000))
    }
    Connections {
        target: Plasmoid.configuration
        function onUpdateIntervalChanged() { root.applyInterval() }
    }

    // ---- process actions (right-click menu) ----
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    P5Support.DataSource {
        id: runner
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source) }
    }
    P5Support.DataSource {                                  // reads a value, then copies it
        id: copier
        engine: "executable"
        onNewData: function(source, d) { disconnectSource(source); root.copyText((d.stdout || "").trim()) }
    }
    function run(cmd) { runner.connectSource(cmd) }
    function copyText(t) { clipboardHelper.text = t; clipboardHelper.selectAll(); clipboardHelper.copy(); clipboardHelper.text = "" }
    function copyCmdline(pid) { copier.connectSource("tr '\\0' ' ' < /proc/" + pid + "/cmdline") }
    function signalProc(pid, sig) { root.run("kill -" + sig + " " + pid) }
    function openLocation(pid) {
        root.run("sh -c " + shq("d=$(dirname \"$(readlink -f /proc/" + pid + "/exe 2>/dev/null)\"); [ -d \"$d\" ] && xdg-open \"$d\""))
    }
    function openJournal(name) { root.run("konsole -e journalctl _COMM=" + shq(name) + " -e") }
    function restartProc(pid) {
        // best-effort: relaunch the same argv in the same cwd, then kill the old pid
        root.run("bash -c " + shq("p=" + pid + "; mapfile -d '' a < /proc/$p/cmdline; cwd=$(readlink /proc/$p/cwd); kill \"$p\"; cd \"$cwd\" 2>/dev/null; setsid \"${a[@]}\" >/dev/null 2>&1 &"))
    }

    // ---- tree -> flat visible rows ----
    function sortVal(p) {
        if (root.sortColumn === "name") return (p.name || "").toLowerCase()
        var c = root.colOf(root.sortColumn)
        return c ? root.colVal(p, c) : (p[root.sortColumn] || 0)
    }
    function cmp(a, b) {
        var av = root.sortVal(a), bv = root.sortVal(b)
        var r = av < bv ? -1 : (av > bv ? 1 : 0)
        return root.sortDescending ? -r : r
    }
    function passes(p) { return p && (root.showKernel || !p.kernel) }
    function displayRoot(p) {
        if (!root.passes(p) || root.isHidden(p)) return false
        var par = root.byPid[p.ppid]
        return par === undefined || root.isHidden(par) || !root.passes(par)
    }
    function rebuild() {
        var lv = root.rowsViewRef
        var keepY = lv ? lv.contentY : 0
        var rows = []
        if (root.searchText !== "") {
            var ql = root.searchText.toLowerCase()
            var m = root.procs.filter(function(p) { return root.passes(p) && (p.name || "").toLowerCase().indexOf(ql) >= 0 })
            m.sort(root.cmp)
            for (var i = 0; i < m.length; i++) rows.push({ proc: m[i], depth: 0, hasChildren: false, expanded: false })
        } else {
            var rl = root.procs.filter(root.displayRoot)
            rl.sort(root.cmp)
            var walk = function(p, depth) {
                var kids = (root.childrenOf[p.pid] || []).map(function(pid) { return root.byPid[pid] })
                    .filter(function(k) { return k && root.passes(k) && !root.isHidden(k) })
                var has = kids.length > 0
                var exp = root.expanded[p.pid] === true
                rows.push({ proc: p, depth: depth, hasChildren: has, expanded: exp })
                if (has && exp) { kids.sort(root.cmp); for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1) }
            }
            for (var j = 0; j < rl.length; j++) walk(rl[j], 0)
        }
        root.visibleRows = rows
        // keep the viewport where it was, instead of snapping to the top each refresh
        if (lv) Qt.callLater(function() {
            lv.contentY = Math.max(0, Math.min(keepY, lv.contentHeight - lv.height))
        })
    }
    function toggle(pid) { var e = root.expanded; e[pid] = !e[pid]; root.expanded = e; rebuild() }
    function collapseAll() { root.expanded = ({}); rebuild() }
    function applySort(col, desc) {
        root.sortColumn = col; root.sortDescending = desc
        Plasmoid.configuration.sortColumn = col; Plasmoid.configuration.sortDescending = desc
        rebuild()
    }
    function headerSort(col) { applySort(col, root.sortColumn === col ? !root.sortDescending : (col !== "name")) }
    onSearchTextChanged: rebuild()
    onShowKernelChanged: rebuild()

    // clickable, sort-aware column header
    component HeaderCell: Item {
        property string label: ""
        property string col: ""
        property int align: Text.AlignLeft
        implicitHeight: hl.implicitHeight + Kirigami.Units.smallSpacing
        PlasmaComponents.Label {
            id: hl
            anchors.fill: parent
            horizontalAlignment: parent.align
            verticalAlignment: Text.AlignVCenter
            font.weight: Font.Bold
            opacity: hdrMa.containsMouse ? 1.0 : 0.8
            elide: Text.ElideRight
            text: parent.label + (root.sortColumn === parent.col ? (root.sortDescending ? "  ▾" : "  ▴") : "")
        }
        MouseArea {
            id: hdrMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.headerSort(parent.col)
        }
    }

    preferredRepresentation: fullRepresentation
    fullRepresentation: Item {
        clip: true
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        implicitWidth: Kirigami.Units.gridUnit * 36
        implicitHeight: Kirigami.Units.gridUnit * 28

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- header: icon + title (left), sort + search (right) ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Kirigami.Icon {
                    source: root.panelIcon
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
                PlasmaComponents.Label { text: i18n("Process Monitor"); font.weight: Font.Bold }

                Item { Layout.fillWidth: true }

                QQC2.ToolButton {
                    flat: true
                    icon.name: "format-indent-less"
                    QQC2.ToolTip.text: i18n("Collapse all"); QQC2.ToolTip.visible: hovered
                    onClicked: root.collapseAll()
                }
                QQC2.TextField {
                    id: searchField
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                    placeholderText: i18n("Search processes…")
                    text: root.searchText
                    onTextChanged: root.searchText = text
                    QQC2.ToolButton {
                        visible: searchField.text !== ""
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        flat: true; icon.name: "edit-clear"
                        onClicked: searchField.clear()
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- column header row ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                HeaderCell { Layout.fillWidth: true; label: i18n("Name"); col: "name" }
                Repeater {
                    model: root.columns
                    delegate: HeaderCell {
                        required property var modelData
                        Layout.preferredWidth: root.numColW
                        label: modelData.label
                        col: modelData.key
                        align: Text.AlignRight
                    }
                }
            }
            Kirigami.Separator { Layout.fillWidth: true }

            // ---- rows ----
            ListView {
                id: rowsView
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                reuseItems: true
                model: root.visibleRows
                boundsBehavior: Flickable.StopAtBounds
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
                Component.onCompleted: root.rowsViewRef = rowsView

                delegate: Rectangle {
                    id: rowItem
                    property var rowProc: modelData.proc
                    width: rowsView.width
                    height: Kirigami.Units.gridUnit * 1.7
                    // zebra striping (matches the System Log), hover highlight on top
                    color: rowMa.containsMouse ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                                               : (index % 2 ? Qt.alpha(Kirigami.Theme.textColor, 0.03) : "transparent")

                    // history sparkline of the sorted metric, behind the row content
                    Sparkline {
                        anchors.fill: parent
                        anchors.topMargin: 1; anchors.bottomMargin: 1
                        z: -1
                        visible: root.sortColumn !== "name" && root.sortColumn !== "pid"
                        values: root.histFor(rowItem.rowProc.pid, root.sortColumn)
                        rangeMax: root.graphMax(root.sortColumn)
                        lineColor: Kirigami.Theme.highlightColor
                        opacity: 0.55
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing / 2
                        spacing: Kirigami.Units.smallSpacing

                        // name cell: indent + expander + icon + label
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Item { Layout.preferredWidth: modelData.depth * Kirigami.Units.gridUnit; Layout.fillHeight: true }
                            QQC2.ToolButton {
                                visible: modelData.hasChildren
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.3
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.3
                                flat: true
                                icon.name: modelData.expanded ? "go-down-symbolic" : "go-next-symbolic"
                                onClicked: root.toggle(modelData.proc.pid)
                            }
                            Item { visible: !modelData.hasChildren; Layout.preferredWidth: Kirigami.Units.gridUnit * 1.3 }
                            Kirigami.Icon {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.rightMargin: Kirigami.Units.smallSpacing
                                // resolved .desktop icon if we found one, else the bare
                                // process name, else a generic executable glyph
                                source: modelData.proc.icon ? modelData.proc.icon : modelData.proc.name
                                fallback: "application-x-executable"
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: modelData.proc.name
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                        Repeater {
                            model: root.columns
                            delegate: PlasmaComponents.Label {
                                required property var modelData
                                Layout.preferredWidth: root.numColW
                                horizontalAlignment: Text.AlignRight
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                opacity: modelData.kind === "bytes" || modelData.kind === "int" ? 0.9 : 1.0
                                text: root.fmtCol(rowItem.rowProc, modelData)
                                color: root.colColor(rowItem.rowProc, modelData)
                            }
                        }
                    }
                    MouseArea {
                        id: rowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.RightButton          // left clicks pass to the expander
                        onClicked: { procMenu.proc = rowItem.rowProc; procMenu.popup() }
                    }
                }
            }

            PlasmaComponents.Label {
                Layout.alignment: Qt.AlignHCenter
                visible: root.visibleRows.length === 0
                text: root.searchText !== "" ? i18n("No matching processes") : i18n("Loading…")
                opacity: 0.5
            }
        }

        // hidden helper so Copy works on X11 + Wayland without external tools
        TextEdit { id: clipboardHelper; visible: false }

        QQC2.Menu {
            id: procMenu
            property var proc: ({})
            QQC2.MenuItem { text: i18n("Copy PID"); icon.name: "edit-copy"; onTriggered: root.copyText(String(procMenu.proc.pid)) }
            QQC2.MenuItem { text: i18n("Copy name"); icon.name: "edit-copy"; onTriggered: root.copyText(procMenu.proc.name || "") }
            QQC2.MenuItem { text: i18n("Copy command line"); icon.name: "edit-copy"; onTriggered: root.copyCmdline(procMenu.proc.pid) }
            QQC2.MenuSeparator {}
            QQC2.MenuItem { text: i18n("Open file location"); icon.name: "folder-open"; onTriggered: root.openLocation(procMenu.proc.pid) }
            QQC2.MenuItem { text: i18n("Open journal log"); icon.name: "utilities-log-viewer"; onTriggered: root.openJournal(procMenu.proc.name || "") }
            QQC2.MenuItem { text: i18n("Restart (best-effort)"); icon.name: "system-reboot"; onTriggered: root.restartProc(procMenu.proc.pid) }
            QQC2.MenuSeparator {}
            QQC2.MenuItem { text: i18n("Stop (SIGSTOP)"); icon.name: "media-playback-pause"; onTriggered: root.signalProc(procMenu.proc.pid, "STOP") }
            QQC2.MenuItem { text: i18n("Continue (SIGCONT)"); icon.name: "media-playback-start"; onTriggered: root.signalProc(procMenu.proc.pid, "CONT") }
            QQC2.MenuSeparator {}
            QQC2.MenuItem { text: i18n("Kill (SIGTERM)"); icon.name: "process-stop"; onTriggered: root.signalProc(procMenu.proc.pid, "TERM") }
            QQC2.MenuItem { text: i18n("Force kill (SIGKILL)"); icon.name: "process-stop"; onTriggered: root.signalProc(procMenu.proc.pid, "KILL") }
            QQC2.MenuItem { text: i18n("Force kill as root…"); icon.name: "process-stop"; onTriggered: root.run("pkexec kill -9 " + procMenu.proc.pid) }
        }
    }
}
