import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Servers")
        icon: "network-server-symbolic"
        source: "config/ConfigServers.qml"
    }
    ConfigCategory {
        name: i18n("Logs")
        icon: "view-history"
        source: "config/ConfigLogs.qml"
    }
    ConfigCategory {
        name: i18n("Stats")
        icon: "speedometer-symbolic"
        source: "config/ConfigStats.qml"
    }
}
