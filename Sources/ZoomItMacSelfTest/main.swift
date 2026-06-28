import Foundation
import ZoomItMacCore

Task { @MainActor in
    do {
        try SelfTestRunner.run()
        print("ZoomItMacSelfTest: PASS")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        print("ZoomItMacSelfTest: FAIL - \(error)")
        Foundation.exit(EXIT_FAILURE)
    }
}

RunLoop.main.run()