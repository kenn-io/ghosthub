// Ghosthub web UI demo approximation. Sidebar inventory comes from
// /api/v1/inventory (real local host, synthetic fleet); every attach opens a
// live local console shell over the byte relay at /ws/v1/attach.
"use strict";

const PROTOCOL_VERSION = 1;
// Fallback for the server's grid-dimension bound; the value the server
// advertises in its hello limits wins when present.
const MAX_GRID_DIMENSION = 1000;
// Fallback for the server's websocket message limit; the advertised value
// wins when present. Input larger than the limit is split into ordered
// chunks — the relay treats input as a byte stream, so chunk boundaries
// need no alignment.
const MAX_MESSAGE_BYTES = 256 * 1024;
const XTermCtor = window.Terminal && window.Terminal.Terminal ? window.Terminal.Terminal : window.Terminal;
const FitCtor = window.FitAddon && window.FitAddon.FitAddon ? window.FitAddon.FitAddon : window.FitAddon;
const Unicode11Ctor =
  window.Unicode11Addon && window.Unicode11Addon.Unicode11Addon
    ? window.Unicode11Addon.Unicode11Addon
    : window.Unicode11Addon;

const state = {
  term: null,
  fit: null,
  socket: null,
  activeRow: null,
  activeLabel: null,
  closedByUser: false,
  resizeObserver: null,
  // The unresolved teardown acknowledgment, shared so every later attach
  // awaits it — not only the attach that initiated the teardown.
  pendingClose: null,
};

let attachSequence = 0;

const elements = {
  inventory: document.getElementById("inventory"),
  sidebar: document.getElementById("sidebar"),
  navToggle: document.getElementById("nav-toggle"),
  windowTitle: document.getElementById("window-title"),
  pane: document.getElementById("pane"),
  emptyState: document.getElementById("empty-state"),
  terminal: document.getElementById("terminal"),
  overlay: document.getElementById("disconnect-overlay"),
  disconnectDetail: document.getElementById("disconnect-detail"),
  reconnect: document.getElementById("reconnect"),
  closePane: document.getElementById("close-pane"),
  toast: document.getElementById("toast"),
};

elements.navToggle.addEventListener("click", () => {
  elements.sidebar.classList.toggle("hidden");
});

elements.reconnect.addEventListener("click", () => {
  if (state.activeLabel) {
    attach(state.activeLabel, state.activeRow);
  }
});

elements.closePane.addEventListener("click", () => {
  // Cancels an attach parked on a pending teardown acknowledgment: when
  // its await resolves, the moved sequence aborts it instead of
  // repopulating the pane the user just closed.
  attachSequence += 1;
  teardown();
  showEmptyState();
  setTitle(null);
  if (state.activeRow) {
    state.activeRow.classList.remove("active");
    state.activeRow = null;
  }
  state.activeLabel = null;
});

let toastTimer = null;
function toast(message, kind) {
  elements.toast.innerHTML = "";
  const icon = document.createElement("span");
  icon.className = `toast-icon ${kind === "ok" ? "ok" : "info"}`;
  icon.textContent = kind === "ok" ? "✓" : "⚠";
  const text = document.createElement("span");
  text.textContent = message;
  elements.toast.append(icon, text);
  elements.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    elements.toast.hidden = true;
  }, 2500);
}

function setTitle(label) {
  elements.windowTitle.innerHTML = "";
  if (!label) {
    const fallback = document.createElement("span");
    fallback.className = "title-fallback";
    fallback.textContent = "Ghosthub";
    elements.windowTitle.append(fallback);
    return;
  }
  const glyph = document.createElement("span");
  glyph.className = "title-glyph";
  glyph.textContent = ">_";
  const name = document.createElement("span");
  name.textContent = label.name;
  const dot = document.createElement("span");
  dot.className = "title-dot";
  dot.textContent = "·";
  const host = document.createElement("span");
  host.className = "title-host";
  host.textContent = label.host;
  elements.windowTitle.append(glyph, name, dot, host);
}

function showEmptyState() {
  elements.emptyState.hidden = false;
  elements.terminal.hidden = true;
  elements.overlay.hidden = true;
}

function showTerminal() {
  elements.emptyState.hidden = true;
  elements.terminal.hidden = false;
  elements.overlay.hidden = true;
}

