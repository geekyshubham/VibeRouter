/* LoadingBlock — shimmer rows sized like the content they stand in for. */
export default function LoadingBlock({ rows = 3, height = 52 }: { rows?: number; height?: number }) {
  return (
    <div className="stack" aria-busy="true" aria-label="Loading">
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="skel" style={{ height }} />
      ))}
    </div>
  );
}
