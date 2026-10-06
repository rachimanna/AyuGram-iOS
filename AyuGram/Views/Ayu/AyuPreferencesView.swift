/*
 * Port of AyuGramPreferencesActivity / MessageSavingPreferencesActivity /
 * RegexFiltersPreferencesActivity / RegexFilterEditActivity / AyuSyncPreferencesActivity
 * (Copyright @Radolyn, 2023, GPL-2.0). Same sections, rows and order as on Android.
 */

import SwiftUI

struct AyuPreferencesView: View {
    @Environment(AyuConfig.self) private var config
    @State private var confirmClear = false
    @State private var stats: AyuDatabase.Stats?
    @State private var toast: String?

    var body: some View {
        @Bindable var config = config
        Form {
            // ~ Ghost essentials
            Section(L("GhostEssentialsHeader")) {
                Toggle(isOn: Binding(get: { config.isGhostModeActive }, set: { config.setGhostMode($0) })) {
                    Label { Text(L("GhostModeToggle")).bold() } icon: { GhostGlyph(active: config.isGhostModeActive).frame(width: 22, height: 22) }
                }
                Toggle(L("DontSendReadPackets"), isOn: inverted($config.sendReadPackets))
                Toggle(L("DontSendOnlinePackets"), isOn: inverted($config.sendOnlinePackets))
                Toggle(L("DontSendUploadProgress"), isOn: inverted($config.sendUploadProgress))
                Toggle(L("SendOfflinePacketAfterOnline"), isOn: $config.sendOfflinePacketAfterOnline)
                Toggle(L("MarkReadAfterSend"), isOn: $config.markReadAfterSend)
                    .disabled(config.sendReadPackets)
                Toggle(isOn: $config.useScheduledMessages) {
                    VStack(alignment: .leading) {
                        Text(L("UseScheduledMessages"))
                        Text(L("UseScheduledMessagesHint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // ~ Spy essentials
            Section(L("SpyEssentialsHeader")) {
                Toggle(L("SaveDeletedMessages"), isOn: $config.saveDeletedMessages)
                Toggle(L("SaveMessagesHistory"), isOn: $config.saveMessagesHistory)
                NavigationLink(L("MessageSavingBtn")) { MessageSavingPreferencesView() }
            }

            // ~ Useful features
            Section {
                Toggle(isOn: $config.keepAliveService) {
                    VStack(alignment: .leading) {
                        Text(L("KeepAliveService"))
                        Text(L("KeepAliveServiceHintIOS")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: config.keepAliveService) { _, _ in NotificationService.scheduleBackgroundRefresh() }
                Toggle(L("DisableAds"), isOn: $config.disableAds)
                Toggle(isOn: $config.localPremium) {
                    VStack(alignment: .leading) {
                        Text(L("LocalPremium"))
                        Text(L("LocalPremiumHint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { LocalPremiumView() } label: {
                    Label(L("PremiumCustomize"), systemImage: "paintpalette.fill")
                }
                NavigationLink {
                    RegexFiltersView()
                } label: {
                    LabeledContent(L("RegexFilters"), value: "\(config.regexFilters.count) \(L("RegexFiltersAmount"))")
                }
            } header: {
                Text(L("QoLTogglesHeader"))
            }

            // ~ Customization
            Section(L("CustomizationHeader")) {
                LabeledContent(L("DeletedMarkText")) {
                    TextField(AyuConstants.defaultDeletedMark, text: $config.deletedMarkText)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(L("EditedMarkText")) {
                    TextField(L("EditedMessage"), text: $config.editedMarkText)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(L("ShowGhostToggleInDrawer"), isOn: $config.showGhostToggleInDrawer)
                Toggle(L("ShowKllButtonInDrawer"), isOn: $config.showKillButtonInDrawer)
            }

            // ~ AyuSync
            Section(L("AyuSyncHeader")) {
                NavigationLink {
                    AyuSyncPreferencesView()
                } label: {
                    LabeledContent(L("AyuSyncStatusTitle"), value: AyuSyncController.shared.state.localized)
                }
            }

            // ~ Debug
            Section {
                Toggle(isOn: $config.walMode) {
                    VStack(alignment: .leading) {
                        Text(L("WALMode"))
                        Text(L("RestartRequired")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let stats {
                    LabeledContent(L("AyuDbDeletedCount"), value: "\(stats.deleted)")
                    LabeledContent(L("AyuDbRevisionsCount"), value: "\(stats.revisions)")
                    LabeledContent(L("AyuDbCachedCount"), value: "\(stats.cached)")
                }
                Button(L("ClearAyuDatabase"), role: .destructive) { confirmClear = true }
            } header: {
                Text(L("SettingsDebug"))
            }
        }
        .navigationTitle(L("AyuPreferences"))
        .task { AyuMessagesController.shared.stats { stats = $0 } }
        .confirmationDialog(L("ClearAyuDatabaseConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("EraseLocalDatabase"), role: .destructive) {
                AyuMessagesController.shared.clean {
                    toast = L("ClearAyuDatabaseNotification")
                    AyuMessagesController.shared.stats { stats = $0 }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).padding(12).background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.toast = nil
                    }
            }
        }
    }

    private func inverted(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !binding.wrappedValue }, set: { binding.wrappedValue = !$0 })
    }
}

/// MessageSavingPreferencesActivity
struct MessageSavingPreferencesView: View {
    @Environment(AyuConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                Toggle(L("MessageSavingSaveMedia"), isOn: $config.saveMedia)
                Group {
                    Toggle(L("MessageSavingSaveMediaInPrivateChats"), isOn: $config.saveMediaInPrivateChats)
                    Toggle(L("MessageSavingSaveMediaInPublicChannels"), isOn: $config.saveMediaInPublicChannels)
                    Toggle(L("MessageSavingSaveMediaInPrivateChannels"), isOn: $config.saveMediaInPrivateChannels)
                    Toggle(L("MessageSavingSaveMediaInPublicGroups"), isOn: $config.saveMediaInPublicGroups)
                    Toggle(L("MessageSavingSaveMediaInPrivateGroups"), isOn: $config.saveMediaInPrivateGroups)
                }
                .disabled(!config.saveMedia)
                .padding(.leading, 12)
            } footer: {
                Text(L("MessageSavingSaveMediaHintIOS"))
            }
            Section(L("General")) {
                Toggle(L("MessageSavingSaveFormatting"), isOn: $config.saveFormatting)
                Toggle(L("MessageSavingSaveReactions"), isOn: $config.saveReactions)
                Toggle(L("MessageSavingSaveForBots"), isOn: $config.saveForBots)
            }
        }
        .navigationTitle(L("MessageSavingBtn"))
    }
}

/// RegexFiltersPreferencesActivity + RegexFilterEditActivity
struct RegexFiltersView: View {
    @Environment(AyuConfig.self) private var config
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        var index: Int?   // nil = new filter
        var text: String
        var id: String { "\(index ?? -1)" }
    }

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                Toggle(L("RegexFiltersEnable"), isOn: $config.regexFiltersEnabled)
                Toggle(L("RegexFiltersInChats"), isOn: $config.regexFiltersInChats)
                Toggle(L("RegexFiltersCaseInsensitive"), isOn: $config.regexFiltersCaseInsensitive)
            } footer: {
                Text(L("RegexFiltersHint"))
            }
            Section(L("RegexFilters")) {
                Button { editing = EditTarget(index: nil, text: "") } label: { Label(L("RegexFiltersAdd"), systemImage: "plus") }
                ForEach(Array(config.regexFilters.enumerated()), id: \.offset) { index, filter in
                    Button { editing = EditTarget(index: index, text: filter) } label: {
                        HStack {
                            Text(filter).font(.body.monospaced()).foregroundStyle(.primary).lineLimit(2)
                            if AyuFilter.validate(filter) != nil {
                                Spacer()
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete { offsets in offsets.sorted(by: >).forEach { config.removeFilter(at: $0) } }
            }
        }
        .navigationTitle(L("RegexFilters"))
        .sheet(item: $editing) { target in
            RegexFilterEditView(initial: target.text) { text in
                if let i = target.index { config.editFilter(at: i, text) } else { config.addFilter(text) }
            }
        }
    }
}

struct RegexFilterEditView: View {
    let initial: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sample = ""

    private var error: String? { AyuFilter.validate(text) }

    private var sampleMatches: Bool? {
        guard error == nil, !sample.isEmpty else { return nil }
        return AyuFilter.matches(sample, patterns: AyuFilter.compile([text], caseInsensitive: AyuConfig.shared.regexFiltersCaseInsensitive))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("RegexFilterPattern"), text: $text, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let error, !text.isEmpty { Text(error).foregroundStyle(.red) }
                }
                Section(L("RegexFilterTest")) {
                    TextField(L("RegexFilterSample"), text: $sample, axis: .vertical)
                    if let sampleMatches {
                        Label(sampleMatches ? L("RegexFilterMatches") : L("RegexFilterNoMatch"),
                              systemImage: sampleMatches ? "eye.slash" : "eye")
                            .foregroundStyle(sampleMatches ? Color.orange : Color.green)
                    }
                }
            }
            .navigationTitle(initial.isEmpty ? L("RegexFiltersAdd") : L("RegexFiltersEdit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
            .onAppear { text = initial }
        }
    }
}

/// AyuSyncPreferencesActivity
struct AyuSyncPreferencesView: View {
    @Environment(AyuConfig.self) private var config
    @State private var sync = AyuSyncController.shared

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                LabeledContent(L("AyuSyncStatusTitle"), value: sync.state.localized)
                if let code = sync.registerStatusCode { LabeledContent(L("AyuSyncRegisterStatus"), value: "\(code)") }
                if let d = sync.lastSent { LabeledContent(L("AyuSyncLastSent"), value: d.formatted(date: .abbreviated, time: .standard)) }
                if let d = sync.lastReceived { LabeledContent(L("AyuSyncLastReceived"), value: d.formatted(date: .abbreviated, time: .standard)) }
            }
            Section {
                Toggle(L("AyuSyncEnable"), isOn: $config.syncEnabled)
                LabeledContent(L("AyuSyncServerURL")) {
                    TextField(AyuConstants.defaultAyuSyncServer, text: $config.syncServerURL)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                LabeledContent(L("AyuSyncServerToken")) {
                    SecureField("token", text: $config.syncServerToken).multilineTextAlignment(.trailing)
                }
                Toggle(L("AyuSyncUseSecureConnection"), isOn: $config.useSecureConnection)
            } footer: {
                Text(L("AyuSyncHint"))
            }
            Section {
                Button(L("AyuSyncReconnect")) { sync.restart() }
                Button(L("AyuSyncForceSync")) { Task { await sync.forceSync() } }
                    .disabled(sync.state != .connected)
                if let url = sync.profileURL, !config.syncServerToken.isEmpty {
                    Link(L("AyuSyncOpenProfile"), destination: url)
                }
            }
        }
        .navigationTitle("AyuSync")
        .onChange(of: config.syncEnabled) { _, _ in sync.restart() }
    }
}

extension AyuSyncConnectionState {
    var localized: String {
        switch self {
        case .disconnected: return L("AyuSyncStateDisconnected")
        case .connecting: return L("AyuSyncStateConnecting")
        case .connected: return L("AyuSyncStateConnected")
        case .error: return L("AyuSyncStateError")
        }
    }
}
