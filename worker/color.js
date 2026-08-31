// SPDX-License-Identifier: GPL-3.0-or-later
// Color palette management for hypr-shuzhi

import {COLORS} from './colors.js';
import * as T from './util.js';

export const FG = {DARK: 0, LIGHT: 1, MODERATE: 2};
export const BgRGBA = {DARK: [0.14, 0.14, 0.14, 1], LIGHT: [0.9, 0.9, 0.9, 1]};
export const BgHex = T.vmap(BgRGBA, v => `#${v.map(x => Math.round(x * 255).toString(16).padStart(2, '0')).join('')}`);

export class Palette {
    constructor() {
        this.$color = COLORS.map(([rgb, name]) => [rgb.map(x => x / 255), name]);
        this.$index = this.$color.reduce((p, [rgb], i) => {
            let [r, g, b] = rgb.map(x => x > 0.04045 ? Math.pow((x + 0.055) / 1.055, 2.4) : x / 12.92);
            let l_raw = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
            let m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
            let s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
            let l = (0.2104542553 * l_raw + 0.7936177850 * m - 0.0040720468 * s) * 0.5 / 0.5693;
            if(l < 0.5) p[FG.DARK].push(i);
            else p[FG.LIGHT].push(i);
            if(l > 0.25 && l < 0.75) p[FG.MODERATE].push(i);
            return p;
        }, {[FG.DARK]: [], [FG.LIGHT]: [], [FG.MODERATE]: []});
    }

    random(style, alpha = 1) {
        let roll = this.$index[style];
        let [rgb, name] = this.$color[T.lot(roll) ?? 0];
        return {color: rgb.concat(alpha), name};
    }
}
