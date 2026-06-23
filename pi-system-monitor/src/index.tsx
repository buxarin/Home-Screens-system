import React from 'react';
import type { PluginComponentProps, ModuleStyle } from './hs-plugin';

/* ── i18n ──────────────────────────────────────────────────────────────── */
const DICT: Record<'en' | 'ru', Record<string, string>> = {
  en: {
    cpu: 'CPU', ram: 'RAM', disk: 'Disk', temp: 'CPU Temp', fan: 'FanHat',
    adapters: 'Adapters', external_ip: 'External IP', vless: 'VLESS',
    socks5: 'SOCKS5', ping: 'Ping', uptime: 'Uptime', overview: 'System',
    used: 'used', free: 'free', of: 'of', clients: 'clients',
    online: 'online', offline: 'offline', idle: 'idle', na: 'n/a',
    noData: 'no data', loading: 'loading…', apiError: 'API unreachable',
    listening: 'listening', not_listening: 'not listening', port: 'port', mac: 'MAC',
  },
  ru: {
    cpu: 'ЦП', ram: 'ОЗУ', disk: 'Диск', temp: 'Темп. ЦП', fan: 'FanHat',
    adapters: 'Адаптеры', external_ip: 'Внешний IP', vless: 'VLESS',
    socks5: 'SOCKS5', ping: 'Пинг', uptime: 'Аптайм', overview: 'Система',
    used: 'занято', free: 'свободно', of: 'из', clients: 'клиентов',
    online: 'онлайн', offline: 'офлайн', idle: 'простой', na: 'н/д',
    noData: 'нет данных', loading: 'загрузка…', apiError: 'API недоступен',
    listening: 'слушает', not_listening: 'не слушает', port: 'порт', mac: 'MAC',
  },
};

type Lang = 'en' | 'ru';
function resolveLang(cfg: Record<string, unknown>): Lang {
  const c = (cfg.language as string) || 'auto';
  if (c === 'ru' || c === 'en') return c;
  const nav = (typeof navigator !== 'undefined' && navigator.language) || 'en';
  return nav.toLowerCase().startsWith('ru') ? 'ru' : 'en';
}
function makeT(lang: Lang) {
  return (key: string) => DICT[lang][key] ?? key;
}

/* ── color constants ────────────────────────────────────────────────────── */
const GREEN = '#22c55e';
const AMBER = '#f59e0b';
const RED   = '#ef4444';
const GREY  = '#6b7280';

/* ── API helpers ────────────────────────────────────────────────────────── */
function apiBase(cfg: Record<string, unknown>): string {
  const override = ((cfg.apiBaseUrl as string) || '').trim().replace(/\/+$/, '');
  if (override) return override;
  const host = (typeof window !== 'undefined' && window.location?.hostname) || 'localhost';
  return `http://${host}:4000`;
}

/* ── data types ─────────────────────────────────────────────────────────── */
interface AdapterInfo { name: string; ipv4?: string; ipv6?: string; mac?: string; up?: boolean }
interface Snapshot {
  system?: {
    cpu?: number; ram_used_mb?: number; ram_total_mb?: number; ram_free_mb?: number;
    ram_pct?: number; disk_used?: string; disk_total?: string; disk_free?: string;
    disk_pct?: number; temp_c?: number; uptime?: string;
  };
  fanhat?: { running?: boolean; status?: string; pwm_pct?: number | null; rpm?: number | null };
  network?: { external_ip?: string; wifi_ssid?: string; adapters?: AdapterInfo[] };
  vless?: { running?: boolean; port?: number; listening?: boolean; client_count?: number };
  socks5?: { running?: boolean; port?: number; listening?: boolean; client_count?: number };
}

/* ── polling hook ───────────────────────────────────────────────────────── */
function usePoll<T>(url: string | null, refreshMs: number): [T | null, string | null] {
  const [data, setData] = React.useState<T | null>(null);
  const [err, setErr] = React.useState<string | null>(null);
  React.useEffect(() => {
    if (!url) return;
    let cancelled = false;
    const run = async () => {
      const ctrl = new AbortController();
      const to = setTimeout(() => ctrl.abort(), Math.max(2000, refreshMs - 200));
      try {
        const r = await fetch(url, { signal: ctrl.signal, cache: 'no-store' });
        if (!r.ok) throw new Error(String(r.status));
        const j = (await r.json()) as T;
        if (!cancelled) { setData(j); setErr(null); }
      } catch (e) {
        if (!cancelled) setErr(String((e as Error)?.message || e));
      } finally { clearTimeout(to); }
    };
    run();
    const id = setInterval(run, Math.max(1000, refreshMs));
    return () => { cancelled = true; clearInterval(id); };
  }, [url, refreshMs]);
  return [data, err];
}

