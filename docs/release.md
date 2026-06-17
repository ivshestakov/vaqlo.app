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

Версия берётся из `CFBundleShortVersionString` в `Resources/Info.plist` — поднимайте её перед релизом.

## На сайт

- Выложить `.dmg` (прямая ссылка для скачивания).
- **Страница приватности** — обязательно: приложение записывает звук, в т.ч. чужой. Указать, что
  всё хранится локально, ничего не уходит в облако; упомянуть ответственность за согласие собеседников.
- Указать лицензии: whisper.cpp / FluidAudio — MIT/Apache; модели Llama 3.2 и Qwen3 скачиваются
  пользователем с HuggingFace (мы их не распространяем) и имеют собственные лицензии.
- **Авто-обновления** (опционально, но ожидаемо): Sparkle + `appcast.xml` на сайте + EdDSA-подпись
  апдейтов. Тогда пользователи получают новые версии без ручного перекачивания DMG.

## Иконка

Готова: `Resources/AppIcon.icns` (вшита в бандл, прописана в Info.plist). Рисуется кодом —
`scripts/makeicon.sh` пересобирает её из `scripts/makeicon.swift` (микрофон + звуковые волны на
фиолетовом сквикле). Меняете дизайн в `makeicon.swift` → запускаете `scripts/makeicon.sh`.

## Что ещё стоит сделать перед публичным релизом

- **Красивый DMG** (фон, раскладка): сейчас простой `hdiutil`. Для оформления — `create-dmg`.
- Прогнать на чистом Mac (без сертификатов разработчика), чтобы убедиться в отсутствии
  предупреждений Gatekeeper.
