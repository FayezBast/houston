import SwiftUI
import HoustonCore

struct AccountsView: View {
    @ObservedObject var store: AccountStore
    let provider: Provider
    var defaultSnapshot: UsageSnapshot?
    var onEditing: (Bool) -> Void = { _ in }
    @State private var label = "Personal"
    @State private var key = ""
    @State private var adding = false
    @State private var connection: Task<Void, Never>?
    @FocusState private var editing: Bool

    var body: some View {
        if AccountProvider(rawValue: provider.rawValue) != nil {
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HoustonSectionHeading(title: "Accounts")
                    Text("Keep work and personal usage separate.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show in Houston").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("Show in Houston", selection: Binding(
                        get: { store.selectedAccount(for: provider)?.id },
                        set: { store.select($0, for: provider) })) {
                        Text("Existing connection").tag(Optional<UUID>.none)
                        ForEach(store.accounts(for: provider)) { account in Text(account.label).tag(Optional(account.id)) }
                    }.labelsHidden().controlSize(.regular).font(.system(size: 12)).frame(maxWidth: .infinity)
                }
                if !store.accounts(for: provider).isEmpty {
                    AccountComparisonView(store: store, provider: provider, defaultSnapshot: defaultSnapshot)
                    DisclosureGroup("Manage accounts") {
                        VStack(spacing: 10) {
                            ForEach(store.accounts(for: provider)) { account in
                                AccountControls(store: store, account: account, onEditing: onEditing)
                            }
                        }.padding(.top, 10)
                    }
                    .font(.system(size: 12))
                }
                DisclosureGroup("Add an account") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Account name", text: $label).focused($editing)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("New account name")
                        if provider == .openrouter {
                            SecureField("API key", text: $key).focused($editing).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("New account API key")
                            Button(adding ? "Checking…" : "Add account", action: connectKey)
                                .disabled(adding || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? UsageAccount.validatedLabel(label)) == nil)
                        } else {
                            Button("Sign in to \(provider.rawValue)…", action: connectBrowser)
                                .disabled((try? UsageAccount.validatedLabel(label)) == nil)
                        }
                    }.controlSize(.regular).padding(.top, 10)
                }
                .font(.system(size: 12))
                if let message = store.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("The selected account appears in Houston. Your app sign-ins stay the same.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: editing) { _, value in onEditing(value) }
            .onDisappear { connection?.cancel(); connection = nil; adding = false; onEditing(false) }
        }
    }

    private func connectBrowser() {
        let name = label
        let signIn = provider == .claude ? ProviderSignIn.claude : ProviderSignIn.cursor
        signIn.show(verified: { credential, snapshot in
            try store.add(provider: provider, label: name, credential: credential, snapshot: snapshot)
        })
    }

    private func connectKey() {
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label
        adding = true
        store.message = nil
        connection = Task {
            defer { adding = false; connection = nil }
            do {
                let snapshot = try await UsageAccountReader.read(provider: .openrouter, credential: Data(credential.utf8))
                try Task.checkCancellation()
                try store.add(provider: .openrouter, label: name, credential: credential, snapshot: snapshot)
                key = ""
                editing = false
            } catch is CancellationError { }
            catch { store.message = error.localizedDescription }
        }
    }
}

private struct AccountControls: View {
    @ObservedObject var store: AccountStore
    let account: UsageAccount
    var onEditing: (Bool) -> Void
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Account label", text: $name).textFieldStyle(.roundedBorder).focused($editing)
                .accessibilityLabel("Rename \(account.label)").onSubmit(rename)
            Button("Save", action: rename)
                .disabled(name == account.label || (try? UsageAccount.validatedLabel(name)) == nil)
                .accessibilityLabel("Save name for \(account.label)")
            Button(role: .destructive) {
                do { try store.remove(account.id) }
                catch { store.message = error.localizedDescription }
            } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                .buttonStyle(.borderless)
                .help("Remove \(account.label) from Houston")
                .accessibilityLabel("Remove \(account.label) from Houston")
        }.controlSize(.regular)
            .onAppear { name = account.label }
            .onChange(of: editing) { _, value in onEditing(value) }
            .onDisappear { onEditing(false) }
    }

    private func rename() {
        do { try store.rename(account.id, to: name); editing = false }
        catch { store.message = error.localizedDescription }
    }
}

struct AccountComparisonView: View {
    @ObservedObject var store: AccountStore
    let provider: Provider
    var defaultSnapshot: UsageSnapshot?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                if let defaultSnapshot {
                    accountCard(label: "Existing connection", snapshot: defaultSnapshot, error: nil,
                                selected: store.selectedAccount(for: provider) == nil, loading: false,
                                select: { store.select(nil, for: provider) })
                }
                ForEach(store.accounts(for: provider)) { account in
                    accountCard(label: account.label, snapshot: store.snapshots[account.id], error: store.errors[account.id],
                                selected: store.selectedAccount(for: provider)?.id == account.id,
                                loading: store.loading.contains(account.id),
                                select: { store.select(account.id, for: provider) })
                        .contextMenu {
                            Button("Refresh account", systemImage: "arrow.clockwise") { store.refresh(account.id) }
                                .disabled(store.loading.contains(account.id))
                            Button("Check connection", systemImage: "key") { store.refresh(account.id, allowInteraction: true) }
                                .disabled(store.loading.contains(account.id))
                        }
                }
            }.padding(.vertical, 2)
        }.scrollIndicators(.visible)
    }

    private func accountCard(label: String, snapshot: UsageSnapshot?, error: String?, selected: Bool, loading: Bool,
                             select: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 8) {
                    Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? provider.color : Color.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Show \(label) in Houston")
                .accessibilityValue(selected ? "Selected" : "Not selected")
            if let snapshot {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 5) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.name).foregroundStyle(.secondary).lineLimit(1)
                            Text(window.expired() || !window.used.isFinite ? "—" : "\(Int(window.remaining))% left").monospacedDigit()
                                .font(.system(size: 15, weight: .medium))
                        }.font(.system(size: 11))
                        if !window.expired(), window.used.isFinite {
                            ProgressView(value: window.remaining, total: 100).tint(provider.color)
                                .accessibilityLabel("\(window.name) allowance remaining")
                                .accessibilityValue("\(Int(window.remaining)) percent")
                        }
                        Text(window.countdown()).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let detail = snapshot.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.isStale || error != nil {
                    Label("Saved reading", systemImage: "clock").font(.system(size: 11)).foregroundStyle(.orange)
                }
            } else {
                Text(loading ? "Checking…" : "No reading yet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if loading {
                Text("Updating…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 184, alignment: .topLeading)
        .background(selected ? provider.color.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? provider.color.opacity(contrast == .increased ? 0.8 : 0.4) : Color.primary.opacity(contrast == .increased ? 0.35 : 0))
                .allowsHitTesting(false)
        }
    }
}
