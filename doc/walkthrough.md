# Walkthrough — AI Quota Widget Enhancement

Мы расширили виджет macOS для работы с тремя подписками (Claude, OpenAI ChatGPT, Google AI Plus) с независимой авторизацией без CLI.

---

## 🛠 Выполненные изменения

### 1. Архитектура и Управление Памятью
- **[Package.swift](file:///Users/alex/src/claude_widget/Package.swift)**: Создан манифест Swift Package Manager для сборки приложения под macOS 14.
- **[KeychainService.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Keychain/KeychainService.swift)**: Реализовано нативное хранилище токенов с использованием `Security.framework` macOS (без вызовов subprocess). Включен фолбэк для автоматического считывания сохраненных ранее токенов Claude Code CLI.
- **[QuotaModels.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Models/QuotaModels.swift)**: Унифицированные структуры данных `QuotaPeriod` и состояние провайдеров `ProviderStatus`.

---

### 2. Провайдеры Данных
- **[ClaudeProvider.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Providers/ClaudeProvider.swift)**: Мониторинг 5-часовых сессионных и 7-дневных недельных лимитов Claude Pro/Max через `GET https://api.anthropic.com/api/oauth/usage`.
- **[OpenAIProvider.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Providers/OpenAIProvider.swift)**: Мониторинг 3-часового скользящего окна лимитов ответов ChatGPT Plus/Pro (`chatgpt.com/backend-api/wham/usage`).
- **[GoogleAIProvider.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Providers/GoogleAIProvider.swift)**: Мониторинг недельных лимитов подписки Google AI Plus по моделям Gemini, Claude и GPT (`cloudcode-pa.googleapis.com`).
- **[AggregateQuotaService.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Services/AggregateQuotaService.swift)**: Оркестратор для параллельного опроса всех трех сервисов с адаптивным интервалом (3-30 мин) и форматированием заголовка менюбара.

---

### 3. Авторизация и Графический Интерфейс
- **[OAuthWebView.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/Auth/OAuthWebView.swift)**: `WKWebView` обертка SwiftUI для авторизации в браузерах провайдеров.
- **[SettingsView.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/App/SettingsView.swift)**: Окно подключения подписок и ввода токенов.
- **[PopoverView.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/PopoverView.swift)**: Обновленный интерфейс с карточками подписок, прогресс-барами и датами сброса лимитов.
- **[MenuBarController.swift](file:///Users/alex/src/claude_widget/Sources/ClaudeQuota/MenuBarController.swift)**: Динамическое отображение статуса `◆ 52%  ⬡ 80%  ✦ 34%` с цветовой индикацией.

---

## 🧪 Проверка сборки

Сборка выполнена через `swift build`:

```bash
[4/7] Compiling ClaudeQuota main.swift
[5/7] Write Objects.LinkFileList
[6/7] Linking ClaudeQuota
[7/7] Applying ClaudeQuota
Build complete! (1.64s)
```

Исполняемый файл успешно создан в `.build/debug/ClaudeQuota`.

