import Foundation

@objc protocol PrivilegedReaderXPCProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func readBytes(
        devicePath: String,
        offset: UInt64,
        length: Int,
        withReply reply: @escaping (Data?, String?) -> Void
    )
}
