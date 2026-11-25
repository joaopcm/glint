import Observation
import ServiceManagement

@MainActor protocol LoginItem {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

struct MainAppLoginItem: LoginItem {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable final class OpenAtLogin {
    static let approvalNote = "macOS needs you to allow Glint in Login Items before it opens at login."

    private let item: any LoginItem
    private(set) var status: SMAppService.Status
    private(set) var failure: String?

    init(item: any LoginItem = MainAppLoginItem()) {
        self.item = item
        status = item.status
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        failure = nil
        do {
            if on {
                try item.register()
            } else {
                try item.unregister()
            }
        } catch {
            failure = on
                ? "macOS didn't add Glint to your login items: \(error.localizedDescription)"
                : "macOS didn't remove Glint from your login items: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        status = item.status
    }

    func openLoginItems() {
        item.openSystemSettingsLoginItems()
    }
}
