// Copyright 2026 Phinomenon Inc.
// Licensed under the Apache License, Version 2.0.

"use strict";

let counterUpdate = Promise.resolve();

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get({ mode: "remove", enabled: true, cleaned: 0 }, state => {
    chrome.storage.local.set(state);
  });
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "trackers-cleaned") return false;
  const increment = Number.isSafeInteger(message.count) && message.count > 0 ? message.count : 0;
  if (increment === 0) return false;

  counterUpdate = counterUpdate
    .then(() => chrome.storage.local.get({ cleaned: 0 }))
    .then(state => chrome.storage.local.set({ cleaned: state.cleaned + increment }))
    .then(() => sendResponse({ ok: true }))
    .catch(() => sendResponse({ ok: false }));
  return true;
});
