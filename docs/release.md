# Релиз и публикация Vaqlo

Канал раздачи — **прямой (DMG на сайте)**, не App Store: захват системного звука, глобальный
хоткей, перечисление аудио-процессов и запуск вложенных бинарей несовместимы с сэндбоксом MAS.

Сборка подписывается Developer ID, проходит hardened runtime и нотаризацию Apple — тогда
Gatekeeper пускает приложение на любом Mac без предупреждений.

## Разовая настройка

1. **Учётка нотаризации** (keychain-профиль `vaqlo-notary`):
   ```bash
   xcrun notarytool store-credentials vaqlo-notary \
       --apple-id "<ваш-apple-id>" --team-id 975ZZPJQNB --password <app-specific-password>
   ```
   App-specific password: appleid.apple.com → Sign-In and Security → App-Specific Passwords.

2. **Provisioning profiles для App Group** (нужны виджету Control Center, чтобы показывать
   статус записи; само приложение работает и без них):
   - В developer.apple.com зарегистрируйте App ID `com.vaqlo.recorder` и `com.vaqlo.recorder.control`,
     обоим включите capability **App Groups** → `group.com.vaqlo`.
   - Создайте два профиля типа **Developer ID** и положите как
     `recorder/Resources/Vaqlo.provisionprofile` и `recorder/Resources/VaqloControl.provisionprofile`.
   - `release.sh` встроит их автоматически, если файлы существуют.

## Выпуск

```bash
cd recorder
scripts/release.sh                 # подпись + нотаризация + DMG
SKIP_NOTARIZE=1 scripts/release.sh # быстрая локальная проверка без нотаризации
```

Результат: `recorder/dist/Vaqlo-<версия>.dmg` — подписан, нотаризован, застейплен.
Проверка: `spctl -a -vvv recorder/dist/Vaqlo.app` должно дать `accepted / Notarized Developer ID`.

Версия берётся из `CFBundleShortVersionString` в `Resources/Info.plist` — поднимайте её перед релизом
(и `CFBundleVersion` — это `sparkle:version`, должен расти).

## Публикация новой версии (чеклист)

1. Поднять версии в `Resources/Info.plist` (см. выше).
2. `scripts/release.sh` — соберёт, нотаризует, застейплит и **напечатает готовый `<item>` для appcast**.
3. `gh release create v<ver> dist/Vaqlo-<ver>.dmg dist/Vaqlo.dmg -R ivshestakov/vaqlo.app`
   (две копии: версионная — её тянет Sparkle, `Vaqlo.dmg` — для стабильной latest-ссылки).
4. Вставить `<item>` вверх `vaqlo/appcast.xml` в репо `ivshestakov/panic-kit`, обновить версию
   на странице, commit+push (сайт деплоится автоматически).
5. **Homebrew** — обязательный шаг, каждая версия должна ставиться через brew: в
   `github.com/ivshestakov/homebrew-tap` поднять `version` и `sha256`
   (`shasum -a 256 dist/Vaqlo-<ver>.dmg`) в `Casks/vaqlo.rb`, commit+push.
   Проверка: `brew livecheck --cask ivshestakov/tap/vaqlo` и `brew fetch --cask ivshestakov/tap/vaqlo`.

## На сайт

- Выложить `.dmg` (прямая ссылка для скачивания).
- **Страница приватности** — обязательно: приложение записывает звук, в т.ч. чужой. Указать, что
  всё хранится локально, ничего не уходит в облако; упомянуть ответственность за согласие собеседников.
- Указать лицензии: whisper.cpp / FluidAudio — MIT/Apache; модели Llama 3.2 и Qwen3 скачиваются
  пользователем с HuggingFace (мы их не распространяем) и имеют собственные лицензии.
- **Авто-обновления**: настроены — Sparkle, фид `panic-kit.com/vaqlo/appcast.xml`, EdDSA-подпись
  апдейтов (ключ в keychain, общий со Skald).

## Иконка

Готова: `Resources/AppIcon.icns` (вшита в бандл, прописана в Info.plist). Рисуется кодом —
`scripts/makeicon.sh` пересобирает её из `scripts/makeicon.swift` (микрофон + звуковые волны на
фиолетовом сквикле). Меняете дизайн в `makeicon.swift` → запускаете `scripts/makeicon.sh`.

## Что ещё стоит сделать перед публичным релизом

- **Красивый DMG** (фон, раскладка): сейчас простой `hdiutil`. Для оформления — `create-dmg`.
- Прогнать на чистом Mac (без сертификатов разработчика), чтобы убедиться в отсутствии
  предупреждений Gatekeeper.
