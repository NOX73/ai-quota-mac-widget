# Подробный план реализации: AIQuota (Claude, OpenAI, Google AI Plus)

> **Статус: исторический план, частично устарел.** Файловая структура ниже (`Auth/OpenAIAuthFlow.swift`,
> `Auth/GoogleAuthFlow.swift`, `Models/QuotaPeriod.swift`, `Models/ProviderStatus.swift`) не совпадает
> с тем, что реально реализовано (единый `Models/QuotaModels.swift`, ручной ввод токена вместо
> отдельных auth-flow для OpenAI/Google — впоследствии тоже удалён). Раздел 4 (UI: символы в
> менюбаре, фиксированные пороги 50/80%, чекбокс "Подключено") описывает более раннюю версию —
> актуальное поведение см. в [`ui-customization.md`](ui-customization.md) и
> [`popover-reactivity-fixes.md`](popover-reactivity-fixes.md). Оставлено как есть для истории.

Данный документ содержит технический план расширения виджета macOS для отслеживания лимитов подписок трех независимых провайдеров (Claude, OpenAI ChatGPT, Google AI Plus) без зависимости от CLI-утилит.

---

## 1. Источники данных и Эндпоинты API

| Провайдер | Тип подписки | Способ авторизации | Эндпоинты и Сервисы | Возвращаемые данные |
|---|---|---|---|---|
| **Claude** | Claude Pro / Max | OAuth 2.0 PKCE через браузер (`claude.ai`) | `GET https://api.anthropic.com/api/oauth/usage`<br>Заголовки:<br>- `Authorization: Bearer <access_token>`<br>- `anthropic-beta: oauth-2025-04-20` | • **5h Session**: % использования за 5 часов<br>• **7d Weekly**: % недельного лимита<br>• **Opus / Sonnet**: разблокированные лимиты по моделям<br>• Даты сброса (`resetsAt`) |
| **OpenAI** | ChatGPT Plus / Pro | Сессионный токен из браузера (`chatgpt.com`) | `GET https://chatgpt.com/backend-api/wham/usage`<br>ИЛИ `/backend-api/accounts/check`<br>Заголовки:<br>- `Authorization: Bearer <session_token>`<br>- `Cookie: __Secure-next-auth.session-token=...` | • Лимит сообщений в 3-часовом окне (например, GPT-4o)<br>• Остаток доступных запросов<br>• Время окончания скользящего окна |
| **Google AI Plus** | Google AI Plus (Antigravity) | Google OAuth 2.0 (`accounts.google.com`) | **gRPC Host**: `cloudcode-pa.googleapis.com`<br>**gRPC Method**: `google.cloud.businessaicode.v1beta.ManagementService/FetchConfig`<br>**Proto**: `Entitlement`<br>ИЛИ REST-транскодинг `POST https://cloudcode-pa.googleapis.com/v1beta/config:fetch` | • **Weekly Gemini**: % использования моделей Gemini<br>• **Weekly Claude**: % использования сторонней модели Claude<br>• **Weekly GPT**: % использования сторонней модели GPT |

---

## 2. Архитектура Проекта

```
Sources/ClaudeQuota/
├── main.swift                          # Точка входа Swift (NSApplication)
│
├── App/
│   ├── MenuBarController.swift         # Управление статусом в NSStatusBar (динамический заголовок)
│   ├── PopoverView.swift               # Главное окно с прогресс-барами подписок
│   └── SettingsView.swift              # Окно управления подключенными аккаунтами
│
├── Auth/
│   ├── OAuthWebView.swift              # SwiftUI обертка вокруг WKWebView для OAuth логина
│   ├── ClaudeAuthFlow.swift            # Авторизация Anthropic (PKCE)
│   ├── OpenAIAuthFlow.swift            # Извлечение сессии chatgpt.com
│   └── GoogleAuthFlow.swift            # OAuth 2.0 авторизация Google
│
├── Keychain/
│   └── KeychainService.swift           # Безопасное хранение токенов в системном Keychain (без CLI / security subprocess)
│
├── Services/
│   ├── AggregateQuotaService.swift     # Главный сервис-оркестратор (собирает данные со всех провайдеров)
│   └── Providers/
│       ├── QuotaProvider.swift         # Протокол единого интерфейса провайдера
│       ├── ClaudeProvider.swift        # Сервис опроса Anthropic OAuth API
│       ├── OpenAIProvider.swift        # Сервис опроса ChatGPT Internal Backend API
│       └── GoogleAIProvider.swift      # Сервис опроса Google Cloud Code / BAIC gRPC API
│
└── Models/
    ├── QuotaPeriod.swift               # Унифицированная структура периода (label, utilization, resetsAt)
    └── ProviderStatus.swift            # Состояние подключения провайдера (connected, error, unconfigured)
```

---

## 3. Детальное описание сервисов

