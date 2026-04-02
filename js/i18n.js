/* ===================================================
   i18n.js — Trilingual support (EN / IT / HE)
   Translations are inlined so this works on file:// (no server needed)
   =================================================== */

const SUPPORTED_LANGS = ['en', 'it', 'he'];
const DEFAULT_LANG = 'en';
const STORAGE_KEY = 'ses_lang';

let currentStrings = {};

/* ── Inline translations ── */
const TRANSLATIONS = {
  en: {
    "lang": "en", "dir": "ltr",
    "nav_home": "Home", "nav_about": "About", "nav_sessions": "Sessions",
    "nav_resources": "Resources", "nav_dana": "Dana", "nav_contact": "Contact",
    "hero_subtitle": "Meditation · Mindfulness · Psychology",
    "hero_title": "Sound & Silence",
    "hero_tagline": "A space of inner stillness\nwhere psychology, meditation, and ancient wisdom meet.",
    "hero_cta_sessions": "Explore Sessions", "hero_cta_about": "Learn More", "hero_scroll": "Scroll",
    "about_eyebrow": "About", "about_heading": "Manuel Katz",
    "about_p1": "Manuel Katz is a clinical and medical psychologist, and a meditation and Buddhism teacher with over 20 years of experience. His work bridges modern psychology with the contemplative traditions of mindfulness, compassion, and inner inquiry.",
    "about_p2": "Founder of Suono e Silenzio (Sound and Silence), Manuel has guided practitioners, healthcare professionals, and corporate teams across Italy and Israel toward greater presence, resilience, and well-being.",
    "about_cta": "Full Biography →",
    "sessions_eyebrow": "Meditation", "sessions_heading": "Sessions & Teachings",
    "sessions_desc": "Weekly guided meditations, dharma talks, and reflections — freely offered for anyone who wishes to practice.",
    "sessions_cta": "Browse All Sessions →",
    "dana_sanskrit": "दान", "dana_eyebrow": "Generosity", "dana_heading": "Support This Work",
    "dana_desc": "These teachings are offered freely in the spirit of Dana — the ancient practice of generosity. If you have benefited from this work and feel moved to give, your contribution sustains this community.",
    "dana_cta": "Give Dana →",
    "page_about_title": "About Manuel Katz",
    "page_about_subtitle": "Psychologist, meditation teacher, and founder of Suono e Silenzio.",
    "bio_heading": "Biography",
    "bio_p1": "Manuel Katz is a clinical and medical psychologist, and a long-time student and teacher of Buddhist meditation. Born in South America, he has lived and worked in Italy and Israel, bringing together diverse traditions and a deep commitment to human flourishing.",
    "bio_p2": "He is the founder of Suono e Silenzio — Sound and Silence — a training and consultancy organization based in Florence, Italy, that has worked with oncology departments, hospitals, corporations, and individuals for over two decades.",
    "bio_p3": "Manuel's approach integrates mindfulness-based stress reduction (MBSR), Tibetan and Theravada Buddhist practice, somatic awareness, and experiential learning. He has trained with teachers in the lineages of Thich Nhat Hanh, Alan Wallace, and the Tibetan tradition at Istituto Lama Tzong Khapa.",
    "bio_p4": "He conducts regular meditation groups and offers retreats, workshops, and individual sessions in Italian, Hebrew, and English. During 2023 he led a free public meditation series — Meditation for Everyone — broadcast live on Zoom and recorded for free access.",
    "philosophy_heading": "Sound & Silence",
    "philosophy_quote": "Sound is the bridge between our inner world and the outer world. Silence is the space where wisdom can be heard.",
    "philosophy_attr": "— Manuel Katz",
    "philosophy_p": "The name Suono e Silenzio reflects the dual movement of practice: an active, expressive engagement with the world, and a receptive, still listening. Together they form the basis of a full human life.",
    "services_heading": "Areas of Work",
    "service_oncology_title": "Oncology & Healthcare",
    "service_oncology_desc": "Supporting oncologists, nurses, and medical teams with burnout prevention, emotional communication, and end-of-life care.",
    "service_corporate_title": "Corporate & Leadership",
    "service_corporate_desc": "Stress management, mindful leadership, communication, and resilience training for organizations.",
    "service_meditation_title": "Meditation & Dharma",
    "service_meditation_desc": "Public meditation sessions, retreats, and individual guidance in mindfulness and Buddhist practice.",
    "partners_heading": "Affiliated Networks",
    "page_sessions_title": "Meditation Sessions", "page_sessions_subtitle": "All recorded teachings, freely offered.",
    "sessions_search_placeholder": "Search topics, titles…",
    "filter_all": "All", "filter_basics": "Meditation Basics", "filter_mind": "Mind & Thoughts",
    "filter_buddhist": "Buddhist Concepts", "filter_resilience": "Resilience", "filter_body": "Body & Breath",
    "sessions_showing": "Showing", "sessions_of": "of", "sessions_results": "sessions",
    "session_watch": "Watch →", "no_results_title": "No sessions found",
    "no_results_text": "Try a different search term or filter.",
    "page_dana_title": "Dana — Generosity", "dana_pali": "dāna",
    "dana_hero_p": "These teachings are freely offered. Dana — generosity — is the ancient practice that sustains the dharma.",
    "dana_philosophy_heading": "What is Dana?",
    "dana_p1": "Dana (दान, dāna) is a Sanskrit and Pali word meaning generosity, gift, or the act of giving. In Buddhist tradition, dana is the first of the ten perfections (paramitas) and the foundation of spiritual practice.",
    "dana_p2": "Unlike payment for services, dana is an offering made freely, from the heart, in gratitude for teachings received. The teacher trusts the community; the community trusts the teaching. This mutual trust is itself a practice.",
    "dana_p3": "Whatever you give — large or small — is received with gratitude. If you are going through difficulty, please do not feel obligated. Your presence and practice are a gift in themselves.",
    "dana_give_heading": "Give Dana",
    "dana_give_instructions": "Scan the QR code with the Bit app, or tap to open directly.",
    "dana_bit_label": "Bit — Phone number",
    "dana_closing": "May your generosity bring benefit to all beings.",
    "page_resources_title": "Resources",
    "page_resources_subtitle": "Affiliated organizations, further reading, and useful links.",
    "resources_heading_online": "Manuel Katz Online",
    "resources_heading_networks": "Affiliated Organizations",
    "resources_heading_practices": "Practices & Traditions",
    "page_contact_title": "Contact",
    "page_contact_subtitle": "Get in touch for sessions, workshops, or consultancy.",
    "contact_info_heading": "Reach Out",
    "contact_info_p": "Manuel Katz is based in Israel and Italy and offers sessions online and in person. For inquiries about meditation groups, retreats, corporate training, or individual work, please write.",
    "contact_email_label": "Email", "contact_location_label": "Locations",
    "contact_location_value": "Israel · Florence, Italy",
    "contact_form_heading": "Send a Message", "contact_name_label": "Your Name",
    "contact_email_input_label": "Email Address", "contact_subject_label": "Subject",
    "contact_subject_meditation": "Meditation Sessions", "contact_subject_retreat": "Retreats & Workshops",
    "contact_subject_corporate": "Corporate / Healthcare Training",
    "contact_subject_individual": "Individual Sessions", "contact_subject_other": "Other",
    "contact_message_label": "Message", "contact_submit": "Send Message",
    "footer_tagline": "Meditation, psychology, and wisdom — for all.",
    "footer_nav_heading": "Navigation", "footer_contact_heading": "Contact",
    "footer_copyright": "© 2024 Manuel Katz / Suono e Silenzio",
    "footer_rights": "All rights reserved."
  },

  it: {
    "lang": "it", "dir": "ltr",
    "nav_home": "Home", "nav_about": "Chi Siamo", "nav_sessions": "Sessioni",
    "nav_resources": "Risorse", "nav_dana": "Dana", "nav_contact": "Contatti",
    "hero_subtitle": "Meditazione · Mindfulness · Psicologia",
    "hero_title": "Suono e Silenzio",
    "hero_tagline": "Uno spazio di quiete interiore\ndove psicologia, meditazione e saggezza antica si incontrano.",
    "hero_cta_sessions": "Esplora le Sessioni", "hero_cta_about": "Scopri di Più", "hero_scroll": "Scorri",
    "about_eyebrow": "Chi Siamo", "about_heading": "Manuel Katz",
    "about_p1": "Manuel Katz è uno psicologo clinico e medico, e insegnante di meditazione e Buddhismo con oltre 20 anni di esperienza. Il suo lavoro unisce la psicologia moderna alle tradizioni contemplative di mindfulness, compassione e indagine interiore.",
    "about_p2": "Fondatore di Suono e Silenzio, Manuel ha guidato professionisti della salute, aziende e individui in Italia e Israele verso una maggiore presenza, resilienza e benessere.",
    "about_cta": "Biografia Completa →",
    "sessions_eyebrow": "Meditazione", "sessions_heading": "Sessioni e Insegnamenti",
    "sessions_desc": "Meditazioni guidate settimanali, dharma talk e riflessioni — offerte liberamente a chiunque voglia praticare.",
    "sessions_cta": "Vedi Tutte le Sessioni →",
    "dana_sanskrit": "दान", "dana_eyebrow": "Generosità", "dana_heading": "Sostieni Questo Lavoro",
    "dana_desc": "Questi insegnamenti sono offerti liberamente nello spirito del Dana — l'antica pratica della generosità. Se hai tratto beneficio da questo lavoro e ti senti mosso a donare, il tuo contributo sostiene questa comunità.",
    "dana_cta": "Offri Dana →",
    "page_about_title": "Chi è Manuel Katz",
    "page_about_subtitle": "Psicologo, insegnante di meditazione e fondatore di Suono e Silenzio.",
    "bio_heading": "Biografia",
    "bio_p1": "Manuel Katz è uno psicologo clinico e medico, e da molti anni studente e insegnante di meditazione buddhista. Nato in Sud America, ha vissuto e lavorato in Italia e Israele, portando insieme diverse tradizioni e un profondo impegno per la fioritura umana.",
    "bio_p2": "È il fondatore di Suono e Silenzio, un'organizzazione di formazione e consulenza con sede a Firenze, che da oltre vent'anni collabora con reparti oncologici, ospedali, aziende e singoli individui.",
    "bio_p3": "L'approccio di Manuel integra la riduzione dello stress basata sulla mindfulness (MBSR), la pratica buddhista tibetana e theravada, la consapevolezza somatica e l'apprendimento esperienziale. Si è formato con insegnanti nelle tradizioni di Thich Nhat Hanh, Alan Wallace e nella tradizione tibetana all'Istituto Lama Tzong Khapa.",
    "bio_p4": "Conduce regolari gruppi di meditazione e offre ritiri, workshop e sessioni individuali in italiano, ebraico e inglese. Nel 2023 ha guidato una serie di meditazioni pubbliche gratuite — Meditazione per Tutti — trasmesse in diretta su Zoom e registrate per la libera fruizione.",
    "philosophy_heading": "Suono e Silenzio",
    "philosophy_quote": "Il suono è il ponte tra il nostro mondo interiore e il mondo esterno. Il silenzio è lo spazio in cui la saggezza può essere ascoltata.",
    "philosophy_attr": "— Manuel Katz",
    "philosophy_p": "Il nome Suono e Silenzio riflette il doppio movimento della pratica: un coinvolgimento attivo ed espressivo con il mondo, e un ascolto ricettivo e silenzioso. Insieme formano la base di una vita umana piena.",
    "services_heading": "Ambiti di Lavoro",
    "service_oncology_title": "Oncologia e Sanità",
    "service_oncology_desc": "Supporto a oncologi, infermieri e team medici con prevenzione del burnout, comunicazione emotiva e cure di fine vita.",
    "service_corporate_title": "Aziendale e Leadership",
    "service_corporate_desc": "Gestione dello stress, leadership consapevole, comunicazione e formazione alla resilienza per le organizzazioni.",
    "service_meditation_title": "Meditazione e Dharma",
    "service_meditation_desc": "Sessioni di meditazione pubbliche, ritiri e guida individuale nella pratica mindfulness e buddhista.",
    "partners_heading": "Reti Affiliate",
    "page_sessions_title": "Sessioni di Meditazione", "page_sessions_subtitle": "Tutti gli insegnamenti registrati, liberamente offerti.",
    "sessions_search_placeholder": "Cerca argomenti, titoli…",
    "filter_all": "Tutti", "filter_basics": "Basi della Meditazione", "filter_mind": "Mente e Pensieri",
    "filter_buddhist": "Concetti Buddhisti", "filter_resilience": "Resilienza", "filter_body": "Corpo e Respiro",
    "sessions_showing": "Mostrando", "sessions_of": "di", "sessions_results": "sessioni",
    "session_watch": "Guarda →", "no_results_title": "Nessuna sessione trovata",
    "no_results_text": "Prova un termine di ricerca o filtro diverso.",
    "page_dana_title": "Dana — Generosità", "dana_pali": "dāna",
    "dana_hero_p": "Questi insegnamenti sono offerti liberamente. Il Dana — la generosità — è l'antica pratica che sostiene il dharma.",
    "dana_philosophy_heading": "Cos'è il Dana?",
    "dana_p1": "Dana (दान, dāna) è una parola sanscrita e pali che significa generosità, dono o atto del dare. Nella tradizione buddhista, il dana è la prima delle dieci perfezioni (paramita) e il fondamento della pratica spirituale.",
    "dana_p2": "A differenza del pagamento per servizi, il dana è un'offerta fatta liberamente, dal cuore, in gratitudine per gli insegnamenti ricevuti. L'insegnante si fida della comunità; la comunità si fida dell'insegnamento. Questa fiducia reciproca è essa stessa una pratica.",
    "dana_p3": "Qualunque cosa tu dia — grande o piccola — viene ricevuta con gratitudine. Se stai attraversando un momento difficile, per favore non sentirti obbligato. La tua presenza e la tua pratica sono già un dono.",
    "dana_give_heading": "Offri Dana",
    "dana_give_instructions": "Scannerizza il codice QR con l'app Bit, o tocca per aprire direttamente.",
    "dana_bit_label": "Bit — Numero di telefono",
    "dana_closing": "Possa la tua generosità portare beneficio a tutti gli esseri.",
    "page_resources_title": "Risorse",
    "page_resources_subtitle": "Organizzazioni affiliate, approfondimenti e link utili.",
    "resources_heading_online": "Manuel Katz Online",
    "resources_heading_networks": "Organizzazioni Affiliate",
    "resources_heading_practices": "Pratiche e Tradizioni",
    "page_contact_title": "Contatti",
    "page_contact_subtitle": "Scrivici per sessioni, workshop o consulenze.",
    "contact_info_heading": "Scrivici",
    "contact_info_p": "Manuel Katz è basato in Israele e Italia e offre sessioni online e in presenza. Per informazioni su gruppi di meditazione, ritiri, formazione aziendale o lavoro individuale, scrivi pure.",
    "contact_email_label": "Email", "contact_location_label": "Sedi",
    "contact_location_value": "Israele · Firenze, Italia",
    "contact_form_heading": "Invia un Messaggio", "contact_name_label": "Il tuo Nome",
    "contact_email_input_label": "Indirizzo Email", "contact_subject_label": "Oggetto",
    "contact_subject_meditation": "Sessioni di Meditazione", "contact_subject_retreat": "Ritiri e Workshop",
    "contact_subject_corporate": "Formazione Aziendale / Sanitaria",
    "contact_subject_individual": "Sessioni Individuali", "contact_subject_other": "Altro",
    "contact_message_label": "Messaggio", "contact_submit": "Invia Messaggio",
    "footer_tagline": "Meditazione, psicologia e saggezza — per tutti.",
    "footer_nav_heading": "Navigazione", "footer_contact_heading": "Contatti",
    "footer_copyright": "© 2024 Manuel Katz / Suono e Silenzio",
    "footer_rights": "Tutti i diritti riservati."
  },

  he: {
    "lang": "he", "dir": "rtl",
    "nav_home": "בית", "nav_about": "אודות", "nav_sessions": "מפגשים",
    "nav_resources": "משאבים", "nav_dana": "דאנה", "nav_contact": "צור קשר",
    "hero_subtitle": "מדיטציה · מיינדפולנס · פסיכולוגיה",
    "hero_title": "צליל ושתיקה",
    "hero_tagline": "מרחב של שקט פנימי\nשבו פסיכולוגיה, מדיטציה וחוכמה עתיקה נפגשים.",
    "hero_cta_sessions": "לצפות במפגשים", "hero_cta_about": "קראו עוד", "hero_scroll": "גלול",
    "about_eyebrow": "אודות", "about_heading": "מנואל קץ",
    "about_p1": "מנואל קץ הוא פסיכולוג קליני ורפואי, ומורה למדיטציה ובודהיזם עם ניסיון של למעלה מ-20 שנה. עבודתו מחברת בין הפסיכולוגיה המודרנית לבין מסורות הכוללות מיינדפולנס, חמלה ועיון פנימי.",
    "about_p2": "מייסד Suono e Silenzio (צליל ושתיקה), מנואל הנחה מתרגלים, אנשי מקצוע בתחום הבריאות וצוותי ארגונים באיטליה ובישראל לקראת נוכחות, חוסן ורווחה.",
    "about_cta": "ביוגרפיה מלאה ←",
    "sessions_eyebrow": "מדיטציה", "sessions_heading": "מפגשים והוראות",
    "sessions_desc": "מדיטציות מודרכות שבועיות, שיחות דהרמה ורפלקציות — המוצעות בחינם לכל מי שרוצה לתרגל.",
    "sessions_cta": "לכל המפגשים ←",
    "dana_sanskrit": "दान", "dana_eyebrow": "נדיבות", "dana_heading": "תמכו בעבודה הזו",
    "dana_desc": "הוראות אלו מוצעות בחינם ברוח הדאנה — תרגול הנדיבות העתיק. אם נהנית מעבודה זו ומרגיש/ה שזז/ה בתוכך משהו, תרומתך מקיימת את הקהילה הזו.",
    "dana_cta": "תרמו דאנה ←",
    "page_about_title": "אודות מנואל קץ",
    "page_about_subtitle": "פסיכולוג, מורה למדיטציה ומייסד Suono e Silenzio.",
    "bio_heading": "ביוגרפיה",
    "bio_p1": "מנואל קץ הוא פסיכולוג קליני ורפואי, ותלמיד ומורה בתחום המדיטציה הבודהיסטית. יליד אמריקה הדרומית, חי ועבד באיטליה ובישראל, ומביא יחד מסורות שונות ומחויבות עמוקה לשגשוג האנושי.",
    "bio_p2": "הוא מייסד Suono e Silenzio — צליל ושתיקה — ארגון הכשרה וייעוץ שבסיסו בפירנצה, איטליה, העובד עם מחלקות אונקולוגיה, בתי חולים, חברות ויחידים במשך למעלה מעשרים שנה.",
    "bio_p3": "הגישה של מנואל משלבת הפחתת מתח מבוססת מיינדפולנס (MBSR), תרגול בודהיסטי טיבטי ותרוואדה, מודעות גופנית ולמידה חוויתית. הוא התאמן עם מורים במסורות של תיץ' נהאט האן, אלן וואלאס ובמסורת הטיבטית במכון לאמה צונג קהאפה.",
    "bio_p4": "הוא מנהל קבוצות מדיטציה קבועות ומציע ריטריטים, סדנאות ומפגשים אישיים בעברית, איטלקית ואנגלית. בשנת 2023 הנחה סדרת מדיטציה ציבורית חינמית — מדיטציה לכולם — ששודרה בזום ותועדה לגישה חינמית.",
    "philosophy_heading": "צליל ושתיקה",
    "philosophy_quote": "הצליל הוא הגשר בין עולמנו הפנימי לעולם החיצוני. השתיקה היא המרחב שבו ניתן לשמוע את החוכמה.",
    "philosophy_attr": "— מנואל קץ",
    "philosophy_p": "השם Suono e Silenzio משקף את התנועה הכפולה של התרגול: מעורבות פעילה וביטויית עם העולם, והאזנה קולטת ושקטה. יחד הם מהווים את הבסיס לחיי אדם מלאים.",
    "services_heading": "תחומי עבודה",
    "service_oncology_title": "אונקולוגיה ובריאות",
    "service_oncology_desc": "תמיכה לרופאים אונקולוגים, אחיות וצוותים רפואיים: מניעת שחיקה, תקשורת רגשית וטיפול בסוף החיים.",
    "service_corporate_title": "ארגונים ומנהיגות",
    "service_corporate_desc": "ניהול מתח, מנהיגות מודעת, תקשורת והכשרת חוסן לארגונים.",
    "service_meditation_title": "מדיטציה ודהרמה",
    "service_meditation_desc": "מפגשי מדיטציה ציבוריים, ריטריטים והדרכה אישית בתרגול מיינדפולנס ובודהיזם.",
    "partners_heading": "רשתות קשורות",
    "page_sessions_title": "מפגשי מדיטציה", "page_sessions_subtitle": "כל ההוראות המוקלטות, מוצעות בחינם.",
    "sessions_search_placeholder": "חפש נושאים, כותרות…",
    "filter_all": "הכל", "filter_basics": "יסודות המדיטציה", "filter_mind": "מוח ומחשבות",
    "filter_buddhist": "מושגים בודהיסטיים", "filter_resilience": "חוסן", "filter_body": "גוף ונשימה",
    "sessions_showing": "מציג", "sessions_of": "מתוך", "sessions_results": "מפגשים",
    "session_watch": "צפה ←", "no_results_title": "לא נמצאו מפגשים",
    "no_results_text": "נסה מונח חיפוש או מסנן שונה.",
    "page_dana_title": "דאנה — נדיבות", "dana_pali": "dāna",
    "dana_hero_p": "הוראות אלו מוצעות בחינם. דאנה — נדיבות — הוא התרגול העתיק המקיים את הדהרמה.",
    "dana_philosophy_heading": "מהו הדאנה?",
    "dana_p1": "דאנה (दान, dāna) היא מילה סנסקריטית ופאלי שמשמעותה נדיבות, מתנה, או מעשה הנתינה. במסורת הבודהיסטית, דאנה היא הראשונה מבין עשר השלמות (פרמיטות) ויסוד התרגול הרוחני.",
    "dana_p2": "בניגוד לתשלום עבור שירותים, דאנה היא הצעה הניתנת בחופשיות, מהלב, מתוך הכרת תודה על ההוראות שהתקבלו. המורה סומך על הקהילה; הקהילה סומכת על ההוראה. האמון ההדדי הזה הוא עצמו תרגול.",
    "dana_p3": "כל מה שתיתן — גדול או קטן — יתקבל בהכרת תודה. אם אתה עובר תקופה קשה, אנא אל תרגיש מחויב. נוכחותך ותרגולך הם עצמם מתנה.",
    "dana_give_heading": "תרמו דאנה",
    "dana_give_instructions": "סרקו את קוד ה-QR עם אפליקציית ביט, או לחצו לפתיחה ישירה.",
    "dana_bit_label": "ביט — מספר טלפון",
    "dana_closing": "שנדיבותך תביא תועלת לכל הברואים.",
    "page_resources_title": "משאבים",
    "page_resources_subtitle": "ארגונים קשורים, קריאה נוספת וקישורים שימושיים.",
    "resources_heading_online": "מנואל קץ אונליין",
    "resources_heading_networks": "ארגונים קשורים",
    "resources_heading_practices": "תרגולים ומסורות",
    "page_contact_title": "צור קשר",
    "page_contact_subtitle": "פנה אלינו למפגשים, סדנאות או ייעוץ.",
    "contact_info_heading": "צרו קשר",
    "contact_info_p": "מנואל קץ מתגורר בישראל ובאיטליה ומציע מפגשים מקוונים ופנים אל פנים. לפניות בנושא קבוצות מדיטציה, ריטריטים, הכשרות ארגוניות או עבודה אישית, אנא כתבו.",
    "contact_email_label": "דוא\"ל", "contact_location_label": "מיקומים",
    "contact_location_value": "ישראל · פירנצה, איטליה",
    "contact_form_heading": "שלח הודעה", "contact_name_label": "שמך",
    "contact_email_input_label": "כתובת דוא\"ל", "contact_subject_label": "נושא",
    "contact_subject_meditation": "מפגשי מדיטציה", "contact_subject_retreat": "ריטריטים וסדנאות",
    "contact_subject_corporate": "הכשרה ארגונית / רפואית",
    "contact_subject_individual": "מפגשים אישיים", "contact_subject_other": "אחר",
    "contact_message_label": "הודעה", "contact_submit": "שלח הודעה",
    "footer_tagline": "מדיטציה, פסיכולוגיה וחוכמה — לכולם.",
    "footer_nav_heading": "ניווט", "footer_contact_heading": "צור קשר",
    "footer_copyright": "© 2024 מנואל קץ / Suono e Silenzio",
    "footer_rights": "כל הזכויות שמורות."
  }
};

