// Apple TV-style volume indicator for the LG CineBeam, replacing LG's
// /usr/lib/qml/WebOSCompositor/views/volume/StarfishVolume.qml (bind-mounted over it).
//
// Written from scratch against the interface StarfishVolumeView.qml expects: the properties it
// sets (partialViewState, supportScreenType, volumeBarMiddleLength, volumeDirectionString), the
// strings it reads for audio guidance, update(), restartClosingTimer(), and BaseView's
// open/close animations. Instead of LG's bar and gauge images, it shows a dark rounded vertical
// pill at the right edge with a thin white level bar filling from the bottom and a speaker icon
// below it.

import QtQuick 2.4
import WebOSCompositorBase 1.0
import WebOSCompositor 1.0

BaseView {
    id: root
    anchors.right: parent.right

    // Set by StarfishVolumeView. Rolling-screen layouts don't exist on the projector.
    property bool partialViewState: false
    property string supportScreenType: "none"
    property real volumeBarMiddleLength: 0

    // Read by StarfishVolumeView for audio guidance (text-to-speech).
    property string volumeDirectionString: ""
    property string sourceType: ""
    property string previousSourceType: ""
    property string exteriorVolumeCause: ""
    property string volumeStr: qsTr("volume") + Settings.l10n.tr
    property string upStr: qsTr("up") + Settings.l10n.tr
    property string downStr: qsTr("down") + Settings.l10n.tr
    property string volumeDisabledStr: qsTr("The device's volume is not controllable with TV remote") + Settings.l10n.tr

    // Outputs whose level the projector can't read (optical, ARC, line out): show direction only.
    property bool exterior: ["external_optical", "external_arc", "external_arc_sound_mode_sync",
                             "lineout", "urcu_oss"].indexOf(LS.audioService.soundOutput) !== -1
    property bool silent: LS.audioService.muted || LS.audioService.disabled
    property real level: {
        var max = LS.audioService.volumeMax > 0 ? LS.audioService.volumeMax : 100;
        var v = LS.audioService.volume > 0 ? LS.audioService.volume : 0;
        return Math.min(v / max, 1);
    }

    // Sizes in 1920×1080 compositor coordinates.
    readonly property real panelWidth: 64
    readonly property real panelHeight: 320
    readonly property real rightMargin: 64

    function update() {
        switch (LS.audioService.soundOutput) {
        case "headphone":
            sourceType = "volume_icon_headset";
            break;
        case "bt_soundbar":
            sourceType = "volume_icon_bluetooth";
            break;
        case "wisa_speaker":
            sourceType = "volume_icon_wisa";
            break;
        case "tv_speaker_bluetooth":
        case "tv_speaker_bt_surround":
            sourceType = "volume_icon_speaker_bluetooth";
            break;
        default:
            sourceType = exterior ? "volume_exterior" : "volume_icon";
            break;
        }
        if (LS.audioService.cause === "volumeUp")
            volumeDirectionString = "up";
        else if (LS.audioService.cause === "volumeDown")
            volumeDirectionString = "down";
        exteriorVolumeCause = silent ? "" : LS.audioService.cause;
        previousSourceType = silent ? "" : sourceType;
        speaker.requestPaint();
    }

    function restartClosingTimer() {
        closingTimer.restart();
    }

    Rectangle {
        id: panel
        width: root.panelWidth
        height: root.panelHeight
        anchors.right: parent.right
        anchors.rightMargin: root.rightMargin
        y: -height / 2 // the view sits at the vertical centre of the screen
        radius: width / 2
        color: "#1c1c1e"
        opacity: 0
        antialiasing: true

        // Speaker glyph, drawn so it stays sharp at any scale. Muted or disabled: crossed out.
        Canvas {
            id: speaker
            width: 30
            height: 30
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 20
            anchors.horizontalCenter: parent.horizontalCenter
            property bool crossed: root.silent
            property real level: root.level
            onCrossedChanged: requestPaint()
            onLevelChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                ctx.fillStyle = "white";
                ctx.strokeStyle = "white";
                ctx.lineCap = "round";
                // Speaker body and cone.
                ctx.beginPath();
                ctx.moveTo(2, 11);
                ctx.lineTo(8, 11);
                ctx.lineTo(15, 4);
                ctx.lineTo(15, 26);
                ctx.lineTo(8, 19);
                ctx.lineTo(2, 19);
                ctx.closePath();
                ctx.fill();
                ctx.lineWidth = 2.4;
                if (crossed) {
                    ctx.beginPath();
                    ctx.moveTo(20, 10);
                    ctx.lineTo(28, 20);
                    ctx.moveTo(28, 10);
                    ctx.lineTo(20, 20);
                    ctx.stroke();
                    return;
                }
                // Sound waves: one, two or three depending on the level.
                var waves = root.exterior ? 2 : (level <= 0 ? 0 : (level < 0.34 ? 1 : (level < 0.67 ? 2 : 3)));
                for (var i = 0; i < waves; i++) {
                    ctx.beginPath();
                    ctx.arc(15, 15, 6 + i * 5, -Math.PI / 4, Math.PI / 4, false);
                    ctx.stroke();
                }
            }
        }

        // Level bar: a dim track with a white fill rising from the bottom.
        Rectangle {
            id: track
            anchors.top: parent.top
            anchors.topMargin: 28
            anchors.bottom: speaker.top
            anchors.bottomMargin: 18
            anchors.horizontalCenter: parent.horizontalCenter
            width: 8
            radius: width / 2
            color: Qt.rgba(1, 1, 1, 0.22)
            visible: !root.exterior

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: root.silent ? 0 : Math.max(parent.width, parent.height * root.level)
                radius: width / 2
                color: "white"
                visible: !root.silent && root.level > 0
                Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
        }

        // Exterior outputs only report the direction of the change.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: track.verticalCenter
            visible: root.exterior && !root.silent
            color: "white"
            font.pixelSize: 28
            text: root.exteriorVolumeCause === "volumeDown" ? "−" : (root.exteriorVolumeCause === "volumeUp" ? "+" : "")
        }
    }

    Timer {
        id: closingTimer
        interval: Settings.local.volume.showingTime
        onTriggered: root.closeView()
    }

    openAnimation: SequentialAnimation {
        ScriptAction { script: closingTimer.restart(); }
        ParallelAnimation {
            NumberAnimation { target: panel; property: "opacity"; to: 0.92; duration: 180; easing.type: Easing.OutQuad }
            NumberAnimation { target: panel; property: "scale"; from: 0.92; to: 1.0; duration: 180; easing.type: Easing.OutQuad }
        }
    }

    closeAnimation: SequentialAnimation {
        ScriptAction { script: root.previousSourceType = ""; }
        NumberAnimation { target: panel; property: "opacity"; to: 0; duration: 300; easing.type: Easing.InQuad }
    }
}
