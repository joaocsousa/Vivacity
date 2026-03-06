import Foundation

let delegate = PrivilegedHelperDelegate()
let listener = NSXPCListener(machServiceName: PrivilegedHelperDelegate.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
