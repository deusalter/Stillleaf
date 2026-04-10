import ServiceManagement

public enum LoginService {
    public static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    public static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
