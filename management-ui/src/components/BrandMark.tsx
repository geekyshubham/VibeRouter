/* BrandMark — the VibeRouter glyph (shared with the favicon and the Mac app). */
import glyphUrl from '../assets/glyph.png';

export function BrandMark({ size = 20 }: { size?: number }) {
  return <img src={glyphUrl} alt="" width={size} height={size} style={{ display: 'block', objectFit: 'contain' }} />;
}

export default BrandMark;
