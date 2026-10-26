/** Sketch on home: your latest drawing; tap it to keep drawing, ＋ for a fresh page. */
import { useApp, type Props } from "../lib/app";

interface Drawing {
  id: bigint;
  title: string;
  image: string;
  /** An older drawing's own picture, under its strokes (the page makes `image` after a change). */
  base?: string;
}

export default function Widget({ host, app: id }: Props) {
  const app = useApp(host);
  const latest = app.useTable<Drawing>("drawing").sort((a, b) => Number(b.id - a.id))[0];
  const src = latest ? latest.image || latest.base : "";
  return (
    <div style={S.box} onClick={() => host.openApp?.(id)}>
      {src ? <img src={src} style={S.img} /> : <div style={S.empty}>✎ Tap to draw</div>}
      <div style={S.tag}>✎ Sketch{latest ? ` · ${latest.title}` : ""}</div>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: { position: "relative", height: "100%", overflow: "hidden", borderRadius: "inherit", background: "#121216" },
  img: { width: "100%", height: "100%", objectFit: "cover", display: "block" },
  empty: { height: "100%", display: "flex", alignItems: "center", justifyContent: "center", opacity: 0.6 },
  tag: {
    position: "absolute", left: "8px", bottom: "8px", padding: "3px 8px", borderRadius: "8px", fontSize: "12px",
    background: "rgba(0,0,0,0.5)", maxWidth: "calc(100% - 16px)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
  },
};
