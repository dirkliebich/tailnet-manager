import Foundation

// MARK: - Report model

/// A shareable report of one sidebar section: summary numbers plus tables.
/// Rendered as one self-contained HTML page (see ReportHTML).
struct ReportDocument: Encodable {
    var title: String
    var subtitle: String
    var stats: [ReportStat] = []
    var tables: [ReportTable] = []
}

enum ReportTone: String, Encodable {
    case neutral, good, warn, bad, info
}

struct ReportStat: Encodable {
    let label: String
    let value: String
    var note: String = ""
    var tone: ReportTone = .neutral
}

struct ReportColumn: Encodable {
    let key: String
    let title: String
    /// Offer a "filter by value" dropdown.
    var filter = false
    /// Offer "Group by" this column.
    var group = false
    /// Sort as numbers (cells should carry a numeric `sort`).
    var numeric = false
}

struct ReportCell: Encodable {
    let text: String
    /// Sort key when the text doesn't sort right ("in 3 days", "Critical").
    var sort: String?
    var tone: ReportTone?
    /// Shown as a pill.
    var badge = false
    /// http(s) only; anything else is dropped by the page.
    var link: String?

    init(_ text: String, sort: String? = nil, tone: ReportTone? = nil, badge: Bool = false, link: String? = nil) {
        self.text = text
        self.sort = sort
        self.tone = tone
        self.badge = badge
        self.link = link
    }

    init(_ number: Int, tone: ReportTone? = nil) {
        self.init("\(number)", sort: "\(number)", tone: tone)
    }

    /// A date shown as "4 Oct 2026, 16:40" that sorts chronologically.
    init(date: Date?, empty: String = "—", tone: ReportTone? = nil) {
        guard let date else {
            self.init(empty, sort: "", tone: tone)
            return
        }
        self.init(date.formatted(date: .abbreviated, time: .shortened),
                  sort: ISO8601DateFormatter().string(from: date), tone: tone)
    }

    static func yesNo(_ value: Bool?, yesTone: ReportTone? = nil, noTone: ReportTone? = nil) -> ReportCell {
        switch value {
        case true?: return ReportCell("Yes", tone: yesTone)
        case false?: return ReportCell("No", tone: noTone)
        case nil: return ReportCell("—")
        }
    }
}

struct ReportDetail: Encodable {
    let label: String
    let value: String
}

struct ReportRow: Encodable {
    let cells: [String: ReportCell]
    var details: [ReportDetail] = []
}

struct ReportTable: Encodable {
    let id: String
    let title: String
    var note: String = ""
    let columns: [ReportColumn]
    var rows: [ReportRow]
    /// Column key grouped by when the page opens ("" = no grouping).
    var groupBy: String = ""
    var sortBy: String = ""
    var sortDescending = false
    var emptyText = "Nothing to show."
}

// MARK: - HTML

/// Turns a report into one HTML file: no network, no external files, light
/// and dark theme, works on a phone. Every value is inserted as text by the
/// page's script, never as HTML, and a Content-Security-Policy blocks
/// anything that isn't the page's own inline code — names in a report come
/// from servers and the policy file, so they're untrusted.
enum ReportHTML {

