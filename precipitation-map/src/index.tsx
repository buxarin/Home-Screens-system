import React from 'react';

const PLUGIN_ID = 'precipitation-map';
const RV_HOST   = 'https://tilecache.rainviewer.com';
const OSM_HOST  = 'https://tile.openstreetmap.org';

interface ModuleStyle {
  fontSize: number; textColor: string; backgroundColor: string;
  borderRadius: number | string; padding: number | string;
  opacity?: number; fontFamily?: string;
}
interface Props { config: Record<string, unknown>; style: ModuleStyle; }

interface RvFrame { time: number; path: string; }

/* ── lat/lon → tile x,y ─────────────────────────────────────────────────── */
function ll2tile(lat: number, lon: number, z: number): { x: number; y: number } {
  const n = Math.pow(2, z);
  const x = Math.floor((lon + 180) / 360 * n);
  const lr = (lat * Math.PI) / 180;
  const y = Math.floor((1 - Math.log(Math.tan(lr) + 1 / Math.cos(lr)) / Math.PI) / 2 * n);
  return { x: Math.max(0, Math.min(n - 1, x)), y: Math.max(0, Math.min(n - 1, y)) };
}

/* ── pluginFetch wrapper (JSON only – for RainViewer API call) ────────────── */
function hsFetch(url: string, cacheTtlMs = 30000): Promise<Response> {
  const sdk = typeof window !== 'undefined' ? (window as any).__HS_SDK__ : null;
  if (sdk?.pluginFetch) return sdk.pluginFetch(PLUGIN_ID, { url, cacheTtlMs });
  return fetch(url, { cache: 'no-store' });
}

/* ── tile URL builders ──────────────────────────────────────────────────── */
function osmUrl(z: number, x: number, y: number): string {
  return `${OSM_HOST}/${z}/${x}/${y}.png`;
}
function radarUrl(path: string, z: number, x: number, y: number): string {
  // color scheme 4 = blue-purple precipitation, options 1_1 = smooth+snow
  return `${RV_HOST}${path}/256/${z}/${x}/${y}/4/1_1.png`;
}

/* ── timestamp label ─────────────────────────────────────────────────────── */
function frameLabel(ts: number, isForecast: boolean): string {
  const d = new Date(ts * 1000);
  const hh = d.getHours().toString().padStart(2, '0');
  const mm = d.getMinutes().toString().padStart(2, '0');
  return `${isForecast ? '+' : ''}${hh}:${mm}`;
}

