import QtQuick
import qs.Commons

// One labelled horizontal usage bar: caption on the left, value on the right,
// track underneath. The fill colour ramps toward `urgent` as the value climbs
// so a hot resource is visible without reading the number.
Item {
  id: root

  property string label: ""
  property string value: ""
  property real fraction: 0
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property real severity: 0
  property real trackHeight: Style.space(6)
  property real labelWidth: 0
  property int labelSize: Style.font.bodySmall

  readonly property color fillColor: severity > 0
    ? Qt.tint(foreground, Qt.rgba(urgent.r, urgent.g, urgent.b, severity))
    : foreground

  implicitHeight: labelRow.implicitHeight + Style.space(4) + trackHeight

  Item {
    id: labelRow
    anchors.left: parent.left
    anchors.right: parent.right
    implicitHeight: Math.max(caption.implicitHeight, reading.implicitHeight)

    Text {
      id: caption
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      opacity: 0.62
      font.family: root.fontFamily
      font.pixelSize: root.labelSize
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.labelWidth > 0 ? root.labelWidth : implicitWidth
      elide: Text.ElideRight
    }

    Text {
      id: reading
      textFormat: Text.PlainText
      text: root.value
      color: root.fillColor
      font.family: root.fontFamily
      font.pixelSize: root.labelSize
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter

      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: labelRow.bottom
    anchors.topMargin: Style.space(4)
    height: root.trackHeight
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: parent.radius
      color: root.fillColor
      width: Math.max(parent.height, parent.width * Math.max(0, Math.min(1, root.fraction)))

      Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }
}
