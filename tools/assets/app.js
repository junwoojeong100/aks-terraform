(function () {
  'use strict';

  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  var store = {
    get: function (k, d) { try { var v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* ignore */ } }
  };
  /* UI strings of the page language (injected by tools/build-html.mjs) */
  var T = window.AKS_I18N || {};

  /* ---------- theme ---------- */
  var root = document.documentElement;
  var saved = store.get('aks-guide-theme', null);
  var prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  function applyTheme(t) {
    root.setAttribute('data-theme', t);
    var b = $('#theme-btn');
    if (b) b.textContent = t === 'dark' ? T.light : T.dark;
  }
  applyTheme(saved || (prefersDark ? 'dark' : 'light'));
  $('#theme-btn').addEventListener('click', function () {
    var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    store.set('aks-guide-theme', next);
    applyTheme(next);
  });

  /* ---------- mobile menu ---------- */
  $('#menu-btn').addEventListener('click', function () { document.body.classList.toggle('menu-open'); });
  $$('.sidebar a').forEach(function (a) {
    a.addEventListener('click', function () { document.body.classList.remove('menu-open'); });
  });

  /* ---------- code: copy / expand ---------- */
  $$('figure.code').forEach(function (fig) {
    var copy = $('.copy', fig);
    var code = $('pre code', fig);
    if (copy && code) {
      copy.addEventListener('click', function () {
        var text = code.textContent;
        var done = function () {
          copy.classList.add('ok');
          var old = copy.textContent;
          copy.textContent = T.copied;
          setTimeout(function () { copy.classList.remove('ok'); copy.textContent = old; }, 1400);
        };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
        } else {
          fallbackCopy(text); done();
        }
      });
    }
    var expand = $('.expand', fig);
    if (expand) {
      expand.addEventListener('click', function () {
        var collapsed = fig.classList.contains('collapsed');
        fig.classList.toggle('collapsed', !collapsed);
        fig.classList.toggle('expanded', collapsed);
        expand.textContent = collapsed ? T.collapse : expand.getAttribute('data-label');
      });
    }
  });
  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch (e) { /* ignore */ }
    document.body.removeChild(ta);
  }

  /* ---------- task list persistence + lab done ---------- */
  var tasks = store.get('aks-guide-tasks', {});
  function refreshDone() {
    $$('.lab-link[data-lab]').forEach(function (a) {
      a.classList.toggle('done', !!tasks['done:' + a.getAttribute('data-lab')]);
    });
  }
  $$('section.lab').forEach(function (sec) {
    var lab = sec.getAttribute('data-lab');
    $$('input[type=checkbox][data-task]', sec).forEach(function (cb) {
      var key = lab + ':' + cb.getAttribute('data-task');
      cb.checked = !!tasks[key];
      cb.closest('li').classList.toggle('checked', cb.checked);
      cb.addEventListener('change', function () {
        tasks[key] = cb.checked; store.set('aks-guide-tasks', tasks);
        cb.closest('li').classList.toggle('checked', cb.checked);
      });
    });
    var done = $('input.lab-done-cb', sec);
    if (done) {
      done.checked = !!tasks['done:' + lab];
      done.addEventListener('change', function () {
        tasks['done:' + lab] = done.checked; store.set('aks-guide-tasks', tasks); refreshDone();
      });
    }
  });
  refreshDone();

  /* ---------- scroll spy + progress ---------- */
  var sections = $$('section.lab');
  var links = {};
  $$('.sidebar .lab-link[data-lab]').forEach(function (a) { links[a.getAttribute('data-lab')] = a; });
  var subLinks = $$('.sidebar .sub a');
  var bar = $('.progress');
  var ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      ticking = false;
      var h = document.documentElement;
      var max = h.scrollHeight - h.clientHeight;
      bar.style.width = (max > 0 ? Math.min(100, (h.scrollTop / max) * 100) : 0) + '%';
      var current = sections[0];
      sections.forEach(function (s) { if (s.getBoundingClientRect().top <= 120) current = s; });
      var id = current ? current.getAttribute('data-lab') : null;
      Object.keys(links).forEach(function (k) { links[k].classList.toggle('active', k === id); });
      var activeSub = null;
      if (current) {
        $$('h2[id], h3[id]', current).forEach(function (hd) { if (hd.getBoundingClientRect().top <= 120) activeSub = hd.id; });
      }
      subLinks.forEach(function (a) { a.classList.toggle('active', a.getAttribute('href') === '#' + activeSub); });
      var act = links[id];
      if (act && act.scrollIntoViewIfNeeded) { /* keep sidebar item visible */
        var sb = $('.sidebar'); var r = act.getBoundingClientRect(); var sr = sb.getBoundingClientRect();
        if (r.top < sr.top + 20 || r.bottom > sr.bottom - 20) sb.scrollTop += r.top - sr.top - 80;
      }
    });
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll);
  onScroll();

  /* ---------- search ---------- */
  var input = $('#search-input');
  var box = $('#results');
  var index = null;
  function buildIndex() {
    if (index) return;
    index = [];
    sections.forEach(function (sec) {
      var lab = sec.getAttribute('data-lab');
      var labTitle = sec.getAttribute('data-title');
      var nodes = $$('h2, h3, p, li, td, th, figure.code', sec);
      var current = { id: sec.id, title: labTitle };
      nodes.forEach(function (n) {
        if (n.tagName === 'H2' || n.tagName === 'H3') { current = { id: n.id || sec.id, title: n.textContent.replace(/#$/, '').trim() }; }
        var txt = (n.tagName === 'FIGURE' ? (($('.file', n) || {}).textContent || '') + ' ' + n.textContent : n.textContent).replace(/\s+/g, ' ').trim();
        if (txt.length > 1) index.push({ lab: lab, labTitle: labTitle, anchor: current.id, heading: current.title, text: txt, lower: txt.toLowerCase(), isCode: n.tagName === 'FIGURE' });
      });
    });
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function snippet(text, lowerText, terms) {
    var pos = -1;
    terms.forEach(function (t) { var p = lowerText.indexOf(t); if (p >= 0 && (pos < 0 || p < pos)) pos = p; });
    var start = Math.max(0, pos - 40);
    var part = text.substr(start, 150);
    var html = esc(part);
    terms.forEach(function (t) {
      if (!t) return;
      var re = new RegExp('(' + t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + ')', 'ig');
      html = html.replace(re, '<mark>$1</mark>');
    });
    return (start > 0 ? '…' : '') + html + (start + 150 < text.length ? '…' : '');
  }
  var activeIdx = -1;
  function runSearch() {
    var q = input.value.trim().toLowerCase();
    if (q.length < 2) { box.classList.remove('open'); box.innerHTML = ''; return; }
    buildIndex();
    var terms = q.split(/\s+/).filter(Boolean);
    var seen = {}; var hits = [];
    index.forEach(function (e) {
      if (terms.every(function (t) { return e.lower.indexOf(t) >= 0; })) {
        var key = e.anchor;
        var score = (e.isCode ? 0 : 2) + (e.heading.toLowerCase().indexOf(terms[0]) >= 0 ? 3 : 0);
        if (!seen[key] || seen[key].score < score) { seen[key] = { e: e, score: score }; }
      }
    });
    Object.keys(seen).forEach(function (k) { hits.push(seen[k]); });
    hits.sort(function (a, b) { return b.score - a.score; });
    hits = hits.slice(0, 12);
    if (!hits.length) { box.innerHTML = '<div class="empty">' + esc(T.noResults) + '</div>'; box.classList.add('open'); return; }
    box.innerHTML = hits.map(function (h) {
      return '<a href="#' + h.e.anchor + '"><div class="r-title">' + esc(h.e.heading) + '</div><div class="r-lab">' + esc(h.e.labTitle) + '</div><div>' + snippet(h.e.text, h.e.lower, terms) + '</div></a>';
    }).join('');
    box.classList.add('open'); activeIdx = -1;
  }
  input.addEventListener('input', runSearch);
  input.addEventListener('focus', runSearch);
  input.addEventListener('keydown', function (ev) {
    var items = $$('a', box);
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault();
      if (!items.length) return;
      activeIdx = (activeIdx + (ev.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items.forEach(function (a, i) { a.classList.toggle('active', i === activeIdx); });
      items[activeIdx].scrollIntoView({ block: 'nearest' });
    } else if (ev.key === 'Enter') {
      var t = items[activeIdx >= 0 ? activeIdx : 0];
      if (t) { location.hash = t.getAttribute('href'); box.classList.remove('open'); input.blur(); }
    } else if (ev.key === 'Escape') { box.classList.remove('open'); input.blur(); }
  });
  document.addEventListener('click', function (ev) {
    if (!ev.target.closest('.search')) box.classList.remove('open');
    else if (ev.target.closest('#results a')) { box.classList.remove('open'); }
  });
  document.addEventListener('keydown', function (ev) {
    var tag = (document.activeElement || {}).tagName;
    if ((ev.key === '/' || (ev.key === 'k' && (ev.ctrlKey || ev.metaKey))) && tag !== 'INPUT' && tag !== 'TEXTAREA') {
      ev.preventDefault(); input.focus(); input.select();
    }
  });
})();
