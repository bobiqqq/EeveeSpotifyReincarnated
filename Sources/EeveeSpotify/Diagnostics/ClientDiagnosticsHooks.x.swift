import Orion
import UIKit

// MARK: - Client Diagnostics Hooks
// Hooks UI presentation and network errors to provide rich diagnostic logging
// for region restrictions, licensing errors, auth failures, and UI popups.

class UIViewControllerPresentationDiagnosticsHook: ClassHook<UIViewController> {
    func presentViewController(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        let clsName = NSStringFromClass(type(of: viewControllerToPresent))
        
        if let alert = viewControllerToPresent as? UIAlertController {
            let title = alert.title ?? "<no title>"
            let msg = alert.message ?? "<no message>"
            writeDebugLog("[UI ALERT] \(title): \(msg)")
            
            let lowerMsg = msg.lowercased()
            let lowerTitle = title.lowercased()
            if lowerTitle.contains("error") || lowerMsg.contains("available") || lowerMsg.contains("region") || lowerMsg.contains("country") || lowerMsg.contains("license") || lowerMsg.contains("restricted") {
                writeDebugLog("[REGION/LICENSING ERROR] Popup shown to user: \"\(title)\" - \"\(msg)\"")
            }
        } else if clsName.contains("Error") || clsName.contains("Alert") || clsName.contains("PopUp") || clsName.contains("Dialog") || clsName.contains("Banner") {
            writeDebugLog("[UI MODAL] Presented modal: \(clsName)")
        }
        
        orig.presentViewController(viewControllerToPresent, animated: flag, completion: completion)
    }
}
