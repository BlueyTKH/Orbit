import Foundation
import Security

@objc protocol NotchFlowLowPowerService {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

private final class LowPowerService: NSObject, NotchFlowLowPowerService {
    func setLowPowerMode(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "lowpowermode", enabled ? "1" : "0"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                reply(false, detail?.isEmpty == false ? detail : "macOS could not change Low Power Mode.")
                return
            }
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = LowPowerService()
    private let expectedIdentifier = "com.kayhsen.NotchFlow"
    private let expectedTeamIdentifier: String?

    override init() {
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &selfCode) == errSecSuccess,
           let selfCode,
           SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess,
           let selfStaticCode,
           SecCodeCopySigningInformation(selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let values = information as? [CFString: Any] {
            expectedTeamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String
        } else {
            expectedTeamIdentifier = nil
        }
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let expectedTeamIdentifier,
              isTrustedNotchFlowClient(pid: connection.processIdentifier, teamIdentifier: expectedTeamIdentifier) else {
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: NotchFlowLowPowerService.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    private func isTrustedNotchFlowClient(pid: pid_t, teamIdentifier: String) -> Bool {
        let attributes: [CFString: Any] = [kSecGuestAttributePid: NSNumber(value: pid)]
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guestCode) == errSecSuccess,
              let guestCode,
              SecCodeCheckValidity(guestCode, [], nil) == errSecSuccess else { return false }

        var information: CFDictionary?
        var guestStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &guestStaticCode) == errSecSuccess,
              let guestStaticCode,
              SecCodeCopySigningInformation(guestStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any] else { return false }

        return values[kSecCodeInfoIdentifier] as? String == expectedIdentifier
            && values[kSecCodeInfoTeamIdentifier] as? String == teamIdentifier
    }
}

@main
private struct NotchFlowLowPowerHelperMain {
    static func main() {
        let listener = NSXPCListener(machServiceName: "com.kayhsen.NotchFlow.lowpower")
        let delegate = ListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
