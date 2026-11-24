import AppKit
import UserNotifications

/// Notifiche di macOS: compaiono in alto a destra e restano nel Centro Notifiche.
/// Le usa Ormeggio per dire a ogni persona che ha installato una versione nuova.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Chiamata quando la persona clicca la notifica di un aggiornamento.
    var onOpenUpdate: (@MainActor () -> Void)?

    /// Stato del permesso, come lo vede macOS. Finisce nella diagnostica.
    private(set) var status: UNAuthorizationStatus = .notDetermined

    var statusText: String {
        switch status {
        case .authorized, .provisional: return "consentite"
        case .denied: return "SPENTE in Impostazioni di Sistema"
        case .notDetermined: return "permesso non ancora dato"
        @unknown default: return "stato sconosciuto"
        }
    }

    var isAllowed: Bool { status == .authorized || status == .provisional }

    /// Va chiamata appena l'app parte: il clic sulla notifica arriva sempre a Ormeggio,
    /// e macOS chiede subito il permesso, così la notifica del prossimo aggiornamento non si perde.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { @MainActor in
            await self.refreshStatus()
            if self.status == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                await self.refreshStatus()
            }
            Log.write("Notifiche: \(self.statusText)")
        }
    }

    func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Apre Impostazioni di Sistema sulle notifiche di Ormeggio.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.sparkfabrik.ormeggio"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Manda la notifica. La prima volta macOS chiede se Ormeggio può mandarne: basta "Consenti".
    func post(title: String, body: String, kind: String) {
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.write("Notifiche di Ormeggio non disponibili (\(error.localizedDescription)): uso quelle di sistema")
                Notifier.systemNotification(title: title, body: body)
                return
            }
            await self.refreshStatus()
            guard granted else {
                Log.write("Notifiche spente per Ormeggio in Impostazioni di Sistema")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["kind": kind]
            let request = UNNotificationRequest(identifier: "\(kind)-\(UUID().uuidString)", content: content, trigger: nil)
            do {
                try await center.add(request)
                Log.write("Notifica mandata: \(title)")
            } catch {
                Log.write("Notifica non mandata (\(error.localizedDescription)): uso quelle di sistema")
                Notifier.systemNotification(title: title, body: body)
            }
        }
    }

    /// Ripiego quando macOS non accetta le notifiche dell'app: le manda tramite AppleScript.
    private static func systemNotification(title: String, body: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
        try? process.run()
    }

    // La notifica compare anche quando Ormeggio è in primo piano.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        Task { @MainActor in
            if kind == "update" { Notifier.shared.onOpenUpdate?() }
        }
        completionHandler()
    }
}
