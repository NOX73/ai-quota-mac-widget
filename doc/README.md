# AIQuota Widget Documentation

Виджет macOS для отображения лимитов подписок трех AI-провайдеров: Claude, OpenAI ChatGPT и Google AI Plus.

> **Внимание по ведению документации**: Вся документация по архитектуре, планам и реализациям фичей проекта находится и ведется строго в директории `doc/` (в частности в `doc/features/`).

## Документы в директории `doc/features/`:

- **[initial-architecture.md](features/initial-architecture.md)**: Подробный архитектурный план системы, API-эндпоинты провайдеров и первоначальная структура приложения.
- **[default-browser-auth.md](features/default-browser-auth.md)**: План и реализация авторизации через дефолтный браузер системы.
- **[oauth-localhost-flow.md](features/oauth-localhost-flow.md)**: Архитектура автоматической CLI-style OAuth авторизации с помощью локального HTTP-сервера на `localhost:54321`.

## Сборка и запуск

```bash
# Сборка проекта через Swift Package Manager
swift build

# Сборка готового macOS .app бандла
./scripts/build_app.sh

# Запуск приложения
open build/ClaudeQuota.app
```
