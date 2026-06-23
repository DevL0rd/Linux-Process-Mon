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
import QtQml.WorkerScript

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
    // The heavy pipeline (parse + history rings + tree-walk) runs OFF the GUI
    // thread in proc.worker.mjs; it hands back the flat row list plus per-PID
    // proc data + sort-column history for the rows it produced. The GUI thread
    // only reconciles the ListModel and formats the visible cells.
    property real memTotal: 0             // system RAM total -> RAM sparkline max
    property real vramTotal: 0            // GPU VRAM total -> VRAM sparkline max
    property var expanded: ({})           // pid -> true when expanded (default: collapsed)
    property var procByPid: ({})          // pid -> proc, for the rows currently shown
    property var sortHistByPid: ({})      // pid -> sort-column history array (linearised)

    // the visible rows live in a ListModel that is reconciled in place each poll
    // (insert/move/set/remove keyed by pid) so delegates PERSIST and only changed
    // values update -- no destroying/recreating the whole list every refresh
    ListModel { id: rowModel }
    property var rowsViewRef: null        // ListView ref (read-only, for scroll state)

    readonly property int histLen: 40
    readonly property var histKeys: ["cpu", "ram", "gpu", "dec", "enc", "vram", "disk", "threads"]
    // each metric's natural ceiling: CPU/GPU/DEC/ENC = 100, RAM = total RAM,
    // VRAM = total VRAM, disk/threads = auto-scale
    function graphMax(col) {
        if (col === "ram") return root.memTotal
        if (col === "vram") return root.vramTotal
        var c = root.colOf(col)
        return (c && c.kind === "pct") ? 100 : 0
    }

    property string searchText: ""
    property string sortColumn: Plasmoid.configuration.sortColumn || "cpu"
    property bool sortDescending: Plasmoid.configuration.sortDescending
    property bool showKernel: Plasmoid.configuration.showKernelThreads
    property bool aggregate: Plasmoid.configuration.aggregateChildren
    property bool hideSystemd: Plasmoid.configuration.hideSystemd
    onAggregateChanged: requestRebuild()
    onHideSystemdChanged: requestRebuild()
    onColumnsChanged: requestRebuild()

    function colVal(p, c) {
        if (c.noagg) return p[c.key] || 0
        if (root.aggregate) { var a = p["a" + c.key]; return a === undefined ? (p[c.key] || 0) : a }
        return p[c.key] || 0
    }
    function colOf(key) { for (var i = 0; i < allColumns.length; i++) if (allColumns[i].key === key) return allColumns[i]; return null }

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
            worker.sendMessage({ text: xhr.responseText, state: root.workerState() })
        }
        xhr.send()
    }
    // UI-state snapshot the worker needs to walk the tree (the parse stays cached
    // worker-side, so sort/search/expand only re-walk -- no re-parse)
    function workerState() {
        var def = root.colOf(root.sortColumn)
        return {
            histKeys: root.histKeys, histLen: root.histLen, aggregate: root.aggregate,
            sortColumn: root.sortColumn, sortNoagg: def ? !!def.noagg : true,
            sortDescending: root.sortDescending, searchText: root.searchText,
            showKernel: root.showKernel, hideSystemd: root.hideSystemd, expanded: root.expanded
        }
    }
    function requestRebuild() { worker.sendMessage({ text: null, state: root.workerState() }) }

    WorkerScript {
        id: worker
        source: Qt.resolvedUrl("proc.worker.mjs")
        onMessage: function(msg) {
            root.memTotal = msg.memTotal
            root.vramTotal = msg.vramTotal
            root.procByPid = msg.procByPid
            root.sortHistByPid = msg.sortHistByPid
            var lv = root.rowsViewRef
            // re-sort/reorder only while at the top; freeze the order when scrolled
            if (!lv || lv.contentY < Kirigami.Units.gridUnit * 1.7)
                root.syncModel(msg.desired)
            else
                root.syncFrozen(msg.desired)
        }
    }
    // event-driven: re-read the instant the collector rewrites the snapshot (no
    // polling). The collector's own sample rate (updateInterval, applied below)
    // sets how often that happens.
    FileWatcher {
        path: root.cachePath
        onChanged: root.read()
    }
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

    // ---- reconcile rowModel against the worker's flat row list ----
    // The parse + history + tree-walk run off-thread in proc.worker.mjs; these
    // syncs only diff the small {pid,depth,hasChildren,expanded} rows against the
    // model (cheap, GUI-thread). Cell values come from procByPid (re-looked-up in
    // the delegate), so they update without the model touching them.
    //
    // keep current row order; just update tree fields, drop gone rows, append new
    // ones at the end (no moves -> no scroll jump while the user is scrolled)
    function syncFrozen(desired) {
        var want = {}, map = {}
        for (var i = 0; i < desired.length; i++) { want[desired[i].pid] = true; map[desired[i].pid] = desired[i] }
        for (var r = rowModel.count - 1; r >= 0; r--)
            if (want[rowModel.get(r).pid] !== true) rowModel.remove(r)
        var have = {}
        for (var x = 0; x < rowModel.count; x++) {
            var m = rowModel.get(x); have[m.pid] = true
            var d = map[m.pid]
            if (d && (m.depth !== d.depth || m.hasChildren !== d.hasChildren || m.expanded !== d.expanded))
                rowModel.set(x, d)
        }
        for (var j = 0; j < desired.length; j++)
            if (have[desired[j].pid] !== true) rowModel.append(desired[j])
    }
    // reconcile rowModel in place to match `desired`, keyed by pid: O(n) when the
    // order is stable (fast path); otherwise insert/move/set/remove only the diff.
    // Detecting removed/new rows is O(n) via the want-set + position scan.
    function syncModel(desired) {
        var n = desired.length
        var want = {}
        for (var i = 0; i < n; i++) want[desired[i].pid] = true
        for (var r = rowModel.count - 1; r >= 0; r--)        // drop gone rows
            if (want[rowModel.get(r).pid] !== true) rowModel.remove(r)
        for (var pos = 0; pos < n; pos++) {
            var d = desired[pos]
            if (pos < rowModel.count && rowModel.get(pos).pid === d.pid) {
                var a = rowModel.get(pos)                     // already in place
                if (a.depth !== d.depth || a.hasChildren !== d.hasChildren || a.expanded !== d.expanded)
                    rowModel.set(pos, d)
                continue
            }
            var cur = -1
            for (var x = pos + 1; x < rowModel.count; x++)
                if (rowModel.get(x).pid === d.pid) { cur = x; break }
            if (cur < 0) {
                rowModel.insert(pos, d)                       // new row
            } else {
                rowModel.move(cur, pos, 1)                    // moved row
                var b = rowModel.get(pos)
                if (b.depth !== d.depth || b.hasChildren !== d.hasChildren || b.expanded !== d.expanded)
                    rowModel.set(pos, d)
            }
        }
    }
    function toggle(pid) { var e = root.expanded; e[pid] = !e[pid]; root.expanded = e; requestRebuild() }
    function collapseAll() { root.expanded = ({}); requestRebuild() }
    function applySort(col, desc) {
        root.sortColumn = col; root.sortDescending = desc
        Plasmoid.configuration.sortColumn = col; Plasmoid.configuration.sortDescending = desc
        requestRebuild()
    }
    function headerSort(col) { applySort(col, root.sortColumn === col ? !root.sortDescending : (col !== "name")) }
    onSearchTextChanged: requestRebuild()
    onShowKernelChanged: requestRebuild()

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
                cacheBuffer: Kirigami.Units.gridUnit * 20   // small offscreen cache, less churn
                model: rowModel
                boundsBehavior: Flickable.StopAtBounds
                QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
                Component.onCompleted: root.rowsViewRef = rowsView

                delegate: Rectangle {
                    id: rowItem
                    required property int index
                    required property int pid
                    required property int depth
                    required property bool hasChildren
                    required property bool expanded
                    // proc data looked up live -> updates in place when byPid refreshes,
                    // without recreating the delegate
                    readonly property var rowProc: root.procByPid[pid] || ({})
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
                        values: root.sortHistByPid[rowItem.pid] || []
                        rangeMax: root.graphMax(root.sortColumn)
                        lineColor: Kirigami.Theme.highlightColor
                        peakMarker: false        // behind-text decoration; no label
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
                            Item { Layout.preferredWidth: rowItem.depth * Kirigami.Units.gridUnit; Layout.fillHeight: true }
                            QQC2.ToolButton {
                                visible: rowItem.hasChildren
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.3
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.3
                                flat: true
                                icon.name: rowItem.expanded ? "go-down-symbolic" : "go-next-symbolic"
                                onClicked: root.toggle(rowItem.pid)
                            }
                            Item { visible: !rowItem.hasChildren; Layout.preferredWidth: Kirigami.Units.gridUnit * 1.3 }
                            Kirigami.Icon {
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                Layout.rightMargin: Kirigami.Units.smallSpacing
                                // resolved .desktop icon if we found one, else the bare
                                // process name, else a generic executable glyph
                                source: rowItem.rowProc.icon ? rowItem.rowProc.icon : (rowItem.rowProc.name || "application-x-executable")
                                fallback: "application-x-executable"
                            }
                            PlasmaComponents.Label {
                                Layout.fillWidth: true
                                text: rowItem.rowProc.name || ""
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
                visible: rowModel.count === 0
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
