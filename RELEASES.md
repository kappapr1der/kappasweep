# Публикация релизов

У KappaSweep два варианта публикации: через GitHub Actions или напрямую с этого
ПК. Основной формат для пользователей - portable-архив: внутри только
`KappaSweep.exe`, `README.md` и `CONFIG.md`.

## Portable-версия

Для локальной сборки из исходников нужен .NET 8 SDK. Пользовательская
portable-версия остаётся self-contained: после загрузки архива отдельно
устанавливать .NET не требуется.

Собрать архив локально:

```powershell
.\build-release.ps1 -Version 1.3.0 -Portable
```

Готовый файл появится в `dist\KappaSweep-Portable-v1.3.0.zip`. После первого
запуска `KappaSweep.exe` создаст скрытую папку `KappaSweepData` рядом с собой.
В ней находятся настройки и внутренний движок, поэтому всю папку можно
переносить целиком.

Обычная сборка остаётся доступна для совместимости:

```powershell
.\build-release.ps1 -Version 1.3.0
```

## Автоматический релиз GitHub Actions

GitHub Actions собирает релиз после пуша тега:

```powershell
git tag v1.3.0
git push origin v1.3.0
```

Это работает, только пока для аккаунта разрешён запуск Actions. При ошибке
про billing lock используй локальную публикацию ниже: она не расходует минуты
GitHub Actions.

## Локальная публикация без Actions

Один раз сохрани fine-grained token с доступом `Contents: Read and write` к
`kappapr1der/kappasweep`:

```powershell
.\save-github-token.ps1
```

Затем опубликуй portable-архив:

```powershell
.\publish-release.ps1 -Version 1.3.0 -Portable
```

Сценарий собирает ZIP, создаёт или использует тег `v1.3.0` и прикрепляет архив
к GitHub Release. Токен сохраняется зашифрованным через DPAPI в
`%APPDATA%\KappaSweep\github-token.txt`, а в репозиторий не попадает.
Ранее сохранённый токен из `%APPDATA%\WinSweep` и переменная
`WINSWEEP_GITHUB_TOKEN` тоже поддерживаются.

Полезные варианты:

```powershell
.\publish-release.ps1 -Version 1.3.0 -Portable -DryRun
.\publish-release.ps1 -Version 1.3.0 -Portable -Prerelease
.\publish-release.ps1 -Version 1.3.0 -Portable -UpdateExisting -ReplaceAsset
.\save-github-token.ps1 -Clear
```

Токен ищется в таком порядке: параметр `-Token`, переменные окружения
`KAPPASWEEP_GITHUB_TOKEN` / `GITHUB_TOKEN` / `GH_TOKEN`, сохранённый DPAPI-токен,
затем скрытый запрос в консоли.
