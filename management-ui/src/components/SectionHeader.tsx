/* SectionHeader — icon + title + subtitle + actions row that opens a panel. */
import type { ComponentType, ReactNode, SVGProps } from 'react';

interface Props {
  Glyph: ComponentType<SVGProps<SVGSVGElement>>;
  title: string;
  sub?: ReactNode;
  actions?: ReactNode;
  id?: string;
}

export default function SectionHeader({ Glyph, title, sub, actions, id }: Props) {
  return (
    <div className="sec-head">
      <div className="sec-icon" aria-hidden>
        <Glyph />
      </div>
      <div className="sec-titles">
        <h2 className="sec-title" id={id}>
          {title}
        </h2>
        {sub && <div className="sec-sub">{sub}</div>}
      </div>
      {actions && <div className="sec-actions">{actions}</div>}
    </div>
  );
}