### 3.1. KeychainService (Безопасное хранение)
Использует нативный Security framework macOS (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`).
*   Сервис: `com.claude.quota.widget`
*   Ключи:
    *   `claude_oauth_token` (access + refresh token + expires_at)
    *   `openai_session_token` (session token)
    *   `google_oauth_token` (access + refresh token)

### 3.2. ClaudeProvider
1. Выполняет проверка наличия токена в `KeychainService`.
2. Если токен истёк — выполняет автоматический refresh через `https://api.anthropic.com/v1/oauth/tokens`.
3. Отправляет запрос `GET https://api.anthropic.com/api/oauth/usage`.
4. Парсит ответ в структуры `QuotaPeriod`:
   - `fiveHour` -> "Session (5h)"
   - `sevenDay` -> "Weekly (7d)"
   - `sevenDayOpus` -> "Weekly Opus"
   - `sevenDaySonnet` -> "Weekly Sonnet"

### 3.3. OpenAIProvider
1. Читает сессионный токен из Keychain.
2. Делает запрос к `https://chatgpt.com/backend-api/wham/usage`.
3. В случае `401 Unauthorized` помечает статус провайдера как `requiresReauth`.
4. Вычисляет % загрузки лимита сообщений скользящего окна.

### 3.4. GoogleAIProvider
1. Использует OAuth2 токен доступа Google.
2. Выполняет вызов к `cloudcode-pa.googleapis.com` (gRPC метод `ManagementService/FetchConfig`).
3. Распаковывает protobuf структуру `Entitlement`.
4. Извлекает распределённые недельные лимиты подписки Google AI Plus по категориям моделей (Gemini, Claude, GPT).

---

## 4. Графический Интерфейс (UI)

### 4.1. Статус в Менюбаре (MenuBarController)
*   **Динамическая строка**: Отображает текущий процент худшего/наиболее загруженного лимита по подключенным провайдерам.
    *   Пример с 1 провайдером: `◆ 52%/27%`
    *   Пример с 3 провайдерами: `◆ 52% | ⬡ 80% | ✦ 34%`
*   **Цветовая индикация**:
    *   Зеленый (< 50%)
    *   Оранжевый (50% - 80%)
    *   Красный (> 80%)

### 4.2. PopoverView (При клике на иконку)
Вертикальный список карточек провайдеров:
*   **Карточка Claude**: Прогресс-бары сессии 5h и недельного лимита 7d с плашками времени сброса.
*   **Карточка OpenAI**: Прогресс-бар окна ответов ChatGPT (GPT-4o / O3).
*   **Карточка Google AI Plus**: Прогресс-бары лимитов на Gemini, Claude и GPT в рамках подписки.
*   **Футер**: Кнопка ручного обновления `↺`, кнопка настроек `⚙`, статус последнего обновления.

### 4.3. SettingsView (Окно настроек)
Содержит 3 секции для настройки каждого провайдера:
*   Статус подключения: `● Подключено` / `○ Не подключено`.
*   Кнопка `[Авторизоваться через браузер]`: открывает встроенный `WKWebView` для ввода учетных данных.
*   Кнопка `[Отключить]`: удаляет ключи из Keychain.

---

## 5. Этапы Реализации

### Этап 1: Рефакторинг архитектуры и Claude OAuth (Фаза 1)
- [x] Перевести проект на модульную структуру `QuotaProvider` и `KeychainService`.
- [x] Создать `WKWebView` обертку (`OAuthWebView.swift`) для авторизации в `claude.ai`.
- [x] Реализовать `ClaudeProvider` с обработкой OAuth PKCE и авто-обновлением токенов.
- [x] Обновить UI настроек (`SettingsView`) для Claude.

### Этап 2: Поддержка OpenAI / ChatGPT (Фаза 2)
- [x] Реализовать `OpenAIAuthFlow` (перехват сессии chatgpt.com).
- [x] Написать `OpenAIProvider` для обработки внутреннего backend API.
- [x] Интегрировать карточку OpenAI в `PopoverView` и строку меню.

### Этап 3: Поддержка Google AI Plus / Antigravity (Фаза 3)
- [x] Настроить Google OAuth 2.0 flow.
- [x] Подключить gRPC / REST клиент для `cloudcode-pa.googleapis.com`.
- [x] Реализовать `GoogleAIProvider` для чтения квот Gemini, Claude и GPT подписки Google AI Plus.
- [x] Финальное тестирование работы всех трех провайдеров одновременно.

---

## 6. Проверка и Тестирование
1. **Авторизация**: Проверка успешного входа через браузер для каждого сервиса по отдельности.
2. **Безопасность**: Проверка отсутствия хранения токенов в открытом виде (только Keychain).
3. **Автообновление**: Проверка фонового обновления данных и адаптивного polling-интервала (3-30 минут).

