import Foundation
import Security

// 会员体系的服务端访问层。纯判定逻辑在 Core.swift；本文件只做钥匙串与 HTTP。

/// 注册 / 登录成功的服务端回执
struct AuthSession: Equatable {
    let token: String
    let profile: MembershipProfile
}

/// token 只进钥匙串，不落数据库与设置文件
enum KeychainStore {
    static let service = "QQDispatch.license"
    private static let account = "token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ token: String) {
        var query = baseQuery
        SecItemDelete(query as CFDictionary)   // 同 service+account 只保留一条
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 鉴权失败（401/403）：调用方须清除本地凭据并回到登录界面
struct LicenseAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 会员服务器 HTTP 客户端；超时 8 秒，错误统一转中文 AppError。
/// 约束：baseURL 归一化只能经 normalize，避免拼路径时出现双斜杠。
final class LicenseService {
    static let defaultBaseURLString = "http://127.0.0.1:8790"
    static var defaultBaseURL: URL { URL(string: defaultBaseURLString)! }

    private let session: URLSession
    var baseURL: URL

    init(baseURL: URL = LicenseService.defaultBaseURL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        self.baseURL = LicenseService.normalize(baseURL.absoluteString)
    }

    /// 服务器地址归一化：去尾部斜杠；非法或为空时回退默认本机地址
    static func normalize(_ raw: String?) -> URL {
        var cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard !cleaned.isEmpty, let url = URL(string: cleaned), url.scheme != nil, url.host != nil else { return defaultBaseURL }
        return url
    }

    // MARK: 接口

    func plans() async throws -> [PlanInfo] {
        let data = try await request("/api/plans")
        do { return try JSONDecoder().decode([PlanInfo].self, from: data) }
        catch { throw AppError("会员服务器返回的套餐格式异常") }
    }

    func register(account: String, password: String) async throws -> AuthSession {
        try await authRequest("/api/register", account: account, password: password)
    }

    func login(account: String, password: String) async throws -> AuthSession {
        try await authRequest("/api/login", account: account, password: password)
    }

    func me(token: String) async throws -> MembershipProfile {
        let data = try await request("/api/me", token: token)
        return try parseProfile(data)
    }

    func redeem(token: String, code: String) async throws -> MembershipProfile {
        let data = try await request("/api/redeem", method: "POST", token: token, body: ["code": code])
        return try parseProfile(data)
    }

    func logout(token: String) async throws {
        _ = try await request("/api/logout", method: "POST", token: token)
    }

    // MARK: 内部

    private struct Envelope: Decodable { let token: String?; let profile: MembershipProfile? }

    private func authRequest(_ path: String, account: String, password: String) async throws -> AuthSession {
        let data = try await request(path, method: "POST", body: ["account": account, "password": password])
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let token = envelope.token, !token.isEmpty, let profile = envelope.profile else {
            throw AppError("会员服务器返回数据格式异常")
        }
        return AuthSession(token: token, profile: profile)
    }

    private func parseProfile(_ data: Data) throws -> MembershipProfile {
        // 约定返回 {profile:{...}}；扁平返回也兼容
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data), let profile = envelope.profile { return profile }
        if let flat = try? JSONDecoder().decode(MembershipProfile.self, from: data), !flat.account.isEmpty { return flat }
        throw AppError("会员服务器返回数据格式异常")
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw AppError("会员服务器地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw Self.networkError(error) }
        guard let http = response as? HTTPURLResponse else { throw AppError("会员服务器响应异常") }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode, data) }
        return data
    }

    /// 401 / 403 属于凭据问题，调用方据此清 token 回登录界面
    static func isAuthError(_ error: Error) -> Bool { error is LicenseAuthError }

    private static func networkError(_ error: Error) -> AppError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return AppError("连接会员服务器超时，请检查网络或服务器地址")
        }
        return AppError("无法连接会员服务器，请检查网络或服务器地址")
    }

    private static func httpError(_ code: Int, _ data: Data) -> Error {
        let server = serverMessage(data)
        switch code {
        case 401: return LicenseAuthError(message: server ?? "登录已过期，请重新登录")
        case 403: return LicenseAuthError(message: server ?? "账号被禁用")
        case 404: return AppError(server ?? "会员服务接口不存在，请检查服务器地址")
        case 409: return AppError(server ?? "卡密已被使用")
        case 400..<500: return AppError(server ?? "请求被会员服务器拒绝（\(code)）")
        default: return AppError(server ?? "会员服务器错误（\(code)），请稍后再试")
        }
    }

    /// 服务端错误文案优先透传（卡密无效、卡密已被使用、账号被禁用等）
    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["error", "message", "detail"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}
