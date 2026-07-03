//#region node_modules/@kurajs/core/dist/kb.js
const popcount = (x) => {
	x = x - (x >>> 1 & 1431655765);
	x = (x & 858993459) + (x >>> 2 & 858993459);
	x = x + (x >>> 4) & 252645135;
	return x * 16843009 >>> 24;
};
var Kb = class Kb {
	dim;
	exactThreshold;
	words;
	embedder;
	embedFn;
	ids = [];
	meta = [];
	vecs;
	codes;
	idx = /* @__PURE__ */ new Map();
	count = 0;
	capacity = 0;
	constructor(opts) {
		const dim = opts.dim ?? opts.embedder?.dim;
		if (!Number.isInteger(dim) || dim <= 0) throw new Error("Kb: dim must be a positive integer (or pass an embedder)");
		this.dim = dim;
		this.words = this.dim + 31 >> 5;
		this.exactThreshold = opts.exactThreshold ?? 1e4;
		this.embedder = opts.embedder;
		this.embedFn = opts.embed;
		this.vecs = /* @__PURE__ */ new Float32Array(0);
		this.codes = /* @__PURE__ */ new Uint32Array(0);
	}
	get size() {
		return this.count;
	}
	/** Build a Kb from a full record set in one shot. */
	static from(records, opts) {
		const kb = new Kb(opts);
		kb.add(records);
		return kb;
	}
	/**
	* Insert or update records (upsert by id). New ids append; existing ids are
	* overwritten in place. Either way the change is searchable immediately — there
	* is no index graph to rebuild. Vectors are normalized and binary-coded on write.
	*/
	add(records) {
		const list = Array.isArray(records) ? records : [...records];
		this.ensure(this.count + list.length);
		for (const rec of list) {
			const existing = this.idx.get(rec.id);
			if (existing !== void 0) this.writeAt(existing, rec);
			else {
				this.writeAt(this.count, rec);
				this.count++;
			}
		}
	}
	/** Alias for {@link add} — reads as intent at a dynamic write site. */
	upsert(record) {
		this.add([record]);
	}
	/** Whether a record with this id exists. */
	has(id) {
		return this.idx.has(id);
	}
	/**
	* Remove a record by id (O(1) swap-remove). Returns true if it existed.
	* Searchable state updates immediately.
	*/
	delete(id) {
		const slot = this.idx.get(id);
		if (slot === void 0) return false;
		const last = this.count - 1;
		if (slot !== last) {
			this.vecs.copyWithin(slot * this.dim, last * this.dim, (last + 1) * this.dim);
			this.codes.copyWithin(slot * this.words, last * this.words, (last + 1) * this.words);
			this.ids[slot] = this.ids[last];
			this.meta[slot] = this.meta[last];
			this.idx.set(this.ids[slot], slot);
		}
		this.ids.pop();
		this.meta.pop();
		this.idx.delete(id);
		this.count--;
		return true;
	}
	writeAt(slot, rec) {
		if (rec.vector.length !== this.dim) throw new Error(`Kb: vector length ${rec.vector.length} != dim ${this.dim} (id=${rec.id})`);
		const vOff = slot * this.dim;
		let ss = 0;
		for (let d = 0; d < this.dim; d++) {
			const x = rec.vector[d];
			this.vecs[vOff + d] = x;
			ss += x * x;
		}
		const inv = 1 / (Math.sqrt(ss) || 1);
		const cOff = slot * this.words;
		for (let w = 0; w < this.words; w++) {
			let bits = 0;
			const base = vOff + (w << 5);
			const lim = Math.min(32, this.dim - (w << 5));
			for (let b = 0; b < lim; b++) {
				this.vecs[base + b] *= inv;
				if (this.vecs[base + b] > 0) bits |= 1 << b;
			}
			this.codes[cOff + w] = bits >>> 0;
		}
		this.ids[slot] = rec.id;
		this.meta[slot] = rec.data ?? void 0;
		this.idx.set(rec.id, slot);
	}
	/** Embed `text` via the configured embedder, then search. */
	async searchText(text, opts = {}) {
		return this.search(await this.embedQuery(text), opts);
	}
	/** Embed and upsert text records (id + text + optional data). Searchable immediately. */
	async addText(records) {
		const vectors = await this.embedTexts(records.map((r) => r.text));
		this.add(records.map((r, i) => ({
			id: r.id,
			vector: vectors[i],
			data: r.data
		})));
	}
	async embedTexts(texts) {
		if (this.embedder) return this.embedder.embed(texts);
		if (this.embedFn) return Promise.all(texts.map(async (t) => Float32Array.from(await this.embedFn(t))));
		throw new Error("Kb: no embedder configured; pass `embedder` (or `embed`) in options");
	}
	async embedQuery(text) {
		return (await this.embedTexts([text]))[0];
	}
	/** k-NN search by query vector (cosine). */
	search(query, opts = {}) {
		if (query.length !== this.dim) throw new Error(`Kb: query length ${query.length} != dim ${this.dim}`);
		const topK = Math.max(1, Math.min(opts.topK ?? 10, this.count));
		if (this.count === 0) return [];
		const q = new Float32Array(this.dim);
		let ss = 0;
		for (let d = 0; d < this.dim; d++) {
			q[d] = query[d];
			ss += q[d] * q[d];
		}
		const inv = 1 / (Math.sqrt(ss) || 1);
		for (let d = 0; d < this.dim; d++) q[d] *= inv;
		return (this.count <= this.exactThreshold ? this.exact(q, topK) : this.ann(q, topK, opts.rerankDepth)).map(([i, score]) => ({
			id: this.ids[i],
			score,
			data: this.meta[i]
		}));
	}
	exact(q, topK) {
		return this.rerankTopK(q, topK, null, this.count);
	}
	ann(q, topK, rerankDepth) {
		const depth = Math.min(this.count, rerankDepth ?? Math.max(topK * 20, Math.ceil(this.count * .005)));
		const qc = new Uint32Array(this.words);
		for (let w = 0; w < this.words; w++) {
			let bits = 0;
			const base = w << 5;
			const lim = Math.min(32, this.dim - base);
			for (let b = 0; b < lim; b++) if (q[base + b] > 0) bits |= 1 << b;
			qc[w] = bits >>> 0;
		}
		const dists = new Int32Array(this.count);
		const counts = new Int32Array(this.dim + 2);
		for (let i = 0; i < this.count; i++) {
			let h = 0;
			const co = i * this.words;
			for (let w = 0; w < this.words; w++) h += popcount((this.codes[co + w] ^ qc[w]) >>> 0);
			dists[i] = h;
			counts[h]++;
		}
		let acc = 0;
		for (let d = 0; d <= this.dim; d++) {
			const c = counts[d];
			counts[d] = acc;
			acc += c;
		}
		const order = new Int32Array(this.count);
		for (let i = 0; i < this.count; i++) order[counts[dists[i]]++] = i;
		return this.rerankTopK(q, topK, order, depth);
	}
	rerankTopK(q, topK, order, limit) {
		const ids = new Int32Array(topK).fill(-1);
		const sc = new Float64Array(topK).fill(-Infinity);
		let filled = 0;
		for (let j = 0; j < limit; j++) {
			const i = order ? order[j] : j;
			const off = i * this.dim;
			let dot = 0;
			for (let d = 0; d < this.dim; d++) dot += this.vecs[off + d] * q[d];
			if (dot > sc[topK - 1]) {
				let p = topK - 1;
				while (p > 0 && sc[p - 1] < dot) {
					sc[p] = sc[p - 1];
					ids[p] = ids[p - 1];
					p--;
				}
				sc[p] = dot;
				ids[p] = i;
				if (filled < topK) filled++;
			}
		}
		const out = [];
		for (let p = 0; p < filled; p++) out.push([ids[p], sc[p]]);
		return out;
	}
	ensure(n) {
		if (n <= this.capacity) return;
		let cap = Math.max(this.capacity || 16, 16);
		while (cap < n) cap *= 2;
		const v = new Float32Array(cap * this.dim);
		v.set(this.vecs.subarray(0, this.count * this.dim));
		this.vecs = v;
		const c = new Uint32Array(cap * this.words);
		c.set(this.codes.subarray(0, this.count * this.words));
		this.codes = c;
		this.capacity = cap;
	}
	/**
	* Serialize to a compact binary buffer (for build-time freeze and loading as a
	* static asset on Workers). Layout: [u32 jsonLen][json][pad to 4][f32 vecs][u32 codes].
	*/
	serialize() {
		const header = JSON.stringify({
			v: 1,
			dim: this.dim,
			count: this.count,
			exactThreshold: this.exactThreshold,
			ids: this.ids,
			data: this.meta
		});
		const json = new TextEncoder().encode(header);
		const jsonPad = json.length + 3 & -4;
		const vecsBytes = this.count * this.dim * 4;
		const codesBytes = this.count * this.words * 4;
		const total = 4 + jsonPad + vecsBytes + codesBytes;
		const buf = new ArrayBuffer(total);
		new DataView(buf).setUint32(0, json.length, true);
		new Uint8Array(buf, 4, json.length).set(json);
		new Float32Array(buf, 4 + jsonPad, this.count * this.dim).set(this.vecs.subarray(0, this.count * this.dim));
		new Uint32Array(buf, 4 + jsonPad + vecsBytes, this.count * this.words).set(this.codes.subarray(0, this.count * this.words));
		return new Uint8Array(buf);
	}
	/** Load a Kb from a buffer produced by {@link serialize}. */
	static load(bytes, opts) {
		const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
		const jsonLen = new DataView(buf).getUint32(0, true);
		const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, jsonLen)));
		const jsonPad = jsonLen + 3 & -4;
		const kb = new Kb({
			dim: header.dim,
			exactThreshold: header.exactThreshold,
			embedder: opts?.embedder,
			embed: opts?.embed
		});
		const words = header.dim + 31 >> 5;
		const vecsBytes = header.count * header.dim * 4;
		kb.ids = header.ids;
		kb.meta = header.data;
		kb.count = header.count;
		kb.capacity = header.count;
		kb.vecs = new Float32Array(buf, 4 + jsonPad, header.count * header.dim);
		kb.codes = new Uint32Array(buf, 4 + jsonPad + vecsBytes, header.count * words);
		for (let i = 0; i < kb.count; i++) kb.idx.set(kb.ids[i], i);
		return kb;
	}
};
//#endregion
//#region node_modules/@kurajs/search/dist/tokenize.js
/**
* Default tokenizer for space-delimited / alphabetic scripts (Latin, Cyrillic,
* Greek, …): lowercase, then split on any run of non-letter / non-number
* characters. Unicode-aware, so accented letters survive.
*
* This does NOT segment space-free scripts (Chinese, Japanese, Thai): those
* collapse to one token per run. For CJK, inject a tokenizer from
* `@kurajs/tokenizers` (via `tokenize` or {@link byLocale}).
*/
const latinTokenizer = (text) => text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
//#endregion
//#region node_modules/@kurajs/search/dist/bm25.js
/**
* In-memory BM25 index. Build with {@link Bm25.from} (or `new Bm25()` + {@link Bm25.add}),
* then {@link Bm25.search}. Building is cheap at docs scale (a few hundred kchars/ms),
* so a frozen corpus can be re-indexed at startup rather than shipped pre-serialized.
*/
var Bm25 = class Bm25 {
	k1;
	b;
	tokenize;
	resolve;
	postings = /* @__PURE__ */ new Map();
	docLen = [];
	ids = [];
	store = [];
	totalLen = 0;
	constructor(opts = {}) {
		this.k1 = opts.k1 ?? 1.2;
		this.b = opts.b ?? .75;
		this.tokenize = opts.tokenize ?? latinTokenizer;
		this.resolve = opts.resolveTokenizer;
	}
	/** Tokenizer for a language: the resolver's pick, or the single tokenizer. */
	tokenizerFor(lang) {
		return this.resolve ? this.resolve(lang) : this.tokenize;
	}
	/** Build an index from records in one call. */
	static from(records, opts) {
		const bm = new Bm25(opts);
		bm.add(records);
		return bm;
	}
	/** Number of indexed documents. */
	get size() {
		return this.ids.length;
	}
	/**
	* Tokenize text exactly as this index does (the configured tokenizer / resolver for `lang`).
	* Use it to align downstream work — e.g. snippet anchoring — with how queries are matched,
	* since a per-locale or normalizing tokenizer can produce different terms than a naive split.
	*/
	tokensOf(text, lang) {
		return this.tokenizerFor(lang)(text);
	}
	/** Index more records. Records are appended; there is no de-duplication by id. */
	add(records) {
		const tf = /* @__PURE__ */ new Map();
		for (const rec of records) {
			const docId = this.ids.length;
			this.ids.push(rec.id);
			this.store.push(rec.data);
			const toks = this.tokenizerFor(rec.lang)(rec.text);
			this.docLen.push(toks.length);
			this.totalLen += toks.length;
			tf.clear();
			for (const t of toks) tf.set(t, (tf.get(t) ?? 0) + 1);
			for (const [t, c] of tf) {
				let p = this.postings.get(t);
				if (!p) {
					p = [];
					this.postings.set(t, p);
				}
				p.push(docId, c);
			}
		}
	}
	/** Rank documents against `query` by BM25, returning the top `topK`. */
	search(query, opts = {}) {
		const n = this.ids.length;
		if (!n) return [];
		const tokens = this.tokenizerFor(opts.lang)(query);
		if (!tokens.length) return [];
		const avgdl = this.totalLen / n;
		const scores = /* @__PURE__ */ new Map();
		const eachDoc = (p, accumulate) => {
			const df = p.length / 2;
			const idf = Math.log((n - df + .5) / (df + .5) + 1);
			for (let i = 0; i < p.length; i += 2) {
				const docId = p[i];
				const dl = this.docLen[docId];
				accumulate(docId, idf * (p[i + 1] * (this.k1 + 1)) / (p[i + 1] + this.k1 * (1 - this.b + this.b * dl / avgdl)));
			}
		};
		const last = tokens[tokens.length - 1];
		const usePrefix = !!opts.prefixLast && last.length >= (opts.minPrefix ?? 2);
		const exact = new Set(usePrefix ? tokens.slice(0, -1) : tokens);
		for (const t of exact) {
			const p = this.postings.get(t);
			if (p) eachDoc(p, (docId, s) => scores.set(docId, (scores.get(docId) ?? 0) + s));
		}
		if (usePrefix) {
			const group = /* @__PURE__ */ new Map();
			let expanded = 0;
			const cap = opts.maxExpand ?? 128;
			for (const [term, p] of this.postings) {
				if (!term.startsWith(last)) continue;
				eachDoc(p, (docId, s) => {
					const c = group.get(docId);
					if (c === void 0 || s > c) group.set(docId, s);
				});
				if (++expanded >= cap) break;
			}
			for (const [docId, s] of group) scores.set(docId, (scores.get(docId) ?? 0) + s);
		}
		const topK = Math.max(0, Math.floor(opts.topK ?? 10));
		return [...scores.entries()].sort((a, b) => b[1] - a[1]).slice(0, topK).map(([docId, score]) => ({
			id: this.ids[docId],
			score,
			data: this.store[docId]
		}));
	}
};
//#endregion
//#region node_modules/@kurajs/search/dist/rrf.js
/**
* Fuse ranked lists by id, returning each item with its RRF score (so callers can
* surface a score consistent with the fused ordering — a raw BM25 score or cosine
* similarity from one input list would not be). The representative item kept for an
* id is the first one seen across the lists in the order given — so pass the list
* whose payload you'd rather display (e.g. the keyword snippet) first.
*/
function rrfScored(lists, idOf, opts = {}) {
	const k = Math.max(0, opts.k ?? 60);
	const score = /* @__PURE__ */ new Map();
	const rep = /* @__PURE__ */ new Map();
	for (const list of lists) {
		const weight = list.weight ?? 1;
		for (let rank = 0; rank < list.hits.length; rank++) {
			const hit = list.hits[rank];
			const id = idOf(hit);
			score.set(id, (score.get(id) ?? 0) + weight / (k + rank + 1));
			if (!rep.has(id)) rep.set(id, hit);
		}
	}
	const fused = [...score.entries()].sort((a, b) => b[1] - a[1]);
	const limit = opts.topK != null ? Math.max(0, Math.floor(opts.topK)) : void 0;
	return (limit != null ? fused.slice(0, limit) : fused).map(([id, s]) => ({
		item: rep.get(id),
		score: s
	}));
}
//#endregion
//#region node_modules/@kurajs/tokenizers/dist/bigram.js
const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const WORD = /[\p{L}\p{N}]/u;
/**
* Dictionary-free CJK tokenizer: emits overlapping character bigrams for runs of
* CJK characters (搜尋引擎 → 搜尋, 尋引, 引擎), and whole lowercased words for runs
* of Latin letters / digits (so mixed text like "iPhone 15 手機" works). A lone CJK
* character is emitted as a unigram.
*
* Bigrams trade a larger index for guaranteed recall and zero dictionary / license
* baggage — the robust default for CJK keyword search, and a safe fallback where
* `Intl.Segmenter` is unavailable.
*/
function cjkBigram() {
	return (text) => {
		const chars = Array.from(text);
		const out = [];
		let i = 0;
		while (i < chars.length) {
			const ch = chars[i];
			if (CJK.test(ch)) {
				let j = i;
				while (j < chars.length && CJK.test(chars[j])) j++;
				const run = chars.slice(i, j);
				if (run.length === 1) out.push(run[0]);
				else for (let k = 0; k < run.length - 1; k++) out.push(run[k] + run[k + 1]);
				i = j;
			} else if (WORD.test(ch)) {
				let j = i;
				while (j < chars.length && WORD.test(chars[j]) && !CJK.test(chars[j])) j++;
				out.push(chars.slice(i, j).join("").toLowerCase());
				i = j;
			} else i++;
		}
		return out;
	};
}
//#endregion
//#region node_modules/@kurajs/tokenizers/dist/segmenter.js
/**
* Word-segmenting CJK tokenizer backed by the native `Intl.Segmenter` (the ECMAScript
* Intl API, dictionary-based via ICU's BreakIterator). Higher precision than bigrams,
* with the dictionary living in the engine (zero bundle cost). Where `Intl.Segmenter`
* is unavailable (e.g. some edge runtimes) it falls back to {@link cjkBigram}, so
* search still works.
*
* @param locale e.g. "zh", "zh-TW", "ja", "ko"
*/
function cjkSegmenter(locale, opts = {}) {
	const Ctor = globalThis.Intl?.Segmenter;
	if (!Ctor) return opts.fallback ?? cjkBigram();
	const seg = new Ctor(locale, { granularity: "word" });
	return (text) => {
		const out = [];
		for (const s of seg.segment(text)) if (s.isWordLike ?? /[\p{L}\p{N}]/u.test(s.segment)) out.push(s.segment.toLowerCase());
		return out;
	};
}
//#endregion
//#region node_modules/@kurajs/docs/dist/nav.js
function slugify(text) {
	return text.trim().toLowerCase().replace(/[`*_~]/g, "").replace(/\s+/g, "-").replace(/[^\p{L}\p{N}-]/gu, "");
}
/** A stateful heading-id generator for ONE document. Slugifies the heading text, falls back to
*  "section" when slugify yields "" (a punctuation/emoji-only heading would otherwise get id=""),
*  and de-dups repeats github-slugger style: the first use keeps the bare slug, later ones get -1,
*  -2, …. Use one slugger per document so the renderer (processHtml) and the search indexer
*  (splitByHeadings) walk the same headings in order and assign IDENTICAL ids — search deep-links
*  (`#id`) must match the rendered anchors, including for repeated and h4 headings. */
function createSlugger() {
	const taken = /* @__PURE__ */ new Map();
	return (text) => {
		const base = slugify(text) || "section";
		let id = base;
		while (taken.has(id)) {
			const n = (taken.get(base) ?? 0) + 1;
			taken.set(base, n);
			id = `${base}-${n}`;
		}
		taken.set(id, taken.get(id) ?? 0);
		return id;
	};
}
//#endregion
//#region node_modules/@kurajs/docs/dist/util.js
/**
* Strip JSX component tags from MDX source for the agent `.md`/llms.txt surface, so
* agents get clean Markdown instead of raw JSX. Keeps children text; drops <Tag .../>,
* <Tag ...> and </Tag> for capitalized component names — but leaves anything inside
* fenced (```…```) or inline (`…`) code untouched.
*/
function stripMdx(source) {
	return source.split(/(```[\s\S]*?```|`[^`\n]*`)/g).map((seg, i) => i % 2 === 1 ? seg : seg.replace(/<([A-Z][A-Za-z0-9]*)\b[^>]*\/>/g, "").replace(/<\/?[A-Z][A-Za-z0-9]*\b[^>]*>/g, "")).join("").replace(/\n{3,}/g, "\n\n");
}
//#endregion
//#region node_modules/@kurajs/docs/dist/search.js
const CJK_PRIMARY = /* @__PURE__ */ new Set([
	"zh",
	"ja",
	"ko"
]);
function defaultTokenizer() {
	const cache = /* @__PURE__ */ new Map();
	return (lang) => {
		if (!lang) return latinTokenizer;
		const l = lang.toLowerCase();
		const primary = l.split("-")[0];
		if (!primary || !CJK_PRIMARY.has(primary)) return latinTokenizer;
		let tok = cache.get(l);
		if (!tok) {
			tok = cjkSegmenter(l);
			cache.set(l, tok);
		}
		return tok;
	};
}
/** Split a doc body into overlapping chunks for embedding. */
function chunk(text, size = 500, overlap = 80) {
	const clean = text.replace(/\r/g, "");
	const out = [];
	for (let i = 0; i < clean.length; i += size - overlap) out.push(clean.slice(i, Math.min(i + size, clean.length)).trim());
	return out.filter((c) => c.length > 30);
}
/**
* Split a markdown body into heading-anchored sections at `##`–`####` (the levels nav's
* processHtml anchors), so each section can be indexed and deep-linked to its own `#id`.
* `headingId` uses the same {@link createSlugger} as the renderer — same heading set, same order —
* so the ids match exactly, including the -1/-2 de-dup for repeated headings. Text before the first
* heading is the intro section (empty headingId = page top). ATX markers inside fenced code blocks
* are ignored, matching what actually becomes a rendered heading.
*/
function splitByHeadings(body) {
	const lines = body.replace(/\r/g, "").split("\n");
	const sections = [];
	const slugId = createSlugger();
	let cur = {
		headingId: "",
		heading: "",
		text: ""
	};
	let inFence = false;
	const flush = () => {
		const t = cur.text.trim();
		if (t || cur.heading) sections.push({
			...cur,
			text: t
		});
	};
	for (const line of lines) {
		if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
		const m = !inFence && /^(#{2,4})\s+(.+?)\s*#*$/.exec(line);
		if (m) {
			flush();
			const heading = m[2].replace(/[`*_~]/g, "").trim();
			cur = {
				headingId: slugId(heading),
				heading,
				text: ""
			};
		} else cur.text += line + "\n";
	}
	flush();
	return sections.length ? sections : [{
		headingId: "",
		heading: "",
		text: body.trim()
	}];
}
/** Rendered HTML → readable plaintext (for indexing + matching): drop script/style, strip tags,
*  decode the few common entities, collapse whitespace. A regex, not a parser — cheap, no deps,
*  safe to run in the browser when the static client derives its index from the shipped HTML. */
function htmlToText(html) {
	return html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&quot;/gi, "\"").replace(/&#0?39;|&#x27;/gi, "'").replace(/\s+/g, " ").trim();
}
/** Split rendered HTML into heading-anchored sections (h2–h4), mirroring {@link splitByHeadings} on
*  markdown. Ids come from the SAME slugger (createSlugger, top-to-bottom) that processHtml + the
*  markdown split use, so a section's `headingId` matches the live page's anchor (deep-links land).
*  Each section keeps its HTML (for a rich preview) and a derived plaintext (index + snippet). */
function splitHtmlByHeadings(html) {
	const slugId = createSlugger();
	const out = [];
	for (const part of html.split(/(?=<h[2-4]\b)/i)) {
		const m = /^<(h[2-4])\b[^>]*>([\s\S]*?)<\/\1>/i.exec(part);
		if (m) {
			const raw = m[2].replace(/<[^>]+>/g, "").trim();
			const rest = part.slice(m[0].length).trim();
			out.push({
				headingId: slugId(raw),
				heading: htmlToText(m[2]),
				html: rest,
				text: htmlToText(rest)
			});
		} else {
			const rest = part.replace(/^\s*<h1\b[^>]*>[\s\S]*?<\/h1>/i, "").trim();
			const text = htmlToText(rest);
			if (text) out.push({
				headingId: "",
				heading: "",
				html: rest,
				text
			});
		}
	}
	return out.length ? out : [{
		headingId: "",
		heading: "",
		html: html.trim(),
		text: htmlToText(html)
	}];
}
/** Keep at most `max` hits per page (slug), preserving order — so one page can't crowd out the
*  rest of the results, while still surfacing its few most relevant headings (Mintlify-style). */
function capPerPage(hits, max) {
	const count = /* @__PURE__ */ new Map();
	const out = [];
	for (const h of hits) {
		const n = count.get(h.slug) ?? 0;
		if (n >= max) continue;
		count.set(h.slug, n + 1);
		out.push(h);
	}
	return out;
}
async function indexKb(entries, embedder) {
	const kb = new Kb({ embedder });
	let n = 0;
	for (const d of entries) {
		const base = {
			slug: d.slug,
			title: String(d.data.title ?? d.slug),
			section: String(d.data.section ?? ""),
			...d.locale ? { locale: d.locale } : {}
		};
		for (const sec of splitByHeadings(d.body)) {
			const secData = sec.headingId ? {
				headingId: sec.headingId,
				heading: sec.heading
			} : {};
			const text = stripMdx(sec.heading ? `${sec.heading}\n${sec.text}` : sec.text);
			for (const c of chunk(text)) await kb.addText([{
				id: `${d.locale ?? "_"}:${d.slug}#${sec.headingId}@${n++}`,
				text: c,
				data: {
					...base,
					...secData,
					text: c
				}
			}]);
		}
	}
	return kb;
}
/** Build a serialized index by embedding every doc chunk. Use at build time (`kura index`). */
async function buildIndex(opts) {
	return (await indexKb(opts.entries, opts.embedder)).serialize();
}
function buildKeywordIndex(entries, tokenizer) {
	const records = entries.flatMap((e) => {
		const title = String(e.data.title ?? e.slug);
		const section = String(e.data.section ?? "");
		return (e.html ? splitHtmlByHeadings(e.html) : splitByHeadings(e.body ?? "").map((s) => ({
			headingId: s.headingId,
			heading: s.heading,
			html: "",
			text: stripMdx(s.text)
		}))).map((sec) => ({
			id: `${e.locale ?? "_"}:${e.slug}#${sec.headingId}`,
			text: `${title}\n${sec.heading}\n${sec.text}`,
			lang: e.locale,
			data: {
				slug: e.slug,
				title,
				section,
				body: sec.text,
				...sec.html ? { html: sec.html } : {},
				...sec.headingId ? {
					headingId: sec.headingId,
					heading: sec.heading
				} : {},
				...e.locale ? { locale: e.locale } : {}
			}
		}));
	});
	return Bm25.from(records, { resolveTokenizer: tokenizer });
}
function snippetAround(body, tokens) {
	if (!tokens.length) return body.slice(0, 160).trim();
	const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const re = new RegExp("(?<![\\p{L}\\p{N}])(?:" + tokens.map(esc).join("|") + ")(?![\\p{L}\\p{N}])", "iu");
	let at = body.search(re);
	if (at < 0) {
		const lc = body.toLowerCase();
		for (const t of tokens) {
			const i = lc.indexOf(t.toLowerCase());
			if (i >= 0 && (at < 0 || i < at)) at = i;
		}
	}
	const start = at > 60 ? at - 40 : 0;
	return body.slice(start, start + 160).trim();
}
function keywordSearch(index, query, limit, fetchK = limit * 4, locale, prefixLast, navBoost) {
	const queryTokens = index.tokensOf(query, locale);
	const navPrefix = navBoost && prefixLast && queryTokens.length === 1 && queryTokens[0].length >= 2 ? queryTokens[0] : null;
	const firstTok = (text) => {
		return index.tokensOf(text ?? "", locale)[0] ?? "";
	};
	const boostOf = (d) => {
		if (!navPrefix) return 0;
		if ((d.slug.split(/[/-]/)[0] ?? "").startsWith(navPrefix) || firstTok(d.title).startsWith(navPrefix)) return 1e3;
		if (d.heading && firstTok(d.heading).startsWith(navPrefix)) return 500;
		return 0;
	};
	const best = /* @__PURE__ */ new Map();
	for (const h of index.search(query, {
		topK: fetchK,
		lang: locale,
		prefixLast
	})) {
		const rank = h.score + boostOf(h.data);
		const hit = {
			slug: h.data.slug,
			title: h.data.title,
			section: h.data.section,
			text: snippetAround(h.data.body, queryTokens),
			score: Number(h.score.toFixed(3)),
			...h.data.html ? { html: h.data.html } : {},
			...h.data.locale ? { locale: h.data.locale } : {},
			...h.data.headingId ? {
				headingId: h.data.headingId,
				heading: h.data.heading
			} : {}
		};
		const key = `${h.data.slug}#${h.data.headingId ?? ""}`;
		const prev = best.get(key);
		if (!prev) {
			best.set(key, {
				hit,
				score: rank
			});
			continue;
		}
		if (rank > prev.score || !!locale && h.data.locale === locale && prev.hit.locale !== locale && rank >= prev.score) best.set(key, {
			hit,
			score: rank
		});
	}
	return [...best.values()].sort((a, b) => b.score - a.score).slice(0, limit).map((e) => e.hit);
}
function collapseSemantic(raw, locale) {
	const best = /* @__PURE__ */ new Map();
	for (const h of raw) {
		const hit = {
			slug: h.data.slug,
			title: h.data.title,
			section: h.data.section,
			score: Number(h.score.toFixed(3)),
			text: h.data.text,
			locale: h.data.locale,
			...h.data.headingId ? {
				headingId: h.data.headingId,
				heading: h.data.heading
			} : {}
		};
		const key = `${h.data.slug}#${h.data.headingId ?? ""}`;
		const prev = best.get(key);
		if (!prev) {
			best.set(key, {
				hit,
				score: h.score
			});
			continue;
		}
		if (h.score > prev.score || locale && h.data.locale === locale && prev.hit.locale !== locale && h.score >= prev.score - .04) best.set(key, {
			hit,
			score: h.score
		});
	}
	return [...best.values()].sort((a, b) => b.score - a.score).map((e) => e.hit);
}
/**
* Runtime search. With an embedder, runs HYBRID search: semantic vectors (over a
* precomputed index — no corpus embedding on the request thread) fused with BM25
* keyword via Reciprocal Rank Fusion, giving keyword precision plus semantic /
* cross-lingual recall. The model is warmed shortly after boot. WITHOUT an embedder,
* search falls back to the zero-dependency BM25 keyword index alone — so a site still
* deploys (and searches well) on Cloudflare Workers with no Workers AI. The embedder
* is the optional upgrade from keyword-only to hybrid.
*/
function createSearch(opts) {
	const tokenizer = opts.tokenizer ?? defaultTokenizer();
	if (!opts.embedder) {
		let index = null;
		const idx = () => index ??= buildKeywordIndex(opts.entries, tokenizer);
		return {
			getKb: async () => null,
			search: async (query, o) => {
				const topK = o?.topK ?? 8;
				return capPerPage(keywordSearch(idx(), query, topK * 3, void 0, o?.locale, o?.prefix, o?.navBoost), o?.maxPerPage ?? 3).slice(0, topK);
			},
			tokensOf: (query, locale) => idx().tokensOf(query, locale)
		};
	}
	const embedder = opts.embedder;
	let building = null;
	let keyword = null;
	const getKb = () => building ??= opts.indexBytes?.length ? Promise.resolve(Kb.load(opts.indexBytes, { embedder })) : indexKb(opts.entries, embedder);
	const getKeyword = () => keyword ??= buildKeywordIndex(opts.entries, tokenizer);
	if (opts.warm !== false) try {
		setTimeout(() => {
			getKb().then((kb) => kb.searchText("warm", { topK: 1 })).catch(() => {});
		}, 50);
	} catch {}
	const search = async (query, o) => {
		const topK = o?.topK ?? 8;
		const maxPerPage = o?.maxPerPage ?? 3;
		const depth = topK * 4;
		if (o?.mode === "keyword") return capPerPage(keywordSearch(getKeyword(), query, topK * 3, depth, o?.locale, o?.prefix, o?.navBoost), maxPerPage).slice(0, topK);
		const semantic = collapseSemantic(await (await getKb()).searchText(query, { topK: depth }), o?.locale);
		return capPerPage(rrfScored([{ hits: keywordSearch(getKeyword(), query, depth, depth, o?.locale) }, { hits: semantic }], (h) => `${h.slug}#${h.headingId ?? ""}`, { topK: topK * 3 }).map(({ item, score }) => ({
			...item,
			score: Number(score.toFixed(4))
		})), maxPerPage).slice(0, topK);
	};
	return {
		getKb,
		search,
		tokensOf: (query, locale) => getKeyword().tokensOf(query, locale)
	};
}
//#endregion
export { buildIndex, chunk, createSearch, defaultTokenizer, htmlToText, splitByHeadings };
