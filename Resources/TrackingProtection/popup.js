// Copyright 2026 Phinomenon Inc.
// Licensed under the Apache License, Version 2.0.

"use strict";

const enabledControl = document.querySelector("#enabled");
const cleanedLabel = document.querySelector("#cleaned");
const removeButton = document.querySelector("#remove");
const maskButton = document.querySelector("#mask");
const statusLabel = document.querySelector("#status");

function render(state) {
  const mode = state.mode === "mask" ? "mask" : "remove";
  const enabled = state.enabled !== false;
  enabledControl.checked = enabled;
  cleanedLabel.textContent = String(Number.isSafeInteger(state.cleaned) ? state.cleaned : 0);
  removeButton.classList.toggle("selected", mode === "remove");
  maskButton.classList.toggle("selected", mode === "mask");

  if (!enabled) {
    statusLabel.textContent = "Paused. Tracking parameters are left unchanged.";
  } else if (mode === "remove") {
    statusLabel.textContent = "Known tracking parameters are removed from followed links.";
  } else {
    statusLabel.textContent = "Known tracking values are replaced with random tokens.";
  }
}

function readState() {
  chrome.storage.local.get({ mode: "remove", enabled: true, cleaned: 0 }, render);
}

enabledControl.addEventListener("change", () => {
  chrome.storage.local.set({ enabled: enabledControl.checked });
});
removeButton.addEventListener("click", () => chrome.storage.local.set({ mode: "remove" }));
maskButton.addEventListener("click", () => chrome.storage.local.set({ mode: "mask" }));
chrome.storage.onChanged.addListener((_changes, areaName) => {
  if (areaName === "local") readState();
});

readState();
