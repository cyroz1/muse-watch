import Combine
import CryptoKit
import Foundation
import MuseKit
import Security
import SwiftUI

/// Simulator research path for checking an existing Muse browser session.
/// The cookie is stored in Keychain and is sent only to muse.ai API requests.
@MainActor
struct MuseCookieSignInView: View {
    @StateObject private var model = MuseCookieSignInModel()
    @State private var showsFirstUseTrustConfirmation = false

    var body: some View {
        Group {
            if let store = model.chatStore {
                ThreadListView(store: store)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        Text("Muse web sign-in")
                            .font(.headline)
                        Text(model.status)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(model.isAuthenticated ? .green : .secondary)
                        Text("Paste the Cookie header from your signed-in muse.ai session. This research build sends it only to HTTPS muse.ai requests.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        SecureField("Muse Cookie header", text: $model.cookieHeader)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Gateway token or WebSocket URL", text: $model.gatewayCredentialInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("The gateway token is separate from the Muse Cookie. It is stored in this simulator’s Keychain and used only for the Muse WebSocket.")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        TextField("Gateway URL", text: $model.gatewayAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("VM ID (or vm_id in URL)", text: $model.vmID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("VM name (optional)", text: $model.vmName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !model.gatewayCredentialInput.isEmpty {
                            Button("Save gateway credential") {
                                model.saveGatewayCredential()
                            }
                            .disabled(!model.isAuthenticated)
                        } else if model.hasSavedGatewayCredential {
                            Text("A gateway credential is stored in Keychain.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button(model.isChecking ? "Checking…" : "Check Muse session") {
                            Task { await model.checkSession() }
                        }
                        .disabled(model.isChecking || (!model.hasSavedCookie && model.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        if model.isAuthenticated {
                            Button(model.isOpeningChat ? "Connecting…" : model.needsFirstUseTrust ? "Trust VM and open chat" : "Open Muse chat") {
                                if model.needsFirstUseTrust {
                                    showsFirstUseTrustConfirmation = true
                                } else {
                                    Task { await model.openChat(allowFirstUse: false) }
                                }
                            }
                            .disabled(model.isOpeningChat)
                            .confirmationDialog(
                                "Trust this Muse VM?",
                                isPresented: $showsFirstUseTrustConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Trust first server key") {
                                    Task { await model.openChat(allowFirstUse: true) }
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("The first standard-VM server key will be pinned to this Muse account and VM. Future key changes are rejected. Confidential VMs stay blocked until their attestation can be verified.")
                            }
                        }
                        if model.hasSavedCookie {
                            Button("Forget Muse session", role: .destructive) {
                                Task { await model.forgetSession() }
                            }
                            .disabled(model.isChecking || model.isOpeningChat)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

@MainActor
private final class MuseCookieSignInModel: ObservableObject {
    @Published var cookieHeader = ""
    @Published var gatewayCredentialInput = ""
    @Published var gatewayAddress = "wss://hatch.metaaivm.com/"
    @Published var vmID = ""
    @Published var vmName = ""
    @Published private(set) var chatStore: ChatStore?
    @Published private(set) var status = "No Muse session has been imported."
    @Published private(set) var isChecking = false
    @Published private(set) var isOpeningChat = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var hasSavedCookie: Bool
    @Published private(set) var hasSavedGatewayCredential: Bool
    @Published private(set) var hasPeerPin = false

    private let cookieStore = MuseWebCookieStore()
    private let gatewayCredentialStore = MuseGatewayCredentialStore()
    private let peerPinStore = MuseKeychainPeerPinStore()
    private var validator: MuseSessionValidator?
    private var admissionProvider: MuseAdmissionProvider?
    private var validatedSession: MuseValidatedSession?

    var needsFirstUseTrust: Bool { !hasPeerPin }

    init() {
        hasSavedCookie = (try? cookieStore.load()) != nil
        hasSavedGatewayCredential = (try? gatewayCredentialStore.loadRecord()) != nil
        if hasSavedCookie {
            status = "A Muse session is stored on this simulator."
        }
#if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if let vmArgument = arguments.firstIndex(of: "--muse-vm-id"),
           arguments.indices.contains(vmArgument + 1) {
            vmID = arguments[vmArgument + 1]
        }
        let cookieFile = arguments.contains("--import-muse-cookie-file")
            ? Self.oneTimeImportFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            : nil
        let gatewayCredentialFile = arguments.contains("--import-muse-gateway-credential-file")
            ? Self.oneTimeGatewayCredentialFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            : nil
        let shouldRunLiveTest = arguments.contains("--muse-live-test")
        if cookieFile != nil || gatewayCredentialFile != nil || shouldRunLiveTest {
            Task {
                if let cookieFile {
                    await importOneTimeFile(at: cookieFile)
                } else if gatewayCredentialFile != nil {
                    await checkSession()
                }
                if let gatewayCredentialFile {
                    await importOneTimeGatewayCredentialFile(at: gatewayCredentialFile)
                }
                if shouldRunLiveTest {
                    await runSimulatorLiveTest(arguments: arguments, sessionAlreadyChecked: cookieFile != nil || gatewayCredentialFile != nil)
                }
            }
        }
#endif
        if ProcessInfo.processInfo.arguments.contains("--import-muse-cookie-file"),
           let fileURL = Self.oneTimeImportFileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            Task { await importOneTimeFile(at: fileURL) }
        }
    }

    func checkSession() async {
        let enteredCookie = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie: String
        if !enteredCookie.isEmpty {
            cookie = Self.cookieValue(from: enteredCookie)
        } else if let savedCookie = try? cookieStore.load() {
            cookie = savedCookie
        } else {
            status = "Enter a valid Cookie header."
            return
        }
        guard !cookie.isEmpty, !cookie.contains("\r"), !cookie.contains("\n") else {
            status = "Enter a valid Cookie header."
            return
        }

        cookieHeader = ""
        isChecking = true
        isAuthenticated = false
        chatStore = nil
        hasPeerPin = false
        defer { isChecking = false }

        do {
            try cookieStore.save(cookie)
            hasSavedCookie = true
            await validator?.clear()
            await admissionProvider?.clear()
            let store = cookieStore
            let newValidator = MuseSessionValidator(fetch: { request in
                try await MuseCookieAuthenticatedFetch.fetch(request, cookieStore: store)
            })
            validator = newValidator
            let session = try await newValidator.validate(forceRefresh: true)
            if let stored = try? gatewayCredentialStore.loadRecord(),
               stored.viewerID != session.viewerID {
                try? gatewayCredentialStore.clear()
                hasSavedGatewayCredential = false
            }
            validatedSession = session
            cookieHeader = ""
            isAuthenticated = true
            if let vmID = selectedVMID() {
                hasPeerPin = (try? await peerPinStore.load(ownerID: session.viewerID, vmID: vmID)) != nil
            }
            status = hasPeerPin
                ? "Muse session validated. This VM's server key is pinned."
                : "Muse session validated. Approve a first-use server key to open chat."
        } catch let error as MuseAuthenticationError {
            validatedSession = nil
            if case .sessionHTTPStatus(401) = error {
                try? cookieStore.clear()
                try? gatewayCredentialStore.clear()
                hasSavedCookie = false
                hasSavedGatewayCredential = false
            } else if case .sessionHTTPStatus(403) = error {
                try? cookieStore.clear()
                try? gatewayCredentialStore.clear()
                hasSavedCookie = false
                hasSavedGatewayCredential = false
            }
            status = error.description
        } catch {
            validatedSession = nil
            status = "Muse session check failed."
        }
    }

    func saveGatewayCredential() {
        guard isAuthenticated, let session = validatedSession else {
            status = "Check the Muse session before saving a gateway credential."
            return
        }
        guard let selectedVMID = selectedVMID() else {
            status = "Enter the selected VM ID before saving a gateway credential."
            return
        }
        do {
            let credential = try MusePreauthorizedGateway(
                gatewayCredentialInput,
                expectedVMID: selectedVMID
            )
            try gatewayCredentialStore.save(
                credential.url.absoluteString,
                viewerID: session.viewerID,
                vmID: selectedVMID
            )
            gatewayCredentialInput = ""
            hasSavedGatewayCredential = true
            status = "Gateway credential saved for this account and VM."
        } catch {
            gatewayCredentialInput = ""
            status = "That gateway credential is invalid or targets a different VM."
        }
    }

    func openChat(allowFirstUse: Bool) async {
        guard isAuthenticated else {
            status = "Validate the Muse session before opening chat."
            return
        }
        guard let session = validatedSession else {
            status = "Recheck the Muse session before opening chat."
            return
        }
        let enteredAddress = gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gatewayAddress = URL(string: enteredAddress) else {
            status = "The Muse gateway address is invalid."
            return
        }
        guard let selectedVMID = selectedVMID() else {
            status = "Enter the selected VM ID or include vm_id in the gateway URL."
            return
        }
        hasPeerPin = (try? await peerPinStore.load(ownerID: session.viewerID, vmID: selectedVMID)) != nil
        if !hasPeerPin && !allowFirstUse {
            status = "Approve the first server key before opening this VM."
            return
        }
        let selectedVMName = vmName.trimmingCharacters(in: .whitespacesAndNewlines)

        isOpeningChat = true
        defer { isOpeningChat = false }
        let store = cookieStore
        do {
            _ = try MuseGatewayTarget(gatewayAddress: gatewayAddress, vmID: selectedVMID)
            let preauthorizedGateway: MusePreauthorizedGateway?
            if let savedURL = try gatewayCredentialStore.load(
                viewerID: session.viewerID,
                vmID: selectedVMID
            ) {
                preauthorizedGateway = try MusePreauthorizedGateway(
                    savedURL,
                    expectedVMID: selectedVMID
                )
            } else {
                preauthorizedGateway = nil
            }
            let verifier = MuseStandardPeerVerifier(
                ownerID: session.viewerID,
                vmID: selectedVMID,
                allowFirstUse: allowFirstUse,
                pinStore: peerPinStore
            )
            let authentication = MuseWatchAuthentication(
                fetch: { request in
                    try await MuseCookieAuthenticatedFetch.fetch(request, cookieStore: store)
                },
                gatewayAddress: gatewayAddress,
                vmID: selectedVMID,
                vmName: selectedVMName.isEmpty ? nil : selectedVMName,
                preauthorizedGateway: preauthorizedGateway,
                verifyPeer: { hello in try await verifier.verify(hello) }
            )
            let transport = MuseGatewayChatTransport(authentication: authentication)
            chatStore = ChatStore(transport: transport, threads: [], messages: [:])
            status = "Chat is ready. Start a new thread and send a message."
        } catch let error as MuseAuthenticationError {
            status = error.description
        } catch {
            status = "Muse chat could not be prepared."
        }
    }

#if DEBUG && targetEnvironment(simulator)
    private func runSimulatorLiveTest(arguments: [String], sessionAlreadyChecked: Bool = false) async {
        guard selectedVMID() != nil else {
            status = "Pass --muse-vm-id with the selected VM ID to run the live test."
            return
        }

        if !sessionAlreadyChecked {
            status = "Checking the saved Muse session…"
            await checkSession()
        }
        guard isAuthenticated else { return }

        let allowFirstUse = arguments.contains("--trust-first-server-key")
        await openChat(allowFirstUse: allowFirstUse)
        guard let store = chatStore else { return }

        let thread = store.startNewThread()
        status = "Sending the Watch connectivity test…"
        await store.send("Connectivity test from Apple Watch. Please reply with the word READY.", in: thread.id)
    }
#endif

    private func selectedVMID() -> String? {
        let address = gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let queryVMIDs = (components.queryItems ?? []).filter { $0.name == "vm_id" }.compactMap(\.value)
        let targetVMID = queryVMIDs.count == 1 ? queryVMIDs[0] : nil
        let enteredVMID = vmID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = enteredVMID.isEmpty ? targetVMID : enteredVMID
        guard let selected, !selected.isEmpty,
              selected == selected.trimmingCharacters(in: .whitespacesAndNewlines),
              selected.utf16.count <= 255,
              queryVMIDs.isEmpty || (queryVMIDs.count == 1 && targetVMID == selected) else { return nil }
        return selected
    }

    private static func cookieValue(from header: String) -> String {
        guard let colon = header.firstIndex(of: ":"),
              header[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Cookie") == .orderedSame else {
            return header
        }
        return header[header.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importOneTimeFile(at url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            guard let header = String(data: data, encoding: .utf8) else {
                throw MuseCookieStoreError.invalidCookie
            }
            try FileManager.default.removeItem(at: url)
            cookieHeader = Self.cookieValue(from: header)
            await checkSession()
        } catch {
            try? FileManager.default.removeItem(at: url)
            status = "The one-time cookie import could not be read."
        }
    }

    private func importOneTimeGatewayCredentialFile(at url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            guard let value = String(data: data, encoding: .utf8) else {
                throw MuseAuthenticationError.invalidGatewayAddress
            }
            try FileManager.default.removeItem(at: url)
            gatewayCredentialInput = value
            saveGatewayCredential()
        } catch {
            try? FileManager.default.removeItem(at: url)
            gatewayCredentialInput = ""
            status = "The one-time gateway credential import could not be read."
        }
    }

    private static var oneTimeImportFileURL: URL? {
#if DEBUG && targetEnvironment(simulator)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("muse-cookie-import.txt", isDirectory: false)
#else
        nil
#endif
    }

    private static var oneTimeGatewayCredentialFileURL: URL? {
#if DEBUG && targetEnvironment(simulator)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("muse-gateway-credential.txt", isDirectory: false)
#else
        nil
#endif
    }

    func forgetSession() async {
        await validator?.clear()
        validator = nil
        await admissionProvider?.clear()
        admissionProvider = nil
        validatedSession = nil
        chatStore = nil
        hasPeerPin = false
        try? cookieStore.clear()
        try? gatewayCredentialStore.clear()
        cookieHeader = ""
        gatewayCredentialInput = ""
        isAuthenticated = false
        hasSavedCookie = false
        hasSavedGatewayCredential = false
        status = "Muse session removed from this simulator."
    }
}

private struct MuseWebCookieStore: Sendable {
    private let service = "ai.muse.research.MuseWatch.muse.ai-session"
    private let account = "web-cookie-header"

    func load() throws -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let cookie = String(data: data, encoding: .utf8) else {
            throw MuseCookieStoreError.unavailable
        }
        return cookie
    }

    func save(_ cookie: String) throws {
        guard cookie.utf8.count <= 16_384,
              !cookie.isEmpty,
              !cookie.contains("\r"),
              !cookie.contains("\n") else {
            throw MuseCookieStoreError.invalidCookie
        }

        let data = Data(cookie.utf8)
        let status = SecItemUpdate(keychainQuery as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw MuseCookieStoreError.unavailable
            }
        } else if status != errSecSuccess {
            throw MuseCookieStoreError.unavailable
        }
    }

    func clear() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MuseCookieStoreError.unavailable
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private struct MuseKeychainPeerPinStore: MusePeerPinStore {
    private let service = "ai.muse.research.MuseWatch.vm-peer-trust"

    func load(ownerID: String, vmID: String) async throws -> MusePeerPin? {
        var query = keychainQuery(ownerID: ownerID, vmID: vmID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let pin = try? JSONDecoder().decode(MusePeerPin.self, from: data) else {
            throw MusePeerTrustError.pinStoreUnavailable
        }
        return pin
    }

    func saveFirstUse(_ pin: MusePeerPin) async throws {
        let data = try JSONEncoder().encode(pin)
        var query = keychainQuery(ownerID: pin.ownerID, vmID: pin.vmID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw MusePeerTrustError.pinStoreUnavailable }
    }

    private func keychainQuery(ownerID: String, vmID: String) -> [String: Any] {
        let identity = Data((ownerID + "\0" + vmID).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: digest
        ]
    }
}

private enum MuseCookieStoreError: Error {
    case invalidCookie
    case unavailable
}

private struct MuseStoredGatewayCredential: Codable {
    let viewerID: String
    let vmID: String
    let webSocketURL: String
}

/// Stores the browser-derived gateway URL only in device-local Keychain and
/// scopes it to the Muse account and VM from which it was imported.
private struct MuseGatewayCredentialStore: Sendable {
    private let service = "ai.muse.research.MuseWatch.gateway-credential"
    private let account = "preauthorized-websocket-url"

    func loadRecord() throws -> MuseStoredGatewayCredential? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(MuseStoredGatewayCredential.self, from: data) else {
            throw MuseCookieStoreError.unavailable
        }
        return credential
    }

    func load(viewerID: String, vmID: String) throws -> String? {
        guard let credential = try loadRecord(),
              credential.viewerID == viewerID,
              credential.vmID == vmID else { return nil }
        return credential.webSocketURL
    }

    func save(_ webSocketURL: String, viewerID: String, vmID: String) throws {
        guard webSocketURL.utf8.count <= 16_384,
              !webSocketURL.isEmpty,
              !viewerID.isEmpty,
              !vmID.isEmpty else {
            throw MuseCookieStoreError.unavailable
        }
        let data = try JSONEncoder().encode(MuseStoredGatewayCredential(
            viewerID: viewerID,
            vmID: vmID,
            webSocketURL: webSocketURL
        ))
        let status = SecItemUpdate(keychainQuery as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw MuseCookieStoreError.unavailable
            }
        } else if status != errSecSuccess {
            throw MuseCookieStoreError.unavailable
        }
    }

    func clear() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MuseCookieStoreError.unavailable
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum MuseCookieAuthenticatedFetch {
    private static let redirectDelegate = MuseWebRedirectDelegate()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }()

    static func fetch(
        _ request: MuseAuthenticatedHTTPRequest,
        cookieStore: MuseWebCookieStore
    ) async throws -> MuseAuthenticatedHTTPResponse {
        guard request.url.scheme == "https", request.url.host == "muse.ai" else {
            throw MuseCookieStoreError.unavailable
        }
        guard let cookie = try cookieStore.load(), !cookie.isEmpty else {
            throw MuseCookieStoreError.unavailable
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        urlRequest.setValue("https://muse.ai", forHTTPHeaderField: "Origin")
        urlRequest.setValue("https://muse.ai/", forHTTPHeaderField: "Referer")
        urlRequest.setValue("1", forHTTPHeaderField: "DNT")
        urlRequest.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        urlRequest.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        urlRequest.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (body, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw MuseCookieStoreError.unavailable
        }
        return MuseAuthenticatedHTTPResponse(statusCode: response.statusCode, body: body)
    }
}

private final class MuseWebRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https", request.url?.host == "muse.ai" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
