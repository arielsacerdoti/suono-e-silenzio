/* ===================================================
   sessions.js — Filter & Search for Sessions Directory
   =================================================== */

const PLAYLIST_URL = 'https://www.youtube.com/playlist?list=PLBnExi1jlBdj2QnlLQ144sdKYSi3bfFYK';

let allSessions = [];
let currentLang = 'en';
let currentFilter = 'all';
let currentSearch = '';

const tagMeta = {
  'all':              { en:'All',               it:'Tutti',                    he:'הכל'              },
  'meditation-basics':{ en:'Meditation Basics', it:'Basi della Meditazione',  he:'יסודות המדיטציה'  },
  'mind-thoughts':    { en:'Mind & Thoughts',   it:'Mente e Pensieri',        he:'מוח ומחשבות'      },
  'buddhist-concepts':{ en:'Buddhist Concepts', it:'Concetti Buddhisti',      he:'מושגים בודהיסטיים'},
  'resilience':       { en:'Resilience',        it:'Resilienza',              he:'חוסן'             },
  'body-breath':      { en:'Body & Breath',     it:'Corpo e Respiro',         he:'גוף ונשימה'       },
};

/* ---------- Load sessions data ---------- */
function loadSessions() {
  if (window.SESSIONS_DATA && Array.isArray(window.SESSIONS_DATA)) {
    allSessions = window.SESSIONS_DATA;
  } else {
    console.error('sessions.js: SESSIONS_DATA not found — make sure sessions-data.js is loaded');
    allSessions = [];
  }
  render();
}

/* ---------- Filter + Search logic ---------- */
function getFiltered() {
  const q = currentSearch.trim().toLowerCase();
  return allSessions.filter(s => {
    /* Tag filter */
    const tagMatch = currentFilter === 'all' || s.tags.includes(currentFilter);
    if (!tagMatch) return false;

    /* Search across title + summary + tags (in current language) */
    if (!q) return true;
    const title   = (s.title[currentLang]   || s.title.en   || '').toLowerCase();
    const summary = (s.summary[currentLang] || s.summary.en || '').toLowerCase();
    const tags    = s.tags.join(' ').toLowerCase();
    const date    = (s.date || '').toLowerCase();
    return title.includes(q) || summary.includes(q) || tags.includes(q) || date.includes(q);
  });
}

/* ---------- Render ---------- */
function render() {
  const filtered = getFiltered();
  const grid  = document.getElementById('sessions-grid');
  const count = document.getElementById('sessions-count');

  /* Update count */
  if (count) {
    const showing = document.documentElement.lang === 'he' ? 'מציג' :
                    document.documentElement.lang === 'it' ? 'Mostrando' : 'Showing';
    const of_     = document.documentElement.lang === 'he' ? 'מתוך' :
                    document.documentElement.lang === 'it' ? 'di'    : 'of';
    const sess    = document.documentElement.lang === 'he' ? 'מפגשים' :
                    document.documentElement.lang === 'it' ? 'sessioni' : 'sessions';
    count.textContent = `${showing} ${filtered.length} ${of_} ${allSessions.length} ${sess}`;
  }

  if (!grid) return;

  if (filtered.length === 0) {
    const noTitle = document.documentElement.lang === 'he' ? 'לא נמצאו מפגשים' :
                    document.documentElement.lang === 'it' ? 'Nessuna sessione trovata' :
                    'No sessions found';
    const noText  = document.documentElement.lang === 'he' ? 'נסה מונח חיפוש או מסנן שונה.' :
                    document.documentElement.lang === 'it' ? 'Prova un termine di ricerca o filtro diverso.' :
                    'Try a different search term or filter.';
    grid.innerHTML = `
      <div class="no-results">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
          <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
        </svg>
        <h3>${noTitle}</h3>
        <p>${noText}</p>
      </div>`;
    return;
  }

  const watchLabel = { en:'Watch →', it:'Guarda →', he:'צפה ←' };
  const lang = currentLang;

  grid.innerHTML = filtered.map((s, idx) => {
    const title   = s.title[lang]   || s.title.en;
    const summary = s.summary[lang] || s.summary.en;

    const dateLocale = lang === 'he' ? 'he-IL' : lang === 'it' ? 'it-IT' : 'en-GB';
    const dateStr = new Date(s.date).toLocaleDateString(dateLocale, {
      year:'numeric', month:'long', day:'numeric'
    });

    const tags = s.tags.map(t => {
      const label = tagMeta[t] ? (tagMeta[t][lang] || tagMeta[t].en) : t;
      return `<span class="tag">${label}</span>`;
    }).join('');

    /* Use real YouTube thumbnail if real ID, else use a gradient placeholder */
    const isRealId = s.id && !s.id.startsWith('PLAYLIST_VIDEO');
    const thumbStyle = isRealId
      ? `background:url('https://i.ytimg.com/vi/${s.id}/hqdefault.jpg') center/cover`
      : `background:linear-gradient(135deg,#1a2e28 0%,#4a7c6f ${50 + idx * 5}%)`;

    const link = isRealId
      ? `https://www.youtube.com/watch?v=${s.id}`
      : PLAYLIST_URL;

    return `
      <article class="session-card" data-tags="${s.tags.join(',')}" data-date="${s.date}">
        <a href="${link}" target="_blank" rel="noopener" class="session-thumb" aria-label="${title}"
           style="${thumbStyle}">
          ${isRealId ? `<img src="https://i.ytimg.com/vi/${s.id}/hqdefault.jpg" alt="${title}" loading="lazy" onerror="this.remove()">` : ''}
          <span class="play-btn" aria-hidden="true">
            <svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>
          </span>
        </a>
        <div class="session-body">
          <div class="session-tags">${tags}</div>
          <h3>${title}</h3>
          <p>${summary}</p>
          <div class="session-meta">
            <time datetime="${s.date}">${dateStr}</time>
            <a href="${link}" target="_blank" rel="noopener">${watchLabel[lang] || watchLabel.en}</a>
          </div>
        </div>
      </article>`;
  }).join('');
}

/* ---------- Bind controls ---------- */
function bindControls() {
  /* Search */
  const searchInput = document.getElementById('session-search');
  if (searchInput) {
    searchInput.addEventListener('input', e => {
      currentSearch = e.target.value;
      render();
    });
  }

  /* Filter buttons */
  document.querySelectorAll('.filter-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      currentFilter = btn.dataset.filter;
      document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      render();
    });
  });
}

/* ---------- React to language changes ---------- */
document.addEventListener('langchange', e => {
  currentLang = e.detail.lang;
  render();
});

/* ---------- Init ---------- */
document.addEventListener('DOMContentLoaded', () => {
  currentLang = localStorage.getItem('ses_lang') || 'en';
  bindControls();
  loadSessions();
});