/* ── Apply language to document ── */
function setLang(lang) {
  if (!SUPPORTED_LANGS.includes(lang)) lang = DEFAULT_LANG;

  currentStrings = TRANSLATIONS[lang] || TRANSLATIONS[DEFAULT_LANG];
  localStorage.setItem(STORAGE_KEY, lang);

  /* Direction */
  const dir = currentStrings.dir || 'ltr';
  document.documentElement.lang = lang;
  document.documentElement.dir  = dir;

  /* Load RTL stylesheet if needed */
  let rtlLink = document.getElementById('rtl-css');
  if (dir === 'rtl') {
    if (!rtlLink) {
      const link = document.createElement('link');
      link.id   = 'rtl-css';
      link.rel  = 'stylesheet';
      link.href = 'css/rtl.css';
      document.head.appendChild(link);
    }
  } else {
    if (rtlLink) rtlLink.remove();
  }

  /* Translate all elements with data-i18n */
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const key = el.getAttribute('data-i18n');
    const val = currentStrings[key];
    if (val !== undefined) el.textContent = val;
  });

  /* Translate placeholders */
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    const key = el.getAttribute('data-i18n-placeholder');
    const val = currentStrings[key];
    if (val !== undefined) el.placeholder = val;
  });

  /* Update active language buttons */
  document.querySelectorAll('.lang-btn').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.lang === lang);
  });

  /* Fire custom event so other scripts can react */
  document.dispatchEvent(new CustomEvent('langchange', { detail: { lang, dir, strings: currentStrings } }));
}

