/**
 * Render the per-branch system prompt from the shared template.
 * Substitutes `{{BRANCH_ID}}`.
 */

import { readFileSync } from "node:fs";
import { SYSTEM_PROMPT_TEMPLATE } from "./paths.js";

export interface RenderSystemPromptOpts {
  branchId: string;
}

export function renderSystemPrompt(opts: RenderSystemPromptOpts): string {
  const template = readFileSync(SYSTEM_PROMPT_TEMPLATE, "utf-8");
  return template.replace(/\{\{BRANCH_ID\}\}/g, opts.branchId);
}
