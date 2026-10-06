# AyuGram iOS 0.2.0

## Privacy and local security

- Per-dialog ghost overrides (inherit/on/off), with a swipe action and a chat settings screen.
- Independent suppression of outgoing text typing; optional hiding of the user's own presence and phone number in this client's UI.
- Per-message delayed read receipts or manual receipts. Closing the dialog, locking or backgrounding cancels pending reads. The explicit Read All action remains available.
- Independent application PIN, biometric unlock, timeout, app-switcher curtain and an empty decoy interface. Salted PBKDF2-SHA256 records use ThisDeviceOnly Keychain and retry throttling.
- A separate shared vault PIN protects selected chats and Telegram folders. Protected dialogs are filtered in search, archives, contacts, forwarding, exports, call logs and badge counts, and navigation routes enforce access.
- New outgoing messages can be deleted for everyone on a durable per-dialog timer. Disabling it cancels queued jobs; failed requests retry and report errors.

Presence is an account-wide Telegram property: opening a ghost dialog requests offline presence for the whole account. Local profile hiding does not change server privacy settings. PIN protection gates the UI; the Telegram/AyuGram databases are not encrypted with this PIN. A local timer cannot execute while iOS has suspended or terminated the process and is processed when execution resumes.

## History

- Unified Deleted feed with pagination and links to the original dialogs.
- Existing copied attachments continue to support photos, videos, round videos, audio and documents.
- Character-safe text differences highlight insertions and removals in edit history.
- Optional notifications of saved incoming edits/deletions, with redacted content when local protection applies.
- TXT/JSON export of deleted messages and revisions, including export of one message's complete edit history.
- Opt-in archive of disappearing media that was explicitly opened, fully downloaded and copied before expiry. Already missing files are not recoverable.
- Account-scoped local call journal populated by received TDLib call updates and call service messages. Removing a Telegram call message does not remove this local record. No call audio/video engine is added.
- Transactional schema 1→2 migration adds retained media and a feed index without deleting existing history.

## Appearance

- Ten icon choices: Classic, Filled, Sunset, Aqua, Rose, Forest, Midnight, Gold, Mono, Lavender.
- Per-chat color/photo wallpapers, rounded/square avatars, compact chat list, existing font slider.
- Custom accent via palette or HEX, local emoji status and animated own-name gradient.
- Optional Contacts and Calls tabs; Chats and Settings stay available.
- Motion switch disables SwiftUI animation transactions and animated identity rendering; Reduce Motion is respected.

There was no Stories tab in the baseline project, so no tab removal was necessary.

## Platform boundaries

iOS posts screenshot notifications after capture. This version shields secret chats during detected recording/mirroring and reports detected screenshots through TDLib. It does not claim to block screenshots. The same curtain covers presented media and sheets while inactive.

Local emoji/name effects and Local Premium do not grant server Premium privileges. History is limited to messages/events observed by this client and media downloaded before removal. Retained media remains in Documents/Saved Attachments and can be cleared with the existing Ayu database cleanup.

## Validation

GitHub Actions runs only when manually dispatched or when a complete draft PR is explicitly marked ready for review. Commit uploads do not start builds. It builds a simulator test target, executes the tests, builds the unsigned device application and packages an IPA. New tests cover per-chat policies, account separation, folder protection, PIN hashing, Unicode differences and non-destructive database migration. Actual Face ID, screenshot reporting, icon switching, background timing and Telegram delivery must additionally be exercised on a physical iPhone using the scenarios below.

1. Enable app/vault/decoy PINs; test wrong PIN throttling, background timeout, cold launch, biometrics and returning from the empty interface.
2. Protect a chat and folder; check search, archive, contacts, forwarding, exported files and notification deep links before/after vault unlock.
3. In two dialogs set ghost on/off; verify read/typing requests from another Telegram client. Set delayed/manual receipts, exit before expiry and repeat after backgrounding.
4. Edit/delete an incoming message with downloaded photo/voice/video-note attachments; browse the unified feed, differences and TXT/JSON exports.
5. Open disappearing media before expiry; verify the copied file when TDLib makes the full file available. Test a screenshot and screen recording in a secret chat.
6. Set a timer, send a message, restart and verify deletion/error reporting after resumption. Disable the timer and confirm queued jobs stop.
7. Switch each icon, import/reset wallpaper, try both avatar shapes, custom HEX, compact layout, hidden tabs and disabled motion.
