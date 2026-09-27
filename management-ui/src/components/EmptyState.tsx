/* EmptyState — icon + title + guidance + optional action, shown in place of an
   empty list so the next step is always visible. */
import type { ComponentType, ReactNode, SVGProps } from 'react';

interface Props {
  Glyph: ComponentType<SVGProps<SVGSVGElement>>;
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}

export default function EmptyState({ Glyph, title, children, action }: Props) {
  return (
    <div className="empty">
      <div className="empty-icon" aria-hidden>
        <Glyph />
      </div>
      <h3>{title}</h3>
      {children && <p>{children}</p>}
      {action}
    </div>
  );
}
