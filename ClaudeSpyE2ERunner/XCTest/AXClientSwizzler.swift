import Foundation
import os
import XCTest

private let _lock = OSAllocatedUnfairLock(initialState: [String: Int]())

enum AXClientSwizzler {
    static var overwriteDefaultParameters: [String: Int] {
        get { _lock.withLock { $0 } }
        set { setup; _lock.withLock { $0 = newValue } }
    }

    private static let setup: Void = {
        guard let axClientiOSClass: AnyClass = objc_getClass("XCAXClient_iOS") as? AnyClass else {
            fatalError("XCAXClient_iOS class not found — XCTest private API may have changed")
        }

        let defaultParametersSelector = Selector(("defaultParameters"))
        guard let original = class_getInstanceMethod(axClientiOSClass, defaultParametersSelector) else {
            fatalError("XCAXClient_iOS.defaultParameters method not found — XCTest private API may have changed")
        }

        let replaced = class_getInstanceMethod(
            AXClientiOS_Standin.self,
            #selector(AXClientiOS_Standin.swizzledDefaultParameters)
        )!

        method_exchangeImplementations(original, replaced)
    }()
}

@objc private class AXClientiOS_Standin: NSObject {
    func originalDefaultParameters() -> NSDictionary {
        let selector = Selector(("defaultParameters"))
        let swizzledSelector = #selector(swizzledDefaultParameters)
        let imp = class_getMethodImplementation(AXClientiOS_Standin.self, swizzledSelector)
        typealias Method = @convention(c) (NSObject, Selector) -> NSDictionary
        let method = unsafeBitCast(imp, to: Method.self)
        return method(self, selector)
    }

    @objc func swizzledDefaultParameters() -> NSDictionary {
        let defaultParameters = originalDefaultParameters().mutableCopy() as! NSMutableDictionary
        let overrides = _lock.withLock { $0 }
        for (key, value) in overrides {
            defaultParameters[key] = value
        }
        return defaultParameters
    }
}
