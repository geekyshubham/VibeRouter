/* ============================================================================
   PageHeader — the per-page title row: title, one-line description, and the
   page's actions on the right. Every tab opens with this so the console reads
   as one system.
   ========================================================================== */
import type { ReactNode } from 'react';

interface Props {
  title: string;
  sub?: string;
  trail?: ReactNode;
}

export default function PageHeader({ title, sub, trail }: Props) {
  return (
    <div className="page-head">
      <div className="ph-titles">
        <h1 className="ph-title">{title}</h1>
        {sub && <div className="ph-sub">{sub}</div>}
      </div>
      {trail && <div className="ph-trail">{trail}</div>}
    </div>
  );
}
