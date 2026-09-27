/* ============================================================================
   ProviderLogo — brand badge for a provider (.plogo). Uses the same icon-*.png
   assets the Swift menu bar app ships, so the console and the native app show
   the same marks. Providers without a shipped icon get tinted initials.
   ========================================================================== */
import { providerMeta } from '../lib/providers';

import iconAntigravity from '../assets/providers/icon-antigravity.png';
import iconClaude from '../assets/providers/icon-claude.png';
import iconCodex from '../assets/providers/icon-codex.png';
import iconCopilot from '../assets/providers/icon-copilot.png';
import iconGemini from '../assets/providers/icon-gemini.png';
import iconGrok from '../assets/providers/icon-grok.png';
import iconKiro from '../assets/providers/icon-kiro.png';
import iconQwen from '../assets/providers/icon-qwen.png';
import iconZai from '../assets/providers/icon-zai.png';

// Provider key → brand icon. Keys match providers.ts. Missing → initials.
const ICONS: Record<string, string> = {
  antigravity: iconAntigravity,
  claude: iconClaude,
  codex: iconCodex,
  copilot: iconCopilot,
  gemini: iconGemini,
  vertex: iconGemini, // Vertex serves Gemini models — reuse the Gemini mark.
  grok: iconGrok,
  kiro: iconKiro,
  qwen: iconQwen,
  zai: iconZai,
  'opencode-go': iconCodex,
};

export default function ProviderLogo({ provider, size = 32 }: { provider: string | undefined | null; size?: number }) {
  const meta = providerMeta(provider);
  const tint = `var(${meta.tintVar})`;
  const iconSrc = ICONS[meta.key];
  const style = {
    width: size,
    height: size,
    background: `color-mix(in oklch, ${tint} 20%, transparent)`,
    color: tint,
  };

  return (
    <div className="plogo" style={style} title={meta.label} aria-hidden>
      {iconSrc ? (
        <img
          src={iconSrc}
          alt=""
          width={Math.round(size * 0.6)}
          height={Math.round(size * 0.6)}
          style={{ objectFit: 'contain', display: 'block' }}
        />
      ) : (
        meta.short
      )}
    </div>
  );
}
