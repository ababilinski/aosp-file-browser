import XCTest
@testable import AndroidFileBrowserCore

final class ADBParsersTests: XCTestCase {
    func testParseStatListingIncludesCreatedDate() {
        let output = """
        drwxrws---|4096|1783376707|1783376716|/storage/emulated/0/DCIM
        -rw-rw----|242233|1783376707|1783376716|/storage/emulated/0/DCIM/city drive.mp4
        -rw-rw----|10|1783376707|0|/storage/emulated/0/DCIM/unknown-created.txt
        """

        let files = ADBParsers.parseStatListing(output)

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[1].name, "city drive.mp4")
        XCTAssertEqual(files[1].size, 242233)
        XCTAssertEqual(files[1].modified?.timeIntervalSince1970, 1783376707)
        XCTAssertEqual(files[1].created?.timeIntervalSince1970, 1783376716)
        XCTAssertNil(files[2].created)
    }

    func testParseDevices() {
        let output = """
        List of devices attached
        1234567890abcdef device usb:1-2 product:oriole model:Pixel_6 device:oriole transport_id:4
        emulator-5554 unauthorized
        """

        let devices = ADBParsers.parseDevices(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "1234567890abcdef")
        XCTAssertEqual(devices[0].state, .device)
        XCTAssertEqual(devices[0].model, "Pixel_6")
        XCTAssertEqual(devices[0].usbLocation, "1-2")
        XCTAssertEqual(devices[0].connectionKind, .usb)
        XCTAssertEqual(devices[1].connectionKind, .virtual)
        XCTAssertEqual(devices[1].state, .unauthorized)
    }

    func testDetectsNetworkADBConnections() {
        let direct = AndroidDevice(
            serial: "192.168.1.42:5555",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "7"
        )
        let paired = AndroidDevice(
            serial: "adb-ABC123-r4Nd0m._adb-tls-connect._tcp",
            state: .device,
            model: "Pixel",
            product: nil,
            transport: "8"
        )

        XCTAssertEqual(direct.connectionKind, .wifi)
        XCTAssertEqual(paired.connectionKind, .wifi)
    }

    func testParseWirelessIPv4AddressFromRouteOrInterface() {
        XCTAssertEqual(
            ADBParsers.parseWirelessIPv4Address(
                "1.1.1.1 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 2000"
            ),
            "192.168.1.42"
        )
        XCTAssertEqual(
            ADBParsers.parseWirelessIPv4Address(
                "12: wlan0 inet 10.0.0.18/24 brd 10.0.0.255 scope global wlan0"
            ),
            "10.0.0.18"
        )
        XCTAssertNil(ADBParsers.parseWirelessIPv4Address("lo inet 127.0.0.1/8"))
    }

    func testParseLongListing() {
        let output = """
        total 12
        drwxr-xr-x 2 shell shell 4096 2026-06-01 12:30 Music
        -rw-r--r-- 1 shell shell 12345 2026-06-02 08:15 track one.mp3
        lrwxrwxrwx 1 root root 4 2026-06-02 08:15 link -> test
        """

        let files = ADBParsers.parseLongListing(output, parentPath: "/storage/emulated/0")

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].name, "Music")
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[1].path, "/storage/emulated/0/link -> test")
        XCTAssertEqual(files[2].size, 12345)
    }

    func testHiddenFilesAndFoldersRemainVisibleInListings() {
        let statOutput = """
        drwxr-xr-x|0|1770000000|1770000000|/storage/emulated/0/.thumbnails
        -rw-r--r--|12|1770000000|1770000000|/storage/emulated/0/.nomedia
        """
        let longOutput = """
        total 4
        drwxr-xr-x 2 shell shell 4096 2026-06-01 12:30 .cache
        -rw-r--r-- 1 shell shell 12 2026-06-02 08:15 .hidden-file
        """

        XCTAssertEqual(Set(ADBParsers.parseStatListing(statOutput).map(\.name)), [".nomedia", ".thumbnails"])
        XCTAssertEqual(Set(ADBParsers.parseLongListing(longOutput, parentPath: "/storage/emulated/0").map(\.name)), [".cache", ".hidden-file"])
    }

    func testParseAbsoluteLongListing() {
        let output = """
        drwxr-xr-x 2 shell shell 4096 2026-06-01 12:30 /storage/emulated/0/DCIM/Camera
        -rw-r--r-- 1 shell shell 12345 2026-06-02 08:15 /storage/emulated/0/DCIM/Camera/IMG 0001.jpg
        lrwxrwxrwx 1 root root 4 2026-06-02 08:15 /storage/emulated/0/link -> /sdcard
        """

        let files = ADBParsers.parseAbsoluteLongListing(output)

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].name, "Camera")
        XCTAssertEqual(files[0].path, "/storage/emulated/0/DCIM/Camera")
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[1].name, "IMG 0001.jpg")
        XCTAssertEqual(files[1].mediaKind, .image)
        XCTAssertEqual(files[2].path, "/storage/emulated/0/link")
        XCTAssertEqual(files[2].kind, .symlink)
    }

    func testParsePackages() {
        let output = """
        package:/data/app/~~abc/base.apk=com.example.alpha
        package:com.example.beta
        """

        let packages = ADBParsers.parsePackages(output, kind: .user)

        XCTAssertEqual(packages.map(\.packageName), ["com.example.alpha", "com.example.beta"])
        XCTAssertEqual(packages[0].apkPath, "/data/app/~~abc/base.apk")
    }

    func testParseStorageSkipsSyntheticMounts() {
        let output = """
        Filesystem       1K-blocks     Used Available Use% Mounted on
        tmpfs              5794308        0   5794308   0% /storage
        /dev/fuse        114786388 46398564  68256752  41% /storage/emulated
        /dev/fuse        114786388 46398564  68256752  41% /storage/emulated/0
        /dev/fuse         32000000 12000000  20000000  38% /storage/1234-5678
        /dev/block/dm-61 114786388 46398564  68256752  41% /data/user/0
        """

        let summaries = ADBParsers.parseStorage(output)

        XCTAssertEqual(summaries.map(\.path), ["/storage/emulated/0", "/storage/1234-5678"])
        XCTAssertEqual(summaries[0].title, "Internal Storage")
    }

    func testParseStorageKeepsInternalWhenEmulatedIsOnlyInternalMount() {
        let output = """
        Filesystem       1K-blocks     Used Available Use% Mounted on
        tmpfs              5794308        0   5794308   0% /storage
        /dev/fuse        114786388 46398564  68256752  41% /storage/emulated
        /dev/fuse         32000000 12000000  20000000  38% /storage/1234-5678
        """

        let summaries = ADBParsers.parseStorage(output)

        XCTAssertEqual(summaries.map(\.path), ["/storage/emulated", "/storage/1234-5678"])
        XCTAssertEqual(summaries[0].title, "Internal Storage")
        XCTAssertEqual(summaries[1].title, "SD Card 1234-5678")
    }

    func testParseBatteryStatusWhenChargingOverUSB() {
        let output = """
        Current Battery Service state:
          AC powered: false
          USB powered: true
          Wireless powered: false
          Dock powered: false
          status: 2
          health: 2
          present: true
          level: 82
          scale: 100
        """

        let status = ADBParsers.parseBatteryStatus(output)

        XCTAssertEqual(status?.levelPercent, 82)
        XCTAssertEqual(status?.chargeState, .charging)
        XCTAssertEqual(status?.chargingSource, .usb)
        XCTAssertEqual(status?.statusLabel, "USB charging")
    }

    func testParseBatteryStatusWhenDischargingWithScale() {
        let output = """
        Current Battery Service state:
          AC powered: false
          USB powered: false
          Wireless powered: false
          status: 3
          level: 25
          scale: 50
        """

        let status = ADBParsers.parseBatteryStatus(output)

        XCTAssertEqual(status?.levelPercent, 50)
        XCTAssertEqual(status?.chargeState, .discharging)
        XCTAssertEqual(status?.chargingSource, nil)
        XCTAssertEqual(status?.statusLabel, "Discharging")
    }

    func testParseBatteryStatusWhenFullAndConnectedReportsCharged() {
        let output = """
        Current Battery Service state:
          AC powered: false
          USB powered: true
          Wireless powered: false
          status: 4
          level: 100
          scale: 100
        """

        let status = ADBParsers.parseBatteryStatus(output)

        XCTAssertEqual(status?.levelPercent, 100)
        XCTAssertEqual(status?.chargeState, .notCharging)
        XCTAssertEqual(status?.chargingSource, .usb)
        XCTAssertEqual(status?.statusLabel, "Charged")
    }

    func testParseBatteryStatusWhenConnectedButNotChargingReportsConnected() {
        let output = """
        Current Battery Service state:
          AC powered: false
          USB powered: true
          Wireless powered: false
          status: 4
          level: 82
          scale: 100
        """

        let status = ADBParsers.parseBatteryStatus(output)

        XCTAssertEqual(status?.levelPercent, 82)
        XCTAssertEqual(status?.chargeState, .notCharging)
        XCTAssertEqual(status?.chargingSource, .usb)
        XCTAssertEqual(status?.statusLabel, "Connected")
    }

    func testRemoteQuoting() {
        XCTAssertEqual(ADBClient.quoteRemote("/sdcard/Music/Bob's Song.mp3"), "'/sdcard/Music/Bob'\\''s Song.mp3'")
    }

    func testParsePackageDetailsWithIntentEndpoints() {
        let package = AndroidPackage(
            packageName: "com.example.app",
            apkPath: "/data/app/base.apk",
            kind: .user,
            enabled: nil,
            versionName: nil,
            permissions: [],
            activities: [],
            receivers: [],
            services: [],
            providers: []
        )
        let dumpsys = """
        Activity Resolver Table:
          Non-Data Actions:
              android.intent.action.MAIN:
                abc123 com.example.app/.MainActivity filter def456
                  Action: "android.intent.action.MAIN"
                  Category: "android.intent.category.LAUNCHER"

        Receiver Resolver Table:
          Non-Data Actions:
              android.intent.action.BOOT_COMPLETED:
                aaa111 com.example.app/.BootReceiver filter bbb222
                  Action: "android.intent.action.BOOT_COMPLETED"

        requested permissions:
          android.permission.INTERNET
          android.permission.POST_NOTIFICATIONS
        """

        let parsed = ADBParsers.parsePackageDetails(package: package, dumpsys: dumpsys)

        XCTAssertEqual(parsed.permissions, ["android.permission.INTERNET", "android.permission.POST_NOTIFICATIONS"])
        XCTAssertEqual(parsed.activities.first?.component, "com.example.app/.MainActivity")
        XCTAssertEqual(parsed.activities.first?.actions, ["android.intent.action.MAIN"])
        XCTAssertEqual(parsed.activities.first?.categories, ["android.intent.category.LAUNCHER"])
        XCTAssertEqual(parsed.receivers.first?.component, "com.example.app/.BootReceiver")
    }

    func testParseRunningProcessNames() {
        let output = """
        NAME
        system_server
        com.example.alpha
        com.example.alpha:remote
        u0_a123      1234  567  123456  com.example.beta
        """

        let names = ADBParsers.parseRunningProcessNames(output)

        XCTAssertTrue(names.contains("com.example.alpha"))
        XCTAssertTrue(names.contains("com.example.alpha:remote"))
        XCTAssertTrue(names.contains("com.example.beta"))
        XCTAssertFalse(names.contains("system_server"))
    }

    func testParsePackageDetailsReclassifiesSystemFlags() {
        let package = AndroidPackage(
            packageName: "com.google.android.safetycore",
            apkPath: "/data/app/~~abc/base.apk",
            kind: .user,
            enabled: nil,
            versionName: nil,
            permissions: [],
            activities: [],
            receivers: [],
            services: [],
            providers: []
        )
        let dumpsys = """
        Package [com.google.android.safetycore] (123abc):
          pkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA UPDATED_SYSTEM_APP ]
          privateFlags=[ PRIVILEGED ]
        """

        let parsed = ADBParsers.parsePackageDetails(package: package, dumpsys: dumpsys)

        XCTAssertEqual(parsed.kind, .system)
    }

    func testParseAppStorageStats() {
        let output = """
        App Size: 178000000
        Data Size: 420000000
        Cache Size: 70720000
        """

        let stats = ADBParsers.parseAppStorageStats(output)

        XCTAssertEqual(stats?.appBytes, 178000000)
        XCTAssertEqual(stats?.userDataBytes, 420000000)
        XCTAssertEqual(stats?.cacheBytes, 70720000)
        XCTAssertEqual(stats?.totalBytes, 668720000)
    }

}
