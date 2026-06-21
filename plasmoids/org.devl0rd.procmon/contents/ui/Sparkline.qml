/*
 * A filled line chart driven by a plain array of values, with a hover marker +
 * tooltip showing the value under the cursor. Auto-scales (with an optional
 * floor) or uses a fixed max.
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.quickcharts as Charts

Item {
    id: s

    property var values: []
    property color lineColor: Kirigami.Theme.highlightColor
    property bool filled: true
    property real rangeMax: 0          // 0 = auto-scale
    property real rangeFloor: 0        // auto-scale never zooms in below this
    // tooltip text for the hovered point (index 0 = oldest). Override per use.
    property var tipText: function(value, index, total) { return "" + value }

    Charts.LineChart {
        anchors.fill: parent
        smooth: true
        lineWidth: 1.25
        Charts.SingleValueSource { id: lineSrc; value: s.lineColor }
        Charts.SingleValueSource { id: fillSrc; value: Qt.alpha(s.lineColor, 0.16) }
        Charts.ArraySource { id: arr; array: s.values }
        valueSources: [ arr ]
        colorSource: lineSrc
        fillColorSource: s.filled ? fillSrc : null
        yRange {
            from: 0
            to: s.rangeMax
            automatic: s.rangeMax <= 0
            minimum: s.rangeFloor
        }
    }

    // vertical marker at the hovered sample
    Rectangle {
        visible: hover.containsMouse && hover.idx >= 0 && s.values.length > 1
        width: 1
        height: s.height
        color: Qt.alpha(s.lineColor, 0.6)
        x: s.values.length > 1 ? hover.idx / (s.values.length - 1) * s.width : 0
    }

    // tooltip bubble that follows the cursor
    Rectangle {
        id: bubble
        z: 10
        visible: hover.containsMouse && hover.idx >= 0 && s.values.length > 1
        color: Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.alpha(Kirigami.Theme.textColor, 0.3)
        radius: 3
        width: lbl.implicitWidth + Kirigami.Units.smallSpacing * 2
        height: lbl.implicitHeight + Kirigami.Units.smallSpacing
        x: Math.max(0, Math.min(s.width - width, hover.mx - width / 2))
        y: 0
        QQC2.Label {
            id: lbl
            anchors.centerIn: parent
            font: Kirigami.Theme.smallFont
            text: (hover.idx >= 0 && hover.idx < s.values.length)
                  ? s.tipText(s.values[hover.idx], hover.idx, s.values.length) : ""
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton   // don't steal clicks from anything beneath
        property int idx: -1
        property real mx: 0
        onPositionChanged: function(m) {
            mx = m.x
            if (s.values.length > 1) {
                var i = Math.round(m.x / s.width * (s.values.length - 1))
                idx = Math.max(0, Math.min(s.values.length - 1, i))
            } else {
                idx = -1
            }
        }
        onExited: idx = -1
    }
}
