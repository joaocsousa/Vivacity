import XCTest
@testable import Vivacity

final class PrivilegedDiskReaderTests: XCTestCase {
    func testPreferredPrivilegedDevicePathUsesContainerForAPFSSnapshot() {
        let path = PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/dev/disk3s1s1") { _ in
            [
                "FilesystemType": "apfs",
                "APFSSnapshot": true,
                "APFSContainerReference": "disk3",
            ]
        }

        XCTAssertEqual(path, "/dev/rdisk3")
    }

    func testPreferredPrivilegedDevicePathUsesContainerForBootDataVolume() {
        let path = PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/dev/disk3s5") { _ in
            [
                "FilesystemType": "apfs",
                "APFSSnapshot": false,
                "APFSContainerReference": "disk3",
                "MountPoint": "/System/Volumes/Data",
                "Internal": true,
                "FileVault": true,
                "Bootable": true,
            ]
        }

        XCTAssertEqual(path, "/dev/rdisk3")
    }

    func testPreferredPrivilegedDevicePathUsesRawDeviceForDiskNodes() {
        XCTAssertEqual(
            PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/dev/disk3s5") { _ in nil },
            "/dev/rdisk3s5"
        )
    }

    func testPreferredPrivilegedDevicePathLeavesRawDeviceUntouched() {
        XCTAssertEqual(
            PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/dev/rdisk3s5") { _ in nil },
            "/dev/rdisk3s5"
        )
    }

    func testPreferredPrivilegedDevicePathLeavesNonDevicePathsUntouched() {
        XCTAssertEqual(
            PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/tmp/example.img"),
            "/tmp/example.img"
        )
    }

    func testPreferredPrivilegedDevicePathLeavesNonBootAPFSVolumeOnItsOwnRawNode() {
        let path = PrivilegedDiskReader.preferredPrivilegedDevicePath(for: "/dev/disk8s1") { _ in
            [
                "FilesystemType": "apfs",
                "APFSSnapshot": false,
                "APFSContainerReference": "disk8",
                "MountPoint": "/Volumes/External",
                "Internal": false,
                "FileVault": false,
                "Bootable": false,
            ]
        }

        XCTAssertEqual(path, "/dev/rdisk8s1")
    }
}
