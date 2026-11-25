import Foundation
import ServiceManagement
import Testing
@testable import Lunetta

@MainActor final class FakeLoginItem: LoginItem {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var error: Error?
    var calls: [String] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let error { throw error }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() {
        calls.append("openSystemSettingsLoginItems")
    }
}

@MainActor struct OpenAtLoginTests {
    @Test(arguments: [
        (SMAppService.Status.notRegistered, false, false),
        (.notFound, false, false),
        (.enabled, true, false),
        (.requiresApproval, true, true),
    ])
    func toggleShowsTheRealStatus(status: SMAppService.Status, isOn: Bool, needsApproval: Bool) {
        let openAtLogin = OpenAtLogin(item: FakeLoginItem(status: status))
        #expect(openAtLogin.isOn == isOn)
        #expect(openAtLogin.needsApproval == needsApproval)
        #expect(openAtLogin.failure == nil)
    }

    @Test func turningOnRegistersAndTurningOffUnregisters() {
        let item = FakeLoginItem(status: .notRegistered)
        let openAtLogin = OpenAtLogin(item: item)

        openAtLogin.set(true)
        #expect(openAtLogin.isOn)
        openAtLogin.set(false)

        #expect(!openAtLogin.isOn)
        #expect(item.calls == ["register", "unregister"])
    }

    @Test func registeringThatNeedsApprovalSaysSoAndOpensLoginItems() {
        let item = FakeLoginItem(status: .notRegistered)
        item.statusAfterRegister = .requiresApproval
        let openAtLogin = OpenAtLogin(item: item)

        openAtLogin.set(true)
        openAtLogin.openLoginItems()

        #expect(openAtLogin.needsApproval)
        #expect(item.calls == ["register", "openSystemSettingsLoginItems"])
    }

    @Test func aRegisterErrorShowsTheReasonFromMacOSAndKeepsTheToggleOff() {
        let item = FakeLoginItem(status: .notRegistered)
        item.error = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let openAtLogin = OpenAtLogin(item: item)

        openAtLogin.set(true)

        #expect(!openAtLogin.isOn)
        #expect(openAtLogin.failure == "macOS didn't add Lunetta to your login items: Operation not permitted")
    }

    @Test func refreshPicksUpAChangeMadeInSystemSettings() {
        let item = FakeLoginItem(status: .enabled)
        let openAtLogin = OpenAtLogin(item: item)
        item.status = .notRegistered

        openAtLogin.refresh()

        #expect(!openAtLogin.isOn)
    }
}
