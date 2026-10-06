# AyuGram 0.3: Telegram chat features

This combined version preserves the 0.2 privacy settings, per-chat ghost mode, history,
local security, appearance, name, icons and Local Premium. It also brings the independent
media/stories work into the same version, rather than replacing the privacy branch.

## Implemented

- Voice recording: microphone permission, stop, local preview, retry, explicit send, cancellation
  on dismissal. Mono AAC/M4A is accepted by the pinned TDLib API. Playback detects Ogg by its
  header, so M4A is no longer mistakenly passed to the Opus decoder.
- Video selection from Photos and conversion to streaming MP4 before sending. Video dimensions
  are read from the exported file. Large videos use file transfers instead of loading all bytes.
- Poll and quiz creation, anonymous/multiple choices, voting, retraction, live poll updates.
  Telegram limits where polls can be posted; the UI offers them in groups/channels/bots/Saved Messages.
- Add/remove emoji reactions with server errors displayed; pin/unpin messages.
- Search in a chat, media/files/links/pinned filters, pagination, jump to results.
  Secret chats use the separate TDLib secret-search method. Ayu message filters are respected.
- Silent text sending, exact scheduled date, scheduled message list, send now and deletion.
  An explicit date overrides Ayu's 12-second mode for that request, without changing the global setting.
- Editing media captions (including removing captions), as well as text messages.
- Installed/recent/favorite sticker picker with query search.
- Gzip/TGS Lottie playback and inline MP4 GIF animation from the media branch. Reduced-motion,
  visibility and background playback policies are retained. WebM stickers still use thumbnails.
- Story viewing from the media branch. Hidden/locked chats stay excluded. Opening stories follows
  per-chat read policy; this is not a guarantee of invisible viewing in all server-side scenarios.
- Bot inline URL/callback/copy/user buttons and ordinary text reply keyboards. Unsupported buttons
  (payments, login URLs, Web Apps, account/contact/location sharing) remain disabled. Deleted-message
  keyboards never invoke callbacks.

## Size target

Release uses `-Osize`, dead-code stripping, arm64 device builds and maximum ZIP compression.
CI attaches `AyuGram-size-report.json`, which reports compressed IPA bytes and installed app bytes
separately, lists the largest files, and checks a target of 70,000,000 bytes for the IPA.

70 MB is a target, not a verified result before building. Telegram media/cache and later signing
can change storage consumption. Dependency sizes cannot be inferred from repository source size.
No Telegram functions, languages or Ayu assets are removed merely to meet this number.

## Remaining parity gaps

This remains a custom TDLib/SwiftUI client, not the complete official Telegram iOS codebase.
Voice/video calls, live group calls, story posting/editing, Mini Apps and payments, full inline bots,
multiple account lifecycle, separate forum-topic navigation, group/channel administration and
complete server privacy/settings flows are not implemented. There is no claim of full Telegram parity.

## Validation

Local Swift syntax, YAML, localization and IPA-report checks are followed by one combined CI run
(simulator tests and unsigned device build). Physical-device validation is still required for microphone
permissions, recording interruptions, Photos imports, playback, real bot callbacks and server features.
