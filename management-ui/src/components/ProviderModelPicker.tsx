/* ============================================================================
   ProviderModelPicker — pick a provider, then one of its models. Used by the
   fallback chain on Models and by the Playground. A model served by several
   providers appears under each of them.
   ========================================================================== */
import { useMemo } from 'react';
import { asArray } from '../lib/apiClient';
import { providerMeta } from '../lib/providers';

interface PickerModel {
  id: string;
  providers: string[] | null;
}

/** Providers that serve at least one of `models`, with model counts, by label. */
export function providersOf(models: PickerModel[]): { id: string; label: string; count: number }[] {
  const counts = new Map<string, number>();
  models.forEach((m) => asArray<string>(m.providers).forEach((p) => counts.set(p, (counts.get(p) ?? 0) + 1)));
  return [...counts.entries()]
    .map(([id, count]) => ({ id, label: providerMeta(id).label, count }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

export default function ProviderModelPicker({
  idPrefix,
  models,
  provider,
  model,
  onChange,
}: {
  idPrefix: string;
  models: PickerModel[];
  provider: string;
  model: string;
  onChange: (provider: string, model: string) => void;
}) {
  const providers = useMemo(() => providersOf(models), [models]);
  const inProvider = useMemo(
    () => models.filter((m) => asArray<string>(m.providers).includes(provider)).sort((a, b) => a.id.localeCompare(b.id)),
    [models, provider],
  );

  return (
    <>
      <div className="field">
        <label htmlFor={`${idPrefix}-provider`}>Provider</label>
        <select
          id={`${idPrefix}-provider`}
          className="inp"
          value={provider}
          disabled={!providers.length}
          onChange={(e) => {
            const next = e.target.value;
            const first = models.filter((m) => asArray<string>(m.providers).includes(next)).map((m) => m.id).sort()[0] ?? '';
            onChange(next, first);
          }}
        >
          {providers.length === 0 && <option value="">No providers</option>}
          {providers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label} ({p.count})
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label htmlFor={`${idPrefix}-model`}>Model</label>
        <select
          id={`${idPrefix}-model`}
          className="inp mono"
          value={model}
          disabled={!inProvider.length}
          onChange={(e) => onChange(provider, e.target.value)}
        >
          {inProvider.length === 0 && <option value="">No models</option>}
          {inProvider.map((m) => (
            <option key={m.id} value={m.id}>
              {m.id}
            </option>
          ))}
        </select>
      </div>
    </>
  );
}
