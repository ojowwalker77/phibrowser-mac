// Copyright 2026 Phinomenon Inc.
// Licensed under the Apache License, Version 2.0.

(() => {
  "use strict";

  const knownParameters = new Set([
    "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad", "gclaw",
    "fbclid", "fb_action_ids", "fb_action_types", "fb_ref", "fb_source", "fb_locale", "_fb",
    "msclkid", "ttclid", "twclid", "li_fat_id", "yclid", "_openstat",
    "mc_eid", "mc_cid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
    "hsctatracking", "igshid", "igsh", "epik", "sc_cid", "_ke", "mkt_tok",
    "s_kwcid", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id",
    "_branch_match_id", "wickedid"
  ]);

  function isTrackingParameter(name) {
    const normalized = name.toLowerCase();
    return knownParameters.has(normalized) || normalized.startsWith("utm_");
  }

  function randomToken(length) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const bytes = new Uint8Array(length);
    crypto.getRandomValues(bytes);
    let token = "";
    for (const byte of bytes) {
      token += alphabet[byte % alphabet.length];
    }
    return token;
  }

  function cleanURL(input, mode) {
    if (mode !== "remove" && mode !== "mask") return null;

    let url;
    try {
      url = new URL(input);
    } catch {
      return null;
    }
    if (!url.search) return null;

    const cleanedEntries = [];
    let cleanedCount = 0;
    for (const [name, value] of url.searchParams.entries()) {
      if (!isTrackingParameter(name)) {
        cleanedEntries.push([name, value]);
        continue;
      }

      cleanedCount += 1;
      if (mode === "mask") {
        const tokenLength = Math.max(8, Math.min(32, value.length || 16));
        cleanedEntries.push([name, randomToken(tokenLength)]);
      }
    }

    if (cleanedCount === 0) return null;
    const query = new URLSearchParams(cleanedEntries).toString();
    url.search = query ? `?${query}` : "";
    return { url: url.toString(), count: cleanedCount };
  }

  globalThis.LuaTrackingProtection = Object.freeze({
    cleanURL,
    isTrackingParameter
  });
})();
