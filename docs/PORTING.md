# Как AyuGram4A перенесён на iOS

Исходник: `AyuGram/AyuGram4A` (последний коммит 7013145, 28.07.2023).
Цель порта — нативное iOS-приложение (Swift, SwiftUI/UIKit), а не обёртка над Android-кодом.

## 1. Архитектура оригинала

```
AyuGram4A
├── TMessagesProj/jni/                 C++: tgnet (MTProto), opus, ffmpeg, webp, rlottie …
├── TMessagesProj/src/main/java/
│   ├── org/telegram/…                 Telegram Android (DrKLO): ~600 тыс. строк Java
│   │     messenger/MessagesController, MessagesStorage (SQLite), SendMessagesHelper,
│   │     tgnet/ConnectionsManager, ui/ (ChatActivity, DialogsActivity, ProfileActivity …)
│   ├── com/exteragram/…               exteraGram: настройки, Monet-тема, утилиты
│   └── com/radolyn/ayugram/…          AyuGram: ~5 200 строк + ~40 хуков в коде Telegram
└── schemas/…AyuDatabase               Room-схема AyuGram
```

Модули AyuGram (`com.radolyn.ayugram`):

| Android | Назначение |
|---|---|
| `AyuConfig` | ~30 настроек (SharedPreferences `ayuconfig`) |
| `utils/AyuGhostUtils`, `utils/AyuState` | режим призрака, разовые «разрешения» пакетов |
| `messages/AyuMessagesController`, `AyuSavePreferences` | сохранение удалённых сообщений и истории правок |
| `database/*` (Room) | `DeletedMessage`, `EditedMessage`, `DeletedMessageReaction` |
| `AyuFilter` | regex-фильтры сообщений |
| `sync/*` | AyuSync (WebSocket-синхронизация прочтений) |
| `ui/*` | экраны настроек, «История правок», ячейка сообщения |
| хуки в `ConnectionsManager` | глушение `readHistory`, `setTyping`, подмена `updateStatus` |
| хуки в `SendMessagesHelper` | авто-отложка (`schedule_date = now + 11`) |
| хуки в `MessagesController` | перехват `updateDeleteMessages` / правок |
| хуки в `ChatMessageCell`, `DialogCell`, `DrawerLayoutAdapter` | метки 🧹/«изменено», размытие, кнопки в меню |

## 2. Архитектура iOS-порта

```
AyuGram/
├── App/            точка входа, навигация (AppRouter, Route), RootView
├── Core/
│   ├── Telegram/   TelegramService (TDLib через TDLibKit), конвертеры TDLib → модели, FileStore, ключи API
│   ├── Ayu/        AyuConfig, AyuFilter, AyuState/LocalReadStore, AyuMessagesController, AyuConstants
│   ├── Storage/    SQLiteDatabase (обёртка sqlite3), AyuDatabase (схема Room → SQLite)
│   ├── Sync/       AyuSyncController (URLSessionWebSocketTask)
│   ├── Media/      OpusOggDecoder (голосовые), AudioPlayback
│   └── NotificationService, Formatters, AppLog
├── Models/         MessageItem, ChatItem, UserItem … (свои модели, UI не импортирует TDLibKit)
├── ViewModels/     ChatViewModel, ChatListViewModel
├── Views/          Auth, ChatList, Chat, Profile, Settings, Ayu, Components
└── Resources/      en/ru Localizable.strings (ключи как в strings.xml Android)
```

Сеть, протокол MTProto, локальная база Telegram, загрузка файлов: **TDLib** — официальная
кросс-платформенная библиотека Telegram. Это прямой аналог связки
`ConnectionsManager + MessagesController + MessagesStorage + FileLoader` из Android.

## 3. Соответствие API

| Android | iOS |
|---|---|
| Java / Kotlin | Swift 5 (Xcode 16+) |
| Activity / Fragment, RecyclerView | SwiftUI `NavigationStack`, `List`, `LazyVStack` |
| SharedPreferences | `UserDefaults(suiteName: "ayuconfig")`, те же ключи |
| Room (SQLite) | sqlite3 C API (`SQLiteDatabase`), те же таблицы |
| OkHttp / java-websocket | `URLSession`, `URLSessionWebSocketTask` |
| tgnet (C++ MTProto) | TDLib 1.8.67 (TDLibKit) |
| NotificationCenter (Telegram) | `TelegramService` → `ChatEventSink`, `Foundation.NotificationCenter` |
| Downloads/AyuGram/Saved Attachments | Документы приложения → «Файлы» → AyuGram → Saved Attachments |
| Foreground Service | `BGAppRefreshTask` + локальные уведомления |
| opus (JNI) | libopus/libogg XCFramework → WAV → AVAudioPlayer |
| Crashlytics | не используется |

## 4. Перенос функций AyuGram

