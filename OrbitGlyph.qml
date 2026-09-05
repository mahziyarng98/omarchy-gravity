import QtQuick
import qs.Commons

// The Gravity mark: a core with two satellites on two tracks, always turning.
//
// Drawn rather than set in a font, for two reasons. The bar's icon fonts have
// nothing that reads as an orbit at 16px, and a glyph cannot move -- and the
// motion is the identity here. It is the same mark in the bar and in the
// middle of the panel, at two sizes, so the thing you click and the thing you
// land on are visibly the same object.
//
// Everything scales off `unit` so one component serves both. Colors come from
// the caller, which resolves them from the live theme.
Item {
  id: glyph

  property color coreColor: Color.accent
  property color satelliteColor: Color.foreground
  property color trackColor: Util.alpha(satelliteColor, 0.20)
  property bool showTracks: true
  property bool spinning: true
  // Multiplier on the orbital periods. Below 1 is slower.
  property real speed: 1.0

  readonly property real unit: Math.min(width, height)
  readonly property real innerTrack: unit * 0.54
  readonly property real outerTrack: unit * 0.96
  readonly property real strokeWidth: Math.max(1, unit * 0.045)

  // Animators run on the render thread, so the mark keeps its rhythm even
  // while the shell's GUI thread is busy laying out a panel.
  RotationAnimator {
    target: innerOrbit
    from: 0
    to: 360
    duration: Math.max(400, Math.round(2600 / Math.max(0.05, glyph.speed)))
    loops: Animation.Infinite
    running: glyph.spinning
  }

  RotationAnimator {
    target: outerOrbit
    from: 0
    to: 360
    duration: Math.max(400, Math.round(5200 / Math.max(0.05, glyph.speed)))
    loops: Animation.Infinite
    running: glyph.spinning
  }

  Rectangle {
    visible: glyph.showTracks
    anchors.centerIn: parent
    width: glyph.innerTrack
    height: width
    radius: width / 2
    color: "transparent"
    border.width: glyph.strokeWidth
    border.color: glyph.trackColor
  }

  Rectangle {
    visible: glyph.showTracks
    anchors.centerIn: parent
    width: glyph.outerTrack
    height: width
    radius: width / 2
    color: "transparent"
    border.width: glyph.strokeWidth
    border.color: Util.alpha(glyph.trackColor, 0.6)
  }

  Item {
    id: innerOrbit
    anchors.centerIn: parent
    width: glyph.innerTrack
    height: width

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: parent.width - width / 2
      width: Math.max(2, glyph.unit * 0.155)
      height: width
      radius: width / 2
      color: glyph.satelliteColor
    }
  }

  Item {
    id: outerOrbit
    anchors.centerIn: parent
    width: glyph.outerTrack
    height: width

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      // Half a turn out of phase with the inner satellite. The offset lives
      // in the satellite's position rather than the track's rotation because
      // the animator owns `rotation` outright and would overwrite it.
      x: -width / 2
      width: Math.max(2, glyph.unit * 0.2)
      height: width
      radius: width / 2
      color: glyph.satelliteColor
    }
  }

  Rectangle {
    id: core
    anchors.centerIn: parent
    width: glyph.unit * 0.26
    height: width
    radius: width / 2
    color: glyph.coreColor
    transformOrigin: Item.Center

    SequentialAnimation on scale {
      running: glyph.spinning
      loops: Animation.Infinite
      NumberAnimation { from: 1.0; to: 1.18; duration: 1300; easing.type: Easing.InOutSine }
      NumberAnimation { from: 1.18; to: 1.0; duration: 1300; easing.type: Easing.InOutSine }
    }
  }
}
