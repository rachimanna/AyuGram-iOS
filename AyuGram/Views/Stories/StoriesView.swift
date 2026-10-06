import AVKit
import SwiftUI

struct StoriesStrip: View {
    @Environment(TelegramService.self) private var service
    @State private var selected: ChatStoryGroup?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(service.orderedStoryGroups) { group in
                    let chat = service.chats[group.id]
                    Button { selected = group } label: {
                        VStack(spacing: 5) {
                            AvatarView(id: group.id, title: chat?.title ?? service.chatTitle(group.id),
                                       photo: chat?.photo, size: 56)
                                .padding(4)
                                .overlay(Circle().stroke(group.hasUnread ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 2))
                            Text(chat?.title ?? service.chatTitle(group.id))
                                .font(.caption).lineLimit(1).frame(width: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if group.id == service.orderedStoryGroups.last?.id {
                            Task { await service.loadMoreStories() }
                        }
                    }
                }
                if service.storiesLoading { ProgressView().frame(width: 50) }
                else if !service.storiesLoadedAll {
                    Button { Task { await service.loadMoreStories() } } label: {
                        Label(L(service.storiesError == nil ? "StoriesMore" : "Retry"), systemImage: "arrow.clockwise")
                    }
                    .font(.caption)
                }
            }
            .padding(12)
        }
        .accessibilityLabel(L("Stories"))
        .fullScreenCover(item: $selected) { group in
            StoryViewer(group: group).environment(service)
        }
    }
}

private struct StoryViewer: View {
    let group: ChatStoryGroup
    @Environment(TelegramService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if group.references.indices.contains(index) {
                StoryPage(reference: group.references[index])
                    .id(group.references[index].id)
            }
            VStack {
                HStack(spacing: 3) {
                    ForEach(group.references.indices, id: \.self) { i in
                        Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.3)).frame(height: 3)
                    }
                }
                HStack {
                    Text(service.chatTitle(group.id)).font(.headline).lineLimit(1)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .accessibilityLabel(L("Done"))
                }
                Spacer()
                HStack {
                    Button { index = max(0, index - 1) } label: {
                        Label(L("StoryPrevious"), systemImage: "chevron.left")
                    }
                    .disabled(index == 0)
                    Spacer()
                    Button {
                        if index + 1 < group.references.count { index += 1 }
                        else { dismiss() }
                    } label: {
                        Label(L("StoryNext"), systemImage: "chevron.right")
                    }
                }
                .padding(.vertical, 10)
            }
            .padding()
            .allowsHitTesting(true)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .onAppear { index = group.firstUnreadIndex }
        .onChange(of: service.storyGroups[group.id]?.references) { _, references in
            // A deleted story must disappear from an already open viewer as well.
            if let current = group.references.indices.contains(index) ? group.references[index] : nil,
               references?.contains(current) != true { dismiss() }
        }
    }
}

private struct StoryPage: View {
    let reference: StoryReference
    @Environment(TelegramService.self) private var service
    @Environment(\.scenePhase) private var scenePhase
    @State private var item: StoryItem?
    @State private var errorText: String?
    @State private var attempt = 0
    @State private var player: AVPlayer?

    var body: some View {
        let path = service.files.path(for: item?.file)
        let viewing = path != nil && scenePhase == .active
        ZStack {
            if let item {
                switch item.content {
                case .photo(let photo):
                    MediaImage(file: photo.file, thumb: photo.thumb, contentMode: .fit, maxPixel: 2048)
                case .video(let video):
                    if let player { VideoPlayer(player: player).padding(.vertical, 90) }
                    else { MediaImage(file: video.thumb?.file, thumb: video.thumb, contentMode: .fit) }
                case .unsupported:
                    Text(L("StoryUnsupported")).padding()
                }
                if item.file != nil && path == nil {
                    VStack {
                        ProgressView().tint(.white)
                        Button(L("Retry")) { if let file = item.file { service.files.download(file) } }
                    }
                }
            } else if let errorText {
                VStack(spacing: 12) {
                    Text(errorText).multilineTextAlignment(.center)
                    Button(L("Retry")) { attempt += 1 }
                }
                .padding(30)
            } else { ProgressView().tint(.white) }
        }
        .overlay(alignment: .bottom) {
            if let caption = item?.caption, !caption.isEmpty {
                ScrollView {
                    Text(RichTextRenderer.attributed(caption, linkColor: .white,
                                                     revealSpoilers: false, fontSize: 16))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(.black.opacity(0.65))
                .padding(.bottom, 70)
            }
        }
        .task(id: attempt) {
            errorText = nil
            do {
                let result = try await service.story(reference)
                guard !Task.isCancelled else { return }
                item = result
                service.files.request(result.file, priority: 16)
            } catch {
                guard !Task.isCancelled else { return }
                errorText = TelegramService.describe(error)
            }
        }
        .task(id: path) {
            player?.pause()
            player = nil
            if let path, case .video = item?.content {
                player = AVPlayer(url: MediaViewer.playableURL(for: path))
                if scenePhase == .active { player?.play() }
            }
        }
        .task(id: viewing) {
            guard viewing else { return }
            let opened = await service.openStory(reference)
            defer {
                if opened { Task { await service.closeStory(reference) } }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { break }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}
