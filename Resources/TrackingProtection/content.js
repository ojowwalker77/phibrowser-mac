// Copyright 2026 Phinomenon Inc.
// Licensed under the Apache License, Version 2.0.

(() => {
  "use strict";

  let mode = "remove";
  let enabled = true;

  function reportCleaned(count) {
    if (count <= 0) return;
    chrome.runtime.sendMessage({ type: "trackers-cleaned", count }, () => {
      // Reading lastError suppresses noise when the extension is reloaded
      // while a page still owns the previous content-script context.
      void chrome.runtime.lastError;
    });
  }

  function cleanCurrentURL() {
    if (!enabled) return;
    const result = LuaTrackingProtection.cleanURL(location.href, mode);
    if (!result || result.url === location.href) return;

    try {
      history.replaceState(history.state, "", result.url);
      reportCleaned(result.count);
    } catch {
      // Some documents disallow history mutation. Link cleaning remains active.
    }
  }

  function cleanAnchor(anchor) {
    if (!enabled || !anchor?.href) return;
    const result = LuaTrackingProtection.cleanURL(anchor.href, mode);
    if (!result || result.url === anchor.href) return;
    anchor.href = result.url;
    reportCleaned(result.count);
  }

  function anchorFromEvent(event) {
    const target = event.composedPath?.()[0] ?? event.target;
    return target?.closest?.("a[href]") ?? null;
  }

  for (const eventName of ["pointerdown", "mousedown", "auxclick", "click", "contextmenu"]) {
    document.addEventListener(eventName, event => cleanAnchor(anchorFromEvent(event)), true);
  }

  document.addEventListener("keydown", event => {
    if (event.key === "Enter") cleanAnchor(anchorFromEvent(event));
  }, true);

  for (const eventName of ["pageshow", "popstate", "hashchange"]) {
    addEventListener(eventName, cleanCurrentURL, true);
  }

  chrome.storage.local.get({ mode: "remove", enabled: true }, state => {
    mode = state.mode === "mask" ? "mask" : "remove";
    enabled = state.enabled !== false;
    cleanCurrentURL();
  });

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== "local") return;
    if (changes.mode) mode = changes.mode.newValue === "mask" ? "mask" : "remove";
    if (changes.enabled) enabled = changes.enabled.newValue !== false;
    cleanCurrentURL();
  });
})();
