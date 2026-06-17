import Foundation
import SwiftUI

/// Поддерживаемые языки интерфейса (украинский вместо русского).
enum AppLanguage: String, CaseIterable, Identifiable {
    case uk, en, fr, es, pt, de, it
    var id: String { rawValue }

    /// Название языка на нём самом — для пикера в настройках.
    var nativeName: String {
        switch self {
        case .uk: "Українська"
        case .en: "English"
        case .fr: "Français"
        case .es: "Español"
        case .pt: "Português"
        case .de: "Deutsch"
        case .it: "Italiano"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Язык по умолчанию из системных предпочтений; неподдержанные → английский.
    static var systemDefault: AppLanguage {
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2))
            if let lang = AppLanguage(rawValue: base) { return lang }
        }
        return .en
    }
}

/// Рантайм-локализация: язык можно менять на лету, вьюхи перерисовываются.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// Снимок текущего языка для чтения из любого потока (запись только с main).
    nonisolated(unsafe) static var currentLanguage: AppLanguage = .en

    @Published private(set) var language: AppLanguage {
        didSet { LocalizationManager.currentLanguage = language }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: SettingsKeys.appLanguage),
           let lang = AppLanguage(rawValue: saved) {
            language = lang
        } else {
            language = AppLanguage.systemDefault
        }
        LocalizationManager.currentLanguage = language
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: SettingsKeys.appLanguage)
    }

    var locale: Locale { language.locale }

    /// Параметры для саммаризации на текущем языке.
    var summary: SummaryStrings { SummaryStrings.all.value(for: language) }

    func string(_ key: String) -> String {
        guard let tr = Strings.table[key] else { return key }
        return tr.value(for: language)
    }
}

/// Глобальный хелпер. `L("key")` или `L("key", arg1, arg2)` для строк с %@/%d.
/// Читает язык из снимка — работает на любом потоке.
func L(_ key: String, _ args: CVarArg...) -> String {
    guard let tr = Strings.table[key] else { return key }
    let template = tr.value(for: LocalizationManager.currentLanguage)
    return args.isEmpty ? template : String(format: template, arguments: args)
}

/// Перевод одной строки на 7 языков.
struct Tr {
    let uk, en, fr, es, pt, de, it: String
    func value(for lang: AppLanguage) -> String {
        switch lang {
        case .uk: uk
        case .en: en
        case .fr: fr
        case .es: es
        case .pt: pt
        case .de: de
        case .it: it
        }
    }
}

private func t(_ uk: String, _ en: String, _ fr: String, _ es: String,
               _ pt: String, _ de: String, _ it: String) -> Tr {
    Tr(uk: uk, en: en, fr: fr, es: es, pt: pt, de: de, it: it)
}

/// Тексты для саммаризации: LLM получает их на языке интерфейса.
struct SummaryStrings {
    let system: String       // системный промпт (на нужном языке)
    let intro: String        // инструкция «сделай выжимку в формате»
    let tldr: String         // заголовок TL;DR
    let tldrHint: String
    let decisions: String
    let decisionsHint: String
    let actions: String
    let actionsHint: String
    let transcriptLabel: String
    let condense: String     // инструкция для длинных транскриптов

    struct Localized {
        let map: [AppLanguage: SummaryStrings]
        func value(for lang: AppLanguage) -> SummaryStrings { map[lang] ?? map[.en]! }
    }

    static let all = Localized(map: [
        .uk: .init(
            system: "Ти — асистент, що робить вижимки з транскриптів робочих зустрічей і розмов. Відповідай українською. Будь конкретним, не вигадуй того, чого немає в тексті.",
            intro: "Нижче транскрипт запису. Зроби вижимку в markdown суворо в такому форматі:",
            tldr: "Головне", tldrHint: "(3–5 пунктів — найважливіше)",
            decisions: "Рішення", decisionsHint: "(що вирішили; якщо рішень не було — пропусти розділ)",
            actions: "Дії", actionsHint: "(хто що має зробити і до якого терміну; якщо немає — пропусти розділ)",
            transcriptLabel: "Транскрипт:",
            condense: "Стисни наступний фрагмент транскрипту зустрічі до ключових фактів, рішень і завдань (щільний конспект, без води):"
        ),
        .en: .init(
            system: "You summarize transcripts of work meetings and conversations. Answer in English. Be concrete, don't invent anything not in the text.",
            intro: "Below is a transcript of a recording. Make a summary in markdown strictly in this format:",
            tldr: "TL;DR", tldrHint: "(3–5 bullet points — the essentials)",
            decisions: "Decisions", decisionsHint: "(what was decided; skip this section if there were none)",
            actions: "Action items", actionsHint: "(who does what and by when; skip if none)",
            transcriptLabel: "Transcript:",
            condense: "Condense the following meeting transcript fragment into key facts, decisions and tasks (dense notes, no fluff):"
        ),
        .fr: .init(
            system: "Tu résumes des transcriptions de réunions et de conversations de travail. Réponds en français. Sois concret, n’invente rien qui ne soit pas dans le texte.",
            intro: "Voici la transcription d’un enregistrement. Rédige un résumé en markdown strictement dans ce format :",
            tldr: "En bref", tldrHint: "(3 à 5 points — l’essentiel)",
            decisions: "Décisions", decisionsHint: "(ce qui a été décidé ; ignore cette section s’il n’y en a pas)",
            actions: "Actions", actionsHint: "(qui fait quoi et pour quand ; ignore s’il n’y en a pas)",
            transcriptLabel: "Transcription :",
            condense: "Condense le fragment de transcription suivant en faits clés, décisions et tâches (notes denses, sans superflu) :"
        ),
        .es: .init(
            system: "Resumes transcripciones de reuniones y conversaciones de trabajo. Responde en español. Sé concreto, no inventes nada que no esté en el texto.",
            intro: "A continuación hay una transcripción de una grabación. Haz un resumen en markdown estrictamente con este formato:",
            tldr: "Resumen", tldrHint: "(3–5 puntos — lo esencial)",
            decisions: "Decisiones", decisionsHint: "(qué se decidió; omite esta sección si no hubo)",
            actions: "Acciones", actionsHint: "(quién hace qué y para cuándo; omite si no hay)",
            transcriptLabel: "Transcripción:",
            condense: "Condensa el siguiente fragmento de transcripción en hechos clave, decisiones y tareas (notas densas, sin relleno):"
        ),
        .pt: .init(
            system: "Resumes transcrições de reuniões e conversas de trabalho. Responde em português. Sê concreto, não inventes nada que não esteja no texto.",
            intro: "Abaixo está a transcrição de uma gravação. Faz um resumo em markdown estritamente neste formato:",
            tldr: "Resumo", tldrHint: "(3–5 pontos — o essencial)",
            decisions: "Decisões", decisionsHint: "(o que foi decidido; omite esta secção se não houve)",
            actions: "Ações", actionsHint: "(quem faz o quê e até quando; omite se não houver)",
            transcriptLabel: "Transcrição:",
            condense: "Condensa o seguinte fragmento de transcrição em factos-chave, decisões e tarefas (notas densas, sem enrolação):"
        ),
        .de: .init(
            system: "Du fasst Transkripte von Arbeitsbesprechungen und Gesprächen zusammen. Antworte auf Deutsch. Sei konkret, erfinde nichts, was nicht im Text steht.",
            intro: "Unten steht das Transkript einer Aufnahme. Erstelle eine Zusammenfassung in Markdown streng in diesem Format:",
            tldr: "Kurzfassung", tldrHint: "(3–5 Stichpunkte — das Wesentliche)",
            decisions: "Entscheidungen", decisionsHint: "(was beschlossen wurde; lass den Abschnitt weg, wenn es keine gab)",
            actions: "Aufgaben", actionsHint: "(wer macht was bis wann; weglassen, wenn keine)",
            transcriptLabel: "Transkript:",
            condense: "Verdichte den folgenden Transkript-Ausschnitt zu Kernfakten, Entscheidungen und Aufgaben (dichte Notizen, ohne Füllwörter):"
        ),
        .it: .init(
            system: "Riassumi trascrizioni di riunioni e conversazioni di lavoro. Rispondi in italiano. Sii concreto, non inventare nulla che non sia nel testo.",
            intro: "Di seguito la trascrizione di una registrazione. Crea un riassunto in markdown rigorosamente in questo formato:",
            tldr: "In sintesi", tldrHint: "(3–5 punti — l’essenziale)",
            decisions: "Decisioni", decisionsHint: "(cosa è stato deciso; ometti la sezione se non ce ne sono)",
            actions: "Azioni", actionsHint: "(chi fa cosa ed entro quando; ometti se non ce ne sono)",
            transcriptLabel: "Trascrizione:",
            condense: "Condensa il seguente frammento di trascrizione in fatti chiave, decisioni e attività (note dense, senza fronzoli):"
        ),
    ])
}