/* Detect preferred language */
function detectLang() {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored && SUPPORTED_LANGS.includes(stored)) return stored;

  const browser = (navigator.language || navigator.userLanguage || '').slice(0, 2).toLowerCase();
  if (browser === 'he') return 'he';
  if (browser === 'it') return 'it';
  return DEFAULT_LANG;
}

/* Get a single translated string (for JS use) */
function t(key) {
  return currentStrings[key] || key;
}

/* Build shared navigation HTML */
function buildNav(activePage) {
  const pages = [
    { key: 'nav_home',      href: 'index.html'     },
    { key: 'nav_about',     href: 'about.html'     },
    { key: 'nav_sessions',  href: 'sessions.html'  },
    { key: 'nav_resources', href: 'resources.html' },
    { key: 'nav_dana',      href: 'dana.html'      },
    { key: 'nav_contact',   href: 'contact.html'   },
  ];

  const currentLang = currentStrings.lang || DEFAULT_LANG;

  const linksHTML = pages.map(p => {
    const active = p.href === activePage ? 'aria-current="page"' : '';
    return `<li><a href="${p.href}" data-i18n="${p.key}" ${active}>${t(p.key)}</a></li>`;
  }).join('');

  const langBtns = SUPPORTED_LANGS.map(l =>
    `<button class="lang-btn${currentLang === l ? ' active' : ''}" data-lang="${l}" aria-label="Switch to ${l.toUpperCase()}">${l === 'he' ? 'עב' : l.toUpperCase()}</button>`
  ).join('');

  return `
    <nav class="site-nav${activePage === 'index.html' ? ' transparent' : ''}" id="site-nav" aria-label="Main navigation">
      <div class="container nav-inner">
        <a href="index.html" class="nav-logo" aria-label="Suono e Silenzio home">Suono e Silenzio</a>
        <ul class="nav-links" id="nav-links">
          ${linksHTML}
        </ul>
        <div class="nav-right" style="display:flex;align-items:center;gap:1rem;">
          <div class="lang-switcher" role="group" aria-label="Language">
            ${langBtns}
          </div>
          <button class="nav-toggle" id="nav-toggle" aria-expanded="false" aria-controls="nav-links" aria-label="Menu">
            <span></span><span></span><span></span>
          </button>
        </div>
      </div>
    </nav>`;
}

