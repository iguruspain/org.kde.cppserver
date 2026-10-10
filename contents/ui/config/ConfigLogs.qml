// ConfigLogs.qml – log view settings for the cpp servers widget.
// Values live in the per-instance KConfig (contents/config/main.xml, next to
// uiJson); the widget reads them live, so there is nothing to "Apply".

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
            text: i18n("Options for the log view in the widget. Changes apply immediately.")
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Font")
        }
        RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Layout.preferredWidth: Kirigami.Units.gridUnit * 32

            QQC2.SpinBox {
                from: 0
                to: 24
                value: Plasmoid.configuration.logFontSize
                onValueChanged: Plasmoid.configuration.logFontSize = value
            }
            QQC2.Label {
                text: i18n("Log font size (0 = theme default)")
            }
        }

        Kirigami.Separator {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Statistics")
        }

        QQC2.CheckBox {
            text: i18n("Show error count")
            checked: Plasmoid.configuration.logShowErrors
            onToggled: Plasmoid.configuration.logShowErrors = checked
        }
        QQC2.CheckBox {
            text: i18n("Show warning count")
            checked: Plasmoid.configuration.logShowWarnings
            onToggled: Plasmoid.configuration.logShowWarnings = checked
        }
        QQC2.CheckBox {
            text: i18n("Show out-of-memory count")
            checked: Plasmoid.configuration.logShowOom
            onToggled: Plasmoid.configuration.logShowOom = checked
        }
        QQC2.CheckBox {
            text: i18n("Show max generation speed (t/s, llama.cpp only)")
            checked: Plasmoid.configuration.logShowTps
            onToggled: Plasmoid.configuration.logShowTps = checked
        }

        QQC2.Label {
            Layout.fillWidth: true
            opacity: 0.6
            wrapMode: Text.Wrap
            text: i18n("Counts are computed from the log text and work with any server. The speed (t/s) is only printed by llama.cpp.")
        }
    }
}