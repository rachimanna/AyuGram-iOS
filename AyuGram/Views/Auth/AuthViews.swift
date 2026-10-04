import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// First launch without built-in credentials: ask for api_id / api_hash (my.telegram.org).
struct ApiCredentialsView: View {
    @Environment(TelegramService.self) private var service
    @State private var apiId = ""
    @State private var apiHash = ""

    private var credentials: ApiCredentials? {
        guard let id = Int(apiId.trimmingCharacters(in: .whitespaces)) else { return nil }
        let c = ApiCredentials(apiId: id, apiHash: apiHash.trimmingCharacters(in: .whitespaces))
        return c.isValid ? c : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("api_id", text: $apiId)
                        .keyboardType(.numberPad)
                    TextField("api_hash", text: $apiHash)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text(L("ApiCredentialsHeader"))
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("ApiCredentialsFooter"))
                        Link("my.telegram.org", destination: URL(string: "https://my.telegram.org/apps")!)
                    }
                }
                Section {
                    Button(L("Continue")) {
                        if let credentials { service.provideCredentials(credentials) }
                    }
                    .disabled(credentials == nil)
                }
            }
            .navigationTitle(AyuConstants.appName)
        }
    }
}

struct AuthFlowView: View {
    @Environment(TelegramService.self) private var service
    /// "Wrong number?" — TDLib accepts a new phone number while waiting for the code.
    @State private var changingPhone = false

    var body: some View {
        NavigationStack {
            Group {
                switch service.authStep {
                case .phone: PhoneEntryView()
                case .code where changingPhone: PhoneEntryView(onSent: { changingPhone = false })
                case .code(let info): CodeEntryView(info: info, onChangePhone: { changingPhone = true })
                case .qr(let link): QrLoginView(link: link)
                case .password(let hint, _): PasswordEntryView(hint: hint)
                case .registration: RegistrationView()
                case .unsupported(let text):
                    ContentUnavailableView(L("AuthUnsupportedTitle"), systemImage: "exclamationmark.triangle", description: Text(text))
                default: ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Shared async-action helper with error display.
private struct AuthAction {
    @MainActor
    static func run(_ busy: Binding<Bool>, _ errorText: Binding<String?>, _ action: @escaping @MainActor () async throws -> Void) {
        busy.wrappedValue = true
        errorText.wrappedValue = nil
        Task { @MainActor in
            do {
                try await action()
            } catch {
                errorText.wrappedValue = TelegramService.describe(error)
            }
            busy.wrappedValue = false
        }
    }
}

struct PhoneEntryView: View {
    var onSent: (() -> Void)? = nil
    @Environment(TelegramService.self) private var service
    @State private var phone = "+"
    @State private var busy = false
    @State private var error: String?

    private var digits: String { phone.filter { $0.isNumber } }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    GhostGlyph().frame(width: 84, height: 84)
                    Text(L("YourPhone")).font(.title2.bold())
                    Text(L("StartText")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField(L("PhoneNumber"), text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.title3)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button {
                    AuthAction.run($busy, $error) {
                        try await service.sendPhone("+" + digits)
                        onSent?()
                    }
                } label: {
                    HStack { Text(L("Next")); if busy { Spacer(); ProgressView() } }
                }
                .disabled(digits.count < 7 || busy)
                Button(L("LoginWithQr")) {
                    AuthAction.run($busy, $error) { try await service.requestQr() }
                }
                .disabled(busy)
            }
        }
        .navigationTitle(AyuConstants.appName)
    }
}

struct CodeEntryView: View {
    let info: CodeInfo
    var onChangePhone: () -> Void = {}
    @Environment(TelegramService.self) private var service
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField(L("Code"), text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .focused($focused)
                    .onChange(of: code) { _, new in
                        if new.count == info.length && info.length > 0 { submit() }
                    }
            } header: {
                Text(info.phone)
            } footer: {
                VStack(alignment: .leading) {
                    Text(info.deliveredVia)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            Section {
                Button(L("Next")) { submit() }.disabled(code.isEmpty || busy)
                if info.canResend {
                    Button(L("ResendCode")) { AuthAction.run($busy, $error) { try await service.resendCode() } }
                }
                Button(L("WrongNumber")) { onChangePhone() }
            }
        }
        .navigationTitle(L("EnterCode"))
        .onAppear { focused = true }
    }

    private func submit() {
        AuthAction.run($busy, $error) { try await service.sendCode(code) }
    }
}

struct PasswordEntryView: View {
    let hint: String
    @Environment(TelegramService.self) private var service
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                SecureField(L("Password"), text: $password)
            } header: {
                Text(L("TwoStepVerification"))
            } footer: {
                VStack(alignment: .leading) {
                    if !hint.isEmpty { Text(LF("PasswordHint", hint)) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            Section {
                Button(L("Next")) {
                    AuthAction.run($busy, $error) { try await service.sendPassword(password) }
                }
                .disabled(password.isEmpty || busy)
            }
        }
        .navigationTitle(L("Password"))
    }
}

struct RegistrationView: View {
    @Environment(TelegramService.self) private var service
    @State private var first = ""
    @State private var last = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField(L("FirstName"), text: $first)
                TextField(L("LastName"), text: $last)
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
            Button(L("Next")) {
                AuthAction.run($busy, $error) { try await service.register(firstName: first, lastName: last) }
            }
            .disabled(first.isEmpty || busy)
        }
        .navigationTitle(L("YourName"))
    }
}

struct QrLoginView: View {
    let link: String
    @Environment(TelegramService.self) private var service

    var body: some View {
        VStack(spacing: 24) {
            if let image = Self.qr(link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(L("QrLoginTitle")).font(.title2.bold())
            Text(L("QrLoginSteps")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        }
        .padding()
        .navigationTitle(L("LoginWithQr"))
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