enum Strings {
    static let table: [String: Tr] = [
        // — Меню (menu bar) —
        "menu.idle": t("Не записує", "Not recording", "Pas d’enregistrement", "Sin grabar", "Sem gravar", "Nimmt nicht auf", "Non in registrazione"),
        "menu.recording": t("● Йде запис", "● Recording", "● Enregistrement", "● Grabando", "● Gravando", "● Aufnahme läuft", "● Registrazione"),
        "menu.start": t("Почати запис", "Start recording", "Démarrer l’enregistrement", "Iniciar grabación", "Iniciar gravação", "Aufnahme starten", "Avvia registrazione"),
        "menu.stop": t("Зупинити запис", "Stop recording", "Arrêter l’enregistrement", "Detener grabación", "Parar gravação", "Aufnahme stoppen", "Ferma registrazione"),
        "menu.open": t("Відкрити Vaqlo", "Open Vaqlo", "Ouvrir Vaqlo", "Abrir Vaqlo", "Abrir o Vaqlo", "Vaqlo öffnen", "Apri Vaqlo"),
        "menu.settings": t("Налаштування…", "Settings…", "Réglages…", "Ajustes…", "Definições…", "Einstellungen…", "Impostazioni…"),
        "menu.help": t("Дозволи та довідка…", "Permissions & help…", "Autorisations et aide…", "Permisos y ayuda…", "Permissões e ajuda…", "Berechtigungen & Hilfe…", "Autorizzazioni e aiuto…"),
        "menu.quit": t("Вийти", "Quit", "Quitter", "Salir", "Sair", "Beenden", "Esci"),
        "menu.checkUpdates": t("Перевірити оновлення…", "Check for Updates…", "Rechercher des mises à jour…", "Buscar actualizaciones…", "Procurar atualizações…", "Nach Updates suchen…", "Cerca aggiornamenti…"),

        // — Главное окно —
        "mode.day": t("День", "Day", "Jour", "Día", "Dia", "Tag", "Giorno"),
        "mode.week": t("Тиждень", "Week", "Semaine", "Semana", "Semana", "Woche", "Settimana"),
        "top.record": t("Запис", "Record", "Enregistrer", "Grabar", "Gravar", "Aufnehmen", "Registra"),
        "top.stop": t("Стоп", "Stop", "Arrêter", "Detener", "Parar", "Stopp", "Ferma"),
        "top.transcribeAll": t("Транскрибувати все", "Transcribe all", "Tout transcrire", "Transcribir todo", "Transcrever tudo", "Alles transkribieren", "Trascrivi tutto"),
        "top.transcribing": t("Транскрибування…", "Transcribing…", "Transcription…", "Transcribiendo…", "Transcrevendo…", "Transkription…", "Trascrizione…"),
        "top.trash": t("Кошик", "Trash", "Corbeille", "Papelera", "Lixo", "Papierkorb", "Cestino"),
        "top.settings": t("Налаштування", "Settings", "Réglages", "Ajustes", "Definições", "Einstellungen", "Impostazioni"),
        "top.noPending": t("Немає необроблених сесій", "No unprocessed sessions", "Aucune session à traiter", "No hay sesiones sin procesar", "Sem sessões por processar", "Keine unbearbeiteten Sitzungen", "Nessuna sessione da elaborare"),
        "top.pending": t("Обробити: %d", "%d to process", "%d à traiter", "%d por procesar", "%d por processar", "%d zu verarbeiten", "%d da elaborare"),
        "search.placeholder": t("Пошук у транскриптах", "Search transcripts", "Rechercher dans les transcriptions", "Buscar en transcripciones", "Pesquisar transcrições", "Transkripte durchsuchen", "Cerca nelle trascrizioni"),
        "search.results": t("Результати", "Results", "Résultats", "Resultados", "Resultados", "Ergebnisse", "Risultati"),
        "hotkey.help": t("Гаряча клавіша: %@", "Hotkey: %@", "Raccourci : %@", "Atajo: %@", "Atalho: %@", "Tastenkürzel: %@", "Scorciatoia: %@"),
        "select.title": t("Виберіть сесію", "Select a session", "Sélectionnez une session", "Selecciona una sesión", "Selecione uma sessão", "Sitzung auswählen", "Seleziona una sessione"),
        "select.desc": t("Клікніть блок на таймлайні", "Click a block on the timeline", "Cliquez sur un bloc de la frise", "Haz clic en un bloque de la línea de tiempo", "Clique num bloco da linha do tempo", "Klicke auf einen Block in der Zeitleiste", "Clicca un blocco sulla timeline"),

        // — Таймлайн —
        "today": t("Сьогодні", "Today", "Aujourd’hui", "Hoy", "Hoje", "Heute", "Oggi"),
        "block.recording": t("йде запис", "recording", "enregistrement", "grabando", "gravando", "Aufnahme", "registrazione"),
        "block.pending": t("очікує транскрибування", "waiting to transcribe", "en attente de transcription", "esperando transcripción", "aguardando transcrição", "wartet auf Transkription", "in attesa di trascrizione"),
        "block.transcribing": t("транскрибується", "transcribing", "transcription", "transcribiendo", "transcrevendo", "Transkription", "trascrizione"),
        "block.done": t("готово", "done", "terminé", "listo", "concluído", "fertig", "fatto"),
        "block.tooltip": t("%@ · %d хв · %@", "%@ · %d min · %@", "%@ · %d min · %@", "%@ · %d min · %@", "%@ · %d min · %@", "%@ · %d Min · %@", "%@ · %d min · %@"),

        // — Деталка сессии —
        "state.recording": t("запис", "recording", "enreg.", "grabando", "gravando", "Aufnahme", "registr."),
        "state.pending": t("не оброблено", "not processed", "non traité", "sin procesar", "por processar", "unbearbeitet", "non elaborato"),
        "state.transcribing": t("в роботі", "processing", "en cours", "procesando", "a processar", "in Arbeit", "in corso"),
        "state.done": t("готово", "done", "terminé", "listo", "concluído", "fertig", "fatto"),
        "act.transcribe": t("Транскрибувати", "Transcribe", "Transcrire", "Transcribir", "Transcrever", "Transkribieren", "Trascrivi"),
        "act.export": t("Експорт у теку", "Export to folder", "Exporter vers un dossier", "Exportar a carpeta", "Exportar para pasta", "In Ordner exportieren", "Esporta in cartella"),
        "act.showFiles": t("Показати файли", "Show files", "Afficher les fichiers", "Mostrar archivos", "Mostrar ficheiros", "Dateien anzeigen", "Mostra file"),
        "act.inProgress": t("В роботі…", "In progress…", "En cours…", "En curso…", "Em curso…", "Läuft…", "In corso…"),
        "delete.title": t("Видалити запис у Кошик?", "Move recording to Trash?", "Déplacer l’enregistrement vers la corbeille ?", "¿Mover la grabación a la papelera?", "Mover a gravação para o lixo?", "Aufnahme in den Papierkorb verschieben?", "Spostare la registrazione nel cestino?"),
        "delete.btn": t("Видалити у Кошик", "Move to Trash", "Vers la corbeille", "Mover a la papelera", "Mover para o lixo", "In den Papierkorb", "Sposta nel cestino"),
        "delete.msg": t("Сесія (аудіо, метадані й транскрипт) переїде до Кошика й автоматично видалиться за кілька днів. До того її можна відновити.", "The session (audio, metadata and transcript) will move to the Trash and be deleted automatically after a few days. Until then you can restore it.", "La session (audio, métadonnées et transcription) ira à la corbeille et sera supprimée automatiquement après quelques jours. Vous pouvez la restaurer jusque-là.", "La sesión (audio, metadatos y transcripción) irá a la papelera y se eliminará automáticamente tras unos días. Hasta entonces puedes restaurarla.", "A sessão (áudio, metadados e transcrição) vai para o lixo e será apagada automaticamente após alguns dias. Até lá pode restaurá-la.", "Die Sitzung (Audio, Metadaten und Transkript) wandert in den Papierkorb und wird nach einigen Tagen automatisch gelöscht. Bis dahin kannst du sie wiederherstellen.", "La sessione (audio, metadati e trascrizione) andrà nel cestino e verrà eliminata automaticamente dopo qualche giorno. Fino ad allora puoi ripristinarla."),
        "info.type": t("Тип", "Type", "Type", "Tipo", "Tipo", "Typ", "Tipo"),
        "info.start": t("Початок", "Start", "Début", "Inicio", "Início", "Beginn", "Inizio"),
        "info.end": t("Кінець", "End", "Fin", "Fin", "Fim", "Ende", "Fine"),
        "info.apps": t("Застосунки", "Apps", "Apps", "Apps", "Apps", "Apps", "App"),
        "info.recordingNow": t("йде запис", "recording", "enregistrement", "grabando", "gravando", "Aufnahme läuft", "registrazione"),
        "summary.title": t("Саммарі", "Summary", "Résumé", "Resumen", "Resumo", "Zusammenfassung", "Riassunto"),
        "summary.make": t("Зробити саммарі", "Make summary", "Générer le résumé", "Crear resumen", "Criar resumo", "Zusammenfassung erstellen", "Crea riassunto"),
        "summary.update": t("Оновити", "Update", "Actualiser", "Actualizar", "Atualizar", "Aktualisieren", "Aggiorna"),
        "summary.thinking": t("Думає…", "Thinking…", "Réflexion…", "Pensando…", "A pensar…", "Denkt nach…", "Sto pensando…"),
        "content.recording": t("Йде запис…", "Recording…", "Enregistrement…", "Grabando…", "Gravando…", "Aufnahme läuft…", "Registrazione…"),
        "content.pending.title": t("Ще не транскрибовано", "Not transcribed yet", "Pas encore transcrit", "Aún sin transcribir", "Ainda não transcrito", "Noch nicht transkribiert", "Non ancora trascritto"),
        "content.pending.desc": t("Натисніть «Транскрибувати» або налаштуйте розклад", "Press “Transcribe” or set up a schedule", "Appuyez sur « Transcrire » ou configurez une planification", "Pulsa «Transcribir» o configura una programación", "Carregue em «Transcrever» ou configure um agendamento", "Drücke „Transkribieren“ oder richte einen Zeitplan ein", "Premi «Trascrivi» o imposta una pianificazione"),
        "content.transcribing": t("Транскрибується…", "Transcribing…", "Transcription…", "Transcribiendo…", "A transcrever…", "Wird transkribiert…", "Trascrizione in corso…"),
        "transcript.empty": t("Мовлення не виявлено.", "No speech detected.", "Aucune parole détectée.", "No se detectó voz.", "Nenhuma fala detetada.", "Keine Sprache erkannt.", "Nessun parlato rilevato."),
        "player.loading": t("Завантаження аудіо…", "Loading audio…", "Chargement de l’audio…", "Cargando audio…", "A carregar áudio…", "Audio wird geladen…", "Caricamento audio…"),
        "player.deleted": t("Аудіо видалено — залишився лише транскрипт.", "Audio deleted — only the transcript remains.", "Audio supprimé — seule la transcription reste.", "Audio eliminado: solo queda la transcripción.", "Áudio apagado — resta apenas a transcrição.", "Audio gelöscht — nur das Transkript bleibt.", "Audio eliminato — resta solo la trascrizione."),
        "player.seek": t("Послухати з цього місця", "Play from here", "Lire à partir d’ici", "Reproducir desde aquí", "Reproduzir a partir daqui", "Ab hier abspielen", "Riproduci da qui"),
        "focus.prefix": t("у фокусі: %@", "in focus: %@", "au premier plan : %@", "en foco: %@", "em foco: %@", "im Fokus: %@", "in primo piano: %@"),
        "focus.help": t("Застосунок, активний у цей момент. Це контекст, а не джерело звуку.", "App active at that moment. This is context, not the audio source.", "App active à ce moment. C’est le contexte, pas la source audio.", "App activa en ese momento. Es el contexto, no la fuente de audio.", "App ativa nesse momento. É o contexto, não a fonte de áudio.", "Zu diesem Zeitpunkt aktive App. Das ist der Kontext, nicht die Audioquelle.", "App attiva in quel momento. È il contesto, non la sorgente audio."),
        "rename.title": t("Хто це — «%@»?", "Who is “%@”?", "Qui est « %@ » ?", "¿Quién es «%@»?", "Quem é «%@»?", "Wer ist „%@“?", "Chi è «%@»?"),
        "rename.placeholder": t("Ім’я", "Name", "Nom", "Nombre", "Nome", "Name", "Nome"),
        "rename.hint": t("Голос запам’ятається: наступного разу цю людину буде підписано автоматично.", "The voice will be remembered: next time this person is labeled automatically.", "La voix sera mémorisée : la prochaine fois, cette personne sera identifiée automatiquement.", "La voz se recordará: la próxima vez esta persona se etiquetará automáticamente.", "A voz será memorizada: da próxima vez esta pessoa será identificada automaticamente.", "Die Stimme wird gespeichert: Beim nächsten Mal wird diese Person automatisch benannt.", "La voce verrà memorizzata: la prossima volta questa persona sarà etichettata automaticamente."),
        "common.cancel": t("Скасувати", "Cancel", "Annuler", "Cancelar", "Cancelar", "Abbrechen", "Annulla"),
        "common.save": t("Зберегти", "Save", "Enregistrer", "Guardar", "Guardar", "Speichern", "Salva"),
        "common.delete": t("Видалити", "Delete", "Supprimer", "Eliminar", "Eliminar", "Löschen", "Elimina"),
        "common.close": t("Закрити", "Close", "Fermer", "Cerrar", "Fechar", "Schließen", "Chiudi"),
        "common.ok": t("OK", "OK", "OK", "OK", "OK", "OK", "OK"),
        "unit.min": t("хв", "min", "min", "min", "min", "Min", "min"),

        // — Классификация —
        "class.meeting": t("Відеозустріч (%@)", "Video meeting (%@)", "Réunion vidéo (%@)", "Reunión por vídeo (%@)", "Reunião por vídeo (%@)", "Videomeeting (%@)", "Riunione video (%@)"),
        "class.notTranscribed": t("Запис (не транскрибовано)", "Recording (not transcribed)", "Enregistrement (non transcrit)", "Grabación (sin transcribir)", "Gravação (não transcrita)", "Aufnahme (nicht transkribiert)", "Registrazione (non trascritta)"),
        "class.callOrMedia": t("Дзвінок або медіа + розмова", "Call or media + conversation", "Appel ou média + conversation", "Llamada o medios + conversación", "Chamada ou mídia + conversa", "Anruf oder Medien + Gespräch", "Chiamata o media + conversazione"),
        "class.systemAudio": t("Звук з комп’ютера (медіа/дзвінок)", "Computer audio (media/call)", "Audio de l’ordinateur (média/appel)", "Audio del ordenador (medios/llamada)", "Áudio do computador (mídia/chamada)", "Computer-Audio (Medien/Anruf)", "Audio del computer (media/chiamata)"),
        "class.offline": t("Офлайн-розмова біля комп’ютера", "Offline conversation at the computer", "Conversation hors ligne près de l’ordinateur", "Conversación sin conexión junto al ordenador", "Conversa offline junto ao computador", "Offline-Gespräch am Computer", "Conversazione offline al computer"),
        "class.silence": t("Тиша (мовлення не виявлено)", "Silence (no speech detected)", "Silence (aucune parole détectée)", "Silencio (sin voz detectada)", "Silêncio (sem fala detetada)", "Stille (keine Sprache erkannt)", "Silenzio (nessun parlato)"),

        // — Спикеры —
        "speaker.computer": t("Комп’ютер", "Computer", "Ordinateur", "Equipo", "Computador", "Computer", "Computer"),
        "speaker.n": t("Спікер %d", "Speaker %d", "Locuteur %d", "Hablante %d", "Falante %d", "Sprecher %d", "Speaker %d"),
        "self.default": t("я", "me", "moi", "yo", "eu", "ich", "io"),

        // — Кошик —
        "trash.title": t("Кошик", "Trash", "Corbeille", "Papelera", "Lixo", "Papierkorb", "Cestino"),
        "trash.count": t("%d елем.", "%d items", "%d éléments", "%d elementos", "%d itens", "%d Elemente", "%d elementi"),
        "trash.emptyBtn": t("Очистити кошик", "Empty Trash", "Vider la corbeille", "Vaciar papelera", "Esvaziar lixo", "Papierkorb leeren", "Svuota cestino"),
        "trash.confirmEmpty": t("Видалити весь вміст кошика безповоротно?", "Permanently delete all Trash contents?", "Supprimer définitivement tout le contenu de la corbeille ?", "¿Eliminar permanentemente todo el contenido de la papelera?", "Apagar permanentemente todo o conteúdo do lixo?", "Den gesamten Papierkorb-Inhalt endgültig löschen?", "Eliminare definitivamente tutto il contenuto del cestino?"),
        "trash.emptyTitle": t("Кошик порожній", "Trash is empty", "La corbeille est vide", "La papelera está vacía", "O lixo está vazio", "Papierkorb ist leer", "Il cestino è vuoto"),
        "trash.emptyDesc": t("Сюди потрапляє аудіо після транскрибування та видалені сесії", "Audio after transcription and deleted sessions land here", "L’audio après transcription et les sessions supprimées arrivent ici", "Aquí llegan el audio tras la transcripción y las sesiones eliminadas", "Aqui chegam o áudio após a transcrição e as sessões eliminadas", "Hier landen Audio nach der Transkription und gelöschte Sitzungen", "Qui arrivano l’audio dopo la trascrizione e le sessioni eliminate"),
        "trash.kindSession": t("сесія цілком", "whole session", "session entière", "sesión completa", "sessão inteira", "ganze Sitzung", "intera sessione"),
        "trash.kindAudio": t("аудіо (транскрипт збережено)", "audio (transcript kept)", "audio (transcription conservée)", "audio (transcripción guardada)", "áudio (transcrição mantida)", "Audio (Transkript behalten)", "audio (trascrizione conservata)"),
        "trash.restore": t("Відновити", "Restore", "Restaurer", "Restaurar", "Restaurar", "Wiederherstellen", "Ripristina"),
        "trash.deleteNow": t("Видалити зараз", "Delete now", "Supprimer maintenant", "Eliminar ahora", "Eliminar agora", "Jetzt löschen", "Elimina ora"),
        "trash.audioTitle": t("Аудіофайл", "Audio file", "Fichier audio", "Archivo de audio", "Ficheiro de áudio", "Audiodatei", "File audio"),
        "trash.audioDesc": t("Транскрипт цього запису залишився в сесії на таймлайні. Відновіть файл, якщо аудіо ще потрібне.", "The transcript of this recording stayed in the session on the timeline. Restore the file if you still need the audio.", "La transcription de cet enregistrement est restée dans la session sur la frise. Restaurez le fichier si vous avez encore besoin de l’audio.", "La transcripción de esta grabación quedó en la sesión de la línea de tiempo. Restaura el archivo si aún necesitas el audio.", "A transcrição desta gravação ficou na sessão da linha do tempo. Restaure o ficheiro se ainda precisar do áudio.", "Das Transkript dieser Aufnahme ist in der Sitzung in der Zeitleiste geblieben. Stelle die Datei wieder her, wenn du das Audio noch brauchst.", "La trascrizione di questa registrazione è rimasta nella sessione sulla timeline. Ripristina il file se ti serve ancora l’audio."),
        "trash.selectItem": t("Виберіть елемент", "Select an item", "Sélectionnez un élément", "Selecciona un elemento", "Selecione um item", "Element auswählen", "Seleziona un elemento"),
        "trash.noTranscript": t("Транскрипту немає — сесію не транскрибували перед видаленням.", "No transcript — the session wasn't transcribed before deletion.", "Pas de transcription — la session n’a pas été transcrite avant suppression.", "Sin transcripción: la sesión no se transcribió antes de eliminarla.", "Sem transcrição — a sessão não foi transcrita antes de ser eliminada.", "Kein Transkript — die Sitzung wurde vor dem Löschen nicht transkribiert.", "Nessuna trascrizione — la sessione non è stata trascritta prima dell’eliminazione."),
        "trash.leftSoon": t("видалиться під час найближчого очищення", "will be deleted at next cleanup", "sera supprimé au prochain nettoyage", "se eliminará en la próxima limpieza", "será apagado na próxima limpeza", "wird beim nächsten Aufräumen gelöscht", "verrà eliminato alla prossima pulizia"),
        "trash.leftDays": t("автовидалення через %d дн.", "auto-deletes in %d days", "suppression auto dans %d j", "se borra solo en %d días", "apaga sozinho em %d dias", "löscht sich in %d Tagen", "si elimina tra %d giorni"),
        "trash.leftHours": t("автовидалення через %d год", "auto-deletes in %d h", "suppression auto dans %d h", "se borra solo en %d h", "apaga sozinho em %d h", "löscht sich in %d Std", "si elimina tra %d h"),

        // — Настройки: вкладки —
        "tab.general": t("Основні", "General", "Général", "General", "Geral", "Allgemein", "Generale"),
        "tab.models": t("Моделі", "Models", "Modèles", "Modelos", "Modelos", "Modelle", "Modelli"),
        "tab.voices": t("Голоси", "Voices", "Voix", "Voces", "Vozes", "Stimmen", "Voci"),
        "tab.storage": t("Сховище", "Storage", "Stockage", "Almacenamiento", "Armazenamento", "Speicher", "Archiviazione"),

        // — Настройки: язык —
        "set.lang.section": t("Мова", "Language", "Langue", "Idioma", "Idioma", "Sprache", "Lingua"),
        "set.lang.label": t("Інтерфейс і саммарі", "Interface and summaries", "Interface et résumés", "Interfaz y resúmenes", "Interface e resumos", "Oberfläche und Zusammenfassungen", "Interfaccia e riassunti"),
        "set.lang.hint": t("Визначає мову застосунку та мову саммарі.", "Sets the app language and the language of summaries.", "Définit la langue de l’app et celle des résumés.", "Define el idioma de la app y el de los resúmenes.", "Define o idioma da app e o dos resumos.", "Legt die App-Sprache und die Sprache der Zusammenfassungen fest.", "Imposta la lingua dell’app e quella dei riassunti."),

        // — Настройки: хоткей —
        "set.hotkey.section": t("Гаряча клавіша", "Hotkey", "Raccourci", "Atajo", "Atalho", "Tastenkürzel", "Scorciatoia"),
        "set.hotkey.label": t("Старт/стоп запису", "Start/stop recording", "Démarrer/arrêter l’enregistrement", "Iniciar/detener grabación", "Iniciar/parar gravação", "Aufnahme starten/stoppen", "Avvia/ferma registrazione"),
        "set.hotkey.change": t("Змінити", "Change", "Modifier", "Cambiar", "Alterar", "Ändern", "Cambia"),
        "set.hotkey.capturing": t("Натисніть сполучення…", "Press a shortcut…", "Appuyez sur un raccourci…", "Pulsa una combinación…", "Prima uma combinação…", "Tastenkombination drücken…", "Premi una combinazione…"),

        // — Настройки: иконка —
        "set.icon.section": t("Іконка в menu bar", "Menu bar icon", "Icône de la barre de menus", "Icono de la barra de menús", "Ícone da barra de menus", "Menüleisten-Symbol", "Icona barra dei menu"),
        "set.icon.idle": t("Звичайний стан", "Idle state", "État au repos", "Estado inactivo", "Estado normal", "Ruhezustand", "Stato a riposo"),
        "set.icon.recording": t("Під час запису", "While recording", "Pendant l’enregistrement", "Durante la grabación", "Durante a gravação", "Während der Aufnahme", "Durante la registrazione"),
        "set.icon.hint": t("Емодзі замість «червоної крапки» — запис не впадає в око оточенню.", "Emoji instead of a red dot — recording isn't conspicuous to people around you.", "Emoji au lieu d’un point rouge — l’enregistrement est discret pour l’entourage.", "Emoji en vez de un punto rojo: la grabación no llama la atención.", "Emoji em vez de um ponto vermelho — a gravação não chama a atenção.", "Emoji statt rotem Punkt — die Aufnahme fällt der Umgebung nicht auf.", "Emoji al posto del punto rosso — la registrazione non dà nell’occhio."),

        // — Настройки: автодетект встреч —
        "set.meeting.section": t("Автовиявлення зустрічей", "Meeting auto-detect", "Détection automatique des réunions", "Detección automática de reuniones", "Deteção automática de reuniões", "Meeting-Erkennung", "Rilevamento riunioni"),
        "set.meeting.label": t("Коли застосунок вмикає мікрофон", "When an app turns on the microphone", "Quand une app active le micro", "Cuando una app activa el micrófono", "Quando uma app liga o microfone", "Wenn eine App das Mikrofon einschaltet", "Quando un’app accende il microfono"),
        "set.meeting.off": t("Нічого не робити", "Do nothing", "Ne rien faire", "No hacer nada", "Não fazer nada", "Nichts tun", "Non fare nulla"),
        "set.meeting.notify": t("Запропонувати записати", "Offer to record", "Proposer d’enregistrer", "Ofrecer grabar", "Sugerir gravar", "Aufnahme anbieten", "Proponi di registrare"),
        "set.meeting.auto": t("Записувати автоматично", "Record automatically", "Enregistrer automatiquement", "Grabar automáticamente", "Gravar automaticamente", "Automatisch aufnehmen", "Registra automaticamente"),
        "set.meeting.autostop": t("Зупиняти, коли мікрофон звільнився", "Stop when the microphone is released", "Arrêter quand le micro est libéré", "Detener cuando se libere el micrófono", "Parar quando o microfone for libertado", "Stoppen, wenn das Mikrofon frei ist", "Ferma quando il microfono è libero"),
        "set.meeting.hint": t("Vaqlo помічає, що Zoom, Meet, Teams або інший застосунок почали використовувати мікрофон, — щоб ви не забули ввімкнути запис.", "Vaqlo notices when Zoom, Meet, Teams or another app starts using the microphone — so you don't forget to record.", "Vaqlo détecte quand Zoom, Meet, Teams ou une autre app utilise le micro — pour ne pas oublier d’enregistrer.", "Vaqlo detecta cuando Zoom, Meet, Teams u otra app empieza a usar el micrófono, para que no olvides grabar.", "O Vaqlo nota quando o Zoom, Meet, Teams ou outra app começa a usar o microfone — para não se esquecer de gravar.", "Vaqlo bemerkt, wenn Zoom, Meet, Teams oder eine andere App das Mikrofon nutzt — damit du die Aufnahme nicht vergisst.", "Vaqlo nota quando Zoom, Meet, Teams o un’altra app inizia a usare il microfono — così non dimentichi di registrare."),
        "set.names.section": t("Імена тих, хто говорить", "Speaker names", "Noms des intervenants", "Nombres de quien habla", "Nomes de quem fala", "Namen der Sprechenden", "Nomi di chi parla"),
        "set.names.label": t("Розпізнавати імена у дзвінках (Slack)", "Recognize names in calls (Slack)", "Reconnaître les noms en appel (Slack)", "Reconocer nombres en llamadas (Slack)", "Reconhecer nomes em chamadas (Slack)", "Namen in Anrufen erkennen (Slack)", "Riconoscere i nomi nelle chiamate (Slack)"),
        "set.names.hint": t("Vaqlo читає, хто говорить, з вікна Slack-хадла (потрібен «Універсальний доступ») і підписує репліки справжніми іменами. Імена прив’язуються до голосів — далі впізнаються й без застосунку.", "Vaqlo reads who's speaking from the Slack huddle window (needs Accessibility) and labels lines with real names. Names bind to voices — later recognized even without the app.", "Vaqlo lit qui parle depuis la fenêtre du huddle Slack (nécessite l’Accessibilité) et étiquette avec les vrais noms. Les noms sont liés aux voix — reconnus ensuite même sans l’app.", "Vaqlo lee quién habla desde la ventana del huddle de Slack (requiere Accesibilidad) y etiqueta con nombres reales. Los nombres se vinculan a las voces y luego se reconocen sin la app.", "O Vaqlo lê quem fala na janela do huddle do Slack (requer Acessibilidade) e identifica com nomes reais. Os nomes ligam-se às vozes — depois reconhecidos sem a app.", "Vaqlo liest aus dem Slack-Huddle-Fenster, wer spricht (benötigt Bedienungshilfen), und beschriftet mit echten Namen. Namen werden an Stimmen gebunden — später auch ohne App erkannt.", "Vaqlo legge chi parla dalla finestra dell’huddle di Slack (richiede Accessibilità) ed etichetta con nomi reali. I nomi si legano alle voci — poi riconosciuti anche senza l’app."),
        "set.names.grant": t("Надати доступ", "Grant access", "Autoriser l’accès", "Conceder acceso", "Conceder acesso", "Zugriff erlauben", "Concedi accesso"),
        "set.names.granted": t("Доступ надано", "Access granted", "Accès autorisé", "Acceso concedido", "Acesso concedido", "Zugriff erteilt", "Accesso concesso"),
        "onb.ax.title": t("Імена тих, хто говорить", "Speaker names", "Noms des intervenants", "Nombres de quien habla", "Nomes de quem fala", "Namen der Sprechenden", "Nomi di chi parla"),
        "onb.ax.sub": t("Універсальний доступ — щоб читати імена з вікна Slack-хадла (необов’язково)", "Accessibility — to read names from the Slack huddle window (optional)", "Accessibilité — pour lire les noms depuis le huddle Slack (facultatif)", "Accesibilidad: para leer nombres del huddle de Slack (opcional)", "Acessibilidade — para ler nomes do huddle do Slack (opcional)", "Bedienungshilfen — um Namen aus dem Slack-Huddle zu lesen (optional)", "Accessibilità — per leggere i nomi dall’huddle di Slack (opzionale)"),
        "set.meeting.enable": t("Виявляти зустрічі (за використанням мікрофона)", "Detect meetings (by microphone use)", "Détecter les réunions (usage du micro)", "Detectar reuniones (uso del micrófono)", "Detetar reuniões (uso do microfone)", "Meetings erkennen (Mikrofonnutzung)", "Rileva riunioni (uso del microfono)"),
        "set.meeting.apps": t("Застосунки-тригери", "Trigger apps", "Apps déclencheuses", "Apps que activan", "Apps de gatilho", "Auslöser-Apps", "App di attivazione"),
        "set.meeting.appsHint": t("Як реагувати, коли застосунок вмикає мікрофон. Голосові асистенти й диктовники поставте на «Ігнорувати», щоб вони не запускали запис. Невідомі застосунки спитають при першій появі.", "How to react when an app turns on the microphone. Set voice assistants and dictation tools to “Ignore” so they don't start a recording. Unknown apps are asked on first appearance.", "Comment réagir quand une app active le micro. Mettez les assistants vocaux et la dictée sur « Ignorer ». Les apps inconnues sont demandées à la première apparition.", "Cómo reaccionar cuando una app activa el micrófono. Pon los asistentes de voz y dictado en «Ignorar». Las apps desconocidas se preguntan la primera vez.", "Como reagir quando uma app liga o microfone. Coloca assistentes de voz e ditado em «Ignorar». Apps desconhecidas são perguntadas na primeira vez.", "Wie reagiert werden soll, wenn eine App das Mikrofon einschaltet. Sprachassistenten und Diktierwerkzeuge auf „Ignorieren“ setzen. Unbekannte Apps werden beim ersten Mal gefragt.", "Come reagire quando un’app accende il microfono. Imposta assistenti vocali e dettatura su «Ignora». Le app sconosciute vengono chieste alla prima comparsa."),
        "set.meeting.addApp": t("Додати застосунок…", "Add app…", "Ajouter une app…", "Añadir app…", "Adicionar app…", "App hinzufügen…", "Aggiungi app…"),
        "set.meeting.noApps": t("Поки немає правил. Вони з’являться, коли застосунок уперше задіє мікрофон, або додайте вручну.", "No rules yet. They appear when an app first uses the microphone, or add one manually.", "Aucune règle. Elles apparaissent quand une app utilise le micro, ou ajoutez-en une.", "Sin reglas todavía. Aparecen cuando una app usa el micrófono, o añade una.", "Sem regras ainda. Aparecem quando uma app usa o microfone, ou adicione uma.", "Noch keine Regeln. Sie erscheinen, wenn eine App das Mikrofon nutzt, oder füge eine hinzu.", "Ancora nessuna regola. Compaiono quando un’app usa il microfono, o aggiungine una."),
        "policy.auto": t("Записувати автоматично", "Record automatically", "Enregistrer automatiquement", "Grabar automáticamente", "Gravar automaticamente", "Automatisch aufnehmen", "Registra automaticamente"),
        "policy.ask": t("Питати щоразу", "Ask each time", "Demander à chaque fois", "Preguntar cada vez", "Perguntar sempre", "Jedes Mal fragen", "Chiedi ogni volta"),
        "policy.never": t("Ігнорувати", "Ignore", "Ignorer", "Ignorar", "Ignorar", "Ignorieren", "Ignora"),
        "notif.firstSeen.title": t("Нове застосування мікрофона", "New microphone use", "Nouvelle utilisation du micro", "Nuevo uso del micrófono", "Novo uso do microfone", "Neue Mikrofonnutzung", "Nuovo uso del microfono"),
        "notif.firstSeen.body": t("%@ задіяв мікрофон. Записувати зустрічі з нього?", "%@ used the microphone. Record meetings from it?", "%@ a utilisé le micro. Enregistrer ses réunions ?", "%@ usó el micrófono. ¿Grabar reuniones desde esta app?", "%@ usou o microfone. Gravar reuniões a partir dela?", "%@ hat das Mikrofon genutzt. Meetings davon aufnehmen?", "%@ ha usato il microfono. Registrare le riunioni da quest’app?"),
        "notif.policy.always": t("Завжди", "Always", "Toujours", "Siempre", "Sempre", "Immer", "Sempre"),
        "notif.policy.ask": t("Питати", "Ask", "Demander", "Preguntar", "Perguntar", "Fragen", "Chiedi"),
        "notif.policy.never": t("Ніколи", "Never", "Jamais", "Nunca", "Nunca", "Nie", "Mai"),
        "meeting.row": t("Зустріч", "Meeting", "Réunion", "Reunión", "Reunião", "Meeting", "Riunione"),
        "meeting.participants": t("Учасники", "Participants", "Participants", "Participantes", "Participantes", "Teilnehmer", "Partecipanti"),
        "meeting.largeGroup": t("Велика група людей (%d)", "Large group (%d)", "Grand groupe (%d)", "Grupo grande (%d)", "Grupo grande (%d)", "Große Gruppe (%d)", "Gruppo numeroso (%d)"),
        "meeting.untitled": t("Без назви", "Untitled", "Sans titre", "Sin título", "Sem título", "Ohne Titel", "Senza titolo"),
        "set.cal.section": t("Календар", "Calendar", "Calendrier", "Calendario", "Calendário", "Kalender", "Calendario"),
        "set.cal.label": t("Підписувати записи зустрічами з календаря", "Label recordings with calendar meetings", "Étiqueter avec les réunions du calendrier", "Etiquetar con reuniones del calendario", "Identificar com reuniões do calendário", "Aufnahmen mit Kalender-Meetings beschriften", "Etichetta con le riunioni del calendario"),
        "set.cal.hint": t("Vaqlo бере назву зустрічі та учасників із системного календаря (зокрема підключеного Google). Більше 20 учасників — «велика група людей».", "Vaqlo takes the meeting title and participants from the system calendar (including a connected Google account). More than 20 participants → “large group”.", "Vaqlo prend le titre et les participants depuis le calendrier système (y compris un compte Google connecté). Plus de 20 participants → « grand groupe ».", "Vaqlo toma el título y los participantes del calendario del sistema (incluida una cuenta de Google conectada). Más de 20 participantes → «grupo grande».", "O Vaqlo usa o título e os participantes do calendário do sistema (incluindo uma conta Google ligada). Mais de 20 participantes → «grupo grande».", "Vaqlo übernimmt Titel und Teilnehmer aus dem Systemkalender (inkl. verbundenem Google-Konto). Mehr als 20 Teilnehmer → „große Gruppe“.", "Vaqlo prende titolo e partecipanti dal calendario di sistema (incluso un account Google collegato). Più di 20 partecipanti → «gruppo numeroso»."),
        "onb.cal.title": t("Календар", "Calendar", "Calendrier", "Calendario", "Calendário", "Kalender", "Calendario"),
        "onb.cal.sub": t("Щоб підписувати записи назвою зустрічі та учасниками (необов’язково)", "To label recordings with the meeting title and participants (optional)", "Pour étiqueter avec le titre et les participants (facultatif)", "Para etiquetar con el título y los participantes (opcional)", "Para identificar com o título e participantes (opcional)", "Um Aufnahmen mit Titel und Teilnehmern zu beschriften (optional)", "Per etichettare con titolo e partecipanti (opzionale)"),
        "common.granted": t("Доступ надано", "Access granted", "Accès autorisé", "Acceso concedido", "Acesso concedido", "Zugriff erteilt", "Accesso concesso"),

        // — Настройки: транскрипт —
        "set.transcript.section": t("Транскрипт", "Transcript", "Transcription", "Transcripción", "Transcrição", "Transkript", "Trascrizione"),
        "set.selflabel.label": t("Підпис ваших реплік", "Label for your lines", "Étiquette de vos répliques", "Etiqueta de tus intervenciones", "Etiqueta das suas falas", "Bezeichnung deiner Wortbeiträge", "Etichetta dei tuoi interventi"),
        "set.selflabel.hint": t("Так підписується все, що записано з мікрофона, — у вікні та в md-файлах.", "Labels everything recorded from the microphone — in the window and in the md files.", "Étiquette tout ce qui est enregistré au micro — dans la fenêtre et les fichiers md.", "Etiqueta todo lo grabado por el micrófono, en la ventana y en los archivos md.", "Identifica tudo o que é gravado pelo microfone — na janela e nos ficheiros md.", "Bezeichnet alles, was über das Mikrofon aufgenommen wird — im Fenster und in den md-Dateien.", "Etichetta tutto ciò che viene registrato dal microfono — nella finestra e nei file md."),

        // — Настройки: язык транскрибации —
        "set.translang.section": t("Мова транскрибування", "Transcription language", "Langue de transcription", "Idioma de transcripción", "Idioma da transcrição", "Transkriptionssprache", "Lingua di trascrizione"),
        "set.translang.label": t("Мова", "Language", "Langue", "Idioma", "Idioma", "Sprache", "Lingua"),
        "set.translang.auto": t("Автовизначення", "Auto-detect", "Détection auto", "Detección automática", "Deteção automática", "Automatisch", "Rilevamento automatico"),
        "set.translang.hint": t("«Авто» визначає мову на кожному 5-хвилинному фрагменті окремо.", "“Auto” detects the language of each 5-minute chunk separately.", "« Auto » détecte la langue de chaque segment de 5 min séparément.", "«Auto» detecta el idioma de cada fragmento de 5 min por separado.", "«Auto» deteta o idioma de cada fragmento de 5 min separadamente.", "„Auto“ erkennt die Sprache jedes 5-Minuten-Abschnitts einzeln.", "«Auto» rileva la lingua di ogni segmento di 5 min separatamente."),

        // — Настройки: расписание —
        "set.schedule.section": t("Транскрибування за розкладом", "Scheduled transcription", "Transcription planifiée", "Transcripción programada", "Transcrição agendada", "Geplante Transkription", "Trascrizione pianificata"),
        "set.schedule.mode": t("Режим", "Mode", "Mode", "Modo", "Modo", "Modus", "Modalità"),
        "set.schedule.manual": t("Вручну", "Manual", "Manuel", "Manual", "Manual", "Manuell", "Manuale"),
        "set.schedule.everyN": t("Кожні N годин", "Every N hours", "Toutes les N heures", "Cada N horas", "A cada N horas", "Alle N Stunden", "Ogni N ore"),
        "set.schedule.daily": t("Щодня о…", "Daily at…", "Chaque jour à…", "Cada día a las…", "Diariamente às…", "Täglich um…", "Ogni giorno alle…"),
        "set.schedule.everyHours": t("Кожні %d год", "Every %d h", "Toutes les %d h", "Cada %d h", "A cada %d h", "Alle %d Std", "Ogni %d h"),
        "set.schedule.time": t("Час", "Time", "Heure", "Hora", "Hora", "Uhrzeit", "Ora"),

        // — Настройки: аудио/хранение —
        "set.audio.section": t("Аудіо після транскрибування", "Audio after transcription", "Audio après transcription", "Audio tras la transcripción", "Áudio após a transcrição", "Audio nach der Transkription", "Audio dopo la trascrizione"),
        "set.audio.retention": t("Тримати в Кошику %d дн., потім видаляти", "Keep in Trash for %d days, then delete", "Garder %d j dans la corbeille, puis supprimer", "Mantener %d días en la papelera y luego eliminar", "Manter %d dias no lixo e depois apagar", "%d Tage im Papierkorb behalten, dann löschen", "Tieni %d giorni nel cestino, poi elimina"),
        "set.audio.hint": t("Аудіо переїжджає до Кошика одразу після транскрибування й видаляється саме. Транскрипти не видаляються ніколи — лише вручну.", "Audio moves to the Trash right after transcription and deletes itself. Transcripts are never deleted — only manually.", "L’audio va à la corbeille juste après la transcription et se supprime tout seul. Les transcriptions ne sont jamais supprimées — seulement manuellement.", "El audio va a la papelera justo tras la transcripción y se elimina solo. Las transcripciones nunca se eliminan, solo manualmente.", "O áudio vai para o lixo logo após a transcrição e apaga-se sozinho. As transcrições nunca são apagadas — só manualmente.", "Audio wandert direkt nach der Transkription in den Papierkorb und löscht sich selbst. Transkripte werden nie automatisch gelöscht — nur manuell.", "L’audio va nel cestino subito dopo la trascrizione e si elimina da solo. Le trascrizioni non vengono mai eliminate — solo manualmente."),

        // — Настройки: экспорт/логин —
        "set.export.section": t("Експорт", "Export", "Exportation", "Exportación", "Exportação", "Export", "Esportazione"),
        "set.export.none": t("Теку не вибрано", "No folder selected", "Aucun dossier sélectionné", "Sin carpeta seleccionada", "Nenhuma pasta selecionada", "Kein Ordner ausgewählt", "Nessuna cartella selezionata"),
        "set.export.choose": t("Вибрати…", "Choose…", "Choisir…", "Elegir…", "Escolher…", "Auswählen…", "Scegli…"),
        "set.login": t("Запускати під час входу в систему", "Launch at login", "Lancer à la connexion", "Abrir al iniciar sesión", "Abrir ao iniciar sessão", "Beim Anmelden starten", "Avvia all’accesso"),

        // — Настройки: модели —
        "set.models.whisper": t("Whisper — транскрибування", "Whisper — transcription", "Whisper — transcription", "Whisper — transcripción", "Whisper — transcrição", "Whisper — Transkription", "Whisper — trascrizione"),
        "set.models.llm": t("LLM — саммарі зустрічей", "LLM — meeting summaries", "LLM — résumés de réunions", "LLM — resúmenes de reuniones", "LLM — resumos de reuniões", "LLM — Meeting-Zusammenfassungen", "LLM — riassunti riunioni"),
        "set.models.autosum": t("Робити саммарі автоматично після транскрибування", "Summarize automatically after transcription", "Résumer automatiquement après la transcription", "Resumir automáticamente tras la transcripción", "Resumir automaticamente após a transcrição", "Nach der Transkription automatisch zusammenfassen", "Riassumi automaticamente dopo la trascrizione"),
        "set.models.voice": t("Розпізнавання голосів (FluidAudio)", "Voice recognition (FluidAudio)", "Reconnaissance vocale (FluidAudio)", "Reconocimiento de voz (FluidAudio)", "Reconhecimento de voz (FluidAudio)", "Stimmerkennung (FluidAudio)", "Riconoscimento voce (FluidAudio)"),
        "set.models.activehint": t("Активна модель (галочка) використовується для всіх операцій. Файли — в Application Support/Vaqlo/models.", "The active model (checkbox) is used for all operations. Files are stored in Application Support/Vaqlo/models.", "Le modèle actif (case cochée) est utilisé pour toutes les opérations. Les fichiers sont dans Application Support/Vaqlo/models.", "El modelo activo (casilla) se usa para todas las operaciones. Los archivos están en Application Support/Vaqlo/models.", "O modelo ativo (caixa marcada) é usado em todas as operações. Os ficheiros estão em Application Support/Vaqlo/models.", "Das aktive Modell (Häkchen) wird für alle Vorgänge verwendet. Dateien liegen in Application Support/Vaqlo/models.", "Il modello attivo (spunta) è usato per tutte le operazioni. I file sono in Application Support/Vaqlo/models."),
        "model.download": t("Завантажити", "Download", "Télécharger", "Descargar", "Descarregar", "Laden", "Scarica"),
        "model.cancel": t("Скасувати", "Cancel", "Annuler", "Cancelar", "Cancelar", "Abbrechen", "Annulla"),
        "model.recommended": t("рекомендовано", "recommended", "recommandé", "recomendado", "recomendado", "empfohlen", "consigliato"),

        // — Модели: описания —
        "model.whisper.turbo": t("Найкраща якість для української та англійської", "Best quality for Ukrainian and English", "Meilleure qualité pour l’ukrainien et l’anglais", "Mejor calidad para ucraniano e inglés", "Melhor qualidade para ucraniano e inglês", "Beste Qualität für Ukrainisch und Englisch", "Migliore qualità per ucraino e inglese"),
        "model.whisper.small": t("Швидше, помітно слабше на українській", "Faster, noticeably weaker on Ukrainian", "Plus rapide, nettement moins bon en ukrainien", "Más rápido, claramente más débil en ucraniano", "Mais rápido, visivelmente pior em ucraniano", "Schneller, deutlich schwächer bei Ukrainisch", "Più veloce, nettamente più debole in ucraino"),
        "model.whisper.base": t("Чорнове якість, дуже швидко", "Draft quality, very fast", "Qualité brouillon, très rapide", "Calidad de borrador, muy rápido", "Qualidade de rascunho, muito rápido", "Entwurfsqualität, sehr schnell", "Qualità bozza, molto veloce"),
        "model.llm.qwen": t("Найкраща якість саммарі багатьма мовами", "Best summary quality across many languages", "Meilleure qualité de résumé dans de nombreuses langues", "Mejor calidad de resumen en muchos idiomas", "Melhor qualidade de resumo em muitos idiomas", "Beste Zusammenfassungsqualität in vielen Sprachen", "Migliore qualità dei riassunti in molte lingue"),
        "model.llm.llama3b": t("Трохи легша, англійська сильніша за інші", "A bit lighter, English stronger than the rest", "Un peu plus légère, l’anglais meilleur que le reste", "Algo más ligera, el inglés mejor que el resto", "Um pouco mais leve, inglês melhor que o resto", "Etwas leichter, Englisch besser als der Rest", "Un po’ più leggera, inglese migliore del resto"),
        "model.llm.llama1b": t("Дуже швидка, чорнова якість", "Very fast, draft quality", "Très rapide, qualité brouillon", "Muy rápida, calidad de borrador", "Muito rápida, qualidade de rascunho", "Sehr schnell, Entwurfsqualität", "Molto veloce, qualità bozza"),

        // — Голоса (CoreML) —
        "voice.coreml.title": t("CoreML-моделі діаризації", "Diarization CoreML models", "Modèles CoreML de diarisation", "Modelos CoreML de diarización", "Modelos CoreML de diarização", "CoreML-Diarisierungsmodelle", "Modelli CoreML di diarizzazione"),
        "voice.coreml.notyet": t("Завантажаться автоматично при першому транскрибуванні", "Will download automatically on first transcription", "Se téléchargeront automatiquement à la première transcription", "Se descargarán automáticamente en la primera transcripción", "Serão descarregados automaticamente na primeira transcrição", "Werden bei der ersten Transkription automatisch geladen", "Verranno scaricati automaticamente alla prima trascrizione"),
        "voice.coreml.downloaded": t("Завантажені автоматично · %d МБ", "Downloaded automatically · %d MB", "Téléchargés automatiquement · %d Mo", "Descargados automáticamente · %d MB", "Descarregados automaticamente · %d MB", "Automatisch geladen · %d MB", "Scaricati automaticamente · %d MB"),

        // — Голоса (профили) —
        "voices.section": t("Запам’ятані голоси", "Remembered voices", "Voix mémorisées", "Voces recordadas", "Vozes memorizadas", "Gespeicherte Stimmen", "Voci memorizzate"),
        "voices.empty": t("Поки порожньо. Перейменуйте спікера в транскрипті («Спікер 1» → ім’я) — голос запам’ятається й розпізнаватиметься в наступних записах.", "Empty so far. Rename a speaker in a transcript (“Speaker 1” → name) — the voice will be remembered and recognized in future recordings.", "Vide pour l’instant. Renommez un locuteur dans une transcription (« Locuteur 1 » → nom) — la voix sera mémorisée et reconnue.", "Vacío por ahora. Renombra a un hablante en una transcripción («Hablante 1» → nombre): la voz se recordará y se reconocerá.", "Vazio por agora. Renomeie um falante numa transcrição («Falante 1» → nome) — a voz será memorizada e reconhecida.", "Noch leer. Benenne einen Sprecher in einem Transkript um („Sprecher 1“ → Name) — die Stimme wird gespeichert und wiedererkannt.", "Per ora vuoto. Rinomina un interlocutore in una trascrizione («Speaker 1» → nome) — la voce verrà memorizzata e riconosciuta."),
        "voices.you": t("це ви · зразків: %d", "this is you · samples: %d", "c’est vous · échantillons : %d", "eres tú · muestras: %d", "é você · amostras: %d", "das bist du · Proben: %d", "sei tu · campioni: %d"),
        "voices.samples": t("зразків: %d", "samples: %d", "échantillons : %d", "muestras: %d", "amostras: %d", "Proben: %d", "campioni: %d"),
        "voices.rename": t("Перейменувати", "Rename", "Renommer", "Renombrar", "Renomear", "Umbenennen", "Rinomina"),
        "voices.hint": t("Видалення голосу не змінює вже готові транскрипти — лише перестає впізнавати його в нових записах.", "Deleting a voice doesn't change existing transcripts — it just stops recognizing it in new recordings.", "Supprimer une voix ne change pas les transcriptions existantes — elle cesse juste d’être reconnue dans les nouveaux enregistrements.", "Eliminar una voz no cambia las transcripciones existentes: solo deja de reconocerla en nuevas grabaciones.", "Eliminar uma voz não altera as transcrições existentes — apenas deixa de a reconhecer em novas gravações.", "Das Löschen einer Stimme ändert bestehende Transkripte nicht — sie wird nur in neuen Aufnahmen nicht mehr erkannt.", "Eliminare una voce non cambia le trascrizioni esistenti — smette solo di riconoscerla nelle nuove registrazioni."),
        "voices.renameTitle": t("Перейменувати «%@»", "Rename “%@”", "Renommer « %@ »", "Renombrar «%@»", "Renomear «%@»", "„%@“ umbenennen", "Rinomina «%@»"),

        // — Хранилище —
        "storage.records": t("Записи", "Recordings", "Enregistrements", "Grabaciones", "Gravações", "Aufnahmen", "Registrazioni"),
        "storage.total": t("Усього сесій", "Total sessions", "Total des sessions", "Sesiones en total", "Total de sessões", "Sitzungen gesamt", "Sessioni totali"),
        "storage.done": t("Транскрибовано", "Transcribed", "Transcrites", "Transcritas", "Transcritas", "Transkribiert", "Trascritte"),
        "storage.pending": t("Очікують", "Waiting", "En attente", "En espera", "Em espera", "Wartend", "In attesa"),
        "storage.recorded": t("Записано всього", "Recorded in total", "Enregistré au total", "Grabado en total", "Gravado no total", "Insgesamt aufgenommen", "Registrato in totale"),
        "storage.week": t("За цей тиждень", "This week", "Cette semaine", "Esta semana", "Esta semana", "Diese Woche", "Questa settimana"),
        "storage.disk": t("Зайнято на диску", "Disk usage", "Espace disque utilisé", "Uso del disco", "Uso do disco", "Belegter Speicher", "Spazio su disco"),
        "storage.audio": t("Аудіо (не оброблено)", "Audio (unprocessed)", "Audio (non traité)", "Audio (sin procesar)", "Áudio (não processado)", "Audio (unbearbeitet)", "Audio (non elaborato)"),
        "storage.trash": t("Аудіо в Кошику", "Audio in Trash", "Audio dans la corbeille", "Audio en la papelera", "Áudio no lixo", "Audio im Papierkorb", "Audio nel cestino"),
        "storage.transcripts": t("Транскрипти та саммарі", "Transcripts and summaries", "Transcriptions et résumés", "Transcripciones y resúmenes", "Transcrições e resumos", "Transkripte und Zusammenfassungen", "Trascrizioni e riassunti"),
        "storage.models": t("Моделі Whisper / LLM", "Whisper / LLM models", "Modèles Whisper / LLM", "Modelos Whisper / LLM", "Modelos Whisper / LLM", "Whisper-/LLM-Modelle", "Modelli Whisper / LLM"),
        "storage.diar": t("Моделі розпізнавання голосів", "Voice recognition models", "Modèles de reconnaissance vocale", "Modelos de reconocimiento de voz", "Modelos de reconhecimento de voz", "Stimmerkennungsmodelle", "Modelli di riconoscimento voce"),
        "storage.totalSize": t("Разом", "Total", "Total", "Total", "Total", "Gesamt", "Totale"),
        "storage.openFolder": t("Відкрити теку даних", "Open data folder", "Ouvrir le dossier de données", "Abrir carpeta de datos", "Abrir pasta de dados", "Datenordner öffnen", "Apri cartella dati"),
        "unit.minLong": t("%d хв", "%d min", "%d min", "%d min", "%d min", "%d Min", "%d min"),
        "unit.hours": t("%.1f год", "%.1f h", "%.1f h", "%.1f h", "%.1f h", "%.1f Std", "%.1f h"),
        "unit.gb": t("%.1f ГБ", "%.1f GB", "%.1f Go", "%.1f GB", "%.1f GB", "%.1f GB", "%.1f GB"),
        "unit.mb": t("%d МБ", "%d MB", "%d Mo", "%d MB", "%d MB", "%d MB", "%d MB"),
        "set.icon.emojiHelp": t("Можна вставити будь-який емодзі", "You can paste any emoji", "Vous pouvez coller n’importe quel emoji", "Puedes pegar cualquier emoji", "Pode colar qualquer emoji", "Du kannst ein beliebiges Emoji einfügen", "Puoi incollare qualsiasi emoji"),
        "set.title": t("Налаштування Vaqlo", "Vaqlo Settings", "Réglages Vaqlo", "Ajustes de Vaqlo", "Definições do Vaqlo", "Vaqlo-Einstellungen", "Impostazioni Vaqlo"),

        // — Онбординг —
        "onb.welcome": t("Ласкаво просимо до Vaqlo", "Welcome to Vaqlo", "Bienvenue dans Vaqlo", "Bienvenido a Vaqlo", "Bem-vindo ao Vaqlo", "Willkommen bei Vaqlo", "Benvenuto in Vaqlo"),
        "onb.subtitle": t("Локальний диктофон зустрічей: запис, транскрибування та саммарі — все на вашому Mac, без хмари.", "A local meeting recorder: recording, transcription and summaries — all on your Mac, no cloud.", "Un enregistreur de réunions local : enregistrement, transcription et résumés — tout sur votre Mac, sans cloud.", "Una grabadora de reuniones local: grabación, transcripción y resúmenes, todo en tu Mac, sin nube.", "Um gravador de reuniões local: gravação, transcrição e resumos — tudo no seu Mac, sem nuvem.", "Ein lokaler Meeting-Recorder: Aufnahme, Transkription und Zusammenfassungen — alles auf deinem Mac, ohne Cloud.", "Un registratore di riunioni locale: registrazione, trascrizione e riassunti — tutto sul tuo Mac, senza cloud."),
        "onb.mic.title": t("Мікрофон", "Microphone", "Microphone", "Micrófono", "Microfone", "Mikrofon", "Microfono"),
        "onb.mic.sub": t("Запис вашого голосу", "Recording your voice", "Enregistrement de votre voix", "Grabar tu voz", "Gravar a sua voz", "Aufnahme deiner Stimme", "Registrazione della tua voce"),
        "onb.allow": t("Дозволити", "Allow", "Autoriser", "Permitir", "Permitir", "Erlauben", "Consenti"),
        "onb.openSettings": t("Відкрити налаштування", "Open Settings", "Ouvrir les réglages", "Abrir Ajustes", "Abrir Definições", "Einstellungen öffnen", "Apri Impostazioni"),
        "onb.sys.title": t("Системний звук", "System audio", "Audio du système", "Audio del sistema", "Áudio do sistema", "Systemton", "Audio di sistema"),
        "onb.sys.sub": t("Запис того, що грає в динаміках (Zoom, відео). Запит з’явиться під час першого запису.", "Recording what plays through the speakers (Zoom, video). The prompt appears on first recording.", "Enregistre ce qui passe par les haut-parleurs (Zoom, vidéo). La demande apparaît au premier enregistrement.", "Graba lo que suena por los altavoces (Zoom, vídeo). El aviso aparece en la primera grabación.", "Grava o que toca nas colunas (Zoom, vídeo). O pedido aparece na primeira gravação.", "Nimmt auf, was über die Lautsprecher läuft (Zoom, Video). Die Abfrage erscheint bei der ersten Aufnahme.", "Registra ciò che esce dagli altoparlanti (Zoom, video). La richiesta appare alla prima registrazione."),
        "onb.notif.title": t("Сповіщення", "Notifications", "Notifications", "Notificaciones", "Notificações", "Mitteilungen", "Notifiche"),
        "onb.notif.sub": t("«Схоже, почалася зустріч — записати?»", "“Looks like a meeting started — record?”", "« Une réunion semble avoir commencé — enregistrer ? »", "«Parece que empezó una reunión, ¿grabar?»", "«Parece que começou uma reunião — gravar?»", "„Sieht aus wie ein Meeting — aufnehmen?“", "«Sembra iniziata una riunione — registrare?»"),
        "onb.login.title": t("Запуск під час входу", "Launch at login", "Lancement à la connexion", "Abrir al iniciar sesión", "Abrir ao iniciar sessão", "Beim Anmelden starten", "Avvia all’accesso"),
        "onb.login.sub": t("Щоб Vaqlo завжди був готовий записувати", "So Vaqlo is always ready to record", "Pour que Vaqlo soit toujours prêt à enregistrer", "Para que Vaqlo siempre esté listo para grabar", "Para o Vaqlo estar sempre pronto a gravar", "Damit Vaqlo immer aufnahmebereit ist", "Così Vaqlo è sempre pronto a registrare"),
        "onb.login.on": t("Увімкнути", "Enable", "Activer", "Activar", "Ativar", "Aktivieren", "Attiva"),
        "onb.login.off": t("Вимкнути", "Disable", "Désactiver", "Desactivar", "Desativar", "Deaktivieren", "Disattiva"),
        "onb.hotkey": t("Гаряча клавіша запису: %@", "Recording hotkey: %@", "Raccourci d’enregistrement : %@", "Atajo de grabación: %@", "Atalho de gravação: %@", "Aufnahme-Tastenkürzel: %@", "Scorciatoia di registrazione: %@"),
        "onb.done": t("Готово", "Done", "Terminé", "Listo", "Concluído", "Fertig", "Fatto"),

        // — Уведомления —
        "notif.meeting.title": t("Схоже, почалася зустріч", "Looks like a meeting started", "Une réunion semble avoir commencé", "Parece que empezó una reunión", "Parece que começou uma reunião", "Sieht nach einem Meeting aus", "Sembra iniziata una riunione"),
        "notif.meeting.body": t("%@ використовує мікрофон. Записати?", "%@ is using the microphone. Record?", "%@ utilise le micro. Enregistrer ?", "%@ está usando el micrófono. ¿Grabar?", "%@ está a usar o microfone. Gravar?", "%@ verwendet das Mikrofon. Aufnehmen?", "%@ sta usando il microfono. Registrare?"),
        "notif.record": t("Записати", "Record", "Enregistrer", "Grabar", "Gravar", "Aufnehmen", "Registra"),
        "notif.auto.title": t("Vaqlo записує зустріч", "Vaqlo is recording the meeting", "Vaqlo enregistre la réunion", "Vaqlo está grabando la reunión", "O Vaqlo está a gravar a reunião", "Vaqlo nimmt das Meeting auf", "Vaqlo sta registrando la riunione"),
        "notif.auto.body": t("%@ використовує мікрофон — запис почався автоматично.", "%@ is using the microphone — recording started automatically.", "%@ utilise le micro — l’enregistrement a démarré automatiquement.", "%@ está usando el micrófono: la grabación empezó automáticamente.", "%@ está a usar o microfone — a gravação começou automaticamente.", "%@ verwendet das Mikrofon — die Aufnahme startete automatisch.", "%@ sta usando il microfono — la registrazione è partita automaticamente."),

        // — Ошибки —
        "err.title": t("Помилка", "Error", "Erreur", "Error", "Erro", "Fehler", "Errore"),
        "err.mic": t("Немає доступу до мікрофона. Дозвольте в Системних налаштуваннях → Конфіденційність → Мікрофон.", "No microphone access. Allow it in System Settings → Privacy → Microphone.", "Pas d’accès au micro. Autorisez-le dans Réglages Système → Confidentialité → Microphone.", "Sin acceso al micrófono. Permítelo en Ajustes del Sistema → Privacidad → Micrófono.", "Sem acesso ao microfone. Permita em Definições do Sistema → Privacidade → Microfone.", "Kein Mikrofonzugriff. Erlaube ihn in Systemeinstellungen → Datenschutz → Mikrofon.", "Nessun accesso al microfono. Consentilo in Impostazioni di Sistema → Privacy → Microfono."),
        "err.noModel": t("Спочатку завантажте модель Whisper у налаштуваннях (вкладка «Моделі»).", "First download a Whisper model in settings (Models tab).", "Téléchargez d’abord un modèle Whisper dans les réglages (onglet Modèles).", "Primero descarga un modelo Whisper en ajustes (pestaña Modelos).", "Primeiro descarregue um modelo Whisper nas definições (separador Modelos).", "Lade zuerst ein Whisper-Modell in den Einstellungen (Tab Modelle).", "Prima scarica un modello Whisper nelle impostazioni (scheda Modelli)."),
        "err.summaryModel": t("Завантажте модель для саммарі в налаштуваннях (вкладка «Моделі»).", "Download a summary model in settings (Models tab).", "Téléchargez un modèle de résumé dans les réglages (onglet Modèles).", "Descarga un modelo de resumen en ajustes (pestaña Modelos).", "Descarregue um modelo de resumo nas definições (separador Modelos).", "Lade ein Zusammenfassungsmodell in den Einstellungen (Tab Modelle).", "Scarica un modello per i riassunti nelle impostazioni (scheda Modelli)."),
        "err.exportFolder": t("Вкажіть теку експорту в налаштуваннях", "Choose an export folder in settings", "Choisissez un dossier d’export dans les réglages", "Elige una carpeta de exportación en ajustes", "Escolha uma pasta de exportação nas definições", "Wähle einen Export-Ordner in den Einstellungen", "Scegli una cartella di esportazione nelle impostazioni"),
        "err.startFailed": t("Не вдалося почати запис", "Couldn't start recording", "Impossible de démarrer l’enregistrement", "No se pudo iniciar la grabación", "Não foi possível iniciar a gravação", "Aufnahme konnte nicht gestartet werden", "Impossibile avviare la registrazione"),
        "err.transcribeFailed": t("Транскрибування не вдалося", "Couldn't transcribe", "Échec de la transcription", "No se pudo transcribir", "Não foi possível transcrever", "Transkription fehlgeschlagen", "Trascrizione non riuscita"),
        "err.exportFailed": t("Помилка експорту", "Export error", "Erreur d’export", "Error de exportación", "Erro de exportação", "Exportfehler", "Errore di esportazione"),
        "msg.exported": t("Експортовано: %@", "Exported: %@", "Exporté : %@", "Exportado: %@", "Exportado: %@", "Exportiert: %@", "Esportato: %@"),
        "msg.restoreFailed": t("Не вдалося відновити: %@", "Couldn't restore: %@", "Échec de la restauration : %@", "No se pudo restaurar: %@", "Não foi possível restaurar: %@", "Wiederherstellen fehlgeschlagen: %@", "Impossibile ripristinare: %@"),

        // — Транскрипт (markdown) —
        "md.recording": t("Запис", "Recording", "Enregistrement", "Grabación", "Gravação", "Aufnahme", "Registrazione"),
        "err.noAudio": t("У сесії немає аудіофайлів", "No audio files in the session", "Aucun fichier audio dans la session", "No hay archivos de audio en la sesión", "Sem ficheiros de áudio na sessão", "Keine Audiodateien in der Sitzung", "Nessun file audio nella sessione"),
        "err.transcribeFirst": t("Спочатку транскрибуйте сесію.", "Transcribe the session first.", "Transcrivez d’abord la session.", "Primero transcribe la sesión.", "Transcreva a sessão primeiro.", "Transkribiere zuerst die Sitzung.", "Trascrivi prima la sessione."),
        "err.noTextForSummary": t("У транскрипті немає тексту для саммарі.", "No text in the transcript to summarize.", "Aucun texte à résumer dans la transcription.", "No hay texto en la transcripción para resumir.", "Não há texto na transcrição para resumir.", "Kein Text im Transkript zum Zusammenfassen.", "Nessun testo nella trascrizione da riassumere."),
        "err.micUnavailable": t("Мікрофон недоступний", "Microphone unavailable", "Microphone indisponible", "Micrófono no disponible", "Microfone indisponível", "Mikrofon nicht verfügbar", "Microfono non disponibile"),
        "err.sysTap": t("Не вдалося отримати системний звук. Перевірте дозвіл «Запис звуку системи».", "Couldn't capture system audio. Check the System Audio Recording permission.", "Impossible de capturer l’audio système. Vérifiez l’autorisation d’enregistrement audio du système.", "No se pudo capturar el audio del sistema. Comprueba el permiso de grabación de audio del sistema.", "Não foi possível capturar o áudio do sistema. Verifique a permissão de gravação de áudio do sistema.", "Systemton konnte nicht erfasst werden. Prüfe die Berechtigung zur Systemton-Aufnahme.", "Impossibile catturare l’audio di sistema. Controlla l’autorizzazione di registrazione audio di sistema."),
        "common.appFallback": t("застосунок", "an app", "une app", "una app", "uma app", "eine App", "un’app"),
        "trash.sessionTitle": t("Сесія %@", "Session %@", "Session %@", "Sesión %@", "Sessão %@", "Sitzung %@", "Sessione %@"),
        "err.audioCorrupt": t("Аудіо пошкоджено — запис перервали до завершення. Сесію можна видалити в Кошик (🗑).", "Audio is corrupted — recording was interrupted before completion. You can delete the session to Trash (🗑).", "Audio corrompu — l’enregistrement a été interrompu. Vous pouvez supprimer la session (🗑).", "Audio dañado: la grabación se interrumpió. Puedes eliminar la sesión (🗑).", "Áudio corrompido — a gravação foi interrompida. Pode eliminar a sessão (🗑).", "Audio beschädigt — die Aufnahme wurde abgebrochen. Du kannst die Sitzung löschen (🗑).", "Audio danneggiato — la registrazione è stata interrotta. Puoi eliminare la sessione (🗑)."),
    ]
}
