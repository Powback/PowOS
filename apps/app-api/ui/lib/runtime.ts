/** One runtime read as a hook (lib/api.ts call): again whenever [key] changes, and when the page is shown again. */
import { useEffect, useState } from "preact/hooks";
import { call, type Net } from "./api";

/** [data, error, reload]; no timers at rest - visibility only. */
export function useRuntime<T>(net: Net | undefined, app: string, path: string | null, key = 0): [T | null, string | null, () => void] {
  const [data, setData] = useState<T | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [n, setN] = useState(0);
  useEffect(() => {
    if (!path) return;
    call<T>(net, app, path).then((d) => (setData(d), setErr(null)), (e) => setErr(String(e?.message ?? e)));
  }, [path, key, n]);
  useEffect(() => {
    const onShow = () => document.visibilityState === "visible" && setN((x) => x + 1);
    document.addEventListener("visibilitychange", onShow);
    return () => document.removeEventListener("visibilitychange", onShow);
  }, []);
  return [data, err, () => setN(n + 1)];
}
