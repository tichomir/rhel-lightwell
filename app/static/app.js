/* Image Mode Train Service - UI behaviour.
 *
 * No framework and no build step, deliberately. Lightwell has no npm coverage,
 * so a Node toolchain in this repository would be both unnecessary and slightly
 * embarrassing. Plain ES2020 in one file.
 */

"use strict";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const DEFAULT_TEMPLATE = [
  "IMAGE MODE TRAIN SERVICE",
  "Reference: {{ booking.reference }}",
  "Passenger: {{ booking.passenger_name }}",
  "Service:   {{ booking.service_code }}",
  "Route:     {{ booking.origin_name }} to {{ booking.destination_name }}",
  "Date:      {{ booking.travel_date }} at {{ booking.depart_time }}",
  "Fare:      EUR {{ '%.2f'|format(booking.price_eur) }}",
].join("\n");

async function api(path, options) {
  const res = await fetch(path, Object.assign({
    headers: { "Content-Type": "application/json" },
  }, options || {}));
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    const detail = body && body.detail ? body.detail : `HTTP ${res.status}`;
    throw new Error(detail);
  }
  return body;
}

function text(value, fallback) {
  if (value === null || value === undefined || value === "") {
    return fallback === undefined ? "not reported" : fallback;
  }
  return String(value);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]);
}