/* Build shared footer HTML */
function buildFooter() {
  const pages = [
    { key: 'nav_home',      href: 'index.html'     },
    { key: 'nav_about',     href: 'about.html'     },
    { key: 'nav_sessions',  href: 'sessions.html'  },
    { key: 'nav_resources', href: 'resources.html' },
    { key: 'nav_dana',      href: 'dana.html'      },
    { key: 'nav_contact',   href: 'contact.html'   },
  ];

  const currentLang = currentStrings.lang || DEFAULT_LANG;

  const navItems = pages.map(p =>
    `<li><a href="${p.href}" data-i18n="${p.key}">${t(p.key)}</a></li>`
  ).join('');

  const langBtns = SUPPORTED_LANGS.map(l =>
    `<button class="lang-btn${currentLang === l ? ' active' : ''}" data-lang="${l}">${l === 'he' ? 'עב' : l.toUpperCase()}</button>`
  ).join('');

  return `
    <footer class="site-footer">
      <div class="container">
        <div class="footer-grid">
          <div class="footer-brand">
            <a href="index.html" class="nav-logo">Suono e Silenzio</a>
            <p data-i18n="footer_tagline">${t('footer_tagline')}</p>
            <div class="footer-lang lang-switcher" role="group" aria-label="Language">
              ${langBtns}
            </div>
          </div>
          <div class="footer-col">
            <h4 data-i18n="footer_nav_heading">${t('footer_nav_heading')}</h4>
            <ul>${navItems}</ul>
          </div>
          <div class="footer-col">
            <h4 data-i18n="footer_contact_heading">${t('footer_contact_heading')}</h4>
            <ul>
              <li><a href="mailto:mkatz@suonoesilenzio.it">mkatz@suonoesilenzio.it</a></li>
              <li><a href="contact.html" data-i18n="nav_contact">${t('nav_contact')}</a></li>
            </ul>
          </div>
        </div>
        <div class="footer-bottom">
          <span data-i18n="footer_copyright">${t('footer_copyright')}</span>
          <span data-i18n="footer_rights">${t('footer_rights')}</span>
        </div>
      </div>
    </footer>`;
}

