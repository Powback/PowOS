# Launcher search

The shared web launcher searches installed app names, settings destinations and enabled AppAPI capabilities. All Android, Linux and PowOS launcher apps keep name search. AppAPI capabilities require the local App API app/runtime; unavailable providers do not prevent settings or app search.

Settings results open the matching screen and scroll/focus the named control. AppAPI results open the selected app/action in App API, including its existing inputs and confirmation flow. Searching or selecting a result never calls the capability. Disabled apps and actions are omitted. This indexes capability metadata, not every app's private contents.

`shell/search.ts` exports `registerSearchProvider({ id, search(text, signal) })`. A provider returns destinations `{ id, label, source, keywords?, open() }`; it may return a Promise. Return its unregister function when unloading a provider. Observe the abort signal for expensive work. Searches debounce 100 ms, time out providers after 1.8 s, discard old-query responses and show available results immediately. Providers must return only user-visible, authorized entries; discovery must not execute writes. Built-in settings use the same result contract. AppAPI reads `/apps` through the App API app's declared network capability and caches metadata for one minute.

PowOS app pages receive an optional `route: Record<string,string>` prop from `openApp(id, from, route)`. App API accepts `{app, action}` to open a specific capability. Other apps can use this to implement their own result destinations.

Checks: `shell/dev/gate.sh --tree` includes launcher search at mobile and desktop widths. `tools/phone/verify/queue.sh add --dev auto <task> launcher-search.sh` checks the deployed shell and real catalog without executing any capability.