    static func render(_ report: ReportDocument, generatedAt: Date = .now) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // Inside <script>: no "</script>", no HTML-significant characters.
        let safeJSON = json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return template
            .replacingOccurrences(of: "__TITLE__", with: escapeHTML(report.title))
            .replacingOccurrences(of: "__GENERATED__", with: escapeHTML(generatedAt.formatted(date: .long, time: .shortened)))
            .replacingOccurrences(of: "__DATA__", with: safeJSON)
    }

    /// "Tailnet report – Services – 2026-10-04 1640.html"
    static func fileName(for report: ReportDocument, at date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let title = report.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Tailnet report – \(title) – \(f.string(from: date)).html"
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let template = #"""
<!doctype html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
<meta name="color-scheme" content="light dark">
<title>__TITLE__</title>
<style>
:root {
  --bg: #f5f6f8; --panel: #ffffff; --panel2: #f9fafb; --text: #1b1d21; --muted: #667085;
  --line: #e4e7ec; --head: #f2f4f7; --chip: #eef0f4; --hover: #f7f8fa; --accent: #5654d6;
  --good: #157f3c; --warn: #b54708; --bad: #c01c28; --info: #175cd3; --shadow: 0 1px 2px rgba(16,24,40,.06);
}
:root[data-theme="dark"] {
  --bg: #0f1115; --panel: #181b21; --panel2: #1d2128; --text: #e8eaef; --muted: #98a2b3;
  --line: #2a2f38; --head: #1f232a; --chip: #232832; --hover: #20252d; --accent: #9b9aff;
  --good: #4ade80; --warn: #fbbf24; --bad: #f87171; --info: #60a5fa; --shadow: none;
}
@media (prefers-color-scheme: dark) {
  :root[data-theme="auto"] {
    --bg: #0f1115; --panel: #181b21; --panel2: #1d2128; --text: #e8eaef; --muted: #98a2b3;
    --line: #2a2f38; --head: #1f232a; --chip: #232832; --hover: #20252d; --accent: #9b9aff;
    --good: #4ade80; --warn: #fbbf24; --bad: #f87171; --info: #60a5fa; --shadow: none;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); }
body { font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
.wrap { max-width: 1440px; margin: 0 auto; padding: 0 16px 48px; }
header.top { position: sticky; top: 0; z-index: 5; background: color-mix(in srgb, var(--bg) 92%, transparent);
  backdrop-filter: blur(8px); border-bottom: 1px solid var(--line); }
header.top .wrap { display: flex; flex-wrap: wrap; gap: 12px 20px; align-items: center; padding-top: 14px; padding-bottom: 14px; }
.brand { flex: 1 1 280px; min-width: 0; }
.brand h1 { margin: 0; font-size: 22px; letter-spacing: -.01em; }
.brand p { margin: 2px 0 0; color: var(--muted); }
.actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
input, select, button { font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--line);
  border-radius: 8px; padding: 6px 10px; min-height: 34px; }
input[type=search] { min-width: 220px; }
button { cursor: pointer; }
button:hover, select:hover { border-color: color-mix(in srgb, var(--accent) 45%, var(--line)); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.seg button { border: 0; border-radius: 0; min-height: 32px; background: var(--panel); }
.seg button + button { border-left: 1px solid var(--line); }
.seg button[aria-pressed="true"] { background: var(--accent); color: #fff; }
nav#toc { display: flex; flex-wrap: wrap; gap: 8px; margin: 16px 0 4px; }
.chip { display: inline-flex; gap: 6px; align-items: center; padding: 4px 10px; border-radius: 999px; background: var(--chip);
  color: var(--text); text-decoration: none; font-size: 13px; }
.chip .n { color: var(--muted); font-variant-numeric: tabular-nums; }
.stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; margin: 16px 0; }
.stat { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; box-shadow: var(--shadow); }
.stat-label { color: var(--muted); font-size: 12.5px; }
.stat-value { font-size: 24px; font-weight: 700; letter-spacing: -.01em; margin-top: 2px; font-variant-numeric: tabular-nums; }
.stat-note { color: var(--muted); font-size: 12px; margin-top: 2px; }
.stat.tone-good .stat-value { color: var(--good); } .stat.tone-warn .stat-value { color: var(--warn); }
.stat.tone-bad .stat-value { color: var(--bad); } .stat.tone-info .stat-value { color: var(--info); }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 14px; margin: 18px 0; box-shadow: var(--shadow); overflow: hidden; scroll-margin-top: 90px; }
.card-head { display: flex; align-items: baseline; gap: 10px; padding: 14px 16px 4px; }
.card-head h2 { margin: 0; font-size: 17px; }
.count { color: var(--muted); font-variant-numeric: tabular-nums; }
.note { margin: 0; padding: 0 16px 6px; color: var(--muted); }
.toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 8px 16px 12px; border-bottom: 1px solid var(--line); }
.toolbar .field { display: inline-flex; gap: 6px; align-items: center; color: var(--muted); font-size: 12.5px; }
.toolbar .spacer { flex: 1; }
.toolbar .ghost { background: transparent; }
.tablewrap { max-height: 75vh; overflow: auto; }
table.rt { width: 100%; border-collapse: separate; border-spacing: 0; }
.rt th { position: sticky; top: 0; z-index: 1; background: var(--head); text-align: left; padding: 0; border-bottom: 1px solid var(--line); white-space: nowrap; }
.rt th button.sort { width: 100%; text-align: left; border: 0; border-radius: 0; background: transparent; font-weight: 600; padding: 8px 10px; min-height: 0; }
.rt th .arrow { color: var(--muted); margin-left: 4px; }
.rt td { padding: 7px 10px; border-bottom: 1px solid var(--line); vertical-align: top; overflow-wrap: anywhere; }
.rt td.x, .rt th.x { width: 34px; padding-right: 0; }
.rt tr.row:hover td { background: var(--hover); }
.rt tr.group td { background: var(--chip); padding: 0; position: sticky; top: 35px; z-index: 0; }
.rt button.grp { display: flex; gap: 8px; align-items: center; width: 100%; border: 0; border-radius: 0; background: transparent; padding: 8px 10px; text-align: left; }
.grp .caret { width: 12px; color: var(--muted); }
.grp .gtitle { color: var(--muted); }
.grp .gcount { color: var(--muted); font-variant-numeric: tabular-nums; }
button.more { min-height: 22px; width: 22px; padding: 0; border-radius: 6px; line-height: 1; color: var(--muted); }
.rt tr.detail td { background: var(--panel2); }
dl { display: grid; grid-template-columns: minmax(120px, max-content) 1fr; gap: 4px 16px; margin: 4px 0 6px 34px; }
dt { color: var(--muted); } dd { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.tone-good { color: var(--good); } .tone-warn { color: var(--warn); } .tone-bad { color: var(--bad); } .tone-info { color: var(--info); }
.badge { display: inline-block; padding: 1px 8px; border-radius: 999px; font-size: 12px; font-weight: 600;
  background: color-mix(in srgb, currentColor 14%, transparent); }
.empty { color: var(--muted); padding: 18px 16px; margin: 0; }
a { color: var(--accent); }
footer { color: var(--muted); font-size: 12.5px; margin-top: 28px; }
@media (max-width: 760px) {
  input[type=search] { min-width: 0; width: 100%; }
  .actions { width: 100%; }
  .actions input { flex: 1; }
  .tablewrap { max-height: none; overflow: visible; }
  .rt thead { display: none; }
  .rt, .rt tbody, .rt tr, .rt td { display: block; width: 100%; }
  .rt tr.row { border-bottom: 1px solid var(--line); padding: 6px 0; }
  .rt td { border: 0; padding: 3px 16px; display: flex; gap: 12px; }
  .rt td::before { content: attr(data-label); flex: 0 0 38%; color: var(--muted); font-size: 12.5px; }
  .rt td.x::before { content: ""; flex: 0; }
  .rt td.x { width: auto; padding: 4px 16px 0; }
  .rt td:empty { display: none; }
  .rt tr.group td { position: static; }
  dl { margin-left: 0; grid-template-columns: 1fr; }
}
@media print {
  header.top { position: static; backdrop-filter: none; }
  .actions, .toolbar, nav#toc, button.more { display: none !important; }
  .tablewrap { max-height: none; overflow: visible; }
  .rt th, .rt tr.group td { position: static; }
  .card { break-inside: auto; box-shadow: none; }
}
</style>
</head>
<body>
<header class="top"><div class="wrap">
  <div class="brand"><h1 id="title"></h1><p id="subtitle"></p></div>
  <div class="actions">
    <input id="q" type="search" placeholder="Search everything…  ( / )" aria-label="Search everything">
    <div class="seg" role="group" aria-label="Theme">
      <button type="button" data-theme-set="auto" title="Follow the system">Auto</button>
      <button type="button" data-theme-set="light">Light</button>
      <button type="button" data-theme-set="dark">Dark</button>
    </div>
    <button type="button" id="print" title="Print or save as PDF">Print / PDF</button>
  </div>
</div></header>
<div class="wrap">
  <nav id="toc" aria-label="Tables"></nav>
  <section id="stats" class="stats" aria-label="Summary"></section>
  <main id="tables"></main>
  <footer>Generated by Tailnet Manager on __GENERATED__. Read-only snapshot.</footer>
</div>
<script type="application/json" id="report-data">__DATA__</script>
<script>
(() => {
  "use strict";
  const data = JSON.parse(document.getElementById("report-data").textContent);
  const root = document.documentElement;
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  };

  // Theme: Auto follows the system; the choice is remembered when allowed.
  const THEME_KEY = "tailnet-report-theme";
  const setTheme = (t) => {
    root.setAttribute("data-theme", t);
    try { localStorage.setItem(THEME_KEY, t); } catch (e) {}
    document.querySelectorAll("[data-theme-set]").forEach((b) =>
      b.setAttribute("aria-pressed", String(b.getAttribute("data-theme-set") === t)));
  };
  let savedTheme = "auto";
  try { savedTheme = localStorage.getItem(THEME_KEY) || "auto"; } catch (e) {}
  setTheme(["auto", "light", "dark"].includes(savedTheme) ? savedTheme : "auto");
  document.querySelectorAll("[data-theme-set]").forEach((b) =>
    b.addEventListener("click", () => setTheme(b.getAttribute("data-theme-set"))));

  document.getElementById("title").textContent = data.title;
  document.getElementById("subtitle").textContent = data.subtitle;

  const statsEl = document.getElementById("stats");
  (data.stats || []).forEach((s) => {
    const c = el("div", "stat tone-" + (s.tone || "neutral"));
    c.appendChild(el("div", "stat-label", s.label));
    c.appendChild(el("div", "stat-value", s.value));
    if (s.note) c.appendChild(el("div", "stat-note", s.note));
    statsEl.appendChild(c);
  });
  statsEl.hidden = !(data.stats || []).length;

  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const cellText = (row, key) => (row.cells[key] ? row.cells[key].text : "");
  const sortVal = (row, key) => {
    const c = row.cells[key];
    if (!c) return "";
    return c.sort !== undefined && c.sort !== null ? c.sort : c.text;
  };
  const compare = (a, b, numeric) => {
    if (numeric) {
      const x = parseFloat(a), y = parseFloat(b);
      if (isNaN(x) && isNaN(y)) return 0;
      if (isNaN(x)) return 1;
      if (isNaN(y)) return -1;
      return x - y;
    }
    if (a === "" && b !== "") return 1;
    if (b === "" && a !== "") return -1;
    return collator.compare(a, b);
  };
  const words = (q) => q.toLowerCase().split(/\s+/).filter(Boolean);
  const matches = (hay, ws) => ws.every((w) => hay.includes(w));
  const rowHasBad = (r) => Object.values(r.cells).some((c) => c.tone === "bad");
  const csvField = (v) => {
    let s = String(v === undefined || v === null ? "" : v);
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;   // never a spreadsheet formula
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const slug = (s) => s.replace(/[^\w\- ]+/g, "").trim().replace(/\s+/g, "-").toLowerCase();

  let globalWords = [];
  const tables = [];
  const toc = document.getElementById("toc");
  const main = document.getElementById("tables");

  const makeTable = (t) => {
    const colByKey = {};
    t.columns.forEach((c) => { colByKey[c.key] = c; });
    const hasDetails = t.rows.some((r) => (r.details || []).length);
    t.rows.forEach((r) => {
      const parts = t.columns.map((c) => cellText(r, c.key));
      (r.details || []).forEach((d) => parts.push(d.label + " " + d.value));
      r._hay = parts.join(" \u0001 ").toLowerCase();
    });
    const st = {
      words: [], filters: {}, group: t.groupBy || "",
      sort: t.sortBy || (t.columns[0] ? t.columns[0].key : ""), desc: !!t.sortDescending,
      collapsed: null, open: new Set(),
    };

    const card = el("section", "card");
    card.id = "t-" + t.id;
    const head = el("div", "card-head");
    head.appendChild(el("h2", null, t.title));
    const count = el("span", "count");
    head.appendChild(count);
    card.appendChild(head);
    if (t.note) card.appendChild(el("p", "note", t.note));

    const tb = el("div", "toolbar");
    const search = el("input");
    search.type = "search";
    search.placeholder = "Search " + t.title.toLowerCase() + "…";
    search.setAttribute("aria-label", "Search " + t.title);
    let timer;
    search.addEventListener("input", () => {
      clearTimeout(timer);
      timer = setTimeout(() => { st.words = words(search.value); st.collapsed = null; render(); }, 120);
    });
    tb.appendChild(search);

    const filterSelects = [];
    t.columns.filter((c) => c.filter).forEach((c) => {
      const counts = new Map();
      t.rows.forEach((r) => { const v = cellText(r, c.key) || "—"; counts.set(v, (counts.get(v) || 0) + 1); });
      if (counts.size < 2) return;
      const sel = el("select");
      sel.setAttribute("aria-label", "Filter by " + c.title);
      const all = el("option", null, "All");
      all.value = "";
      sel.appendChild(all);
      [...counts.keys()].sort(collator.compare).forEach((v) => {
        const o = el("option", null, v + "  (" + counts.get(v) + ")");
        o.value = v;
        sel.appendChild(o);
      });
      sel.addEventListener("change", () => {
        if (sel.value) st.filters[c.key] = sel.value; else delete st.filters[c.key];
        st.collapsed = null;
        render();
      });
      const f = el("label", "field");
      f.appendChild(el("span", null, c.title));
      f.appendChild(sel);
      tb.appendChild(f);
      filterSelects.push(sel);
    });

    const groupable = t.columns.filter((c) => c.group);
    let groupSel = null;
    if (groupable.length) {
      groupSel = el("select");
      groupSel.setAttribute("aria-label", "Group by");
      const none = el("option", null, "No grouping");
      none.value = "";
      groupSel.appendChild(none);
      groupable.forEach((c) => { const o = el("option", null, c.title); o.value = c.key; groupSel.appendChild(o); });
      groupSel.value = st.group;
      groupSel.addEventListener("change", () => { st.group = groupSel.value; st.collapsed = null; render(); });
      const f = el("label", "field");
      f.appendChild(el("span", null, "Group by"));
      f.appendChild(groupSel);
      tb.appendChild(f);
    }

    const sortSel = el("select");
    sortSel.setAttribute("aria-label", "Sort by");
    t.columns.forEach((c) => { const o = el("option", null, c.title); o.value = c.key; sortSel.appendChild(o); });
    sortSel.value = st.sort;
    const dirBtn = el("button", null);
    dirBtn.type = "button";
    const syncDir = () => {
      dirBtn.textContent = st.desc ? "↓" : "↑";
      dirBtn.title = st.desc ? "Descending" : "Ascending";
    };
    syncDir();
    sortSel.addEventListener("change", () => { st.sort = sortSel.value; render(); });
    dirBtn.addEventListener("click", () => { st.desc = !st.desc; syncDir(); render(); });
    const sf = el("label", "field");
    sf.appendChild(el("span", null, "Sort"));
    sf.appendChild(sortSel);
    tb.appendChild(sf);
    tb.appendChild(dirBtn);

    tb.appendChild(el("span", "spacer"));
    const groupsBtn = el("button", null, "Collapse all");
    groupsBtn.type = "button";
    tb.appendChild(groupsBtn);
    const clearBtn = el("button", "ghost", "Clear");
    clearBtn.type = "button";
    clearBtn.addEventListener("click", () => {
      search.value = ""; st.words = []; st.filters = {};
      filterSelects.forEach((s) => { s.value = ""; });
      st.collapsed = null;
      render();
    });
    tb.appendChild(clearBtn);
    const csvBtn = el("button", null, "Download CSV");
    csvBtn.type = "button";
    tb.appendChild(csvBtn);
    card.appendChild(tb);

    const wrap = el("div", "tablewrap");
    const table = el("table", "rt");
    const thead = el("thead");
    const htr = el("tr");
    htr.appendChild(el("th", "x"));
    const arrows = {};
    t.columns.forEach((c) => {
      const th = el("th");
      th.scope = "col";
      const b = el("button", "sort", c.title);
      b.type = "button";
      const a = el("span", "arrow");
      b.appendChild(a);
      arrows[c.key] = { a, th };
      b.addEventListener("click", () => {
        if (st.sort === c.key) st.desc = !st.desc; else { st.sort = c.key; st.desc = false; }
        sortSel.value = st.sort; syncDir(); render();
      });
      th.appendChild(b);
      htr.appendChild(th);
    });
    thead.appendChild(htr);
    const tbody = el("tbody");
    table.appendChild(thead);
    table.appendChild(tbody);
    wrap.appendChild(table);
    card.appendChild(wrap);
    const empty = el("p", "empty", t.emptyText || "Nothing to show.");
    card.appendChild(empty);
    main.appendChild(card);

    const chip = el("a", "chip");
    chip.href = "#" + card.id;
    chip.appendChild(el("span", null, t.title));
    const chipN = el("span", "n");
    chip.appendChild(chipN);
    toc.appendChild(chip);

    const visibleRows = () => t.rows.filter((r) => {
      for (const k in st.filters) { if ((cellText(r, k) || "—") !== st.filters[k]) return false; }
      return matches(r._hay, globalWords) && matches(r._hay, st.words);
    });
    const sorted = (rows) => {
      const c = colByKey[st.sort];
      if (!c) return rows;
      return rows.slice().sort((a, b) => {
        const r = compare(sortVal(a, c.key), sortVal(b, c.key), c.numeric);
        return st.desc ? -r : r;
      });
    };
    const renderCell = (td, cell) => {
      if (!cell) return;
      let node;
      if (cell.link && /^https?:\/\//i.test(cell.link)) {
        node = el("a", null, cell.text);
        node.href = cell.link;
        node.target = "_blank";
        node.rel = "noopener noreferrer";
      } else {
        node = el("span", null, cell.text);
      }
      const cls = [];
      if (cell.badge) cls.push("badge");
      if (cell.tone && cell.tone !== "neutral") cls.push("tone-" + cell.tone);
      if (cls.length) node.className = cls.join(" ");
      td.appendChild(node);
    };
    const addRow = (r) => {
      const tr = el("tr", "row");
      const tdx = el("td", "x");
      if ((r.details || []).length) {
        const open = st.open.has(r);
        const b = el("button", "more", open ? "−" : "+");
        b.type = "button";
        b.setAttribute("aria-expanded", String(open));
        b.setAttribute("aria-label", open ? "Hide details" : "Show details");
        b.addEventListener("click", () => { if (st.open.has(r)) st.open.delete(r); else st.open.add(r); render(); });
        tdx.appendChild(b);
      }
      tr.appendChild(tdx);
      t.columns.forEach((c) => {
        const td = el("td");
        td.setAttribute("data-label", c.title);
        renderCell(td, r.cells[c.key]);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
      if (st.open.has(r)) {
        const dtr = el("tr", "detail");
        const dtd = el("td");
        dtd.colSpan = t.columns.length + 1;
        const dl = el("dl");
        r.details.forEach((d) => { dl.appendChild(el("dt", null, d.label)); dl.appendChild(el("dd", null, d.value)); });
        dtd.appendChild(dl);
        dtr.appendChild(dtd);
        tbody.appendChild(dtr);
      }
    };

    const render = () => {
      const rows = sorted(visibleRows());
      const total = t.rows.length;
      count.textContent = rows.length === total ? total + (total === 1 ? " item" : " items") : rows.length + " of " + total;
      chipN.textContent = String(rows.length);
      const narrowed = st.words.length || Object.keys(st.filters).length;
      clearBtn.hidden = !narrowed;
      t.columns.forEach((c) => {
        const { a, th } = arrows[c.key];
        a.textContent = st.sort === c.key ? (st.desc ? "▼" : "▲") : "";
        th.setAttribute("aria-sort", st.sort === c.key ? (st.desc ? "descending" : "ascending") : "none");
      });
      tbody.textContent = "";
      empty.hidden = rows.length > 0;
      wrap.hidden = rows.length === 0;
      if (!st.group || !colByKey[st.group]) {
        groupsBtn.hidden = true;
        rows.forEach(addRow);
        return;
      }
      const gc = colByKey[st.group];
      const groups = new Map();
      rows.forEach((r) => {
        const k = cellText(r, gc.key) || "—";
        if (!groups.has(k)) groups.set(k, []);
        groups.get(k).push(r);
      });
      const keyOf = (k) => sortVal(groups.get(k)[0], gc.key);
      const keys = [...groups.keys()].sort((a, b) => compare(keyOf(a), keyOf(b), gc.numeric) || collator.compare(a, b));
      // Big tables open folded; narrowing (search, filter) opens everything.
      if (st.collapsed === null) {
        const fold = !narrowing() && rows.length > 150 && keys.length > 1;
        st.collapsed = new Set(fold ? keys : []);
      }
      keys.forEach((k) => {
        const list = groups.get(k);
        const folded = st.collapsed.has(k);
        const tr = el("tr", "group");
        const td = el("td");
        td.colSpan = t.columns.length + 1;
        const b = el("button", "grp");
        b.type = "button";
        b.setAttribute("aria-expanded", String(!folded));
        b.appendChild(el("span", "caret", folded ? "▸" : "▾"));
        b.appendChild(el("span", "gtitle", gc.title + ":"));
        b.appendChild(el("strong", null, k));
        b.appendChild(el("span", "gcount", "· " + list.length));
        const bad = list.filter(rowHasBad).length;
        if (bad) b.appendChild(el("span", "badge tone-bad", bad + " need attention"));
        b.addEventListener("click", () => { if (st.collapsed.has(k)) st.collapsed.delete(k); else st.collapsed.add(k); render(); });
        td.appendChild(b);
        tr.appendChild(td);
        tbody.appendChild(tr);
        if (!folded) list.forEach(addRow);
      });
      groupsBtn.hidden = false;
      const allFolded = keys.every((k) => st.collapsed.has(k));
      groupsBtn.textContent = allFolded ? "Expand all" : "Collapse all";
      groupsBtn.onclick = () => { st.collapsed = new Set(allFolded ? [] : keys); render(); };
    };
    const narrowing = () => globalWords.length || st.words.length || Object.keys(st.filters).length;

    csvBtn.addEventListener("click", () => {
      const rows = sorted(visibleRows());
      const header = t.columns.map((c) => csvField(c.title));
      if (hasDetails) header.push("Details");
      const lines = [header.join(",")];
      rows.forEach((r) => {
        const cells = t.columns.map((c) => csvField(cellText(r, c.key)));
        if (hasDetails) cells.push(csvField((r.details || []).map((d) => d.label + ": " + d.value).join("; ")));
        lines.push(cells.join(","));
      });
      const blob = new Blob(["﻿" + lines.join("\r\n") + "\r\n"], { type: "text/csv;charset=utf-8" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = slug(data.title + " " + t.title) + ".csv";
      document.body.appendChild(a);
      a.click();
      setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
    });

    const api = {
      render,
      expandAll: () => { st.collapsed = new Set(); render(); },
      resetFold: () => { st.collapsed = null; },
    };
    render();
    return api;
  };

  (data.tables || []).forEach((t) => tables.push(makeTable(t)));
  if (!(data.tables || []).length) toc.hidden = true;

  const q = document.getElementById("q");
  let gtimer;
  q.addEventListener("input", () => {
    clearTimeout(gtimer);
    gtimer = setTimeout(() => {
      globalWords = words(q.value);
      tables.forEach((t) => { t.resetFold(); t.render(); });
    }, 120);
  });
  document.addEventListener("keydown", (e) => {
    const tag = (document.activeElement && document.activeElement.tagName) || "";
    if (e.key === "/" && tag !== "INPUT" && tag !== "SELECT" && tag !== "TEXTAREA") { e.preventDefault(); q.focus(); }
  });
  const printAll = () => tables.forEach((t) => t.expandAll());
  window.addEventListener("beforeprint", printAll);
  document.getElementById("print").addEventListener("click", () => { printAll(); window.print(); });
})();
</script>
</body>
</html>
"""#
}
