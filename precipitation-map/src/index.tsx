import React from 'react';

const PLUGIN_ID = 'precipitation-map';
const RV_HOST   = 'https://tilecache.rainviewer.com';
const OSM_HOST  = 'https://tile.openstreetmap.org';
const TILE_PX   = 256;

interface ModuleStyle {
  fontSize: number; textColor: string; backgroundColor: string;
  borderRadius: number | string; padding: number | string;
  opacity?: number; fontFamily?: string;
}
interface Props { config: Record<string, unknown>; style: ModuleStyle; }
interface RvFrame { time: number; path: string; }

function ll2tile(lat: number, lon: number, z: number): { x: number; y: number } {
  const n = Math.pow(2, z);
  const x = Math.floor((lon + 180) / 360 * n);
  const lr = (lat * Math.PI) / 180;
  const y = Math.floor((1 - Math.log(Math.tan(lr) + 1 / Math.cos(lr)) / Math.PI) / 2 * n);
  return { x: Math.max(0, Math.min(n - 1, x)), y: Math.max(0, Math.min(n - 1, y)) };
}

function hsFetch(url: string, cacheTtlMs = 30000): Promise<Response> {
  const sdk = typeof window !== 'undefined' ? (window as any).__HS_SDK__ : null;
  if (sdk?.pluginFetch) return sdk.pluginFetch(PLUGIN_ID, { url, cacheTtlMs });
  return fetch(url, { cache: 'no-store' });
}

function osmUrl(z: number, x: number, y: number): string {
  return `${OSM_HOST}/${z}/${x}/${y}.png`;
}
function radarUrl(path: string, z: number, x: number, y: number): string {
  return `${RV_HOST}${path}/256/${z}/${x}/${y}/4/1_1.png`;
}

function frameLabel(ts: number, isForecast: boolean): string {
  const d = new Date(ts * 1000);
  const hh = d.getHours().toString().padStart(2, '0');
  const mm = d.getMinutes().toString().padStart(2, '0');
  return `${isForecast ? '+' : ''}${hh}:${mm}`;
}

export default function PrecipitationMap({ config, style }: Props) {
  const lat        = Number(config.latitude  ?? 35.0);
  const lon        = Number(config.longitude ?? 33.0);
  const zoom       = Math.max(1, Math.min(6, Number(config.zoom ?? 6)));
  const radarOpacity  = Number(config.opacity  ?? 0.75);
  const animSpeed  = Math.max(200, Number(config.animSpeed ?? 600));
  const refreshMs  = Math.max(300000, Number(config.refreshMs ?? 600000));
  const showAttr   = config.showAttribution !== false;

  const [frames, setFrames]     = React.useState<{ frame: RvFrame; forecast: boolean }[]>([]);
  const [frameIdx, setFrameIdx] = React.useState(0);
  const [loading, setLoading]   = React.useState(true);
  const [error, setError]       = React.useState(false);

  /* container size for dynamic tile grid */
  const containerRef = React.useRef<HTMLDivElement>(null);
  const [size, setSize] = React.useState({ w: 400, h: 400 });

  React.useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(entries => {
      const r = entries[0].contentRect;
      setSize({ w: Math.max(1, r.width), h: Math.max(1, r.height) });
    });
    ro.observe(el);
    // initial measurement
    const r = el.getBoundingClientRect();
    if (r.width > 0) setSize({ w: r.width, h: r.height });
    return () => ro.disconnect();
  }, []);

  /* fetch frame list */
  React.useEffect(() => {
    let cancelled = false;
    const load = async () => {
      try {
        const r = await hsFetch('https://api.rainviewer.com/public/weather-maps.json', 30000);
        const j = await r.json();
        const past    = (j?.radar?.past    ?? []) as RvFrame[];
        const nowcast = (j?.radar?.nowcast ?? []) as RvFrame[];
        if (!cancelled) {
          const all = [
            ...past.map(f => ({ frame: f, forecast: false })),
            ...nowcast.map(f => ({ frame: f, forecast: true })),
          ];
          setFrames(all);
          setFrameIdx(past.length > 0 ? past.length - 1 : 0);
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

  /* dynamic tile grid — tiles are always TILE_PX×TILE_PX, grid expands to fill container */
  const center   = ll2tile(lat, lon, zoom);
  const cols     = Math.ceil(size.w / TILE_PX) + 2;  // +2 ensures coverage at any offset
  const rows     = Math.ceil(size.h / TILE_PX) + 2;
  const halfCols = Math.floor(cols / 2);
  const halfRows = Math.floor(rows / 2);
  // shift grid so that the center tile is centred in the container
  const offsetX  = Math.round((size.w - cols * TILE_PX) / 2);
  const offsetY  = Math.round((size.h - rows * TILE_PX) / 2);

  const cells: { tx: number; ty: number; col: number; row: number }[] = [];
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      cells.push({
        tx: center.x - halfCols + col,
        ty: center.y - halfRows + row,
        col,
        row,
      });
    }
  }

  const currentPath = frames[frameIdx]?.frame?.path ?? '';
  const isForecast  = frames[frameIdx]?.forecast ?? false;
  const ts          = frames[frameIdx]?.frame?.time;

  const wrapStyle: React.CSSProperties = {
    width: '100%', height: '100%', boxSizing: 'border-box',
    position: 'relative', overflow: 'hidden',
    borderRadius: style.borderRadius,
    backgroundColor: '#1a2535',
    fontFamily: style.fontFamily,
  };

  if (loading) {
    return (
      <div ref={containerRef} style={{ ...wrapStyle, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ color: '#6b7280', fontSize: style.fontSize * 0.85 }}>Loading radar…</span>
      </div>
    );
  }
  if (error) {
    return (
      <div ref={containerRef} style={{ ...wrapStyle, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ color: '#ef4444', fontSize: style.fontSize * 0.85 }}>Radar unavailable</span>
      </div>
    );
  }

  return (
    <div ref={containerRef} style={wrapStyle}>
      {/* tile grid — fixed TILE_PX size, positioned to centre on lat/lon */}
      <div style={{ position: 'absolute', left: offsetX, top: offsetY, width: cols * TILE_PX, height: rows * TILE_PX }}>
        {cells.map(({ tx, ty, col, row }) => (
          <div key={`${tx}-${ty}`} style={{
            position: 'absolute',
            left: col * TILE_PX, top: row * TILE_PX,
            width: TILE_PX, height: TILE_PX,
          }}>
            <img
              src={osmUrl(zoom, tx, ty)}
              width={TILE_PX} height={TILE_PX}
              style={{ display: 'block' }}
              alt=""
            />
            {currentPath && (
              <img
                src={radarUrl(currentPath, zoom, tx, ty)}
                width={TILE_PX} height={TILE_PX}
                style={{
                  display: 'block', position: 'absolute', inset: 0,
                  opacity: radarOpacity, mixBlendMode: 'screen',
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
