#!/usr/bin/env node

import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const pluginsRoot = path.join(repoRoot, "plugins");
const siteRoot = path.join(repoRoot, "site");
const registryPath = path.join(pluginsRoot, "index.json");
const branch = "master";

function normalizePath(value) {
  return value.split(path.sep).join("/");
}

function githubUrls(repository, repoPath) {
  const cleanRepository = repository.replace(/\/$/, "");
  const encodedPath = repoPath
    .split("/")
    .map((part) => encodeURIComponent(part))
    .join("/");

  return {
    page: `${cleanRepository}/tree/${branch}/${encodedPath}`,
    blob: `${cleanRepository}/blob/${branch}/${encodedPath}`,
    raw: `${cleanRepository.replace("github.com", "raw.githubusercontent.com")}/${branch}/${encodedPath}`,
  };
}

function safeRelativeAsset(pluginPath, assetPath) {
  if (typeof assetPath !== "string" || assetPath.trim() === "") {
    return null;
  }

  if (/^[a-z]+:/i.test(assetPath) || assetPath.startsWith("/") || assetPath.includes("..")) {
    return null;
  }

  return normalizePath(path.posix.join(pluginPath, assetPath));
}

function inferKind(folder) {
  const prefix = folder.split("-")[0];
  const known = new Set(["launcher", "floating", "action", "trigger", "streamdeck", "touchbar"]);
  return known.has(prefix) ? prefix : "plugin";
}

function typeLabel(type) {
  const labels = {
    FloatingMenuWidget: "Floating Menu",
    StreamDeck: "Stream Deck",
    TouchBar: "Touch Bar",
  };

  return labels[type] ?? type;
}

function normalizeAuthor(author) {
  if (!author) {
    return { name: "Unknown" };
  }

  if (typeof author === "string") {
    return { name: author };
  }

  return {
    name: author.name || "Unknown",
    url: author.url || null,
  };
}

async function pathExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readJson(filePath) {
  const raw = await fs.readFile(filePath, "utf8");
  return JSON.parse(raw);
}

async function scanPluginFolders(section) {
  const sectionPath = path.join(pluginsRoot, section);
  if (!(await pathExists(sectionPath))) {
    return [];
  }

  const entries = await fs.readdir(sectionPath, { withFileTypes: true });
  const plugins = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }

    const folderPath = path.join(sectionPath, entry.name);
    const manifestPath = path.join(folderPath, "plugin.json");
    if (!(await pathExists(manifestPath))) {
      continue;
    }

    const manifest = await readJson(manifestPath);
    const repoPath = normalizePath(path.relative(repoRoot, folderPath));
    plugins.push({
      section,
      folder: entry.name,
      path: repoPath,
      manifest,
    });
  }

  return plugins;
}

async function buildCatalog() {
  const registry = (await pathExists(registryPath))
    ? await readJson(registryPath)
    : { repository: "https://github.com/folivoraAI/BetterTouchToolPlugins", plugins: [] };

  const repository = registry.repository || "https://github.com/folivoraAI/BetterTouchToolPlugins";
  const registryOrder = new Map((registry.plugins || []).map((plugin, index) => [plugin.path, index]));
  const registryByPath = new Map((registry.plugins || []).map((plugin) => [plugin.path, plugin]));
  const folderPlugins = [
    ...(await scanPluginFolders("official")),
    ...(await scanPluginFolders("community")),
  ];

  const plugins = [];

  for (const folderPlugin of folderPlugins) {
    const registryEntry = registryByPath.get(folderPlugin.path) || {};
    const manifest = folderPlugin.manifest;
    const entry = manifest.entry || registryEntry.entry || null;
    const sourcePath = entry ? normalizePath(path.posix.join(folderPlugin.path, entry)) : null;
    const readmePath = normalizePath(path.posix.join(folderPlugin.path, "README.md"));
    const screenshots = Array.isArray(manifest.screenshots)
      ? manifest.screenshots
          .map((asset) => safeRelativeAsset(folderPlugin.path, asset))
          .filter(Boolean)
      : [];

    const urls = githubUrls(repository, folderPlugin.path);
    const sourceUrls = sourcePath ? githubUrls(repository, sourcePath) : null;
    const readmeUrls = githubUrls(repository, readmePath);
    const screenshotUrls = screenshots.map((assetPath) => githubUrls(repository, assetPath).raw);
    const reviewStatus = manifest.reviewStatus || registryEntry.reviewStatus || folderPlugin.section;
    const type = manifest.type || registryEntry.type || "Plugin";
    const permissions = Array.isArray(manifest.permissions) ? manifest.permissions : [];
    const tags = [
      folderPlugin.section,
      inferKind(folderPlugin.folder),
      type,
      typeLabel(type),
      reviewStatus,
      ...permissions,
    ]
      .filter(Boolean)
      .map((tag) => String(tag).toLowerCase());

    plugins.push({
      name: manifest.name || registryEntry.name || folderPlugin.folder,
      identifier: manifest.identifier || registryEntry.identifier || "",
      type,
      typeLabel: typeLabel(type),
      folder: folderPlugin.folder,
      section: folderPlugin.section,
      reviewStatus,
      description: manifest.description || registryEntry.description || "",
      entry,
      author: normalizeAuthor(manifest.author),
      minimumBetterTouchToolVersion: manifest.minimumBetterTouchToolVersion || null,
      permissions,
      screenshots: screenshotUrls,
      links: {
        folder: urls.page,
        source: sourceUrls?.blob || null,
        readme: readmeUrls.blob,
      },
      origin: manifest.origin || null,
      copyright: manifest.copyright || null,
      license: manifest.license || null,
      tags: Array.from(new Set(tags)),
      searchText: [
        manifest.name,
        manifest.identifier,
        manifest.description,
        manifest.type,
        manifest.reviewStatus,
        folderPlugin.section,
        folderPlugin.folder,
        normalizeAuthor(manifest.author).name,
        manifest.origin?.repository,
        manifest.origin?.source,
        manifest.copyright,
        manifest.license,
        permissions.join(" "),
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase(),
      order: registryOrder.has(folderPlugin.path) ? registryOrder.get(folderPlugin.path) : 1000,
    });
  }

  plugins.sort((a, b) => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }

    return a.name.localeCompare(b.name);
  });

  return {
    schemaVersion: 1,
    repository,
    branch,
    pluginCount: plugins.length,
    plugins,
  };
}

async function main() {
  const catalog = await buildCatalog();
  await fs.mkdir(siteRoot, { recursive: true });

  const json = `${JSON.stringify(catalog, null, 2)}\n`;
  await fs.writeFile(path.join(siteRoot, "catalog.json"), json);
  await fs.writeFile(
    path.join(siteRoot, "plugins.generated.js"),
    `window.BTT_PLUGIN_CATALOG = ${json};`
  );

  console.log(`Generated ${catalog.pluginCount} plugin records in site/.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