function showDisconnect(detail) {
  elements.disconnectDetail.textContent = detail;
  elements.overlay.hidden = false;
}

// Tear down the current attachment. The returned promise resolves once
// the old socket has closed — the server sends its close frame only after
// the relay threads joined and the PTY child was reaped, so awaiting it
// serializes a replacement attachment behind the previous one's teardown
// and two PTY clients never overlap on one multiplexer session. A timeout
// bounds a vanished server.
function teardown() {
  if (state.resizeObserver) {
    state.resizeObserver.disconnect();
    state.resizeObserver = null;
  }
  // state.pendingClose holds the un-raced acknowledgment: it resolves
  // only when the server's close event genuinely arrives, so a retry
  // after a timed-out attempt still waits for (or immediately receives)
  // the real acknowledgment. Each caller gets a timeout-raced view of it
  // — false means teardown unconfirmed, never permission to proceed.
  const previous = state.pendingClose;
  let acknowledgment = previous;
  if (state.socket) {
    const socket = state.socket;
    state.closedByUser = true;
    state.socket = null;
    let closeEvent = Promise.resolve(true);
    if (socket.readyState !== WebSocket.CLOSED) {
      closeEvent = new Promise((resolve) => {
        socket.addEventListener("close", () => resolve(true), { once: true });
      });
    }
    socket.close();
    acknowledgment = previous ? previous.then(() => closeEvent) : closeEvent;
  }
  if (acknowledgment && acknowledgment !== previous) {
    const stored = acknowledgment;
    state.pendingClose = stored;
    stored.then(() => {
      if (state.pendingClose === stored) {
        state.pendingClose = null;
      }
    });
  }
  if (state.term) {
    state.term.dispose();
    state.term = null;
    state.fit = null;
  }
  elements.terminal.innerHTML = "";
  if (!acknowledgment) {
    return Promise.resolve(true);
  }
  const timeout = new Promise((resolve) => {
    setTimeout(() => resolve(false), 5000);
  });
  return Promise.race([acknowledgment, timeout]);
}

function geometry(gridLimit) {
  return {
    columns: Math.min(gridLimit, state.term.cols),
    rows: Math.min(gridLimit, state.term.rows),
    pixel_width: Math.min(65535, elements.terminal.clientWidth),
    pixel_height: Math.min(65535, elements.terminal.clientHeight),
  };
}

