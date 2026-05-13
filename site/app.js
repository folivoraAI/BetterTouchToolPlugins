(function () {
  "use strict";

  const catalog = window.BTT_PLUGIN_CATALOG || { plugins: [] };
  const plugins = Array.isArray(catalog.plugins) ? catalog.plugins : [];
  const state = {
    query: "",
    origin: "all",
    type: "all",
  };

  const elements = {
    search: document.querySelector("#search-input"),
    typeFilters: document.querySelector("#type-filters"),
    grid: document.querySelector("#plugin-grid"),
    empty: document.querySelector("#empty-state"),
    resultCount: document.querySelector("#result-count"),
    clearFilters: document.querySelector("#clear-filters"),
    total: document.querySelector("#stat-total"),
    official: document.querySelector("#stat-official"),
    community: document.querySelector("#stat-community"),
    dialog: document.querySelector("#plugin-dialog"),
    dialogContent: document.querySelector("#dialog-content"),
    dialogClose: document.querySelector(".dialog-close"),
  };

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function attr(value) {
    return escapeHtml(value);
  }

  function prettyStatus(status) {
    const labels = {
      official: "Official",
      "community-reviewed": "Reviewed",
      submitted: "Submitted",
    };

    return labels[status] || status || "Listed";
  }

  function originFor(plugin) {
    if (plugin.section === "official" || plugin.reviewStatus === "official") {
      return "official";
    }

    return "community";
  }

  function pluginTypes() {
    const types = new Map();
    for (const plugin of plugins) {
      types.set(plugin.type, plugin.typeLabel || plugin.type);
    }

    return Array.from(types.entries()).sort((a, b) => a[1].localeCompare(b[1]));
  }

  function visiblePlugins() {
    const query = state.query.trim().toLowerCase();
    const terms = query.split(/\s+/).filter(Boolean);

    return plugins.filter((plugin) => {
      if (state.origin !== "all" && originFor(plugin) !== state.origin) {
        return false;
      }

      if (state.type !== "all" && plugin.type !== state.type) {
        return false;
      }

      if (terms.length === 0) {
        return true;
      }

      return terms.every((term) => plugin.searchText.includes(term));
    });
  }

  function renderStats() {
    const official = plugins.filter((plugin) => originFor(plugin) === "official").length;
    const community = plugins.length - official;
    elements.total.textContent = plugins.length;
    elements.official.textContent = official;
    elements.community.textContent = community;
  }

  function renderTypeFilters() {
    const filters = [
      '<button class="filter is-active" type="button" data-filter-group="type" data-filter-value="all">All types</button>',
      ...pluginTypes().map(([type, label]) => {
        const count = plugins.filter((plugin) => plugin.type === type).length;
        return `<button class="filter" type="button" data-filter-group="type" data-filter-value="${attr(type)}">${escapeHtml(label)} (${count})</button>`;
      }),
    ];

    elements.typeFilters.innerHTML = filters.join("");
  }

  function renderVisual(plugin) {
    const screenshot = plugin.screenshots && plugin.screenshots[0];
    if (screenshot) {
      return `<img src="${attr(screenshot)}" alt="${attr(plugin.name)} screenshot" loading="lazy">`;
    }

    return `
      <div class="visual-art" data-type="${attr(plugin.type)}" aria-hidden="true">
        <strong>${escapeHtml(plugin.name)}</strong>
        <span>${escapeHtml(plugin.typeLabel || plugin.type)}</span>
      </div>
    `;
  }

  function renderPermissionPills(plugin) {
    const permissions = Array.isArray(plugin.permissions) ? plugin.permissions.slice(0, 4) : [];
    if (permissions.length === 0) {
      return '<span class="pill">No extra permissions</span>';
    }

    const remaining = plugin.permissions.length - permissions.length;
    const pills = permissions.map((permission) => `<span class="pill">${escapeHtml(permission)}</span>`);
    if (remaining > 0) {
      pills.push(`<span class="pill">+${remaining}</span>`);
    }

    return pills.join("");
  }

  function renderPluginCard(plugin, index) {
    const downloadButton = plugin.links.download
      ? `<a class="primary-button" href="${attr(plugin.links.download)}" download="${attr(plugin.downloadFileName || "")}">Download</a>`
      : "";
    const sourceButton = plugin.links.source
      ? `<a class="secondary-button" href="${attr(plugin.links.source)}">Source</a>`
      : "";

    return `
      <article class="plugin-card" data-plugin-index="${index}">
        <div class="plugin-card__visual">
          ${renderVisual(plugin)}
        </div>
        <div class="plugin-card__body">
          <div>
            <div class="card-kicker">
              <span class="badge">${escapeHtml(plugin.typeLabel || plugin.type)}</span>
              <span class="status" data-status="${attr(plugin.reviewStatus)}">${escapeHtml(prettyStatus(plugin.reviewStatus))}</span>
            </div>
            <h3>${escapeHtml(plugin.name)}</h3>
            <p>${escapeHtml(plugin.description)}</p>
          </div>
          <div class="plugin-meta">
            <span class="pill">${escapeHtml(plugin.author.name)}</span>
            ${renderPermissionPills(plugin)}
          </div>
          <div class="card-actions">
            ${downloadButton}
            ${sourceButton}
            <button class="secondary-button" type="button" data-details="${index}">Details</button>
          </div>
        </div>
      </article>
    `;
  }

  function renderGrid() {
    const results = visiblePlugins();
    elements.grid.innerHTML = results.map(renderPluginCard).join("");
    elements.empty.hidden = results.length > 0;
    elements.resultCount.textContent = `Showing ${results.length} of ${plugins.length} plugins`;
  }

  function updateFilterButtons(group, value) {
    document.querySelectorAll(`[data-filter-group="${group}"]`).forEach((button) => {
      button.classList.toggle("is-active", button.dataset.filterValue === value);
    });
  }

  function resetFilters() {
    state.query = "";
    state.origin = "all";
    state.type = "all";
    elements.search.value = "";
    updateFilterButtons("origin", "all");
    updateFilterButtons("type", "all");
    renderGrid();
  }

  function detailItem(label, value) {
    if (!value) {
      return "";
    }

    return `
      <div class="detail-item">
        <span>${escapeHtml(label)}</span>
        <code>${escapeHtml(value)}</code>
      </div>
    `;
  }

  function openDetails(plugin) {
    const permissions = Array.isArray(plugin.permissions) && plugin.permissions.length > 0
      ? plugin.permissions.join(", ")
      : "No extra permissions";

    const minimumVersion = plugin.minimumBetterTouchToolVersion || "Not specified";
    const downloadLink = plugin.links.download
      ? `<a class="primary-button" href="${attr(plugin.links.download)}" download="${attr(plugin.downloadFileName || "")}">Download</a>`
      : "";
    const sourceLink = plugin.links.source
      ? `<a class="secondary-button" href="${attr(plugin.links.source)}">View source</a>`
      : "";
    const originRepoLink = plugin.origin && plugin.origin.repository
      ? `<a class="secondary-button" href="${attr(plugin.origin.repository)}">Original repo</a>`
      : "";
    const originSourceLink = plugin.origin && plugin.origin.source
      ? `<a class="secondary-button" href="${attr(plugin.origin.source)}">Original source</a>`
      : "";

    elements.dialogContent.innerHTML = `
      <div class="dialog-content">
        <div class="card-kicker">
          <span class="badge">${escapeHtml(plugin.typeLabel || plugin.type)}</span>
          <span class="status" data-status="${attr(plugin.reviewStatus)}">${escapeHtml(prettyStatus(plugin.reviewStatus))}</span>
        </div>
        <h2 id="dialog-title">${escapeHtml(plugin.name)}</h2>
        <p>${escapeHtml(plugin.description)}</p>
        <div class="detail-grid">
          ${detailItem("Identifier", plugin.identifier)}
          ${detailItem("Entry file", plugin.entry)}
          ${detailItem("Author", plugin.author.name)}
          ${detailItem("Minimum BTT", minimumVersion)}
          ${detailItem("Permissions", permissions)}
          ${detailItem("Folder", plugin.folder)}
          ${detailItem("Copyright", plugin.copyright)}
          ${detailItem("Upstream license", plugin.license)}
        </div>
        <div class="card-actions">
          ${downloadLink}
          ${sourceLink}
          <a class="secondary-button" href="${attr(plugin.links.readme)}">Readme</a>
          <a class="secondary-button" href="${attr(plugin.links.folder)}">Folder</a>
          ${originRepoLink}
          ${originSourceLink}
        </div>
      </div>
    `;

    elements.dialog.showModal();
  }

  function bindEvents() {
    elements.search.addEventListener("input", (event) => {
      state.query = event.target.value;
      renderGrid();
    });

    document.addEventListener("click", (event) => {
      const filter = event.target.closest("[data-filter-group]");
      if (filter) {
        const group = filter.dataset.filterGroup;
        state[group] = filter.dataset.filterValue;
        updateFilterButtons(group, state[group]);
        renderGrid();
        return;
      }

      const detailButton = event.target.closest("[data-details]");
      if (detailButton) {
        const index = Number(detailButton.dataset.details);
        const plugin = visiblePlugins()[index];
        if (plugin) {
          openDetails(plugin);
        }
      }
    });

    elements.clearFilters.addEventListener("click", resetFilters);
    elements.dialogClose.addEventListener("click", () => elements.dialog.close());
    elements.dialog.addEventListener("click", (event) => {
      if (event.target === elements.dialog) {
        elements.dialog.close();
      }
    });
  }

  function init() {
    renderStats();
    renderTypeFilters();
    bindEvents();
    renderGrid();
  }

  init();
})();
