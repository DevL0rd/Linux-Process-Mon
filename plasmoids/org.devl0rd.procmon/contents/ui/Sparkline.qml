/*
 * A filled line chart driven by a plain array of values, with a hover marker +
 * tooltip showing the value under the cursor. Auto-scales (with an optional
 * floor) or uses a fixed max. The line + fill are drawn with a vertical value
 * gradient -- blue at the bottom through green/yellow to red at the top -- so
 * each point along the history is coloured by its value.
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: s

    property var values: []
    property color lineColor: Kirigami.Theme.highlightColor
    property bool filled: true
    property bool gradient: true       // false -> flat lineColor
    property real rangeMax: 0          // 0 = auto-scale
    property real rangeFloor: 0        // auto-scale never zooms in below this
    // tooltip text for the hovered point (index 0 = oldest). Override per use.
    property var tipText: function(value, index, total) { return "" + value }

    // blue (low) -> green/yellow -> red (full), matching the bar/meter fills
    function gradColor(v) {
        var t = Math.max(0, Math.min(1, v / 100))
        return Qt.hsla((1 - t) * 0.66, 0.62, 0.55, 1.0)
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var vals = s.values || []
            var n = vals.length
            if (n < 1 || width <= 0 || height <= 0)
                return

            var hi = s.rangeMax > 0 ? s.rangeMax : s.rangeFloor
            if (s.rangeMax <= 0)
                for (var k = 0; k < n; k++) hi = Math.max(hi, vals[k])
            hi = Math.max(hi, 1)
            var dx = n > 1 ? width / (n - 1) : 0
            function yOf(v) { return height - Math.max(0, Math.min(1, v / hi)) * height }
            function trace() {
                ctx.beginPath()
                if (n === 1) { ctx.moveTo(0, yOf(vals[0])); ctx.lineTo(width, yOf(vals[0])); return }
                for (var i = 0; i < n; i++) {
                    var x = i * dx, y = yOf(vals[i])
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                }
            }

            // fill under the line
            if (s.filled) {
                trace()
                ctx.lineTo(n > 1 ? (n - 1) * dx : width, height)
                ctx.lineTo(0, height)
                ctx.closePath()
                if (s.gradient) {
                    var fg = ctx.createLinearGradient(0, height, 0, 0)
                    fg.addColorStop(0.0, Qt.alpha(s.gradColor(0), 0.04))
                    fg.addColorStop(0.5, Qt.alpha(s.gradColor(50), 0.15))
                    fg.addColorStop(1.0, Qt.alpha(s.gradColor(100), 0.30))
                    ctx.fillStyle = fg
                } else {
                    ctx.fillStyle = Qt.alpha(s.lineColor, 0.16)
                }
                ctx.fill()
            }

            // the line on top, coloured by height
            trace()
            ctx.lineWidth = 1.5
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            if (s.gradient) {
                var lg = ctx.createLinearGradient(0, height, 0, 0)
                lg.addColorStop(0.00, s.gradColor(0))
                lg.addColorStop(0.33, s.gradColor(33))
                lg.addColorStop(0.66, s.gradColor(66))
                lg.addColorStop(1.00, s.gradColor(100))
                ctx.strokeStyle = lg
            } else {
                ctx.strokeStyle = s.lineColor
            }
            ctx.stroke()
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: s
            function onValuesChanged() { canvas.requestPaint() }
            function onRangeMaxChanged() { canvas.requestPaint() }
            function onRangeFloorChanged() { canvas.requestPaint() }
            function onGradientChanged() { canvas.requestPaint() }
            function onLineColorChanged() { canvas.requestPaint() }
        }
    }

    // vertical marker at the hovered sample
    Rectangle {
        visible: hover.containsMouse && hover.idx >= 0 && s.values.length > 1
        width: 1
        height: s.height
        color: Qt.alpha(Kirigami.Theme.textColor, 0.5)
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
