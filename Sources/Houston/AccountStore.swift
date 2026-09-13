import Foundation
import Combine
import HoustonCore

@MainActor final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [UsageAccount] = []
    @Published private(set) var selected: [String: UUID] = [:]
    @Published private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published var message: String?
    var onSelectionChanged: ((Provider) -> Void)?
    var onSnapshot: ((UsageAccount, UsageSnapshot) -> Void)?
    var onFailure: ((UsageAccount, String) -> Void)?
    private let file: URL
    private let reader: @Sendable (UsageAccount, Bool) async throws -> UsageSnapshot
    private let saveSecret: (String, String) throws -> Void
    private let removeSecret: (String) throws -> Void
    private var requests: [UUID: UUID] = [:]
    private var loadFailed = false

    static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Houston/accounts.json")
    }

    init(file: URL = AccountStore.defaultFile,
         reader: @escaping @Sendable (UsageAccount, Bool) async throws -> UsageSnapshot = { try await UsageAccountReader.read($0, allowInteraction: $1) },
         saveSecret: @escaping (String, String) throws -> Void = { try SecretStore.save($0, account: $1) },
         removeSecret: @escaping (String) throws -> Void = { try SecretStore.remove(account: $0) }) {
        self.file = file
        self.reader = reader
        self.saveSecret = saveSecret
        self.removeSecret = removeSecret
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let catalog = try JSONDecoder().decode(UsageAccountCatalog.self, from: Data(contentsOf: file)).validated()
            accounts = catalog.accounts
            selected = catalog.selected
        } catch {
            loadFailed = true
            message = "Could not load saved accounts. Existing credentials and the account file were left unchanged. \(error.localizedDescription)"
        }
    }

    func accounts(for provider: Provider) -> [UsageAccount] { accounts.filter { $0.provider.rawValue == provider.rawValue } }

    func selectedAccount(for provider: Provider) -> UsageAccount? {
        accounts.first { $0.id == selected[provider.rawValue] && $0.provider.rawValue == provider.rawValue }
    }

    private func persist(_ accounts: [UsageAccount], selected: [String: UUID]) throws {
        guard !loadFailed else { throw UsageError.unavailable("Repair the saved accounts file before changing accounts.") }
        let catalog = try UsageAccountCatalog(accounts: accounts, selected: selected).validated()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: file, options: .atomic)
    }

    /// The sign-in window verifies usage before committing a unique credential. Legacy items stay intact.
    @discardableResult
    func add(provider: Provider, label: String, credential: String, snapshot: UsageSnapshot) throws -> UsageAccount {
        guard !loadFailed else { throw UsageError.unavailable("Repair the saved accounts file before changing accounts.") }
        guard let provider = AccountProvider(rawValue: provider.rawValue) else {
            throw UsageError.unavailable("This provider uses its local app sign-in.")
        }
        let account = try UsageAccount(provider: provider, label: label)
        try saveSecret(credential, account.keychainAccount)
        var selection = selected
        selection[provider.rawValue] = account.id
        do { try persist(accounts + [account], selected: selection) }
        catch {
            try? removeSecret(account.keychainAccount)
            throw error
        }
        accounts.append(account)
        selected = selection
        snapshots[account.id] = snapshot
        message = nil
        onSelectionChanged?(Provider(rawValue: provider.rawValue)!)
        onSnapshot?(account, snapshot)
        return account
    }

    func rename(_ id: UUID, to label: String) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updated = accounts
        updated[index].label = try UsageAccount.validatedLabel(label)
        try persist(updated, selected: selected)
        accounts = updated
        message = nil
    }

    func select(_ id: UUID?, for provider: Provider) {
        guard id == nil || accounts.contains(where: { $0.id == id && $0.provider.rawValue == provider.rawValue }),
              selected[provider.rawValue] != id else { return }
        var updated = selected
        updated[provider.rawValue] = id
        do {
            try persist(accounts, selected: updated)
            selected = updated
            message = nil
            onSelectionChanged?(provider)
        } catch { message = error.localizedDescription }
    }

    func remove(_ id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let updated = accounts.filter { $0.id != id }
        var selection = selected
        let wasSelected = selection[account.provider.rawValue] == id
        if wasSelected { selection[account.provider.rawValue] = nil }
        // Persist first: a failed disk write must never delete a still-referenced credential.
        try persist(updated, selected: selection)
        do { try removeSecret(account.keychainAccount) }
        catch {
            try persist(accounts, selected: selected)
            throw error
        }
        requests[id] = nil
        loading.remove(id)
        accounts = updated
        selected = selection
        snapshots[id] = nil
        errors[id] = nil
        message = nil
        if wasSelected { onSelectionChanged?(Provider(rawValue: account.provider.rawValue)!) }
    }

    func refreshAll(enabled: Set<Provider>) {
        for account in accounts where enabled.contains(Provider(rawValue: account.provider.rawValue)!) { refresh(account.id) }
    }

    @discardableResult
    func refresh(_ id: UUID, allowInteraction: Bool = false) -> Task<Void, Never>? {
        guard let account = accounts.first(where: { $0.id == id }), !loading.contains(id) else { return nil }
        let request = UUID()
        requests[id] = request
        loading.insert(id)
        let read = reader
        return Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<UsageSnapshot, Error> in
                do { return .success(try await read(account, allowInteraction)) }
                catch { return .failure(error) }
            }.value
            guard let self, requests[id] == request, accounts.contains(where: { $0.id == id }) else { return }
            requests[id] = nil
            loading.remove(id)
            switch result {
            case .success(let snapshot):
                snapshots[id] = snapshot
                errors[id] = nil
                onSnapshot?(account, snapshot)
            case .failure(let error):
                errors[id] = error.localizedDescription
                onFailure?(account, error.localizedDescription)
            }
        }
    }

    func invalidate(provider: Provider) {
        for account in accounts(for: provider) {
            requests[account.id] = nil
            loading.remove(account.id)
        }
    }

    func stop() {
        requests.removeAll()
        loading.removeAll()
    }
}