async function attach(label, row) {
  attachSequence += 1;
  const sequence = attachSequence;
  const acknowledged = await teardown();
  if (sequence !== attachSequence) {
    return; // a newer attach superseded this one while it waited
  }
  state.activeLabel = label;
  if (state.activeRow) {
    state.activeRow.classList.remove("active");
  }
  state.activeRow = row;
  row.classList.add("active");
  setTitle(label);
  if (acknowledged === false) {
    // The requested target is already recorded above, so Reconnect
    // retries this session, not the one being torn down.
    showDisconnect("The previous session is still closing; try again.");
    return;
  }
  showTerminal();

  const term = new XTermCtor({
    // The Unicode 11 addon lives behind xterm's proposed-API gate; without
    // this flag, reading term.unicode throws before the terminal opens.
    allowProposedApi: true,
    fontFamily: '"Cascadia Mono", Consolas, monospace',
    fontSize: 13,
    cursorBlink: true,
    theme: {
      background: "#0c0c14",
      foreground: "#d8dee9",
      cursor: "#9dc7ed",
      selectionBackground: "#133d6a",
    },
  });
  const fit = new FitCtor();
  term.loadAddon(fit);
  // The hello declares unicode_width 11; load the matching width tables so
  // the capability is true, not aspirational.
  term.loadAddon(new Unicode11Ctor());
  term.unicode.activeVersion = "11";
  term.open(elements.terminal);
  fit.fit();
  state.term = term;
  state.fit = fit;

  const socket = new WebSocket(`ws://${location.host}/ws/v1/attach`);
  socket.binaryType = "arraybuffer";
  state.socket = socket;
  state.closedByUser = false;
  const encoder = new TextEncoder();
  // Per-socket hello progress: a stale socket's late frames must never
  // advance or write into a newer attachment's state.
  let helloDone = false;
  let gridLimit = MAX_GRID_DIMENSION;
  let messageLimit = MAX_MESSAGE_BYTES;
  const sendChunked = (bytes) => {
    for (let offset = 0; offset < bytes.length; offset += messageLimit) {
      socket.send(bytes.subarray(offset, offset + messageLimit));
    }
  };

  socket.addEventListener("message", (event) => {
    if (state.socket !== socket) {
      return;
    }
    if (typeof event.data === "string") {
      if (helloDone) {
        return; // no text frames are defined server-to-client after hello
      }
      let hello;
      try {
        hello = JSON.parse(event.data);
      } catch {
        // Detach before closing so the generic close handler does not
        // overwrite this rejection with "Connection closed".
        if (state.socket === socket) {
          state.socket = null;
        }
        socket.close();
        showDisconnect("Malformed server hello");
        return;
      }
      if (hello.protocol !== PROTOCOL_VERSION) {
        if (state.socket === socket) {
          state.socket = null;
        }
        socket.close();
        showDisconnect("Protocol version mismatch");
        return;
      }
      helloDone = true;
      const advertised = hello.limits && hello.limits.max_grid_dimension;
      if (Number.isInteger(advertised) && advertised > 0) {
        gridLimit = advertised;
      }
      const frameLimit = hello.limits && hello.limits.max_frame_bytes;
      const wholeLimit = hello.limits && hello.limits.max_message_bytes;
      messageLimit = Math.min(
        Number.isInteger(frameLimit) && frameLimit > 0 ? frameLimit : MAX_MESSAGE_BYTES,
        Number.isInteger(wholeLimit) && wholeLimit > 0 ? wholeLimit : MAX_MESSAGE_BYTES,
      );
      socket.send(
        JSON.stringify({
          protocol: PROTOCOL_VERSION,
          capabilities: {
            unicode_width: 11,
            ignores_conpty_mode_requests: true,
          },
          initial: geometry(gridLimit),
        }),
      );
      return;
    }
    term.write(new Uint8Array(event.data));
  });

  socket.addEventListener("close", (event) => {
    if (state.closedByUser || state.socket !== socket) {
      return;
    }
    state.socket = null;
    if (event.code === 1000) {
      attachSequence += 1;
      teardown();
      showEmptyState();
      toast("Session ended", "ok");
      if (state.activeRow) {
        state.activeRow.classList.remove("active");
        state.activeRow = null;
      }
      setTitle(null);
      state.activeLabel = null;
    } else {
      showDisconnect(event.reason ? `Closed: ${event.reason}` : "Connection closed");
    }
  });

  term.onData((data) => {
    if (socket.readyState === WebSocket.OPEN && helloDone) {
      sendChunked(encoder.encode(data));
    }
  });

  // Legacy X10/VT200 mouse reports arrive as raw 8-bit character codes,
  // not UTF-8 text; forward them byte-for-byte.
  term.onBinary((data) => {
    if (socket.readyState === WebSocket.OPEN && helloDone) {
      const bytes = new Uint8Array(data.length);
      for (let i = 0; i < data.length; i += 1) {
        bytes[i] = data.charCodeAt(i) & 255;
      }
      sendChunked(bytes);
    }
  });

  term.onResize(() => {
    if (socket.readyState === WebSocket.OPEN && helloDone) {
      socket.send(JSON.stringify({ resize: geometry(gridLimit) }));
    }
  });

  state.resizeObserver = new ResizeObserver(() => {
    if (state.fit) {
      state.fit.fit();
    }
  });
  state.resizeObserver.observe(elements.pane);
  term.focus();
}

// --- Sidebar rendering ---

function sessionRow(options) {
  const row = document.createElement("div");
  row.className = "session-row";
  if (options.nested) {
    row.classList.add("nested");
  }
  if (options.stopped) {
    row.classList.add("stopped");
  }
  const glyph = document.createElement("span");
  glyph.className = "session-glyph";
  glyph.textContent = options.glyph || ">_";
  const name = document.createElement("span");
  name.className = "session-name";
  name.textContent = options.name;
  row.append(glyph, name);
  if (options.recent) {
    const dot = document.createElement("span");
    dot.className = "session-recent";
    dot.title = "Recent output";
    row.append(dot);
  }
  for (const badge of options.badges || []) {
    row.append(badge);
  }
  if (options.detail) {
    const detail = document.createElement("span");
    detail.className = "session-detail";
    detail.textContent = options.detail;
    row.append(detail);
  }
  row.addEventListener("click", () => {
    if (options.demoNote) {
      toast(options.demoNote, "info");
    }
    attach(options.label, row);
  });
  return row;
}