| Функция | Android | iOS | Статус |
|---|---|---|---|
| Режим призрака (переключатель) | `AyuConfig.setGhostMode` | то же, кнопка-призрак в списке чатов | ✅ |
| Не читать сообщения | фейковый ответ на `readHistory` | `viewMessages` не вызывается, чат помечается прочитанным локально (`LocalReadStore`) | ✅ |
| «Прочитать до сюда» | `markReadOnServer` | `viewMessages(forceRead: true)` | ✅ |
| Читать после ответа | `markReadAfterSend` | то же | ✅ |
| Не отправлять «онлайн» | `updateStatus(offline=true)` | опция TDLib `online = false` | ✅ |
| Автоматический «офлайн» | `sendOfflinePacketAfterOnline` | `online=false` после активности | ✅ (см. ограничения) |
| Не отправлять «печатает» | блок `setTyping` | `sendChatAction` не вызывается | ✅ текст; ⚠️ загрузка медиа |
| Отложка | `schedule_date = now + 11` | `messageSchedulingStateSendAtDate(now + 12)` | ✅ |
| Сохранение удалённых | Room `DeletedMessage` | SQLite `deletedmessage` + кэш сообщений | ✅ |
| Метка удалённого 🧹 | `ChatMessageCell` | `MessageFooter` + пунктирная рамка | ✅ |
| История правок | Room `EditedMessage` + `AyuMessageHistory` | `editedmessage` + `EditsHistoryView` | ✅ |
| Метка «изменено» (своя) | `editedMarkText` | то же | ✅ |
| Сохранение медиа (по типам чатов) | копия в Downloads | копия в «Файлы» → Saved Attachments | ✅ если медиа было загружено |
| Сохранение реакций / форматирования / в ботах | да | да | ✅ |
| Свои удаления не сохраняются | `AyuState.permitDeleteMessage` | то же (+ очистка истории) | ✅ |
| Фильтры сообщений (regex) | `AyuFilter` | `AyuFilter` (NSRegularExpression) | ✅ |
| Размытие отфильтрованных в списке чатов | `DialogCell` | `ChatListViewModel.preview` | ✅ |
| Без автозагрузки медиа отфильтрованных | `DownloadController` | `MediaImage(autoDownload: false)` | ✅ |
| Отключить рекламу | `disableAds` | спонсорские сообщения не загружаются | ✅ |
| Локальный Premium | `UserConfig.isPremium()` | значок Premium (только визуально) | ⚠️ частично |
| AyuGram Push Service | foreground-сервис | фоновое обновление + локальные уведомления | ⚠️ частично |
| Кнопка «Закрыть приложение» | `Process.killProcess` | `exit(0)` с подтверждением | ✅ |
| AyuSync | WebSocket | `URLSessionWebSocketTask`, тот же протокол | ✅ (сервер может быть недоступен) |
| WAL-режим БД | Room | `PRAGMA journal_mode` | ✅ |
| Очистка БД AyuGram | `AyuData.clean` | то же + удаление Saved Attachments | ✅ |
| Скриншоты в секретных чатах | патч Telegraher | iOS не запрещает скриншоты; уведомление о скриншоте не отправляется | ✅ |
| Сохранение чатов при бане/кике | патч Telegraher | TDLib хранит историю, недоступность не считается удалением | ⚠️ частично |
| Кнопка «истечь» для TTL-медиа | патч | нет | ❌ этап 2 |
| Официальные ключи API | Telegraher | свои ключи с my.telegram.org | ❌ намеренно |

## 5. Почему что-то нельзя перенести 1:1

* **Постоянный фон.** iOS не даёт обычным приложениям держать соединение в фоне. Push от
  Telegram приходят только приложениям, чей APNs-ключ есть у Telegram (официальным клиентам).
  Аналог — `BGAppRefreshTask` (iOS сама решает, как часто) и локальные уведомления, пока процесс жив.
* **Перехват пакетов.** На Android AyuGram подменяет пакеты внутри своего MTProto-клиента.
  TDLib — закрытая для патчей библиотека (в бинарном виде), поэтому призрак реализован на
  уровне «не делать запрос» + опция `online`. Загрузку медиа TDLib может сопровождать
  статусом «отправляет фото» сам; убрать это можно только патчем TDLib.
* **Удалённые сообщения.** TDLib удаляет сообщение из своей БД до уведомления. Поэтому порт
  кэширует каждое увиденное сообщение (`messagecache`, хранится 90 дней). Сообщения, которые
  приложение не видело (например, пришли и удалились, пока оно было выгружено), сохранить нельзя —
  как и на Android, если сообщение не попало в локальную базу.
* **Официальные ключи.** Ключи Telegram для Android не принадлежат проекту и не должны
  распространяться; нужны свои api_id/api_hash.
* **Local Premium.** Серверные функции Premium (лимиты, загрузка 4 ГБ, расшифровка голоса)
  проверяются сервером, на любом клиенте это только визуальные изменения.
* **Анимированные стикеры (TGS/WebM).** Нужны рендеры Lottie/VP9 — сейчас показывается
  статичная миниатюра. Этап 2 (rlottie / libvpx).
* **Звонки, истории, мини-приложения, запись голосовых** — большие подсистемы Telegram,
  не относящиеся к функциям AyuGram; запланированы на следующие этапы.
