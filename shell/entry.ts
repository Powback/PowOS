/** Small chrome windows do not boot home, widgets, the terminal or the app registry. */
const mode = new URLSearchParams(location.search).get("mode");
if (["statusbar", "windowbar", "windowgrip"].includes(mode ?? "")) await import("./chrome.tsx");
else await import("./app.tsx");
export {};
