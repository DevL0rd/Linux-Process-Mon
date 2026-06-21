import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    property alias cfg_panelIcon: iconField.text
    property alias cfg_updateInterval: intervalSpin.value
    property alias cfg_showKernelThreads: kernelCheck.checked
    property alias cfg_aggregateChildren: aggregateCheck.checked
    property alias cfg_hideSystemd: systemdCheck.checked
    property alias cfg_colorizeUsage: colorizeCheck.checked
    property alias cfg_showGpuColumn: gpuCheck.checked
    property alias cfg_showDecColumn: decCheck.checked
    property alias cfg_showEncColumn: encCheck.checked
    property alias cfg_showVramColumn: vramCheck.checked
    property alias cfg_showDiskColumn: diskCheck.checked
    property alias cfg_showThreadsColumn: threadsCheck.checked
    property alias cfg_showPidColumn: pidCheck.checked

    // persisted from the table header clicks, not edited here
    property string cfg_sortColumn
    property bool cfg_sortDescending

    RowLayout {
        Kirigami.FormData.label: i18n("Panel icon:")
        QQC2.TextField { id: iconField; placeholderText: i18n("icon name") }
    }
    RowLayout {
        Kirigami.FormData.label: i18n("Refresh interval:")
        QQC2.SpinBox { id: intervalSpin; from: 500; to: 10000; stepSize: 250 }
        QQC2.Label { text: i18n("ms"); opacity: 0.6 }
    }
    QQC2.CheckBox { id: kernelCheck; Kirigami.FormData.label: i18n("Show:"); text: i18n("Kernel threads") }
    QQC2.CheckBox { id: aggregateCheck; text: i18n("Add children's usage to parents") }
    QQC2.CheckBox { id: systemdCheck; text: i18n("Hide systemd (show its children at top level)") }
    QQC2.CheckBox { id: colorizeCheck; text: i18n("Colorize CPU / GPU usage") }

    QQC2.CheckBox { id: gpuCheck; Kirigami.FormData.label: i18n("Columns:"); text: i18n("GPU") }
    QQC2.CheckBox { id: decCheck; text: i18n("Decoder (DEC)") }
    QQC2.CheckBox { id: encCheck; text: i18n("Encoder (ENC)") }
    QQC2.CheckBox { id: vramCheck; text: i18n("VRAM") }
    QQC2.CheckBox { id: diskCheck; text: i18n("Disk I/O") }
    QQC2.CheckBox { id: threadsCheck; text: i18n("Threads") }
    QQC2.CheckBox { id: pidCheck; text: i18n("PID") }

    QQC2.Label {
        Kirigami.FormData.label: i18n("Collector:")
        text: i18n("Sampling rate is poll_interval in ~/.config/Linux-Process-Mon/config.json")
        opacity: 0.6
        wrapMode: Text.Wrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
    }
}
