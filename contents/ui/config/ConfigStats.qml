// ConfigStats.qml – live monitor settings for the cpp servers widget.
// Values live in the per-instance KConfig (contents/config/main.xml); the
// Stats tab reads them live, so there is nothing to "Apply".

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

KCM.SimpleKCM {
    id: page

    Kirigami.FormLayout {
        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.8
            wrapMode: Text.Wrap
            text: i18n("What the Stats tab shows for every running server. Changes apply immediately.")
        }

        QQC2.CheckBox {
            text: i18n("Show recent requests (events)")
            checked: Plasmoid.configuration.statShowEvents
            onToggled: Plasmoid.configuration.statShowEvents = checked
        }
        QQC2.CheckBox {
            text: i18n("Show generation speed (t/s)")
            checked: Plasmoid.configuration.statShowTps
            onToggled: Plasmoid.configuration.statShowTps = checked
        }
        QQC2.CheckBox {
            text: i18n("Show token totals (requests, in, out, reused)")
            checked: Plasmoid.configuration.statShowTokens
            onToggled: Plasmoid.configuration.statShowTokens = checked
        }
        QQC2.CheckBox {
            text: i18n("Show VRAM bars")
            checked: Plasmoid.configuration.statShowVram
            onToggled: Plasmoid.configuration.statShowVram = checked
        }
        QQC2.CheckBox {
            text: i18n("Show machine hardware summary (GPU, CPU, RAM)")
            checked: Plasmoid.configuration.statShowHardware
            onToggled: Plasmoid.configuration.statShowHardware = checked
        }

        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.6
            wrapMode: Text.Wrap
            text: i18n("strata reports everything over its HTTP API (/metrics). llama.cpp gives token and context numbers from its log; add --metrics to its command for live t/s and request counters. GPU/CPU/RAM numbers describe the whole machine and come from strata.")
        }
    }
}
