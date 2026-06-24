import React from 'react';

const PLUGIN_ID = 'uv-index';

interface ModuleStyle {
  fontSize: number;
  textColor: string;
  backgroundColor: string;
  borderRadius: number | string;
  padding: number | string;
  opacity?: number;
  fontFamily?: string;
}
interface Props { config: Record<string, unknown>; style: ModuleStyle; }

function hsFetch(url: string, cacheTtlMs = 60000): Promise<Response> {
  const sdk = typeof window !== 'undefined' ? (window as any).__HS_SDK__ : null;
  if (sdk?.pluginFetch) return sdk.pluginFetch(PLUGIN_ID, { url, cacheTtlMs });
  return fetch(url, { cache: 'no-store' });
}

function uvColor(uv: number): string {
  if (uv <= 3) return '#22c55e';
  if (uv <= 7) return '#f59e0b';
  return '#ef4444';
}

function uvLabel(uv: number): string {
  if (uv <= 2)  return 'Low';
  if (uv <= 5)  return 'Moderate';
  if (uv <= 7)  return 'High';
  if (uv <= 10) return 'Very High';
  return 'Extreme';
}

function SunIcon({ uv, color, size }: { uv: number; color: string; size: number }) {
  const cx = size / 2;
  const innerR = size * 0.24;
  const rayInner = size * 0.30;
  const rayOuter = size * 0.46;
  const rayW = Math.max(2, size * 0.07);
  const rays = 8;

  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      {Array.from({ length: rays }).map((_, i) => {
        const a = (i / rays) * Math.PI * 2 - Math.PI / 2;
        return (
          <line key={i}
            x1={cx + Math.cos(a) * rayInner} y1={cx + Math.sin(a) * rayInner}
            x2={cx + Math.cos(a) * rayOuter} y2={cx + Math.sin(a) * rayOuter}
            stroke={color} strokeWidth={rayW} strokeLinecap="round" />
        );
      })}
      <circle cx={cx} cy={cx} r={innerR} fill={color} />
      <text
        x={cx} y={cx}
        textAnchor="middle" dominantBaseline="central"
        fill="white"
        fontSize={uv >= 10 ? innerR * 0.9 : innerR * 1.1}
        fontWeight="bold"
        fontFamily='system-ui, -apple-system, sans-serif'>
        {uv}
      </text>
    </svg>
  );
}

export default function UvIndex({ config, style }: Props) {
  const lat       = Number(config.latitude  ?? 35.0);
  const lon       = Number(config.longitude ?? 33.0);
  const refreshMs = Math.max(60000, Number(config.refreshMs ?? 300000));
  const showLabel = config.showLabel !== false;

  const [uv, setUv]           = React.useState<number | null>(null);
  const [loading, setLoading] = React.useState(true);

  React.useEffect(() => {
    let cancelled = false;
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=uv_index&timezone=auto`;

    const run = async () => {
      try {
        const r = await hsFetch(url, 60000);
        const j = await r.json();
        const val = j?.current?.uv_index;
        if (!cancelled && val != null) { setUv(Math.round(val)); setLoading(false); }
      } catch {
        if (!cancelled) setLoading(false);
      }
    };

    run();
    const id = setInterval(run, refreshMs);
    return () => { cancelled = true; clearInterval(id); };
  }, [lat, lon, refreshMs]);

  const fs       = style.fontSize;
  const iconSize = Math.max(56, fs * 3.4);
  const color    = uv != null ? uvColor(uv) : '#6b7280';

  return (
    <div style={{
      width: '100%', height: '100%', boxSizing: 'border-box',
      display: 'flex', flexDirection: 'column',
      alignItems: 'center', justifyContent: 'center',
      gap: 6,
      backgroundColor: style.backgroundColor,
      borderRadius: style.borderRadius,
      padding: style.padding,
      opacity: style.opacity,
      fontFamily: style.fontFamily,
      color: style.textColor,
    }}>
      {loading ? (
        <span style={{ opacity: 0.45, fontSize: fs * 0.85 }}>…</span>
      ) : uv == null ? (
        <span style={{ opacity: 0.45, fontSize: fs * 0.85 }}>—</span>
      ) : (
        <>
          <SunIcon uv={uv} color={color} size={iconSize} />
          {showLabel && (
            <span style={{ fontSize: fs * 0.72, opacity: 0.75, fontWeight: 500 }}>
              {uvLabel(uv)}
            </span>
          )}
        </>
      )}
    </div>
  );
}
