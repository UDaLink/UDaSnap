import Foundation
import Security

@MainActor
package enum KeychainStore {
    private static let service = "com.udalink.udasnap.ai"
    static let account = "api-key"

    package enum ReadResult {
        case value(String)
        case notFound
        case denied
        case failure(OSStatus)
    }

    /// 进程内缓存：AI 请求优先用内存，避免每次请求都读钥匙串。
    private static var cachedKey: String?

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 当前 App 的 SHA-1 cdhash，与钥匙串 ACL partition 中的 `cdhash:` 对齐。
    private static func currentCdhashHex() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &info
            ) == errSecSuccess,
            let dict = info as? [String: Any],
            let data = dict["unique"] as? Data,
            data.count == 20
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func keychainItemRef() -> SecKeychainItem? {
        var query = baseQuery()
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let result
        else { return nil }
        return (result as! SecKeychainItem)
    }

    /// 静默检查当前构建是否已被条目 ACL 的 partition 列表接受。
    /// 未授权时只返回 false，不读 Key 数据，也不会触发 SecurityAgent。
    private static func hasCurrentBuildAccess() -> Bool {
        guard let item = keychainItemRef(), let cdhash = currentCdhashHex() else { return false }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess,
            let access
        else { return false }
        var acls: CFArray?
        guard SecAccessCopyACLList(access, &acls) == errSecSuccess,
            let acls
        else { return false }

        var sawPartitionList = false
        for index in 0..<CFArrayGetCount(acls) {
            let raw = CFArrayGetValueAtIndex(acls, index)
            let acl = unsafeBitCast(raw, to: SecACL.self)
            var desc: CFString?
            var apps: CFArray?
            var prompt: SecKeychainPromptSelector = []
            guard SecACLCopyContents(acl, &apps, &desc, &prompt) == errSecSuccess,
                let desc
            else { continue }
            let text = desc as String
            // partition ACL 的 description 是十六进制编码的 plist：
            // 3c3f786d6c... -> <?xml ...><dict><key>Partitions</key>...
            guard let plistData = Self.decodeACLDescription(text),
                let object = try? PropertyListSerialization.propertyList(
                    from: plistData, options: [], format: nil
                ),
                let plist = object as? [String: Any],
                let partitions = plist["Partitions"] as? [String]
            else { continue }
            sawPartitionList = true
            let target = "cdhash:" + cdhash.lowercased()
            if partitions.contains(where: { $0.lowercased() == target }) {
                return true
            }
        }
        // 没有 partition 列表的条目（例如新建的 SecAccess ACL）由 App 信任列表控制，
        // 直接读取即可；有 partition 但当前 cdhash 不在列表时不能读。
        return !sawPartitionList
    }

    private static func decodeACLDescription(_ text: String) -> Data? {
        if let data = text.data(using: .utf8),
            let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
            object["Partitions"] != nil
        {
            return data
        }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func readDataResult() -> ReadResult {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8), !value.isEmpty
        {
            return .value(value)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return .denied
        }
        return .failure(status)
    }

    /// AI 路径的静默读取：先检查当前构建授权，再读数据。
    private static func readAuthorizedResult() -> ReadResult {
        guard hasCurrentBuildAccess() else { return .notFound }
        return readDataResult()
    }

    package static func readResult(allowInteraction: Bool = false) -> ReadResult {
        if let cachedKey, !cachedKey.isEmpty {
            return .value(cachedKey)
        }
        let authorized = readAuthorizedResult()
        if case .value = authorized {
            return authorized
        }
        if !allowInteraction {
            return authorized
        }
        // 只有用户明确点「查看」时才允许系统弹一次授权。
        let interactive = readDataResult()
        if case .value(let key) = interactive {
            cachedKey = key
        }
        return interactive
    }

    /// AI 请求、测试连接等普通路径：只读已授权条目，绝不弹登录密码框。
    package static func read() -> String? {
        if let cachedKey, !cachedKey.isEmpty {
            return cachedKey
        }
        if case .value(let value) = readAuthorizedResult() {
            cachedKey = value
            return value
        }
        return nil
    }

    private static func trustedAccess() -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trustedApp) == errSecSuccess,
            let trustedApp
        else { return nil }
        var access: SecAccess?
        guard
            SecAccessCreate(
                "UDaSnap API Key" as CFString,
                [trustedApp] as CFArray,
                &access) == errSecSuccess,
            let access
        else { return nil }
        return access
    }

    @discardableResult
    package static func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete()
        }
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: Data(trimmed.utf8)] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            cachedKey = trimmed
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = baseQuery()
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        if let access = trustedAccess() {
            add[kSecAttrAccess as String] = access
        }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess {
            cachedKey = trimmed
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    package static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            cachedKey = nil
            return true
        }
        return false
    }
}