/* Inject nav + footer into page */
function injectChrome(activePage) {
  const navMount = document.getElementById('nav-mount');
  if (navMount) navMount.innerHTML = buildNav(activePage);

  const footerMount = document.getElementById('footer-mount');
  if (footerMount) footerMount.innerHTML = buildFooter();

  /* Hamburger toggle */
  const toggle = document.getElementById('nav-toggle');
  const navLinks = document.getElementById('nav-links');
  if (toggle && navLinks) {
    toggle.addEventListener('click', () => {
      const open = navLinks.classList.toggle('open');
      toggle.setAttribute('aria-expanded', open);
    });
  }

  /* Transparent nav on hero scroll */
  const siteNav = document.getElementById('site-nav');
  if (siteNav && activePage === 'index.html') {
    const update = () => {
      siteNav.classList.toggle('transparent', window.scrollY < 60);
    };
    window.addEventListener('scroll', update, { passive: true });
    update();
  }
}

/* ===== INIT ===== */
document.addEventListener('DOMContentLoaded', () => {
  const activePage = document.body.dataset.page || 'index.html';
  const lang = detectLang();

  setLang(lang);
  injectChrome(activePage);

  /* Bind language buttons — single listener on document */
  document.addEventListener('click', e => {
    if (e.target.matches('.lang-btn')) {
      setLang(e.target.dataset.lang);
      injectChrome(activePage);
    }
  });

  /* Re-inject chrome on language change to update nav/footer text */
  document.addEventListener('langchange', () => {
    injectChrome(activePage);
  });
});
