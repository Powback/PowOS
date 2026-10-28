# Launcher search

The shared web launcher searches installed app names, settings destinations and enabled AppAPI capabilities. All Android, Linux and PowOS launcher apps keep name search. AppAPI capabilities require the local App API app/runtime; unavailable providers do not prevent settings or app search.

Native Android settings use the system's `SEARCH_INDEXABLES_PROVIDER` catalog: raw records, XML preferences, dynamic records, and non-indexable-key exclusions. Only system providers and resolvable system destinations are accepted. Results retain their preference key, fragment or direct intent, and breadcrumb. The host stores destination intents privately; the web shell can only open an indexed ID, never submit arbitrary intent extras.

`NativeSettingsIndex` refreshes a process-wide snapshot in a background worker when searched after five minutes, or when the language changes. A completion event refreshes an already-open launcher search. Indexing never runs on the UI thread or on every keystroke; it changes no setting. The root helper is a bounded, read-only invocation from the installed APK, using Android's external-provider query API. Privileged installs with `READ_SEARCH_INDEXABLES` use ContentResolver directly. Root access is used only when PowOS root mode is already enabled, and only for the owner user.

Ordinary unrooted installs cannot read Android's system-only index. They retain resolvable standard page links and a query link to Android's own settings search. Coverage means entries published as searchable by the installed OS, not hidden/disabled preferences, private app contents, or controls omitted by the OEM. Provider/app updates are picked up on the next demand-driven cache refresh.

Settings results open the matching screen and scroll/focus the named control. AppAPI results open the selected app/action in App API, including its existing inputs and confirmation flow. Searching or selecting a result never calls the capability. Disabled apps and actions are omitted. This indexes capability metadata, not every app's private contents.

`shell/search.ts` exports `registerSearchProvider({ id, search(text, signal) })`. A provider returns destinations `{ id, label, source, keywords?, open() }`; it may return a Promise. Return its unregister function when unloading a provider. Observe the abort signal for expensive work. Searches debounce 100 ms, time out providers after 1.8 s, discard old-query responses and show available results immediately. Providers must return only user-visible, authorized entries; discovery must not execute writes. Built-in settings use the same result contract. AppAPI reads `/apps` through the App API app's declared network capability and caches metadata for one minute.

PowOS app pages receive an optional `route: Record<string,string>` prop from `openApp(id, from, route)`. App API accepts `{app, action}` to open a specific capability. Other apps can use this to implement their own result destinations.

Checks: `shell/dev/gate.sh --tree` includes launcher search at mobile and desktop widths. `tools/phone/verify/queue.sh add --dev auto <task> launcher-search.sh` checks the deployed shell and real catalog without executing any capability.
