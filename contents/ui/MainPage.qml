// MainPage.qml – Servers / Logs tabs of the widget popup.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras

import "logic.js" as Logic

ColumnLayout {
    id: page
    spacing: 0

    // The PlasmoidItem from main.qml (passed explicitly, no implicit `root`).
    required property var backend

    PlasmaComponents.TabBar {
        id: tabBar
        Layout.fillWidth: true
        currentIndex: page.backend.activeTab
        onCurrentIndexChanged: {
            page.backend.activeTab = currentIndex
            page.backend.persistUiState()
            if (currentIndex === 1) page.backend.tailLog()
        }
        PlasmaComponents.TabButton { icon.name: "system-run";    text: i18n("Servers") }
        PlasmaComponents.TabButton { icon.name: "view-history";  text: i18n("Logs") }
    }

    StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: tabBar.currentIndex

        // ═════════════════════ TAB 0 – Servers ═════════════════════
        ColumnLayout {
            id: serversTab
            spacing: 0
            property string filterText: ""

            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaExtras.SearchField {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    visible: page.backend.servers.length > 4
                    placeholderText: i18n("Search server...")
                    onTextChanged: serversTab.filterText = text.toLowerCase()
                }
                Item { Layout.fillWidth: true; visible: page.backend.servers.length <= 4 }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: page.backend.refreshAll()
                    PlasmaComponents.ToolTip { text: i18n("Reload configuration and status") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: page.backend.openConfig()
                    PlasmaComponents.ToolTip { text: i18n("Configure servers…") }
                }
            }

            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: serverList
                    clip: true
                    model: page.backend.servers.filter(function (s) {
                        return serversTab.filterText === ""
                            || s.name.toLowerCase().indexOf(serversTab.filterText) !== -1
                    })

                    delegate: PlasmaComponents.ItemDelegate {
                        id: del
                        required property var modelData
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 3.6
                        hoverEnabled: true
                        onClicked: if (running) page.backend.showLogs(sid)

                        readonly property string sid: modelData.id
                        readonly property bool running: !!page.backend.runningMap[sid]
                        readonly property bool starting: !!page.backend.pendingStarts[sid]
                        readonly property bool stopping: !!page.backend.pendingStops[sid]
                        readonly property bool busy: starting || stopping
                        readonly property string binary: Logic.serverBinary(modelData.command, page.backend.homeDir)
                        readonly property bool binaryOk: page.backend.depsMap[binary] !== false
                        readonly property string url: Logic.browserUrl(modelData)

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing

                            // status dot
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: Kirigami.Units.gridUnit * 0.7
                                implicitHeight: implicitWidth
                                radius: width / 2
                                color: del.busy ? Kirigami.Theme.neutralTextColor
                                     : del.running ? Kirigami.Theme.positiveTextColor
                                     : !del.binaryOk ? Kirigami.Theme.negativeTextColor
                                     : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.3)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: del.modelData.name || i18n("(unnamed)")
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                    color: !del.binaryOk ? Kirigami.Theme.negativeTextColor
                                                         : Kirigami.Theme.textColor
                                    text: {
                                        if (!del.binaryOk) return i18n("Not found in PATH: %1", del.binary)
                                        var parts = []
                                        var ep = Logic.endpointText(del.modelData)
                                        if (ep) parts.push(ep)
                                        if (del.binary) parts.push(del.binary.split("/").pop())
                                        //if (del.running) parts.push(i18n("pid %1", page.backend.runningMap[del.sid].pid))
                                        return parts.join("  •  ")
                                    }
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = []
                                        if (del.running) parts.push(i18n("pid %1", page.backend.runningMap[del.sid].pid))
                                        return parts.join("  •  ")
                                    }
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                    elide: Text.ElideRight
                                }
                            }

                            PlasmaComponents.ToolButton {
                                visible: del.running && del.url !== ""
                                icon.name: "internet-web-browser-symbolic"
                                display: QQC2.AbstractButton.IconOnly
                                onClicked: Qt.openUrlExternally(del.url)
                                PlasmaComponents.ToolTip { text: i18n("Open %1", del.url) }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "view-history"
                                display: QQC2.AbstractButton.IconOnly
                                onClicked: page.backend.showLogs(del.sid)
                                PlasmaComponents.ToolTip { text: i18n("Show logs") }
                            }
                            PlasmaComponents.Button {
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 6
                                icon.name: del.running ? "media-playback-stop" : "media-playback-start"
                                text: del.stopping ? i18n("Stopping…")
                                    : del.starting ? i18n("Starting…")
                                    : del.running ? i18n("Stop") : i18n("Start")
                                highlighted: del.running
                                enabled: !del.busy && (del.running || del.binaryOk)
                                onClicked: del.running ? page.backend.stopServer(del.sid)
                                                       : page.backend.startServer(del.sid)
                            }
                        }
                    }

                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.gridUnit * 2
                        visible: serverList.count === 0 && !page.backend.loading
                        icon.name: serversTab.filterText !== "" ? "edit-find" : "network-server"
                        text: serversTab.filterText !== "" ? i18n("No servers match")
                                                           : i18n("No servers configured")
                        explanation: serversTab.filterText !== ""
                                     ? "" : i18n("Add llama.cpp / audio.cpp / … servers in the widget settings.")
                        helpfulAction: QQC2.Action {
                            enabled: serversTab.filterText === ""
                            icon.name: "configure"
                            text: i18n("Configure…")
                            onTriggered: page.backend.openConfig()
                        }
                    }
                }
            }

            PlasmaExtras.PlasmoidHeading {
                Layout.fillWidth: true
                position: PlasmaExtras.PlasmoidHeading.Footer
                contentItem: RowLayout {
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        text: i18n("%1 / %2 running", page.backend.runningCount, page.backend.servers.length)
                    }
                    PlasmaComponents.BusyIndicator {
                        visible: page.backend.loading
                        running: visible
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: implicitWidth
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.missingBinaries > 0
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.negativeTextColor
                        text: i18np("%1 binary not in PATH", "%1 binaries not in PATH", page.backend.missingBinaries)
                    }
                }
            }
        }

        // ═════════════════════ TAB 1 – Logs ═════════════════════
        ColumnLayout {
            id: logsTab
            spacing: 0

            readonly property var entry: page.backend.serverById(page.backend.activeLogId)
            readonly property var running: entry ? page.backend.runningMap[entry.id] : undefined
            readonly property string rawText: page.backend.logTexts[page.backend.activeLogId] || ""
            readonly property var filtered: Logic.filterLines(rawText, filterField.text, regexBtn.checked)
            readonly property string logText: filtered.text
            readonly property bool filtering: filterField.text !== ""
            readonly property var stats: Logic.logStats(rawText)

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.backend.servers.length > 0

                PlasmaComponents.ComboBox {
                    Layout.fillWidth: true
                    model: page.backend.servers.map(function (s) { return s.name || s.id })
                    currentIndex: {
                        for (var i = 0; i < page.backend.servers.length; i++)
                            if (page.backend.servers[i].id === page.backend.activeLogId) return i
                        return -1
                    }
                    onActivated: function (i) {
                        page.backend.activeLogId = page.backend.servers[i].id
                        page.backend.persistUiState()
                        page.backend.tailLog()
                    }
                }
                PlasmaComponents.ToolButton {
                    id: pauseBtn
                    checkable: true
                    checked: page.backend.logsPaused
                    onToggled: page.backend.logsPaused = checked
                    icon.name: "media-playback-pause"
                    display: QQC2.AbstractButton.IconOnly
                    PlasmaComponents.ToolTip { text: i18n("Pause live updates (to select text)") }
                }
                PlasmaComponents.ToolButton {
                    id: followBtn
                    checkable: true
                    checked: true
                    icon.name: "go-bottom"
                    display: QQC2.AbstractButton.IconOnly
                    PlasmaComponents.ToolTip { text: i18n("Follow the end of the log") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-copy"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: logsTab.logText !== ""
                    onClicked: { logArea.selectAll(); logArea.copy(); logArea.deselect() }
                    PlasmaComponents.ToolTip { text: i18n("Copy log") }
                }
            }


            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.backend.servers.length > 0

                PlasmaExtras.SearchField {
                    id: filterField
                    Layout.fillWidth: true
                    placeholderText: i18n("Filter log lines…")
                }
                PlasmaComponents.ToolButton {
                    id: regexBtn
                    checkable: true
                    text: ".*"
                    PlasmaComponents.ToolTip { text: i18n("Interpret the filter as a regular expression") }
                }
            }
            PlasmaComponents.Label {
                id: logFileLabel
                Layout.fillWidth: true
                font: Kirigami.Theme.smallFont
                elide: Text.ElideLeft
                enabled: logsTab.running && logsTab.running.logfile !== ""
                opacity: 0.7
                text:logsTab.running.logfile ? i18n("Log file: %1", logsTab.running.logfile) : ""
                MouseArea {
                    anchors.fill: parent
                    enabled: logFileLabel.text !== ""
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Qt.openUrlExternally("file://" + logsTab.running.logfile)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                visible: page.backend.servers.length > 0
                color: Kirigami.Theme.highlightColor
                opacity: 0.5
            }

            QQC2.ScrollView {
                id: logScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: page.backend.servers.length > 0

                QQC2.TextArea {
                    id: logArea
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    font.family: "monospace"
                    font.pointSize: page.backend.logFontSize > 0 ? page.backend.logFontSize
                        : Kirigami.Theme.smallFont.pointSize
                    background: null
                    text: logsTab.logText !== "" ? logsTab.logText
                        : (logsTab.filtering && logsTab.rawText !== "") ? i18n("(no lines match the filter)")
                        : logsTab.running ? i18n("(waiting for output…)")
                        : i18n("Server not running – start it from the Servers tab.")
                    onTextChanged: if (followBtn.checked) Qt.callLater(function () {
                        var f = logScroll.contentItem
                        f.contentY = Math.max(0, f.contentHeight - f.height)
                    })
                }
            }

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: page.backend.servers.length === 0
                icon.name: "view-history"
                text: i18n("No servers configured")
                explanation: i18n("Add servers in the widget settings.")
            }

            PlasmaExtras.PlasmoidHeading {
                Layout.fillWidth: true
                position: PlasmaExtras.PlasmoidHeading.Footer
                contentItem: RowLayout {
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideLeft
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        text: !logsTab.entry ? i18n("No server selected")
                            //: logsTab.running ? i18n("pid %1 — %2", logsTab.running.pid, logsTab.running.logfile)
                            : logsTab.running ? i18n("pid %1", logsTab.running.pid)
                            : i18n("Stopped")
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.showStatErrors && logsTab.stats.errors > 0
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.negativeTextColor
                        text: i18np("%1 error", "%1 errors", logsTab.stats.errors)
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.showStatWarnings && logsTab.stats.warnings > 0
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.neutralTextColor
                        opacity: 0.7
                        text: i18np("%1 warning", "%1 warnings", logsTab.stats.warnings)
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.showStatOom && logsTab.stats.oom > 0
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.negativeTextColor
                        text: i18n("%1 OOM", logsTab.stats.oom)
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.showStatTps && logsTab.stats.maxTps > 0
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        text: i18n("max %1 t/s", logsTab.stats.maxTps.toFixed(2))
                    }
                    PlasmaComponents.Label {
                        visible: logsTab.filtering && logsTab.filtered.ok
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        text: i18n("%1 / %2 lines", logsTab.filtered.matched, logsTab.filtered.total)
                    }
                    PlasmaComponents.Label {
                        visible: logsTab.filtering && !logsTab.filtered.ok
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.negativeTextColor
                        text: i18n("invalid regex")
                    }
                }
            }
        }
    }
}
