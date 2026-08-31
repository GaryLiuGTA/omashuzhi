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

export function fetch() {
  let cent = 45,
    size = { size: `${cent}%` };

  try {
    let json = T.request('POST', 'https://v1.jinrishici.com/all.json'),
      { content, origin, author } = JSON.parse(json),
      title = span(`「${origin}」`, size),
      gap = span('\n', { line_height: '0.15' }),
      body = content.replace(/[，。：；？、！]/g, '\n').replace(/[《》""]/g, ''),
      height = Math.round(body.split('\n').reduce((p, x) => Math.max(p, x.length), 1) * 100 / cent),
      head = span(`${wrap(`「${origin}`, height)}」`, size),
      // No color markup here: draw.js's Seal.gen falls back to its own
      // vermillion stamp color and knock-out-renders the author glyphs,
      // matching upstream shuzhi's untouched online-fetch seal exactly.
      seal = span(author, size);
    return { vtext: `${body}${gap}${head}`, htext: `${content}${gap}${title}`, seal };
  } catch (e) {
    logError(e, 'Failed to fetch motto from jinrishici');
    return DEFAULT_MOTTO;
  }
}

export function get(motto, level) {
  let text = level ? (motto.htext || motto.text || '') : (motto.vtext || motto.text || '');
  return text ? [[text, motto.seal], null] : [null, null];
}
