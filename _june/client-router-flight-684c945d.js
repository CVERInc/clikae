import { a as require_react, i as require_client, n as TITLE_HEADER, o as __toESM, r as decodeTitle, t as FLIGHT_ACCEPT } from "./client.90278050.js";
//#region node_modules/@junejs/core/src/client-router-flight.ts
var import_react = /* @__PURE__ */ __toESM(require_react(), 1);
var import_client = require_client();
async function defaultDecode(stream) {
	return (await import("react-server-dom-webpack/client.browser")).createFromReadableStream(stream);
}
const trimSlash = (p) => p.length > 1 && p.endsWith("/") ? p.slice(0, -1) : p;
function isHardNav(url) {
	return /\.(md|json|txt|xml)$/.test(url.pathname) || url.pathname === "/mcp";
}
let started = false;
let listeners = null;
function startFlightRouter(options = {}) {
	if (started) return;
	const rootEl = document.querySelector("[data-june-root]");
	if (!rootEl) return;
	started = true;
	listeners = new AbortController();
	const signal = listeners.signal;
	const decode = options.decode ?? defaultDecode;
	let root = null;
	const pageKey = () => location.pathname + location.search;
	let lastPage = pageKey();
	let gen = 0;
	function hard(href) {
		location.href = href;
	}
	const stale = (mine) => mine !== gen || signal.aborted;
	async function navigate(href, push) {
		const mine = ++gen;
		const url = new URL(href, location.href);
		try {
			const res = await fetch(url.href, {
				headers: { accept: FLIGHT_ACCEPT },
				signal
			});
			if (stale(mine)) return;
			const ct = res.headers.get("content-type") ?? "";
			if (!res.ok || !res.body || !ct.includes("text/vnd.june.flight")) return hard(url.href);
			const node = await decode(res.body);
			if (stale(mine)) return;
			root ??= (0, import_client.createRoot)(rootEl);
			root.render(import_react.createElement(import_react.Fragment, null, node));
			const title = decodeTitle(res.headers.get(TITLE_HEADER));
			if (title) document.title = title;
			if (push) history.pushState(null, "", url.href);
			lastPage = pageKey();
			window.scrollTo(0, 0);
		} catch {
			if (stale(mine)) return;
			hard(url.href);
		}
	}
	document.addEventListener("click", (e) => {
		if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
		const a = e.target?.closest?.("a[href]");
		if (!a || a.target === "_blank" || a.hasAttribute("download")) return;
		const url = new URL(a.href, location.href);
		if (url.origin !== location.origin || isHardNav(url)) return;
		if (trimSlash(url.pathname) === trimSlash(location.pathname) && url.search === location.search) return;
		e.preventDefault();
		navigate(url.href, true);
	}, { signal });
	window.addEventListener("popstate", () => {
		if (pageKey() === lastPage) {
			++gen;
			return;
		}
		navigate(location.href, false);
	}, { signal });
}
//#endregion
export { startFlightRouter };
