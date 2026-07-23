import Foundation

public enum ADBParsers {
    public static func parseStatListing(_ output: String) -> [AndroidFile] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> AndroidFile? in
                let separator: Character = rawLine.contains("\t") ? "\t" : "|"
                let fields = rawLine.split(
                    separator: separator,
                    maxSplits: 4,
                    omittingEmptySubsequences: false
                ).map(String.init)
                guard fields.count == 5 else { return nil }

                let permissions = fields[0]
                let path = fields[4]
                let name = (path as NSString).lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { return nil }

                let kind: AndroidFileKind
                if permissions.hasPrefix("d") {
                    kind = .directory
                } else if permissions.hasPrefix("l") {
                    kind = .symlink
                } else if permissions.hasPrefix("-") {
                    kind = .file
                } else {
                    kind = .unknown
                }

                return AndroidFile(
                    name: name,
                    path: path,
                    kind: kind,
                    size: Int64(fields[1]),
                    modified: dateFromEpoch(fields[2]),
                    permissions: permissions,
                    created: dateFromEpoch(fields[3])
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind == .directory, rhs.kind != .directory { return true }
                if lhs.kind != .directory, rhs.kind == .directory { return false }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> AndroidDevice? in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 2 else { return nil }

                var attributes: [String: String] = [:]
                for field in fields.dropFirst(2) {
                    let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        attributes[parts[0]] = parts[1]
                    }
                }