function groupHeader(title, addTitle) {
  const header = document.createElement("div");
  header.className = "group-header";
  header.textContent = title;
  const add = document.createElement("button");
  add.className = "group-add";
  add.textContent = "+";
  add.title = addTitle;
  add.addEventListener("click", (event) => {
    event.stopPropagation();
    toast("Creating sessions is not part of the demo yet", "info");
  });
  header.append(add);
  return header;
}

function renderHost(host) {
  const section = document.createElement("div");
  const header = document.createElement("div");
  header.className = "host-header";
  const chevron = document.createElement("span");
  chevron.className = "host-chevron";
  chevron.textContent = "▾";
  const dot = document.createElement("span");
  dot.className = `host-dot ${host.status}`;
  const name = document.createElement("span");
  name.textContent = host.name;
  const endpoint = document.createElement("span");
  endpoint.className = "host-endpoint";
  endpoint.textContent = host.endpoint;
  header.append(chevron, dot, name, endpoint);
  const contents = document.createElement("div");
  header.addEventListener("click", () => {
    const collapsed = contents.hidden;
    contents.hidden = !collapsed;
    chevron.textContent = collapsed ? "▾" : "▸";
  });

  const demo = host.kind !== "local";
  const demoNote = demo
    ? `Demo data: attaching a local console shell instead of ${host.endpoint}`
    : undefined;

  if (host.console) {
    contents.append(groupHeader("Console", "New console"));
    contents.append(
      sessionRow({
        name: host.console.name,
        detail: host.console.subtitle,
        label: { name: host.console.name, host: host.name },
      }),
    );
  }

  const groups = [
    ["TMUX SESSIONS", host.tmux_sessions, "New tmux session"],
    ...(host.herdr_available ? [["HERDR SESSIONS", host.herdr_sessions, "New Herdr session"]] : []),
    ...(host.zellij_available ? [["ZELLIJ SESSIONS", host.zellij_sessions, "New Zellij session"]] : []),
  ];
  for (const [title, sessions, addTitle] of groups) {
    if (host.kind === "local" && sessions.length === 0) {
      continue;
    }
    contents.append(groupHeader(title, addTitle));
    if (sessions.length === 0) {
      const empty = document.createElement("div");
      empty.className = "group-empty";
      empty.textContent = "No sessions";
      contents.append(empty);
      continue;
    }
    for (const session of sessions) {
      contents.append(
        sessionRow({
          name: session.name,
          detail: session.subtitle,
          recent: session.recent,
          stopped: session.stopped,
          demoNote: session.stopped
            ? "Demo: restart opens a local console shell"
            : demoNote,
          label: { name: session.name, host: host.name },
        }),
      );
    }
  }

  if (host.projects.length > 0) {
    contents.append(groupHeader("PROJECTS", "Add Project"));
    for (const project of host.projects) {
      contents.append(
        sessionRow({
          glyph: "▢",
          name: project.name,
          detail: project.subtitle,
          demoNote,
          label: { name: project.name, host: host.name },
        }),
      );
      for (const worktree of project.worktrees) {
        const badges = [];
        if (worktree.added) {
          const added = document.createElement("span");
          added.className = "status-add";
          added.textContent = `+${worktree.added}`;
          badges.push(added);
        }
        if (worktree.ahead) {
          const ahead = document.createElement("span");
          ahead.className = "status-ahead";
          ahead.textContent = `↑${worktree.ahead}`;
          badges.push(ahead);
        }
        contents.append(
          sessionRow({
            nested: true,
            glyph: worktree.primary ? "■" : "△",
            name: worktree.name,
            badges,
            demoNote,
            label: { name: `${project.name} / ${worktree.name}`, host: host.name },
          }),
        );
      }
    }
  }

  section.append(header, contents);
  return section;
}

async function load() {
  let inventory;
  try {
    const response = await fetch("/api/v1/inventory");
    if (!response.ok) {
      throw new Error(`inventory request failed: ${response.status}`);
    }
    inventory = await response.json();
  } catch {
    elements.inventory.textContent = "Unable to load inventory";
    return;
  }
  elements.inventory.innerHTML = "";
  for (const host of inventory.hosts) {
    elements.inventory.append(renderHost(host));
  }
}

load();