/* ── main component ─────────────────────────────────────────────────────── */
export default function PrecipitationMap({ config, style }: Props) {
  const lat        = Number(config.latitude  ?? 35.0);
  const lon        = Number(config.longitude ?? 33.0);
  const zoom       = Math.max(4, Math.min(10, Number(config.zoom ?? 7)));
  const radarOpacity  = Number(config.opacity  ?? 0.75);
  const animSpeed  = Math.max(200, Number(config.animSpeed ?? 600));
  const refreshMs  = Math.max(300000, Number(config.refreshMs ?? 600000));
  const showAttr   = config.showAttribution !== false;

  /* frames from RainViewer */
  const [frames, setFrames]   = React.useState<{ frame: RvFrame; forecast: boolean }[]>([]);
  const [frameIdx, setFrameIdx] = React.useState(0);
  const [loading, setLoading] = React.useState(true);
  const [error, setError]     = React.useState(false);

  /* fetch frame list */
  React.useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const r = await hsFetch('https://api.rainviewer.com/public/weather-maps.json', 30000);
        const j = await r.json();
        const past     = (j?.radar?.past     ?? []) as RvFrame[];
        const nowcast  = (j?.radar?.nowcast  ?? []) as RvFrame[];
        if (!cancelled) {
          const all = [
            ...past.map(f => ({ frame: f, forecast: false })),
            ...nowcast.map(f => ({ frame: f, forecast: true })),
          ];
          setFrames(all);
          setFrameIdx(past.length > 0 ? past.length - 1 : 0); // start at latest past frame
          setLoading(false);
          setError(false);
        }
      } catch {
        if (!cancelled) { setLoading(false); setError(true); }
      }
    };
    load();
    const id = setInterval(load, refreshMs);
    return () => { cancelled = true; clearInterval(id); };
  }, [lat, lon, refreshMs]);

  /* animation loop */
  React.useEffect(() => {
    if (frames.length < 2) return;
    const id = setInterval(() => {
      setFrameIdx(i => (i + 1) % frames.length);
    }, animSpeed);
    return () => clearInterval(id);
  }, [frames.length, animSpeed]);

  /* tile grid: 3×3 centred on lat/lon */
  const center = ll2tile(lat, lon, zoom);
  const GRID   = 3;
  const half   = Math.floor(GRID / 2);
  const cells: { x: number; y: number }[] = [];
  for (let dy = -half; dy <= half; dy++) {
    for (let dx = -half; dx <= half; dx++) {
      cells.push({ x: center.x + dx, y: center.y + dy });
    }
  }

  const currentPath = frames[frameIdx]?.frame?.path ?? '';
  const isForecast  = frames[frameIdx]?.forecast ?? false;
  const ts          = frames[frameIdx]?.frame?.time;

  const wrapStyle: React.CSSProperties = {
    width: '100%', height: '100%', boxSizing: 'border-box',
    position: 'relative', overflow: 'hidden',
    borderRadius: style.borderRadius,
    backgroundColor: '#1a2535', // dark ocean background while loading
    fontFamily: style.fontFamily,
  };

  if (loading) {
    return (
      <div style={{ ...wrapStyle, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ color: '#6b7280', fontSize: style.fontSize * 0.85 }}>Loading radar…</span>
      </div>
    );
  }
  if (error) {
    return (
      <div style={{ ...wrapStyle, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ color: '#ef4444', fontSize: style.fontSize * 0.85 }}>Radar unavailable</span>
      </div>
    );
  }

  return (
    <div style={wrapStyle}>
      {/* tile grid – CSS grid, tiles fill container */}
      <div style={{
        position: 'absolute', inset: 0,
        display: 'grid',
        gridTemplateColumns: `repeat(${GRID}, 1fr)`,
        gridTemplateRows: `repeat(${GRID}, 1fr)`,
      }}>
        {cells.map(({ x, y }) => (
          <div key={`${x}-${y}`} style={{ position: 'relative', overflow: 'hidden' }}>
            {/* OSM base */}
            <img
              src={osmUrl(zoom, x, y)}
              style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', display: 'block' }}
              alt=""
            />
            {/* Radar overlay */}
            {currentPath && (
              <img
                src={radarUrl(currentPath, zoom, x, y)}
                style={{
                  position: 'absolute', inset: 0,
                  width: '100%', height: '100%', display: 'block',
                  opacity: radarOpacity,
                  mixBlendMode: 'screen',
                }}
                alt=""
              />
            )}
          </div>
        ))}
      </div>

      {/* Frame timestamp badge */}
      {ts && (
        <div style={{
          position: 'absolute', top: 8, left: 8,
          background: isForecast ? 'rgba(59,130,246,0.85)' : 'rgba(0,0,0,0.65)',
          color: '#fff', borderRadius: 6,
          fontSize: Math.max(10, style.fontSize * 0.65),
          padding: '2px 7px', fontWeight: 600,
          backdropFilter: 'blur(4px)',
        }}>
          {isForecast ? '▶ ' : ''}{frameLabel(ts, isForecast)}
        </div>
      )}

      {/* Frame progress dots */}
      {frames.length > 1 && (
        <div style={{
          position: 'absolute', bottom: showAttr ? 20 : 6, left: '50%',
          transform: 'translateX(-50%)',
          display: 'flex', gap: 4,
        }}>
          {frames.map((f, i) => (
            <div key={i} style={{
              width: i === frameIdx ? 8 : 5,
              height: i === frameIdx ? 8 : 5,
              borderRadius: '50%',
              background: f.forecast
                ? (i === frameIdx ? '#3b82f6' : 'rgba(59,130,246,0.45)')
                : (i === frameIdx ? '#fff'    : 'rgba(255,255,255,0.35)'),
              transition: 'all 0.2s',
            }} />
          ))}
        </div>
      )}

      {/* Attribution */}
      {showAttr && (
        <div style={{
          position: 'absolute', bottom: 3, right: 6,
          fontSize: 9, color: 'rgba(255,255,255,0.55)',
          pointerEvents: 'none',
        }}>
          RainViewer · © OSM
        </div>
      )}
    </div>
  );
}
