import SwiftUI
import BudgetKit

/// Share the House space with your partner: sign in, then start a household or join one with
/// the partner's invite code. Uses the same free Supabase project as the web app.
struct SharingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var code = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var needsHousehold = false
    @State private var info: String?

    var body: some View {
        let _ = model.syncState // redraw when sync starts, stops or fails
        Form {
            if let sync = model.sync {
                if sync.isConnected {
                    connected(sync)
                } else if needsHousehold || sync.client.session != nil {
                    household(sync)
                } else {
                    signIn(sync)
                }
            } else {
                Section {
                    Text("Sharing is not switched on in this version of the app yet. It needs the address of the free online database the web app uses (Supabase).")
                } footer: {
                    Text("Everything still works on this phone. Use Settings > Backup to move data between phones meanwhile.")
                }
            }
            if let problem { Section { Text(problem).foregroundStyle(.red).accessibilityIdentifier("sharingProblem") } }
            if let info { Section { Text(info) } }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .navigationTitle("Share with partner")
        .onAppear { if name.isEmpty { name = model.store.currentUser.name } }
    }

    func signIn(_ sync: SyncEngine) -> some View {
        Section {
            TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
            SecureField("Password (at least 6 characters)", text: $password).textContentType(.password)
            Button("Sign in") { run { if try await sync.signIn(email: email, password: password) == .needsHousehold { needsHousehold = true } } }
            Button("Create an account") {
                run {
                    let signedIn = try await sync.signUp(email: email, password: password)
                    if signedIn { needsHousehold = true } else { info = "Check your email to confirm the account, then sign in here." }
                }
            }
        } header: {
            Text("Sign in")
        } footer: {
            Text("Use the same account as in the web app. Your Personal space stays private; only the House space is shared.")
        }
    }

    func household(_ sync: SyncEngine) -> some View {
        Group {
            Section {
                TextField("Your name", text: $name)
            }
            Section {
                Button("Start sharing (I'm the first one)") {
                    run { _ = try await sync.createHousehold(displayName: name.isEmpty ? "Me" : name) }
                }
            } footer: {
                Text("You get an invite code to give your partner.")
            }
            Section {
                TextField("Invite code from your partner", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Join my partner") { run { try await sync.joinHousehold(code: code, displayName: name.isEmpty ? "Me" : name) } }
            }
            Section { Button("Sign out", role: .destructive) { run { await sync.signOut(); needsHousehold = false } } }
        }
    }

    func connected(_ sync: SyncEngine) -> some View {
        Group {
            Section {
                LabeledContent("Status", value: status(sync))
                if let last = sync.meta.lastSyncAt, let d = ISO8601DateFormatter.withFractions.date(from: last) {
                    LabeledContent("Last synced", value: d.formatted(date: .omitted, time: .shortened))
                }
                Button("Sync now") { run { try await sync.syncNow() } }
            }
            if let code = model.s.data.settings.inviteCode, model.s.data.users.count < 2 {
                Section {
                    Text(code).font(.title.monospaced()).textSelection(.enabled)
                    ShareLink(item: "Join my budget: open Settings > Share with partner and enter the code \(code)")
                } header: { Text("Invite code") } footer: { Text("Your partner signs in on their phone and enters this code.") }
            }
            Section { Button("Sign out", role: .destructive) { run { await sync.signOut() } } } footer: {
                Text("Your data stays on this phone. Sign in again to keep sharing.")
            }
        }
    }

    func status(_ sync: SyncEngine) -> String {
        switch model.syncState {
        case .syncing: return "Syncing…"
        case .error(let e): return e
        default: return sync.pendingCount > 0 ? "\(sync.pendingCount) changes waiting" : "Up to date"
        }
    }

    func run(_ work: @escaping () async throws -> Void) {
        busy = true
        problem = nil
        Task {
            do { try await work() } catch { problem = error.localizedDescription }
            busy = false
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