/* ── sparkline history ──────────────────────────────────────────────────── */
function useHistory(value: number | undefined, maxPoints: number): number[] {
  const buf = React.useRef<number[]>([]);
  React.useEffect(() => {
    if (value == null || !isFinite(value)) return;
    buf.current.push(value);
    if (buf.current.length > maxPoints) buf.current = buf.current.slice(-maxPoints);
  });
  return buf.current;
}

/* ── ping ───────────────────────────────────────────────────────────────── */
interface PingResult { host: string; name: string; ok: boolean; ms: number | null }
function usePings(base: string, targets: { name: string; host: string }[], refreshMs: number): PingResult[] {
  const key = targets.map((x) => x.host).join('|');
  const [results, setResults] = React.useState<PingResult[]>([]);
  React.useEffect(() => {
    if (!targets.length) { setResults([]); return; }
    let cancelled = false;
    const run = async () => {
      const out = await Promise.all(targets.map(async (t) => {
        try {
          const r = await fetch(`${base}/?ping=${encodeURIComponent(t.host)}`, { cache: 'no-store' });
          const j = await r.json();
          return { host: t.host, name: t.name, ok: !!j.ok, ms: j.ms ?? null } as PingResult;
        } catch { return { host: t.host, name: t.name, ok: false, ms: null } as PingResult; }
      }));
      if (!cancelled) setResults(out);
    };
    run();
    const id = setInterval(run, Math.max(3000, refreshMs));
    return () => { cancelled = true; clearInterval(id); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [base, key, refreshMs]);
  return results;
}

/* ── font/size helpers ──────────────────────────────────────────────────── */
const FONT_MAP: Record<string, string> = {
  system: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  sans:   'Inter, Helvetica, Arial, sans-serif',
  serif:  'Georgia, "Times New Roman", serif',
  mono:   'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
};
function resolveFont(cfg: Record<string, unknown>, style: ModuleStyle): string {
  const f = (cfg.fontFamily as string) || 'inherit';
  if (f === 'inherit') return style.fontFamily;
  if (f === 'custom') return ((cfg.customFont as string) || '').trim() || style.fontFamily;
  return FONT_MAP[f] || style.fontFamily;
}
function resolveSize(cfg: Record<string, unknown>, style: ModuleStyle): number {
  const s = Number(cfg.fontSize) || 0;
  return s > 0 ? s : style.fontSize;
}
function levelColor(value: number, warn: number, crit: number): string {
  if (!isFinite(value)) return GREY;
  if (value >= crit) return RED;
  if (value >= warn) return AMBER;
  return GREEN;
}
function n(v: unknown, d = 0): number { const x = Number(v); return isFinite(x) ? x : d; }

/* ── visual primitives ──────────────────────────────────────────────────── */
function Dot({ color, size = 12 }: { color: string; size?: number }) {
  return (
    <span style={{
      display: 'inline-block', width: size, height: size, borderRadius: '50%', flexShrink: 0,
      background: color, boxShadow: `0 0 ${Math.round(size / 2)}px ${color}99`,
    }} />
  );
}

function CrossedDot({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
      <circle cx="12" cy="12" r="9" fill="none" stroke={GREY} strokeWidth="2.5" />
      <line x1="6" y1="18" x2="18" y2="6" stroke={RED} strokeWidth="2.5" />
    </svg>
  );
}

function Bar({ pct, color, h = 10 }: { pct: number; color: string; h?: number }) {
  const w = Math.max(0, Math.min(100, pct));
  return (
    <div style={{ width: '100%', height: h, borderRadius: h, background: 'rgba(255,255,255,0.14)', overflow: 'hidden' }}>
      <div style={{ width: `${w}%`, height: '100%', background: color, borderRadius: h, transition: 'width .4s ease' }} />
    </div>
  );
}

function Gauge({ pct, color, label, size }: { pct: number; color: string; label: string; size: number }) {
  const r = 42; const c = 2 * Math.PI * r;
  const w = Math.max(0, Math.min(100, pct));
  const dim = Math.max(64, size * 4);
  return (
    <div style={{ position: 'relative', width: dim, height: dim }}>
      <svg viewBox="0 0 100 100" style={{ width: '100%', height: '100%', transform: 'rotate(-90deg)' }}>
        <circle cx="50" cy="50" r={r} fill="none" stroke="rgba(255,255,255,0.14)" strokeWidth="9" />
        <circle cx="50" cy="50" r={r} fill="none" stroke={color} strokeWidth="9" strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={c * (1 - w / 100)}
          style={{ transition: 'stroke-dashoffset .4s ease' }} />
      </svg>
      <div style={{
        position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column',
        alignItems: 'center', justifyContent: 'center',
      }}>
        <span style={{ fontSize: size * 1.1, fontWeight: 700 }}>{label}</span>
      </div>
    </div>
  );
}

/* ── Sparkline ──────────────────────────────────────────────────────────── */
function Sparkline({ values, color, height = 32 }: { values: number[]; color: string; height?: number }) {
  if (values.length < 2) return null;
  const W = 200; const H = height;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;
  const pts = values.map((v, i) => {
    const x = (i / (values.length - 1)) * W;
    const y = H - ((v - min) / range) * (H - 2) - 1;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  return (
    <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none"
      style={{ width: '100%', height, display: 'block', overflow: 'visible' }}>
      <polyline points={pts} fill="none" stroke={color} strokeWidth="2"
        strokeLinejoin="round" strokeLinecap="round" opacity="0.75" />
      <polyline
        points={`0,${H} ${pts} ${W},${H}`}
        fill={`${color}22`} stroke="none" />
    </svg>
  );
}

/* ── built-in icon set ──────────────────────────────────────────────────── */
function Icon({ name, size, color }: { name: string; size: number; color: string }) {
  const p: React.SVGProps<SVGSVGElement> = {
    width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
    stroke: color, strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round',
  };
  switch (name) {
    case 'cpu': return (<svg {...p}><rect x="6" y="6" width="12" height="12" rx="1" /><path d="M9 2v2M15 2v2M9 20v2M15 20v2M2 9h2M2 15h2M20 9h2M20 15h2" /></svg>);
    case 'memory': return (<svg {...p}><rect x="3" y="7" width="18" height="10" rx="1" /><path d="M7 7v10M11 7v10M15 7v10" /></svg>);
    case 'disk': return (<svg {...p}><circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="2.5" /></svg>);
    case 'thermometer': return (<svg {...p}><path d="M14 14.76V4a2 2 0 1 0-4 0v10.76a4 4 0 1 0 4 0z" /></svg>);
    case 'fan': return (<svg {...p}><circle cx="12" cy="12" r="2" /><path d="M12 2a5 5 0 0 1 0 10M12 22a5 5 0 0 1 0-10M2 12a5 5 0 0 1 10 0M22 12a5 5 0 0 1-10 0" /></svg>);
    case 'network': return (<svg {...p}><rect x="2" y="14" width="20" height="7" rx="1" /><path d="M6 17.5h.01M12 3v11M7 8l5-5 5 5" /></svg>);
    case 'globe': return (<svg {...p}><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3c2.5 2.5 2.5 15 0 18M12 3c-2.5 2.5-2.5 15 0 18" /></svg>);
    case 'shield': return (<svg {...p}><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z" /></svg>);
    case 'lock': return (<svg {...p}><rect x="4" y="11" width="16" height="9" rx="2" /><path d="M8 11V8a4 4 0 0 1 8 0v3" /></svg>);
    case 'signal': return (<svg {...p}><path d="M4 20v-4M9 20v-8M14 20v-12M19 20V4" /></svg>);
    default: return (<svg {...p}><path d="M3 12h4l2 7 4-16 2 9h6" /></svg>);
  }
}
const METRIC_ICON: Record<string, string> = {
  cpu: 'cpu', ram: 'memory', disk: 'disk', temp: 'thermometer', fan: 'fan',
  adapters: 'network', external_ip: 'globe', vless: 'shield', socks5: 'lock',
  ping: 'signal', uptime: 'activity', overview: 'activity',
};

/* ── Header ─────────────────────────────────────────────────────────────── */
function Header({ cfg, style, label }: { cfg: Record<string, unknown>; style: ModuleStyle; label: string }) {
  const showLabel = cfg.showLabel !== false;
  const iconType = (cfg.iconType as string) || 'builtin';
  const accent = (cfg.accentColor as string) || '#38bdf8';
  const fs = resolveSize(cfg, style);
  const metric = (cfg.metric as string) || 'overview';
  let iconEl: React.ReactNode = null;
  if (iconType === 'emoji') {
    const e = (cfg.emoji as string) || '';
    if (e) iconEl = <span style={{ fontSize: fs * 0.95 }}>{e}</span>;
  } else if (iconType === 'builtin') {
    let name = (cfg.builtinIcon as string) || 'auto';
    if (name === 'auto') name = METRIC_ICON[metric] || 'activity';
    iconEl = <Icon name={name} size={fs} color={accent} />;
  }
  if (!iconEl && !showLabel) return null;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6, opacity: 0.85, minWidth: 0 }}>
      {iconEl}
      {showLabel && (
        <span style={{ fontSize: fs * 0.78, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {label}
        </span>
      )}
    </div>
  );
}

/* ── threshold defaults ─────────────────────────────────────────────────── */
function defaultThresholds(metric: string): [number, number] {
  switch (metric) {
    case 'cpu':  return [80, 95];
    case 'ram':  return [80, 90];
    case 'disk': return [80, 90];
    case 'temp': return [65, 80];
    default:     return [101, 101];
  }
}

/* ── pct helpers ────────────────────────────────────────────────────────── */
function pctMetric(metric: string, snap: Snapshot): { pct: number; raw: number; primary: string; secondary: string } {
  const s = snap.system || {};
  if (metric === 'cpu')  return { pct: n(s.cpu),       raw: n(s.cpu),       primary: `${n(s.cpu).toFixed(0)}%`,      secondary: '' };
  if (metric === 'ram')  return { pct: n(s.ram_pct),   raw: n(s.ram_pct),   primary: `${n(s.ram_pct).toFixed(0)}%`,  secondary: `${n(s.ram_used_mb)} / ${n(s.ram_total_mb)} MB` };
  if (metric === 'disk') return { pct: n(s.disk_pct),  raw: n(s.disk_pct),  primary: `${n(s.disk_pct).toFixed(0)}%`, secondary: `${s.disk_used ?? '?'} / ${s.disk_total ?? '?'}` };
  if (metric === 'temp') return { pct: Math.min(100, (n(s.temp_c) / 90) * 100), raw: n(s.temp_c), primary: `${n(s.temp_c).toFixed(1)}°C`, secondary: '' };
  if (metric === 'fan')  return { pct: n(snap.fanhat?.pwm_pct), raw: n(snap.fanhat?.pwm_pct), primary: snap.fanhat?.pwm_pct == null ? 'n/a' : `${n(snap.fanhat?.pwm_pct).toFixed(0)}%`, secondary: '' };
  return { pct: 0, raw: 0, primary: '—', secondary: '' };
}

/* ══════════════════════════════════════════════════════════════════════════
   MAIN COMPONENT
   ══════════════════════════════════════════════════════════════════════════ */
export default function PiSystemMonitor({ config, style }: PluginComponentProps) {
  const cfg = config || {};
  const lang = resolveLang(cfg);
  const t = makeT(lang);
  const metric     = (cfg.metric as string)      || 'overview';
  const displayType= (cfg.displayType as string) || 'auto';
  const base       = apiBase(cfg);
  const refreshMs  = Math.max(1000, n(cfg.refreshMs, 4000));
  const accent     = (cfg.accentColor as string) || '#38bdf8';
  const fs         = resolveSize(cfg, style);
  const fontFamily = resolveFont(cfg, style);
  const showSparkline   = cfg.showSparkline !== false;
  const sparklinePoints = Math.max(10, n(cfg.sparklinePoints, 30));

  const needsSnapshot = metric !== 'ping';
  const [snap, err] = usePoll<Snapshot>(needsSnapshot ? `${base}/` : null, refreshMs);

  // Sparkline data: track raw value for cpu/temp/ram/disk
  const SPARKLINE_METRICS = ['cpu', 'temp', 'ram', 'disk'];
  const sparkRaw = SPARKLINE_METRICS.includes(metric)
    ? (metric === 'temp' ? snap?.system?.temp_c : metric === 'cpu' ? snap?.system?.cpu : metric === 'ram' ? snap?.system?.ram_pct : snap?.system?.disk_pct)
    : undefined;
  const sparkHistory = useHistory(sparkRaw, sparklinePoints);

  const pingTargets = React.useMemo(() => {
    return String(cfg.pingTargets || '')
      .split('\n').map((l) => l.trim()).filter(Boolean)
      .map((l) => { const [a, b] = l.split('|'); return b ? { name: a.trim(), host: b.trim() } : { name: a.trim(), host: a.trim() }; });
  }, [cfg.pingTargets]);

  const pings = usePings(base, metric === 'ping' ? pingTargets : [], refreshMs);

  const label = ((cfg.title as string) || '').trim() || t(metric);

  const root: React.CSSProperties = {
    width: '100%', height: '100%', boxSizing: 'border-box', overflow: 'hidden',
    display: 'flex', flexDirection: 'column', gap: 6, justifyContent: 'center',
    fontFamily, fontSize: fs, color: style.textColor,
    backgroundColor: style.backgroundColor, borderRadius: style.borderRadius,
    padding: style.padding, opacity: style.opacity,
    backdropFilter: `blur(${style.backdropBlur ?? 0}px)`,
    WebkitBackdropFilter: `blur(${style.backdropBlur ?? 0}px)`,
  };

  /* ── loading / error ── */
  if (needsSnapshot && !snap) {
    return (
      <div style={{ ...root, alignItems: 'center', justifyContent: 'center', opacity: 0.6, fontSize: fs * 0.8 }}>
        {err ? t('apiError') : t('loading')}
      </div>
    );
  }

  const data = snap || {};
  const [dWarn, dCrit] = defaultThresholds(metric);
  const warn = n(cfg.warnThreshold) > 0 ? n(cfg.warnThreshold) : dWarn;
  const crit = n(cfg.critThreshold) > 0 ? n(cfg.critThreshold) : dCrit;

  /* ── PING ── */
  if (metric === 'ping') {
    const warnMs = n(cfg.pingWarnMs, 150);
    const critMs = n(cfg.pingCritMs, 500);
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6, overflowY: 'auto' }}>
          {pingTargets.map((tg) => {
            const r = pings.find((x) => x.host === tg.host);
            const ok = r?.ok;
            const ms = r?.ms ?? null;
            const color = ms == null ? GREY : ms <= warnMs ? GREEN : ms <= critMs ? AMBER : RED;
            return (
              <div key={tg.host} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: fs * 0.9 }}>
                {ok ? <Dot color={color} size={10} /> : <CrossedDot size={12} />}
                <span style={{ flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{tg.name}</span>
                <span style={{ fontVariantNumeric: 'tabular-nums', color: ok ? color : GREY }}>
                  {ms == null ? '—' : `${ms.toFixed(0)} ms`}
                </span>
              </div>
            );
          })}
          {!pingTargets.length && <span style={{ opacity: 0.5 }}>{t('noData')}</span>}
        </div>
      </div>
    );
  }

  /* ── ADAPTERS ── */
  if (metric === 'adapters') {
    const list = data.network?.adapters || [];
    const showMac  = cfg.showMac !== false;
    const showIpv6 = cfg.showIpv6 === true;
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 7, overflowY: 'auto' }}>
          {list.map((a) => (
            <div key={a.name} style={{ display: 'flex', flexDirection: 'column', gap: 2, fontSize: fs * 0.82 }}>
              {/* Row 1: status dot + name + IPv4 */}
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                <Dot color={a.up ? GREEN : GREY} size={9} />
                <span style={{ fontWeight: 700, minWidth: 48, flexShrink: 0 }}>{a.name}</span>
                <span style={{ fontVariantNumeric: 'tabular-nums', opacity: 0.9, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
                  {a.ipv4 || (a.up ? '—' : t('offline'))}
                </span>
                <span style={{ opacity: 0.5, fontSize: fs * 0.72, flexShrink: 0 }}>
                  {a.up ? 'UP' : 'DOWN'}
                </span>
              </div>
              {/* Row 2: MAC (optional) */}
              {showMac && a.mac && (
                <div style={{ paddingLeft: 16, opacity: 0.45, fontSize: fs * 0.68, fontVariantNumeric: 'tabular-nums', letterSpacing: '0.02em' }}>
                  {t('mac')}: {a.mac}
                </div>
              )}
              {/* Row 3: IPv6 (optional) */}
              {showIpv6 && a.ipv6 && (
                <div style={{ paddingLeft: 16, opacity: 0.5, fontSize: fs * 0.68, fontVariantNumeric: 'tabular-nums', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  IPv6: {a.ipv6}
                </div>
              )}
            </div>
          ))}
          {!list.length && <span style={{ opacity: 0.5 }}>{t('noData')}</span>}
        </div>
      </div>
    );
  }

  /* ── EXTERNAL IP ── */
  if (metric === 'external_ip') {
    const ip = data.network?.external_ip || t('na');
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: fs * 1.4, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{ip}</span>
        </div>
        {data.network?.wifi_ssid && data.network.wifi_ssid !== 'N/A' && (
          <span style={{ fontSize: fs * 0.75, opacity: 0.6 }}>Wi-Fi: {data.network.wifi_ssid}</span>
        )}
      </div>
    );
  }

  /* ── VLESS / SOCKS5 ── */
  if (metric === 'vless' || metric === 'socks5') {
    const p = (metric === 'vless' ? data.vless : data.socks5) || {};
    const defaultName = metric === 'vless' ? 'VLESS-Reality' : 'SOCKS5-Telegram';
    const connName = ((cfg.connectionName as string) || '').trim() || defaultName;
    const cc = n(p.client_count);
    const isRunning   = !!p.running;
    const isListening = !!p.listening;
    const dotColor = !isRunning ? RED : !isListening ? AMBER : cc > 0 ? GREEN : AMBER;
    const stateTxt = !isRunning ? t('offline') : !isListening ? t('not_listening') : cc > 0 ? t('online') : t('idle');

    const showPort      = cfg.showPort !== false;
    const showClients   = cfg.showClientCount !== false;
    const showListening = cfg.showListening !== false;

    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        {/* Name + dot */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <Dot color={dotColor} size={fs * 0.85} />
          <span style={{ fontSize: fs * 1.05, fontWeight: 700, flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {connName}
          </span>
        </div>
        {/* Status row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: fs * 0.8, opacity: 0.75, flexWrap: 'wrap' }}>
          <span>{stateTxt}</span>
          {showPort && p.port && <span style={{ opacity: 0.7 }}>· {t('port')} {p.port}</span>}
          {showListening && (
            <span style={{ color: isListening ? GREEN : AMBER, fontWeight: 600 }}>
              · {isListening ? t('listening') : t('not_listening')}
            </span>
          )}
        </div>
        {/* Client count */}
        {showClients && (
          <div style={{ fontSize: fs * 0.88, fontVariantNumeric: 'tabular-nums' }}>
            <span style={{ fontWeight: 700, color: cc > 0 ? accent : GREY }}>{cc}</span>
            <span style={{ opacity: 0.6 }}> {t('clients')}</span>
          </div>
        )}
      </div>
    );
  }

  /* ── FAN ── */
  if (metric === 'fan') {
    const f = data.fanhat || {};
    const running = !!f.running;
    const pwm = f.pwm_pct;
    const dt = displayType === 'auto' ? 'badge' : displayType;
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <Dot color={running ? GREEN : RED} size={fs * 0.85} />
          <span style={{ fontSize: fs * 0.95, fontWeight: 600 }}>{running ? t('online') : t('offline')}</span>
        </div>
        {pwm != null && dt === 'gauge' && (
          <div style={{ display: 'flex', justifyContent: 'center' }}>
            <Gauge pct={n(pwm)} color={accent} label={`${n(pwm).toFixed(0)}%`} size={fs} />
          </div>
        )}
        {pwm != null && dt === 'bar' && (
          <>
            <Bar pct={n(pwm)} color={accent} />
            <span style={{ fontSize: fs * 0.8, opacity: 0.7 }}>PWM {n(pwm).toFixed(0)}%</span>
          </>
        )}
        {(pwm == null || dt === 'badge' || dt === 'value') && pwm != null && (
          <span style={{ fontSize: fs * 0.85, opacity: 0.75 }}>PWM {n(pwm).toFixed(0)}%</span>
        )}
        {pwm == null && <span style={{ fontSize: fs * 0.8, opacity: 0.5 }}>PWM {t('na')}</span>}
      </div>
    );
  }

  /* ── UPTIME ── */
  if (metric === 'uptime') {
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <span style={{ fontSize: fs * 1.05, fontWeight: 600 }}>{data.system?.uptime || t('na')}</span>
      </div>
    );
  }

  /* ── OVERVIEW ── */
  if (metric === 'overview') {
    const s = data.system || {};
    const rows: { key: string; pct: number; txt: string }[] = [
      { key: 'cpu',  pct: n(s.cpu),      txt: `${n(s.cpu).toFixed(0)}%`     },
      { key: 'ram',  pct: n(s.ram_pct),  txt: `${n(s.ram_pct).toFixed(0)}%` },
      { key: 'disk', pct: n(s.disk_pct), txt: `${n(s.disk_pct).toFixed(0)}%`},
      { key: 'temp', pct: Math.min(100, (n(s.temp_c) / 90) * 100), txt: `${n(s.temp_c).toFixed(0)}°` },
    ];
    const vc = !data.vless?.running || !data.vless?.listening  ? RED : n(data.vless?.client_count)  > 0 ? GREEN : AMBER;
    const sc = !data.socks5?.running || !data.socks5?.listening ? RED : n(data.socks5?.client_count) > 0 ? GREEN : AMBER;
    return (
      <div style={root}>
        <Header cfg={cfg} style={style} label={label} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
          {rows.map((r) => {
            const [w, c] = defaultThresholds(r.key);
            const col = r.key === 'temp' ? levelColor(n(s.temp_c), w, c) : levelColor(r.pct, w, c);
            return (
              <div key={r.key} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: fs * 0.8 }}>
                <span style={{ width: 34, opacity: 0.75 }}>{t(r.key)}</span>
                <div style={{ flex: 1 }}><Bar pct={r.pct} color={col} h={7} /></div>
                <span style={{ width: 38, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{r.txt}</span>
              </div>
            );
          })}
        </div>
        <div style={{ display: 'flex', gap: 14, fontSize: fs * 0.78, opacity: 0.85, flexWrap: 'wrap' }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <Dot color={data.fanhat?.running ? GREEN : RED} size={9} />{t('fan')}
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <Dot color={vc} size={9} />{t('vless')}
            {n(data.vless?.client_count) > 0 && <span style={{ opacity: 0.6, fontSize: fs * 0.68 }}>({n(data.vless?.client_count)})</span>}
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <Dot color={sc} size={9} />{t('socks5')}
            {n(data.socks5?.client_count) > 0 && <span style={{ opacity: 0.6, fontSize: fs * 0.68 }}>({n(data.socks5?.client_count)})</span>}
          </span>
        </div>
      </div>
    );
  }

  /* ── CPU / RAM / DISK / TEMP (numeric + optional sparkline) ── */
  const m = pctMetric(metric, data);
  const valueColor = metric === 'temp' ? levelColor(n(data.system?.temp_c), warn, crit) : levelColor(m.pct, warn, crit);
  const dt = displayType === 'auto' ? (metric === 'temp' ? 'gauge' : 'bar') : displayType;
  const showSpark = showSparkline && SPARKLINE_METRICS.includes(metric) && sparkHistory.length >= 2;

  return (
    <div style={root}>
      <Header cfg={cfg} style={style} label={label} />

      {dt === 'gauge' && (
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <Gauge pct={m.pct} color={valueColor} label={m.primary} size={fs} />
        </div>
      )}

      {dt === 'value' && (
        <span style={{ fontSize: fs * 1.8, fontWeight: 800, color: valueColor, fontVariantNumeric: 'tabular-nums' }}>
          {m.primary}
        </span>
      )}

      {dt === 'badge' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <Dot color={valueColor} size={fs} />
          <span style={{ fontSize: fs * 1.2, fontWeight: 700 }}>{m.primary}</span>
        </div>
      )}

      {dt === 'bar' && (
        <>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: fs * 0.95 }}>
            <span style={{ fontWeight: 700, color: valueColor, fontVariantNumeric: 'tabular-nums' }}>{m.primary}</span>
          </div>
          <Bar pct={m.pct} color={valueColor} />
        </>
      )}

      {m.secondary && (
        <span style={{ fontSize: fs * 0.72, opacity: 0.6 }}>{m.secondary}</span>
      )}

      {showSpark && (
        <div style={{ marginTop: 2 }}>
          <Sparkline values={sparkHistory} color={valueColor} height={Math.max(22, fs * 1.4)} />
        </div>
      )}
    </div>
  );
}
