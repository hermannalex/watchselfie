import SwiftUI
import UserNotifications

@main
struct WatchSelfieApp: App {
    @StateObject private var model = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true } // não deixa a tela apagar
                .task {
                    // Permissão para o aviso "Toque para abrir" quando o Watch pedir a câmera.
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.engine.start()
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [CameraModel.openNotificationID])
            case .background: model.engine.stop()   // o iOS não permite câmera em segundo plano
            default:          break
            }
        }
    }
}