function renderTable(container, columns, rows, emptyMessage) {
  if (!rows || rows.length === 0) {
    container.innerHTML = `<p class="empty">${escapeHtml(emptyMessage)}</p>`;
    return;
  }
  const head = columns.map((c) =>
    `<th${c.numeric ? ' class="numeric"' : ""}>${escapeHtml(c.label)}</th>`).join("");
  const body = rows.map((row) => {
    const cells = columns.map((c) => {
      const raw = c.value(row);
      const cls = [c.numeric ? "numeric" : "", c.mono ? "ref" : ""]
        .filter(Boolean).join(" ");
      return `<td${cls ? ` class="${cls}"` : ""}>${escapeHtml(raw)}</td>`;
    }).join("");
    return `<tr>${cells}</tr>`;
  }).join("");
  container.innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function showError(container, err) {
  container.innerHTML = `<p class="error">${escapeHtml(err.message)}</p>`;
}

/* Navigation -------------------------------------------------------------- */

$$(".nav-item").forEach((btn) => {
  btn.addEventListener("click", () => {
    $$(".nav-item").forEach((b) => b.classList.remove("is-current"));
    $$(".panel").forEach((p) => p.classList.remove("is-current"));
    btn.classList.add("is-current");
    $(`#panel-${btn.dataset.panel}`).classList.add("is-current");
    if (btn.dataset.panel === "status") loadStatus();
    if (btn.dataset.panel === "tickets") loadTickets();
    if (btn.dataset.panel === "receipt") loadBookingChoices();
  });
});

/* Stations ---------------------------------------------------------------- */

async function loadStations() {
  let stations;
  try {
    stations = await api("/api/stations");
  } catch (err) {
    return;
  }
  const options = stations
    .map((s) => `<option value="${escapeHtml(s.code)}">${escapeHtml(s.name)}</option>`)
    .join("");
  ["#origin", "#destination", "#tt-origin", "#tt-destination"].forEach((sel) => {
    const el = $(sel);
    if (el) el.innerHTML = `<option value="">Select station</option>${options}`;
  });
}

/* Search and book --------------------------------------------------------- */

const SERVICE_COLUMNS = [
  { label: "Service", value: (r) => r.service_code, mono: true },
  { label: "From", value: (r) => r.origin_name },
  { label: "To", value: (r) => r.destination_name },
  { label: "Departs", value: (r) => r.depart_time, numeric: true },
  { label: "Arrives", value: (r) => r.arrive_time, numeric: true },
  { label: "Fare", value: (r) => `EUR ${r.price_eur.toFixed(2)}`, numeric: true },
];

$("#search-btn").addEventListener("click", async () => {
  const out = $("#search-results");
  const payload = {
    origin: $("#origin").value,
    destination: $("#destination").value,
    travel_date: $("#travel-date").value,
  };
  if (!payload.origin || !payload.destination || !payload.travel_date) {
    out.innerHTML = '<p class="empty">Choose two stations and a date.</p>';
    return;
  }
  try {
    const rows = await api("/api/search", { method: "POST", body: JSON.stringify(payload) });
    if (rows.length === 0) {
      out.innerHTML = '<p class="empty">No services on that route.</p>';
      return;
    }
    const columns = SERVICE_COLUMNS.concat([{
      label: "", value: () => "",
    }]);
    renderTable(out, columns, rows, "");
    // Add a book button per row.
    const bodyRows = out.querySelectorAll("tbody tr");
    rows.forEach((row, i) => {
      const cell = bodyRows[i].lastElementChild;
      const btn = document.createElement("button");
      btn.className = "btn-primary";
      btn.textContent = "Book";
      btn.addEventListener("click", () => book(row));
      cell.textContent = "";
      cell.appendChild(btn);
    });
  } catch (err) {
    showError(out, err);
  }
});

async function book(service) {
  const out = $("#search-results");
  const passenger = $("#passenger").value.trim();
  if (!passenger) {
    out.insertAdjacentHTML("afterbegin",
      '<p class="error">Enter a passenger name before booking.</p>');
    return;
  }
  try {
    const created = await api("/api/bookings", {
      method: "POST",
      body: JSON.stringify({
        service_id: service.id,
        travel_date: $("#travel-date").value,
        passenger_name: passenger,
      }),
    });
    out.innerHTML =
      `<p class="empty">Booked. Reference <code>${escapeHtml(created.reference)}</code>` +
      ` for ${escapeHtml(created.passenger_name)}.</p>`;
  } catch (err) {
    showError(out, err);
  }
}

/* Timetable --------------------------------------------------------------- */

$("#tt-btn").addEventListener("click", async () => {
  const out = $("#timetable-results");
  const origin = $("#tt-origin").value;
  const destination = $("#tt-destination").value;
  if (!origin || !destination) {
    out.innerHTML = '<p class="empty">Choose two stations.</p>';
    return;
  }
  try {
    const rows = await api("/api/search", {
      method: "POST",
      body: JSON.stringify({
        origin, destination,
        travel_date: new Date().toISOString().slice(0, 10),
      }),
    });
    renderTable(out, SERVICE_COLUMNS, rows, "No services on that route.");
  } catch (err) {
    showError(out, err);
  }
});

/* Tickets ----------------------------------------------------------------- */

async function loadTickets() {
  const out = $("#tickets-results");
  try {
    const rows = await api("/api/bookings");
    renderTable(out, [
      { label: "Reference", value: (r) => r.reference, mono: true },
      { label: "Passenger", value: (r) => r.passenger_name },
      { label: "Service", value: (r) => r.service_code, mono: true },
      { label: "Route", value: (r) => `${r.origin_name} to ${r.destination_name}` },
      { label: "Date", value: (r) => r.travel_date, numeric: true },
      { label: "Fare", value: (r) => `EUR ${r.price_eur.toFixed(2)}`, numeric: true },
    ], rows, "No bookings yet. Book one from the first panel.");
  } catch (err) {
    showError(out, err);
  }
}

/* Receipt ----------------------------------------------------------------- */

async function loadBookingChoices() {
  const select = $("#receipt-booking");
  if (!$("#receipt-template").value) {
    $("#receipt-template").value = DEFAULT_TEMPLATE;
  }
  try {
    const rows = await api("/api/bookings");
    select.innerHTML = '<option value="">Select booking</option>' + rows.map((r) =>
      `<option value="${r.id}">${escapeHtml(r.reference)} — ${escapeHtml(r.passenger_name)}</option>`
    ).join("");
  } catch (err) {
    select.innerHTML = '<option value="">No bookings available</option>';
  }
}

$("#receipt-btn").addEventListener("click", async () => {
  const out = $("#receipt-output");
  const bookingId = $("#receipt-booking").value;
  if (!bookingId) {
    out.textContent = "Select a booking first.";
    return;
  }
  try {
    const res = await api("/api/receipt/preview", {
      method: "POST",
      body: JSON.stringify({
        booking_id: Number(bookingId),
        template: $("#receipt-template").value,
      }),
    });
    out.textContent = res.receipt;
  } catch (err) {
    out.textContent = `Template error: ${err.message}`;
  }
});

/* Status ------------------------------------------------------------------ */

function dl(container, entries) {
  container.innerHTML = entries.map(([term, value, cls]) =>
    `<dt>${escapeHtml(term)}</dt><dd${cls ? ` class="${cls}"` : ""}>${escapeHtml(value)}</dd>`
  ).join("");
}

async function loadStatus() {
  let s;
  try {
    s = await api("/api/status");
  } catch (err) {
    $("#fig-os").textContent = "unavailable";
    $("#fig-dep").textContent = "unavailable";
    return;
  }

  $("#tier-badge").textContent = `${text(s.hostname, "")} · tier ${text(s.tier, "?")}`;

  // Headline figure 1: the operating system. Changes in Act 1.
  $("#fig-os").textContent = s.os_version ? `RHEL ${s.os_version}` : "unknown";
  const osNote = $("#fig-os-note");
  if (s.staged_pending_reboot) {
    osNote.textContent = "An upgrade is staged and applies on reboot";
    osNote.className = "figure-note warn";
  } else if (s.image_mode) {
    osNote.textContent = s.rollback_available
      ? "Image mode · rollback available"
      : "Image mode · no rollback yet";
    osNote.className = "figure-note ok";
  } else {
    osNote.textContent = "bootc not detected — running outside image mode";
    osNote.className = "figure-note";
  }

  // Headline figure 2: the dependency. Changes in Act 4.
  const lw = s.lightwell || {};
  $("#fig-dep").textContent = text(lw.version, "not installed");
  const depNote = $("#fig-dep-note");
  if (lw.remediated) {
    depNote.textContent = "Lightwell remediated build";
    depNote.className = "figure-note ok";
  } else if (lw.version) {
    depNote.textContent = "Upstream build — no security patch applied";
    depNote.className = "figure-note bad";
  } else {
    depNote.textContent = "\u00a0";
    depNote.className = "figure-note";
  }

  dl($("#deployment-list"), [
    ["Host", text(s.hostname)],
    ["Operating system", `${text(s.os_name, "")} ${text(s.os_version, "")}`.trim()],
    ["Architecture", text(s.arch)],
    ["Image", text(s.image)],
    ["Digest", text(s.digest)],
    ["Image version", text(s.image_version)],
    ["Staged upgrade", s.staged_pending_reboot ? "yes, pending reboot" : "none",
      s.staged_pending_reboot ? "warn" : ""],
    ["Rollback", s.rollback_available ? "available" : "none",
      s.rollback_available ? "ok" : ""],
  ]);

  const deps = s.dependencies || {};
  dl($("#deps-list"), Object.keys(deps).map((name) => {
    const version = text(deps[name], "not installed");
    const cls = name === "jinja2" ? (lw.remediated ? "ok" : "bad") : "";
    return [name, version, cls];
  }));

  const db = s.database || {};
  dl($("#db-list"), [
    ["Reachable", db.available ? "yes" : "no", db.available ? "ok" : "bad"],
    ["Server", text(db.server)],
    ["Last error", text(db.error, "none")],
  ]);

  const probe = s.probe || {};
  dl($("#probe-list"), [
    ["Unsafe name emitted", probe.unsafe_key_emitted ? "yes" : "no",
      probe.unsafe_key_emitted ? "bad" : "ok"],
    ["Rendered output", text(probe.rendered, "rejected")],
    ["Rejected with", text(probe.rejected_with, "not rejected")],
  ]);
}

$("#refresh-btn").addEventListener("click", loadStatus);

/* Init -------------------------------------------------------------------- */

$("#travel-date").value = new Date().toISOString().slice(0, 10);
$("#receipt-template").value = DEFAULT_TEMPLATE;
loadStations();
loadStatus();
