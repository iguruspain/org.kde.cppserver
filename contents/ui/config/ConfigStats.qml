// ConfigStats.qml – live monitor settings for the cpp servers widget.
// Values live in the per-instance KConfig (contents/config/main.xml); the
// Stats tab reads them live, so there is nothing to "Apply".

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

pragma ComponentBehavior: Bound

// The kcfg schema (contents/config/main.xml) is invisible to the linter
// without --project, so every Plasmoid.configuration.<key> looks like a missing member.
// qmllint disable missing-property
// i18n() is a global injected by the KCM runtime and invisible to qmllint.
// qmllint disable unqualified

KCM.SimpleKCM {
    id: page

    // indented children of a section's master switch
    readonly property int childIndent: Kirigami.Units.gridUnit * 2

    Kirigami.FormLayout {
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.8
            wrapMode: Text.Wrap
            text: i18n("What the Stats tab shows for every running server. Changes apply immediately.")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Sampling")
        }
        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Layout.preferredWidth: Kirigami.Units.gridUnit * 32

            QQC2.SpinBox {
                from: 250
                to: 10000
                stepSize: 250
                value: Plasmoid.configuration.statSampleMs
                onValueChanged: Plasmoid.configuration.statSampleMs = value
            }
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                verticalAlignment: Text.AlignVCenter
                text: i18n("Sampling frequency in milliseconds: how often each running server is probed and the machine sampled (default 1000 ms)")
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Machine block")
        }
        QQC2.CheckBox {
            text: i18n("Show the machine block (CPU, GPU, VRAM, RAM)")
            checked: Plasmoid.configuration.statShowHardware
            onToggled: Plasmoid.configuration.statShowHardware = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show the VRAM legend (which server holds each slice)")
            enabled: Plasmoid.configuration.statShowHardware
            checked: Plasmoid.configuration.statShowVramLegend
            onToggled: Plasmoid.configuration.statShowVramLegend = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show the sparkline graphs")
            enabled: Plasmoid.configuration.statShowHardware
            checked: Plasmoid.configuration.statShowSparklines
            onToggled: Plasmoid.configuration.statShowSparklines = checked
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Extra info block")
        }
        QQC2.CheckBox {
            text: i18n("Show the extra info block")
            checked: Plasmoid.configuration.statShowExtra
            onToggled: Plasmoid.configuration.statShowExtra = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show token generation speed (t/s)")
            enabled: Plasmoid.configuration.statShowExtra
            checked: Plasmoid.configuration.statShowTps
            onToggled: Plasmoid.configuration.statShowTps = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show GPU temperature")
            enabled: Plasmoid.configuration.statShowExtra
            checked: Plasmoid.configuration.statShowGpuTemp
            onToggled: Plasmoid.configuration.statShowGpuTemp = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show GPU power")
            enabled: Plasmoid.configuration.statShowExtra
            checked: Plasmoid.configuration.statShowGpuPower
            onToggled: Plasmoid.configuration.statShowGpuPower = checked
        }
        QQC2.CheckBox {
            Layout.leftMargin: page.childIndent
            text: i18n("Show disk activity")
            enabled: Plasmoid.configuration.statShowExtra
            checked: Plasmoid.configuration.statShowDisk
            onToggled: Plasmoid.configuration.statShowDisk = checked
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.6
            wrapMode: Text.Wrap
            // the generation-speed switch also drives the per-card figure
            text: i18n("The generation speed also appears inside each server's card even when this block is hidden.")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Cards")
        }
        QQC2.CheckBox {
            text: i18n("Show totals (requests, tokens, reused, context)")
            checked: Plasmoid.configuration.statShowTokens
            onToggled: Plasmoid.configuration.statShowTokens = checked
        }
        QQC2.CheckBox {
            text: i18n("Show the detailed request table")
            checked: Plasmoid.configuration.statShowEvents
            onToggled: Plasmoid.configuration.statShowEvents = checked
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Notes")
        }
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.6
            wrapMode: Text.Wrap
            text: i18n("strata reports everything over its HTTP API (/metrics). llama.cpp gives the same figures - speed, context, live requests - from its log, so no extra flag is needed; --metrics only adds server-side counters. Machine figures (GPU, CPU, RAM, disk) are probed by the widget itself (nvidia-smi and /proc), not by any server.")
        }
    }
}
