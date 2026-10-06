import SwiftUI

/// Device-only cosmetics. This view never changes the account's server Premium flag.
struct LocalPremiumView: View {
    @Environment(AyuConfig.self) private var ayu
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(TelegramService.self) private var service
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var ayu = ayu
        @Bindable var appearance = appearance
        ScrollView {
            VStack(spacing: 24) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $ayu.localPremium) {
                        Label(L("PremiumEnable"), systemImage: "star.circle.fill")
                            .font(.headline)
                    }
                    Text(L("PremiumDeviceOnly"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .premiumCard()

                VStack(alignment: .leading, spacing: 16) {
                    Label(L("PremiumYourStyle"), systemImage: "paintpalette.fill").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                        ForEach(PremiumPalette.allCases) { palette in
                            Button {
                                appearance.premiumPalette = palette
                            } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(palette.gradient)
                                        .frame(height: 58)
                                        .overlay {
                                            if appearance.premiumPalette == palette {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.title2).foregroundStyle(.white)
                                            }
                                        }
                                    Text(palette.title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(palette.title)
                            .accessibilityAddTraits(appearance.premiumPalette == palette ? .isSelected : [])
                        }
                    }
                    Toggle(L("PremiumChatStyle"), isOn: $appearance.premiumChatStyle)
                    Text(L("PremiumStyleHint")).font(.footnote).foregroundStyle(.secondary)
                }
                .premiumCard()

                preview

                VStack(alignment: .leading, spacing: 18) {
                    feature("star.fill", "PremiumBadgeFeature", "PremiumBadgeDetail")
                    feature("paintbrush.pointed.fill", "PremiumStyleFeature", "PremiumStyleDetail")
                    feature("iphone", "PremiumPrivateFeature", "PremiumPrivateDetail")
                }
                .premiumCard()

                Label(L("PremiumServerNote"), systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Ayu Premium")
        .navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: ayu.localPremium)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: appearance.premiumPalette)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "star.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(appearance.premiumPalette.gradient, in: RoundedRectangle(cornerRadius: 32))
                .shadow(color: appearance.premiumPalette.colors[0].opacity(0.25), radius: 18, y: 8)
            Text("Ayu Premium").font(.largeTitle.bold())
            Text(L("PremiumHeroSubtitle"))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Label(L(ayu.localPremium ? "PremiumActive" : "PremiumFree"),
                  systemImage: ayu.localPremium ? "checkmark.circle.fill" : "sparkles")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(appearance.premiumPalette.gradient.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("PremiumPreview")).font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.largeTitle).foregroundStyle(appearance.premiumPalette.gradient)
                Text(service.users[service.myUserId]?.fullName ?? "AyuGram").font(.headline)
                if ayu.localPremium { PremiumBadge() }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(L("PremiumPreviewIncoming"))
                    .padding(12)
                    .background(Theme.incomingBubble, in: RoundedRectangle(cornerRadius: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("PremiumPreviewOutgoing"))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(appearance.outgoingStyle(localPremium: ayu.localPremium), in: RoundedRectangle(cornerRadius: 17))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: AppearanceSettings.validTextSize(appearance.messageTextSize)))
            .padding(14)
            .background { ChatBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .premiumCard()
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(appearance.premiumPalette.gradient)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.subheadline.bold())
                Text(L(detail)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct PremiumBadge: View {
    @Environment(AppearanceSettings.self) private var appearance
    var body: some View {
        Image(systemName: "star.fill")
            .foregroundStyle(appearance.premiumPalette.gradient)
            .accessibilityLabel(L("PremiumBadgeFeature"))
    }
}

struct PremiumSettingsCard: View {
    @Environment(AyuConfig.self) private var ayu
    @Environment(AppearanceSettings.self) private var appearance
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.fill").font(.title)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("Ayu Premium").font(.headline)
                Text(L(ayu.localPremium ? "PremiumActive" : "PremiumHeroSubtitle"))
                    .font(.caption).opacity(0.9)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold())
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.premiumPalette.gradient, in: RoundedRectangle(cornerRadius: 22))
    }
}

private extension View {
    func premiumCard() -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
