// ConfigServers.qml – settings page for the cpp servers widget.
//
// Edits are saved automatically (debounced) to
//   ~/.config/cppserver/servers.json
// so there is nothing to "Apply": the widget notices the new file mtime on its
// next status poll. The file is shared by every instance of the widget.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtQuick.Dialogs
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

import "../logic.js" as Logic

KCM.SimpleKCM {
    id: page

    property string homeDir: ""
    property string configPath: "~/.config/cppserver/servers.json"
    property bool loaded: false
    property string status: ""            // "", "saving", "saved", "error"
    property string statusDetail: ""
    property string expandedId: ""
    property string focusId: ""

    // ── Shell access (read / write servers.json) ──────────────────────────
    property var jobs: []                 // [{cmd, done}]
    property bool jobBusy: false

    P5Support.DataSource {
        id: exe
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source)
            var job = page.jobs.length > 0 ? page.jobs[0] : null
            if (!job || job.cmd !== source) return
            page.jobs = page.jobs.slice(1)
            page.jobBusy = false
            job.done(Number(data["exit code"]), String(data["stdout"] || "").trim(),
                     String(data["stderr"] || "").trim())
            page.nextJob()
        }
    }
    function nextJob() {
        if (jobBusy || jobs.length === 0) return
        jobBusy = true
        exe.connectSource(jobs[0].cmd)
    }
    function ctl(args, done) {
        jobs = jobs.concat([{ cmd: Logic.scriptCmd() + " " + args, done: done }])
        nextJob()
    }

    // ── Model <-> servers.json ────────────────────────────────────────────
    ListModel { id: serversModel }

    function toArray() {
        var out = []
        for (var i = 0; i < serversModel.count; i++) {
            var m = serversModel.get(i)
            out.push({ id: m.sid, name: m.name, command: m.command, host: m.host,
                       port: m.port, configFile: m.configFile, enabled: m.enabled })
        }
        return out
    }

    function uniqueId(base) {
        var b = Logic.slugify(base) || "server"
        var id = b, n = 2
        function taken(x) { for (var i = 0; i < serversModel.count; i++) if (serversModel.get(i).sid === x) return true; return false }
        while (taken(id)) id = b + "-" + (n++)
        return id
    }

    function load() {
        ctl("init", function (code, out) {
            var kv = Logic.parseKv(out)
            page.homeDir = kv.home || ""
            if (kv.config) page.configPath = kv.config
            page.ctl("cfgread", function (code2, out2, err2) {
                if (code2 !== 0) {
                    page.status = "error"
                    page.statusDetail = err2 || i18n("Could not read the configuration")
                    return   // stay unloaded: never overwrite a file we could not read
                }
                var parsed = Logic.safeJsonParse(out2, null)
                if (!Array.isArray(parsed)) {
                    page.status = "error"
                    page.statusDetail = i18n("%1 is not valid JSON; fix or remove it.", page.configPath)
                    return
                }
                Logic.normalizeServers(parsed).forEach(function (s) {
                    serversModel.append({ sid: s.id, name: s.name, command: s.command, host: s.host,
                                   port: s.port, configFile: s.configFile, enabled: s.enabled })
                })
                page.loaded = true
            })
        })
    }

    Timer {
        id: saveTimer
        interval: 450
        onTriggered: page.flush()
    }
    function scheduleSave() {
        if (!loaded) return
        status = "saving"
        saveTimer.restart()
    }
    function flush() {
        if (!loaded) return
        var json = Logic.safeJsonStringify(toArray(), "[]")
        ctl("cfgwrite " + Logic.shQuote(json), function (code, out, err) {
            var kv = Logic.parseKv(out)
            if (code === 0 && kv.ok === "1") {
                if (!saveTimer.running) { page.status = "saved"; page.statusDetail = "" }
            } else {
                page.status = "error"
                page.statusDetail = kv.error || err || i18n("unknown error")
            }
        })
    }
    // Flush pending edits if the dialog is closed within the debounce window.
    Component.onDestruction: if (saveTimer.running) { saveTimer.stop(); flush() }
    Component.onCompleted: load()

    function setField(i, key, value) {
        serversModel.setProperty(i, key, value)
        scheduleSave()
    }

    function addServer(name, command, port, configFile) {
        var id = uniqueId(name || "server")
        serversModel.append({ sid: id, name: name, command: command, host: "127.0.0.1", port: port,
                       configFile: configFile, enabled: true })
        expandedId = id
        focusId = id
        scheduleSave()
    }

    function move(i, delta) {
        var j = i + delta
        if (j < 0 || j >= serversModel.count) return
        serversModel.move(i, j, 1)
        scheduleSave()
    }

    function previewCommand(i) {
        var m = serversModel.get(i)
        return Logic.buildCommand(m, homeDir)
    }

    readonly property var templates: [
        { label: "llama.cpp",           name: "llama.cpp",           port: 8080,
          command: "llama-server --models-preset {CONFIG_FILE} --host {HOST} --port {PORT}" },
        { label: "audio.cpp",           name: "audio.cpp",           port: 8081,
          command: "audiocpp_server --host {HOST} --port {PORT}" },
        { label: "stable-diffusion.cpp", name: "stable-diffusion.cpp", port: 8082,
          command: "sd-server --listen-ip {HOST} --listen-port {PORT}" },
        { label: i18n("Custom command"), name: "", port: 0, command: "" }
    ]

    // A caption above its control(s); children go below the caption.
    component Labeled: ColumnLayout {
        property string label
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: Kirigami.Units.smallSpacing
        QQC2.Label {
            text: parent.label
            opacity: 0.8
        }
    }

    // ── Dialogs ───────────────────────────────────────────────────────────
    property int browseIndex: -1
    FileDialog {
        id: fileDialog
        title: i18n("Select config file")
        onAccepted: {
            var p = decodeURIComponent(selectedFile.toString().replace(/^file:\/\//, ""))
            if (page.homeDir && p.indexOf(page.homeDir + "/") === 0) p = "~" + p.slice(page.homeDir.length)
            if (page.browseIndex >= 0) page.setField(page.browseIndex, "configFile", p)
        }
    }

    property int deleteIndex: -1
    Kirigami.PromptDialog {
        id: deleteDialog
        title: i18n("Remove server")
        subtitle: page.deleteIndex >= 0 && page.deleteIndex < serversModel.count
                  ? i18n("Remove “%1” from the list? A running process is not stopped.",
                         serversModel.get(page.deleteIndex).name || i18n("(unnamed)"))
                  : ""
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                text: i18n("Remove")
                icon.name: "edit-delete"
                onTriggered: {
                    if (page.deleteIndex >= 0) { serversModel.remove(page.deleteIndex); page.scheduleSave() }
                    page.deleteIndex = -1
                    deleteDialog.close()
                }
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: { page.deleteIndex = -1; deleteDialog.close() }
            }
        ]
    }

    // ── UI ────────────────────────────────────────────────────────────────
    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.status === "error"
            type: Kirigami.MessageType.Error
            text: page.statusDetail
        }

        // Header: help + Add
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            QQC2.Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                wrapMode: Text.Wrap
                textFormat: Text.StyledText
                opacity: 0.8
                text: i18n("Placeholders in the command:<br>" +
                           "<b>{HOST}</b> host, <b>{PORT}</b> port, <b>{CONFIG_FILE}</b> config file.<br>" +
                           "<tt>~</tt> and <tt>$HOME</tt> are expanded. An empty value also removes its flag " +
                           "(<tt>--port {PORT}</tt> with port 0 disappears).")
            }

            QQC2.Button {
                Layout.alignment: Qt.AlignTop
                icon.name: "list-add"
                text: i18n("Add")
                enabled: page.loaded
                onClicked: addMenu.popup()

                QQC2.Menu {
                    id: addMenu
                    Repeater {
                        model: page.templates
                        QQC2.MenuItem {
                            required property var modelData
                            text: modelData.label
                            onTriggered: page.addServer(modelData.name, modelData.command,
                                                        modelData.port, "")
                        }
                    }
                }
            }
        }

        Kirigami.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.gridUnit * 2
            visible: page.loaded && serversModel.count === 0
            icon.name: "network-server-symbolic"
            text: i18n("No servers yet")
            explanation: i18n("Use “Add” to create one from a template.")
        }

        // Server cards
        Repeater {
            model: serversModel

            delegate: Rectangle {
                id: card

                required property int index
                required property string sid
                required property string name
                required property string command
                required property string host
                required property int port
                required property string configFile
                required property bool enabled

                readonly property bool expanded: page.expandedId === sid

                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                implicitHeight: cardLayout.implicitHeight + Kirigami.Units.largeSpacing * 2
                radius: Kirigami.Units.cornerRadius
                color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                               Kirigami.Theme.textColor.b, 0.05)
                border.width: 1
                border.color: expanded ? Kirigami.Theme.highlightColor
                                       : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                 Kirigami.Theme.textColor.b, 0.15)

                ColumnLayout {
                    id: cardLayout
                    anchors { fill: parent; margins: Kirigami.Units.largeSpacing }
                    spacing: Kirigami.Units.largeSpacing

                    // ── header row ──
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        QQC2.Label {
                            text: card.index + 1
                            font.bold: true
                            color: card.enabled ? Kirigami.Theme.highlightColor : Kirigami.Theme.disabledTextColor
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 1.5
                            horizontalAlignment: Text.AlignHCenter
                        }

                        QQC2.Switch {
                            checked: card.enabled
                            onToggled: page.setField(card.index, "enabled", checked)
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.text: i18n("Show in the widget")
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            opacity: card.enabled ? 1 : 0.55

                            QQC2.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font.bold: true
                                color: card.name === "" ? Kirigami.Theme.negativeTextColor
                                                        : Kirigami.Theme.textColor
                                text: card.name || i18n("(unnamed)")
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                color: card.command.trim() === "" ? Kirigami.Theme.negativeTextColor
                                                                  : Kirigami.Theme.textColor
                                text: card.command.trim() === "" ? i18n("No command set")
                                      : [Logic.endpointText({ host: card.host, port: card.port }),
                                         Logic.serverBinary(card.command, page.homeDir).split("/").pop()]
                                          .filter(function (x) { return x !== "" }).join("  •  ")
                            }
                        }

                        QQC2.ToolButton {
                            icon.name: "go-up"
                            enabled: card.index > 0
                            display: QQC2.AbstractButton.IconOnly
                            onClicked: page.move(card.index, -1)
                            QQC2.ToolTip.visible: hovered; QQC2.ToolTip.text: i18n("Move up")
                        }
                        QQC2.ToolButton {
                            icon.name: "go-down"
                            enabled: card.index < serversModel.count - 1
                            display: QQC2.AbstractButton.IconOnly
                            onClicked: page.move(card.index, 1)
                            QQC2.ToolTip.visible: hovered; QQC2.ToolTip.text: i18n("Move down")
                        }
                        QQC2.ToolButton {
                            icon.name: card.expanded ? "arrow-up" : "document-edit"
                            display: QQC2.AbstractButton.IconOnly
                            onClicked: page.expandedId = card.expanded ? "" : card.sid
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.text: card.expanded ? i18n("Collapse") : i18n("Edit")
                        }
                        QQC2.ToolButton {
                            icon.name: "edit-delete"
                            display: QQC2.AbstractButton.IconOnly
                            onClicked: { page.deleteIndex = card.index; deleteDialog.open() }
                            QQC2.ToolTip.visible: hovered; QQC2.ToolTip.text: i18n("Remove")
                        }
                    }

                    // ── editor ──
                    // Plain layouts instead of Kirigami.FormLayout: FormLayout sizes
                    // itself from its content (long command, preview…) and reserves a
                    // label column, which overflowed the card. Here every field simply
                    // fills the card width, with its label on top.
                    ColumnLayout {
                        id: form
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: Kirigami.Units.largeSpacing
                        visible: card.expanded

                        Labeled {
                            label: i18n("Name:")
                            QQC2.TextField {
                                id: nameField
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                placeholderText: i18n("e.g. llama-chat")
                                text: card.name
                                onTextEdited: page.setField(card.index, "name", text)
                                Component.onCompleted: if (page.focusId === card.sid) {
                                    page.focusId = ""
                                    forceActiveFocus()
                                }
                            }
                        }

                        Labeled {
                            label: i18n("Command:")
                            QQC2.TextField {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                font.family: "monospace"
                                placeholderText: "llama-server --host {HOST} --port {PORT}"
                                text: card.command
                                onTextEdited: page.setField(card.index, "command", text)
                            }
                        }

                        Labeled {
                            label: i18n("Host / Port:")
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.TextField {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    placeholderText: "127.0.0.1"
                                    text: card.host
                                    onTextEdited: page.setField(card.index, "host", text.trim())
                                }
                                QQC2.SpinBox {
                                    from: 0; to: 65535; editable: true
                                    value: card.port
                                    onValueModified: page.setField(card.index, "port", value)
                                    QQC2.ToolTip.visible: hovered
                                    QQC2.ToolTip.text: i18n("0 = not used")
                                }
                            }
                        }

                        Labeled {
                            label: i18n("Config file:")
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                spacing: Kirigami.Units.smallSpacing
                                QQC2.TextField {
                                    Layout.fillWidth: true
                                    Layout.minimumWidth: 0
                                    placeholderText: "~/Documents/Configs/llama-server.ini"
                                    text: card.configFile
                                    onTextEdited: page.setField(card.index, "configFile", text.trim())
                                }
                                QQC2.Button {
                                    icon.name: "document-open"
                                    text: i18n("Browse…")
                                    onClicked: { page.browseIndex = card.index; fileDialog.open() }
                                }
                            }
                        }

                        Labeled {
                            label: i18n("Will run:")
                            QQC2.Label {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                // an explicit preferred width stops the long, unbroken
                                // command from widening the whole card
                                Layout.preferredWidth: 1
                                wrapMode: Text.WrapAnywhere
                                font.family: "monospace"
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                                opacity: 0.75
                                // touch the fields so the preview re-evaluates on edit
                                text: (card.command, card.host, card.port, card.configFile,
                                       page.previewCommand(card.index)) || i18n("(empty)")
                            }
                        }
                    }
                }
            }
        }

        // Footer: where the data lives + save state
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                implicitWidth: Kirigami.Units.iconSizes.small
                implicitHeight: implicitWidth
                source: page.status === "error" ? "dialog-error"
                      : page.status === "saving" ? "document-save"
                      : "emblem-ok-symbolic"
                visible: page.status !== ""
            }
            QQC2.Label {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.preferredWidth: 1
                elide: Text.ElideMiddle
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: page.status === "saving" ? i18n("Saving…")
                    : page.status === "error"  ? i18n("Not saved")
                    : i18n("Changes are saved automatically to %1", page.configPath)
            }
        }
    }
}
