// SPDX-License-Identifier: GPL-3.0-or-later
// Motto fetching from jinrishici (gushici) API

import * as T from './util.js';

const span = (s, o) => `<span${Object.entries(o).reduce((p, [k, v]) => `${p} ${k}="${v}"`, '')}>${s}</span>`;
const wrap = (s, l) => s.replace(RegExp(`(.{1,${l}})`, 'gu'), '$1\n').trim();

const DEFAULT_MOTTO = {
  vtext: '千里之行\n始于足下',
  htext: '千里之行，始于足下。',
  seal: span('老子', { size: '45%' }),
};

// The API is remote input: it can return anything, including Pango markup.
// Every field is length-clamped (a megabyte-long "poem" is a layout DoS on its
// own) and markup-escaped before it can reach a Pango layout. Clamping happens
// on the RAW text so the plain-text transforms below still see real
// punctuation; escaping is the LAST step, because escaping first would let the
// regexes chew through the entities we just introduced.
const LIMITS = { content: 512, origin: 128, author: 64 };

function clean(value, max) {
  if (typeof value !== 'string') throw new Error('motto field is not a string');
  // Strip C0/C1 controls except newline; they render as boxes or confuse layout.
  let out = value.replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '');
  return out.length > max ? out.slice(0, max) : out;
}

export function fetch() {
  let cent = 45,
    size = { size: `${cent}%` };

  try {
    let json = T.request('POST', 'https://v1.jinrishici.com/all.json'),
      parsed = JSON.parse(json);
    if (!parsed || typeof parsed !== 'object') throw new Error('motto payload is not an object');

    // Raw, clamped, still unescaped — the transforms below need real characters.
    let content = clean(parsed.content, LIMITS.content),
      origin = clean(parsed.origin, LIMITS.origin),
      author = clean(parsed.author, LIMITS.author);
    if (!content) throw new Error('motto content is empty');

    let body = content.replace(/[，。：；？、！]/g, '\n').replace(/[《》""]/g, ''),
      height = Math.round(body.split('\n').reduce((p, x) => Math.max(p, x.length), 1) * 100 / cent),
      wrapped = wrap(`「${origin}`, height);

    // Escape everything that is about to be embedded in markup.
    let eBody = T.esc(body),
      eContent = T.esc(content),
      eTitle = T.esc(`「${origin}」`),
      eHead = `${T.esc(wrapped)}${T.esc('」')}`,
      eAuthor = T.esc(author);

    let title = span(eTitle, size),
      gap = span('\n', { line_height: '0.15' }),
      head = span(eHead, size),
      // No color markup here: draw.js's Seal.gen falls back to its own
      // vermillion stamp color and knock-out-renders the author glyphs,
      // matching upstream shuzhi's untouched online-fetch seal exactly.
      seal = span(eAuthor, size);
    return { vtext: `${eBody}${gap}${head}`, htext: `${eContent}${gap}${title}`, seal };
  } catch (e) {
    logError(e, 'Failed to fetch motto from jinrishici');
    return DEFAULT_MOTTO;
  }
}

export function get(motto, level) {
  let text = level ? (motto.htext || motto.text || '') : (motto.vtext || motto.text || '');
  return text ? [[text, motto.seal], null] : [null, null];
}
