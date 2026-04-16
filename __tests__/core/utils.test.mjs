import { test } from "node:test";
import assert from "node:assert/strict";

import { shellQuote, randomHex } from "../../dist/core/utils.js";
import { tmuxSessionName } from "../../dist/core/tmux.js";

test("shellQuote wraps single quotes", () => {
  assert.equal(shellQuote("hi"), "'hi'");
  assert.equal(shellQuote("it's"), "'it'\\''s'");
  assert.equal(shellQuote(""), "''");
});

test("randomHex produces stable width + valid hex", () => {
  const h = randomHex(4);
  assert.equal(h.length, 8);
  assert.match(h, /^[0-9a-f]{8}$/);
});

test("tmuxSessionName composes loom-<sid>-<branch>", () => {
  assert.equal(tmuxSessionName("abc123", "main"), "loom-abc123-main");
  assert.equal(tmuxSessionName("abc123", "ff00"), "loom-abc123-ff00");
});
