/* ============================================================================
   providers — provider display metadata. Colors map to the --p-* CSS tint
   tokens (see styles/app.css). Used to tint swatches/logos across tabs.
   ========================================================================== */

export interface ProviderMeta {
  key: string;
  label: string;
  /** CSS var holding the brand tint. */
  tintVar: string;
  /** Single-letter/short logo text when no SVG is available. */
  short: string;
}

const META: Record<string, ProviderMeta> = {
  claude: { key: 'claude', label: 'Claude', tintVar: '--p-claude', short: 'C' },
  codex: { key: 'codex', label: 'Codex', tintVar: '--p-codex', short: 'Cx' },
  gemini: { key: 'gemini', label: 'Gemini', tintVar: '--p-gemini', short: 'G' },
  copilot: { key: 'copilot', label: 'Copilot', tintVar: '--p-copilot', short: 'Co' },
  antigravity: { key: 'antigravity', label: 'Antigravity', tintVar: '--p-antigravity', short: 'A' },
  kimi: { key: 'kimi', label: 'Kimi', tintVar: '--p-kimi', short: 'Ki' },
  kiro: { key: 'kiro', label: 'Kiro', tintVar: '--p-kiro', short: 'Kr' },
  grok: { key: 'grok', label: 'Grok', tintVar: '--p-grok', short: 'Gr' },
  qwen: { key: 'qwen', label: 'Qwen', tintVar: '--p-qwen', short: 'Q' },
  zai: { key: 'zai', label: 'Z.ai', tintVar: '--p-zai', short: 'Z' },
  cursor: { key: 'cursor', label: 'Cursor', tintVar: '--p-cursor', short: 'Cu' },
  codebuddy: { key: 'codebuddy', label: 'CodeBuddy', tintVar: '--p-codebuddy', short: 'Cb' },
  gitlab: { key: 'gitlab', label: 'GitLab', tintVar: '--p-gitlab', short: 'Gl' },
  kilo: { key: 'kilo', label: 'Kilo', tintVar: '--p-kilo', short: 'Kl' },
  vertex: { key: 'vertex', label: 'Vertex AI', tintVar: '--p-gemini', short: 'V' },
  'opencode-go': { key: 'opencode-go', label: 'OpenCode Go', tintVar: '--p-codex', short: 'OC' },
  // Ids the backend reports that name a provider above under another spelling.
  'github-copilot': { key: 'copilot', label: 'GitHub Copilot', tintVar: '--p-copilot', short: 'Co' },
  xai: { key: 'grok', label: 'xAI Grok', tintVar: '--p-grok', short: 'x' },
  openai: { key: 'codex', label: 'OpenAI', tintVar: '--p-codex', short: 'O' },
  'openai-compat': { key: 'openai-compat', label: 'OpenAI-compatible', tintVar: '--p-compat', short: 'OC' },
  unknown: { key: 'unknown', label: 'Other', tintVar: '--accent', short: '•' },
};

const FALLBACK: ProviderMeta = {
  key: 'unknown',
  label: 'Provider',
  tintVar: '--accent',
  short: '•',
};

/** Look up provider metadata by a loose key (case-insensitive, token aware). */
export function providerMeta(raw: string | undefined | null): ProviderMeta {
  if (!raw) return FALLBACK;
  const k = raw.toLowerCase().trim();
  if (META[k]) return META[k];

  // 1) Honor an explicit bracketed source prefix, e.g. "[Kiro] claude-sonnet" → kiro.
  const bracket = k.match(/^\[([^\]]+)\]/);
  if (bracket) {
    const tag = bracket[1].trim();
    if (META[tag]) return META[tag];
  }

  // 2) Token-boundary match, longest keys first. Hyphens stay inside tokens so
  //    "claude-sonnet" does NOT match the bare 'claude' key and shadow the real
  //    provider (e.g. a Kiro-served model whose name embeds "claude").
  const tokens = k.split(/[^a-z0-9-]+/).filter(Boolean);
  for (const key of Object.keys(META).sort((a, b) => b.length - a.length)) {
    if (tokens.includes(key)) return META[key];
  }
  return { ...FALLBACK, label: raw };
}

/** CSS color value for a provider's tint (resolves the var at call sites). */
export function providerTint(raw: string | undefined | null): string {
  return `var(${providerMeta(raw).tintVar})`;
}