                return AndroidDevice(
                    serial: fields[0],
                    state: DeviceState(rawValue: fields[1]) ?? .unknown,
                    model: attributes["model"],
                    product: attributes["product"],
                    transport: attributes["transport_id"],
                    usbLocation: attributes["usb"]
                )
            }
    }

    public static func parseWirelessIPv4Address(_ output: String) -> String? {
        let tokens = output.split(whereSeparator: \.isWhitespace).map(String.init)
        if let sourceIndex = tokens.firstIndex(of: "src"),
           tokens.indices.contains(sourceIndex + 1),
           isUsableIPv4Address(tokens[sourceIndex + 1]) {
            return tokens[sourceIndex + 1]
        }

        if let inetIndex = tokens.firstIndex(of: "inet"),
           tokens.indices.contains(inetIndex + 1) {
            let candidate = tokens[inetIndex + 1].split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if isUsableIPv4Address(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isUsableIPv4Address(_ candidate: String) -> Bool {
        let octets = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ octet in
                  guard let value = Int(octet) else { return false }
                  return (0...255).contains(value)
              }) else { return false }
        return octets[0] != "0" && octets[0] != "127"
    }

    public static func parseLongListing(_ output: String, parentPath: String) -> [AndroidFile] {
        output
            .split(separator: "\n")
            .compactMap { rawLine -> AndroidFile? in
                let line = String(rawLine)
                guard !line.hasPrefix("total ") else { return nil }
                let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 8 else { return nil }

                let permissions = parts[0]
                let size = Int64(parts[4])
                let name = parts[7]
                guard name != "." && name != ".." else { return nil }

                let kind: AndroidFileKind
                if permissions.hasPrefix("d") {
                    kind = .directory
                } else if permissions.hasPrefix("l") {
                    kind = .symlink
                } else if permissions.hasPrefix("-") {
                    kind = .file
                } else {
                    kind = .unknown
                }

                return AndroidFile(
                    name: name,
                    path: ADBClient.joinRemote(parentPath, name),
                    kind: kind,
                    size: size,
                    modified: parseListingDate(date: parts[5], timeOrYear: parts[6]),
                    permissions: permissions
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind == .directory, rhs.kind != .directory { return true }
                if lhs.kind != .directory, rhs.kind == .directory { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func parseAbsoluteLongListing(_ output: String) -> [AndroidFile] {
        output
            .split(separator: "\n")
            .compactMap { rawLine -> AndroidFile? in
                let line = String(rawLine)
                guard !line.hasPrefix("total ") else { return nil }
                let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 8 else { return nil }

                let permissions = parts[0]
                let size = Int64(parts[4])
                let rawPath = parts[7]
                let path = rawPath.components(separatedBy: " -> ").first ?? rawPath
                let name = (path as NSString).lastPathComponent
                guard !name.isEmpty, name != "." && name != ".." else { return nil }

                let kind: AndroidFileKind
                if permissions.hasPrefix("d") {
                    kind = .directory
                } else if permissions.hasPrefix("l") {
                    kind = .symlink
                } else if permissions.hasPrefix("-") {
                    kind = .file
                } else {
                    kind = .unknown
                }

                return AndroidFile(
                    name: name,
                    path: path,
                    kind: kind,
                    size: size,
                    modified: parseListingDate(date: parts[5], timeOrYear: parts[6]),
                    permissions: permissions
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind == .directory, rhs.kind != .directory { return true }
                if lhs.kind != .directory, rhs.kind == .directory { return false }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    public static func parseStorage(_ output: String) -> [StorageSummary] {
        let summaries = output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { rawLine -> StorageSummary? in
                let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 6,
                      let blocks = Int64(fields[1]),
                      let used = Int64(fields[2]) else {
                    return nil
                }
                let mount = fields[5]
                guard isUserVisibleStorageMount(mount), blocks > 0 else {
                    return nil
                }
                return StorageSummary(
                    id: mount,
                    title: storageTitle(for: mount),
                    path: mount,
                    usedBytes: used * 1024,
                    totalBytes: blocks * 1024
                )
            }
            .sorted { lhs, rhs in
                if isInternalStoragePath(lhs.path), !isInternalStoragePath(rhs.path) { return true }
                if !isInternalStoragePath(lhs.path), isInternalStoragePath(rhs.path) { return false }
                if lhs.path == "/storage/emulated/0" { return true }
                if rhs.path == "/storage/emulated/0" { return false }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        var seenCanonicalPaths = Set<String>()
        return summaries.filter { summary in
            let canonical = canonicalStoragePath(summary.path)
            return seenCanonicalPaths.insert(canonical).inserted
        }
    }

    public static func parseBatteryStatus(_ output: String) -> BatteryStatus? {
        var fields: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let level = Int(fields["level"] ?? "") else { return nil }
        let scale = max(1, Int(fields["scale"] ?? "") ?? 100)
        let levelPercent = min(100, max(0, Int((Double(level) / Double(scale) * 100).rounded())))
        let statusCode = Int(fields["status"] ?? "") ?? 1
        let source = batteryChargingSource(fields: fields)
        let state: BatteryChargeState

        switch statusCode {
        case 2:
            state = .charging
        case 3:
            state = .discharging
        case 4:
            state = .notCharging
        case 5:
            state = .full
        default:
            state = source == nil ? .unknown : .charging
        }

        return BatteryStatus(levelPercent: levelPercent, chargeState: state, chargingSource: source)
    }

    public static func parsePackages(_ output: String, kind: AppKind) -> [AndroidPackage] {
        output
            .split(separator: "\n")
            .compactMap { rawLine -> AndroidPackage? in
                let line = String(rawLine)
                guard line.hasPrefix("package:") else { return nil }
                let payload = String(line.dropFirst("package:".count))
                if let separator = payload.lastIndex(of: "=") {
                    return AndroidPackage(
                        packageName: String(payload[payload.index(after: separator)...]),
                        apkPath: String(payload[..<separator]),
                        kind: kind,
                        enabled: nil,
                        versionName: nil,
                        permissions: [],
                        activities: [],
                        receivers: [],
                        services: [],
                        providers: []
                    )
                }
                return AndroidPackage(
                    packageName: payload,
                    apkPath: nil,
                    kind: kind,
                    enabled: nil,
                    versionName: nil,
                    permissions: [],
                    activities: [],
                    receivers: [],
                    services: [],
                    providers: []
                )
            }
            .sorted { $0.packageName.localizedStandardCompare($1.packageName) == .orderedAscending }
    }

    public static func parsePackageDetails(package: AndroidPackage, dumpsys: String) -> AndroidPackage {
        var updated = package
        updated.kind = packageKind(from: dumpsys) ?? package.kind
        updated.enabled = !dumpsys.contains("enabled=false")
        updated.versionName = dumpsys
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("versionName=") }
            .map { String($0).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "versionName=", with: "") }

        updated.permissions = dumpsys
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("android.permission.") }
            .map { line in
                line.components(separatedBy: ":").first ?? line
            }
            .removingDuplicates()

        updated.activities = parseResolverEntries(
            dumpsys,
            startMarker: "Activity Resolver Table:",
            endMarkers: ["Receiver Resolver Table:", "Service Resolver Table:", "Provider Resolver Table:", "Queries:"],
            packageName: package.packageName,
            prefix: "activity"
        )
        updated.receivers = parseResolverEntries(
            dumpsys,
            startMarker: "Receiver Resolver Table:",
            endMarkers: ["Service Resolver Table:", "Provider Resolver Table:", "Queries:"],
            packageName: package.packageName,
            prefix: "receiver"
        )
        updated.services = parseResolverEntries(
            dumpsys,
            startMarker: "Service Resolver Table:",
            endMarkers: ["Provider Resolver Table:", "Queries:"],
            packageName: package.packageName,
            prefix: "service"
        )
        updated.providers = parseResolverEntries(
            dumpsys,
            startMarker: "Provider Resolver Table:",
            endMarkers: ["Queries:"],
            packageName: package.packageName,
            prefix: "provider"
        )

        return updated
    }

    public static func parseAppStorageStats(_ output: String) -> AppStorageStats? {
        var appBytes: Int64?
        var userDataBytes: Int64?
        var cacheBytes: Int64?

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            let normalized = line
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            guard let value = firstInteger(in: line) else { continue }

            if normalized.contains("cache") {
                cacheBytes = value
            } else if normalized.contains("data") || normalized.contains("user") {
                userDataBytes = value
            } else if normalized.contains("app") || normalized.contains("code") || normalized.contains("apk") {
                appBytes = value
            }
        }

        guard appBytes != nil || userDataBytes != nil || cacheBytes != nil else {
            return nil
        }
        return AppStorageStats(appBytes: appBytes, userDataBytes: userDataBytes, cacheBytes: cacheBytes)
    }

    private static func firstInteger(in line: String) -> Int64? {
        let pattern = #"-?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else {
            return nil
        }
        return Int64(line[range])
    }

    private static func packageKind(from dumpsys: String) -> AppKind? {
        let flagLines = dumpsys
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter {
                $0.hasPrefix("pkgFlags=")
                    || $0.hasPrefix("privateFlags=")
                    || $0.hasPrefix("flags=")
                    || $0.hasPrefix("privateFlagsExt=")
            }

        guard !flagLines.isEmpty else { return nil }
        let flags = flagLines.joined(separator: " ").uppercased()
        if flags.contains("SYSTEM")
            || flags.contains("UPDATED_SYSTEM_APP")
            || flags.contains("PRIVILEGED") {
            return .system
        }
        return .user
    }

    public static func parseRunningProcessNames(_ output: String) -> Set<String> {
        Set(output
            .split(separator: "\n")
            .compactMap { rawLine -> String? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, line != "NAME" else { return nil }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let candidate = fields.last else { return nil }
                guard candidate.contains(".") else { return nil }
                return candidate
            })
    }

    private static func parseResolverEntries(
        _ dumpsys: String,
        startMarker: String,
        endMarkers: [String],
        packageName: String,
        prefix: String
    ) -> [AndroidIntentEndpoint] {
        let lines = dumpsys.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == startMarker }) else {
            return []
        }

        let end = lines[(start + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return endMarkers.contains(trimmed)
        } ?? lines.endIndex

        var entries: [AndroidIntentEndpoint] = []
        var current: AndroidIntentEndpoint?
        var counter = 0

        func finishCurrent() {
            guard var current else { return }
            current.actions = current.actions.removingDuplicates()
            current.categories = current.categories.removingDuplicates()
            current.data = current.data.removingDuplicates()
            entries.append(current)
        }

        for line in lines[(start + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let component = resolverComponent(from: trimmed, packageName: packageName) {
                finishCurrent()
                counter += 1
                current = AndroidIntentEndpoint(id: "\(prefix)-\(counter)-\(component)", component: component)
            } else if trimmed.hasPrefix("Action: ") {
                current?.actions.append(quotedPayload(from: trimmed) ?? trimmed.replacingOccurrences(of: "Action: ", with: ""))
            } else if trimmed.hasPrefix("Category: ") {
                current?.categories.append(quotedPayload(from: trimmed) ?? trimmed.replacingOccurrences(of: "Category: ", with: ""))
            } else if trimmed.hasPrefix("Scheme: ")
                        || trimmed.hasPrefix("Authority: ")
                        || trimmed.hasPrefix("Path: ")
                        || trimmed.hasPrefix("StaticType: ") {
                current?.data.append(trimmed)
            }
        }

        finishCurrent()
        return entries.removingDuplicates { lhs, rhs in
            lhs.component == rhs.component
                && lhs.actions == rhs.actions
                && lhs.categories == rhs.categories
                && lhs.data == rhs.data
        }
    }

    private static func resolverComponent(from line: String, packageName: String) -> String? {
        guard line.contains(packageName), line.contains(" filter ") else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let component = fields.first(where: { $0.hasPrefix(packageName) }) else {
            return nil
        }
        return component
    }

    private static func quotedPayload(from line: String) -> String? {
        guard let first = line.firstIndex(of: "\""),
              let last = line.lastIndex(of: "\""),
              first != last else {
            return nil
        }
        return String(line[line.index(after: first)..<last])
    }

    private static func parseListingDate(date: String, timeOrYear: String) -> Date? {
        let currentYear = Calendar.current.component(.year, from: Date())
        let candidate = timeOrYear.contains(":") ? "\(date) \(currentYear) \(timeOrYear)" : "\(date) \(timeOrYear) 00:00"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeOrYear.contains(":") ? "yyyy-MM-dd yyyy HH:mm" : "yyyy-MM-dd yyyy HH:mm"
        return formatter.date(from: candidate)
    }

    private static func dateFromEpoch(_ value: String) -> Date? {
        guard let seconds = TimeInterval(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isUserVisibleStorageMount(_ mount: String) -> Bool {
        mount == "/storage/emulated/0"
            || mount == "/storage/emulated"
            || mount == "/sdcard"
            || mount.hasPrefix("/storage/") && mount != "/storage/emulated" && !mount.hasPrefix("/storage/emulated/")
    }

    private static func canonicalStoragePath(_ mount: String) -> String {
        isInternalStoragePath(mount) ? "/storage/emulated/0" : mount
    }

    private static func storageTitle(for mount: String) -> String {
        switch mount {
        case "/storage/emulated/0", "/storage/emulated", "/sdcard":
            return "Internal Storage"
        default:
            return mount.replacingOccurrences(of: "/storage/", with: "SD Card ")
        }
    }

    private static func isInternalStoragePath(_ mount: String) -> Bool {
        mount == "/storage/emulated/0" || mount == "/storage/emulated" || mount == "/sdcard"
    }

    private static func batteryChargingSource(fields: [String: String]) -> BatteryChargingSource? {
        func isPowered(_ key: String) -> Bool {
            fields[key]?.lowercased() == "true"
        }

        if isPowered("wireless powered") { return .wireless }
        if isPowered("usb powered") { return .usb }
        if isPowered("ac powered") { return .ac }
        if isPowered("dock powered") { return .dock }
        return nil
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }

    func removingDuplicates(by shouldRemove: (Element, Element) -> Bool) -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(where: { shouldRemove($0, element) }) {
            result.append(element)
        }
        return result
    }
}
