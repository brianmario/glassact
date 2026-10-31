//! Intra prediction (spec 7.11.2): the edges, the intra edge filter and upsampling, filter intra,
//! the per-pixel predictors and the whole-block predictors the encoders call, and CfL (7.11.5).
use super::*;

/// `AboveRow[-1]` / `LeftCol[-1]` live at index `EDGE_OFF - 1` of an [`Edge`].
pub const EDGE_OFF: usize = 16;
pub const EDGE_LEN: usize = EDGE_OFF + 2 * 64 + 16;
/// An AboveRow or LeftCol array: element k (k >= -2) at index `EDGE_OFF + k`.
pub type Edge = [u8; EDGE_LEN];
const O: usize = EDGE_OFF;

#[inline(always)]
fn at(e: &Edge, k: i32) -> i32 {
    e[(O as i32 + k) as usize] as i32
}

/// Builds AboveRow[-1 .. w+h-1] and LeftCol[-1 .. w+h-1] (spec 7.11.2). `plane` starts at sample
/// (0, 0) of the plane; (x, y) is the tx block's top-left sample.
pub fn build_edges(
    plane: &[u8],
    stride: usize,
    x: i32,
    y: i32,
    log2w: i32,
    log2h: i32,
    have_left: bool,
    have_above: bool,
    have_above_right: bool,
    have_below_left: bool,
    max_x: i32,
    max_y: i32,
    above: &mut Edge,
    left: &mut Edge,
) {
    let (w, h) = (1i32 << log2w, 1i32 << log2h);
    let n = (w + h) as usize;
    let (xu, yu) = (x as usize, y as usize);
    if !have_above && have_left {
        above[O..O + n].fill(plane[yu * stride + xu - 1]);
    } else if !have_above && !have_left {
        above[O..O + n].fill((1 << 7) - 1);
    } else {
        let above_limit = (x + if have_above_right { 2 * w } else { w } - 1).min(max_x);
        let row = &plane[(yu - 1) * stride..];
        // AboveRow[i] = CurrFrame[y - 1][Min(aboveLimit, x + i)]
        let k = (above_limit - x + 1).clamp(0, n as i32) as usize;
        above[O..O + k].copy_from_slice(&row[xu..xu + k]);
        let last = row[above_limit as usize];
        above[O + k..O + n].fill(last);
    }
    if !have_left && have_above {
        left[O..O + n].fill(plane[(yu - 1) * stride + xu]);
    } else if !have_left && !have_above {
        left[O..O + n].fill((1 << 7) + 1);
    } else {
        let left_limit = (y + if have_below_left { 2 * h } else { h } - 1).min(max_y);
        for i in 0..n {
            let yy = (y + i as i32).min(left_limit) as usize;
            left[O + i] = plane[yy * stride + xu - 1];
        }
    }
    let c = if have_above && have_left {
        plane[(yu - 1) * stride + xu - 1]
    } else if have_above {
        plane[(yu - 1) * stride + xu]
    } else if have_left {
        plane[yu * stride + xu - 1]
    } else {
        1 << 7
    };
    above[O - 1] = c;
    left[O - 1] = c;
}

#[inline]
pub fn is_directional(mode: i32) -> bool {
    (V_PRED..=D67_PRED).contains(&mode)
}

#[inline]
pub fn sm_weights(log2: i32) -> &'static [u8] {
    match log2 {
        2 => &Sm_Weights_Tx_4x4,
        3 => &Sm_Weights_Tx_8x8,
        4 => &Sm_Weights_Tx_16x16,
        5 => &Sm_Weights_Tx_32x32,
        _ => &Sm_Weights_Tx_64x64,
    }
}

/// The DC value (spec 7.11.2.5).
pub fn dc_value(above: &Edge, left: &Edge, have_left: bool, have_above: bool, log2w: i32, log2h: i32) -> i32 {
    let (w, h) = (1usize << log2w, 1usize << log2h);
    let sum = |e: &Edge, n: usize| e[O..O + n].iter().map(|&v| v as i32).sum::<i32>();
    if have_left && have_above {
        let s = sum(left, h) + sum(above, w) + ((w + h) as i32 >> 1);
        return s / (w + h) as i32;
    }
    if have_left {
        return clip1((sum(left, h) + (h as i32 >> 1)) >> log2h);
    }
    if have_above {
        return clip1((sum(above, w) + (w as i32 >> 1)) >> log2w);
    }
    1 << 7
}

/// One predicted sample of a non-DC mode (spec 7.11.2.2 / 4 / 6), (i, j) = (row, col). `p_angle` is
/// only used by directional modes; `up_a` / `up_l` are the edge upsampling flags (0 unless
/// [`edge_prepare`] upsampled the arrays).
pub fn pred_pixel_up(
    mode: i32,
    p_angle: i32,
    i: i32,
    j: i32,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    up_a: i32,
    up_l: i32,
) -> i32 {
    let (w, h) = (1i32 << log2w, 1i32 << log2h);
    if is_directional(mode) {
        if p_angle == 90 {
            return at(above, j);
        }
        if p_angle == 180 {
            return at(left, i);
        }
        if p_angle < 90 {
            let dx = Dr_Intra_Derivative[p_angle as usize] as i32;
            let idx = (i + 1) * dx;
            let base = (idx >> (6 - up_a)) + (j << up_a);
            let shift = ((idx << up_a) >> 1) & 0x1F;
            let max_base_x = (w + h - 1) << up_a;
            if base < max_base_x {
                return round2(at(above, base) * (32 - shift) + at(above, base + 1) * shift, 5);
            }
            return at(above, max_base_x);
        }
        if p_angle < 180 {
            let dx = Dr_Intra_Derivative[(180 - p_angle) as usize] as i32;
            let dy = Dr_Intra_Derivative[(p_angle - 90) as usize] as i32;
            let idx = (j << 6) - (i + 1) * dx;
            let base = idx >> (6 - up_a);
            if base >= -(1 << up_a) {
                let shift = ((idx * (1 << up_a)) >> 1) & 0x1F;
                return round2(at(above, base) * (32 - shift) + at(above, base + 1) * shift, 5);
            }
            let idx = (i << 6) - (j + 1) * dy;
            let base = idx >> (6 - up_l);
            let shift = ((idx * (1 << up_l)) >> 1) & 0x1F;
            return round2(at(left, base) * (32 - shift) + at(left, base + 1) * shift, 5);
        }
        let dy = Dr_Intra_Derivative[(270 - p_angle) as usize] as i32;
        let idx = (j + 1) * dy;
        let base = (idx >> (6 - up_l)) + (i << up_l);
        let shift = ((idx << up_l) >> 1) & 0x1F;
        return round2(at(left, base) * (32 - shift) + at(left, base + 1) * shift, 5);
    }
    if mode == SMOOTH_PRED {
        let (wx, wy) = (sm_weights(log2w), sm_weights(log2h));
        let (wxj, wyi) = (wx[j as usize] as i32, wy[i as usize] as i32);
        let s = wyi * at(above, j) + (256 - wyi) * at(left, h - 1) + wxj * at(left, i) + (256 - wxj) * at(above, w - 1);
        return round2(s, 9);
    }
    if mode == SMOOTH_V_PRED {
        let wyi = sm_weights(log2h)[i as usize] as i32;
        return round2(wyi * at(above, j) + (256 - wyi) * at(left, h - 1), 8);
    }
    if mode == SMOOTH_H_PRED {
        let wxj = sm_weights(log2w)[j as usize] as i32;
        return round2(wxj * at(left, i) + (256 - wxj) * at(above, w - 1), 8);
    }
    // PAETH (basic intra prediction process)
    let (a, l, tl) = (at(above, j), at(left, i), at(above, -1));
    let base = a + l - tl;
    let (p_left, p_top, p_top_left) = ((base - l).abs(), (base - a).abs(), (base - tl).abs());
    if p_left <= p_top && p_left <= p_top_left {
        l
    } else if p_top <= p_top_left {
        a
    } else {
        tl
    }
}
pub fn pred_pixel(mode: i32, p_angle: i32, i: i32, j: i32, log2w: i32, log2h: i32, above: &Edge, left: &Edge) -> i32 {
    pred_pixel_up(mode, p_angle, i, j, log2w, log2h, above, left, 0, 0)
}

// ---- intra edge filter + upsampling (spec 7.11.2.4 step 4, 7.11.2.7 .. 7.11.2.12) ----

/// 7.11.2.9
pub fn edge_strength(w: i32, h: i32, filter_type: i32, delta: i32) -> i32 {
    let (d, blk_wh) = (delta.abs(), w + h);
    let mut strength = 0;
    if filter_type == 0 {
        if blk_wh <= 8 {
            if d >= 56 {
                strength = 1;
            }
        } else if blk_wh <= 16 {
            if d >= 40 {
                strength = 1;
            }
        } else if blk_wh <= 24 {
            if d >= 8 {
                strength = 1;
            }
            if d >= 16 {
                strength = 2;
            }
            if d >= 32 {
                strength = 3;
            }
        } else if blk_wh <= 32 {
            strength = 1;
            if d >= 4 {
                strength = 2;
            }
            if d >= 32 {
                strength = 3;
            }
        } else {
            strength = 3;
        }
    } else if blk_wh <= 8 {
        if d >= 40 {
            strength = 1;
        }
        if d >= 64 {
            strength = 2;
        }
    } else if blk_wh <= 16 {
        if d >= 20 {
            strength = 1;
        }
        if d >= 48 {
            strength = 2;
        }
    } else if blk_wh <= 24 {
        if d >= 4 {
            strength = 3;
        }
    } else {
        strength = 3;
    }
    strength
}
/// 7.11.2.10
pub fn edge_use_upsample(w: i32, h: i32, filter_type: i32, delta: i32) -> bool {
    let (d, blk_wh) = (delta.abs(), w + h);
    if d <= 0 || d >= 40 {
        return false;
    }
    if filter_type == 0 { blk_wh <= 16 } else { blk_wh <= 8 }
}
/// 7.11.2.12: filters buf[k] for k = 0 .. sz-2 (edge[i] = buf[i - 1]).
pub fn edge_filter(buf: &mut Edge, sz: i32, strength: i32) {
    if strength == 0 {
        return;
    }
    let sz = sz as usize;
    let mut edge = [0u8; 160];
    edge[..sz].copy_from_slice(&buf[O - 1..O - 1 + sz]);
    let k = &Intra_Edge_Kernel[(strength - 1) as usize];
    let last = sz - 1;
    for i in 1..sz {
        let mut s = 0i32;
        for (j, &kj) in k.iter().enumerate() {
            let p = (i + j).saturating_sub(2).min(last);
            s += kj as i32 * edge[p] as i32;
        }
        buf[O + i - 1] = ((s + 8) >> 4) as u8;
    }
}
/// 7.11.2.11: upsamples buf[-1 .. numPx-1] into buf[-2 .. 2*numPx-2].
pub fn edge_upsample(buf: &mut Edge, num_px: i32) {
    let n = num_px as usize;
    let mut dup = [0u8; 40];
    dup[0] = buf[O - 1];
    dup[1..n + 2].copy_from_slice(&buf[O - 1..O + n]);
    dup[n + 2] = buf[O + n - 1];
    buf[O - 2] = dup[0];
    for i in 0..n {
        let s = -(dup[i] as i32) + 9 * dup[i + 1] as i32 + 9 * dup[i + 2] as i32 - dup[i + 3] as i32;
        buf[O + 2 * i - 1] = clip1(round2(s, 4)) as u8;
        buf[O + 2 * i] = dup[i + 2];
    }
}

/// Edge preprocessing of a directional prediction when enable_intra_edge_filter = 1: the corner
/// filter, the above / left edge filters, upsampling. `above` / `left` change in place; returns the
/// upsampling flags (upA, upL). `filter_type`: 1 if the above or left block uses a SMOOTH* mode
/// (spec get_filter_type, [`crate::blockinfo::get_filter_type`]). (x, y, max_x, max_y) as for
/// [`build_edges`].
pub fn edge_prepare(
    p_angle: i32,
    log2w: i32,
    log2h: i32,
    filter_type: i32,
    have_left: bool,
    have_above: bool,
    x: i32,
    y: i32,
    max_x: i32,
    max_y: i32,
    above: &mut Edge,
    left: &mut Edge,
) -> (i32, i32) {
    let (w, h) = (1i32 << log2w, 1i32 << log2h);
    if p_angle != 90 && p_angle != 180 {
        if p_angle > 90 && p_angle < 180 && (w + h) >= 24 {
            let c = round2(left[O] as i32 * 5 + above[O - 1] as i32 * 6 + above[O] as i32 * 5, 4) as u8;
            left[O - 1] = c;
            above[O - 1] = c;
        }
        if have_above {
            let strength = edge_strength(w, h, filter_type, p_angle - 90);
            let num_px = w.min(max_x - x + 1) + if p_angle < 90 { h } else { 0 } + 1;
            edge_filter(above, num_px, strength);
        }
        if have_left {
            let strength = edge_strength(w, h, filter_type, p_angle - 180);
            let num_px = h.min(max_y - y + 1) + if p_angle > 180 { w } else { 0 } + 1;
            edge_filter(left, num_px, strength);
        }
    }
    let up_a = edge_use_upsample(w, h, filter_type, p_angle - 90);
    if up_a {
        edge_upsample(above, w + if p_angle < 90 { h } else { 0 });
    }
    let up_l = edge_use_upsample(w, h, filter_type, p_angle - 180);
    if up_l {
        edge_upsample(left, h + if p_angle > 180 { w } else { 0 });
    }
    (up_a as i32, up_l as i32)
}

/// Recursive (filter-intra) prediction, spec 7.11.2.3, mode = filter_intra_mode 0..4. `dst` doubles
/// as the pred array (row stride).
pub fn predict_filter_intra(
    mode: i32,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    dst: &mut [u8],
    stride: usize,
) {
    let (w4, h2) = ((1usize << log2w) >> 2, (1usize << log2h) >> 1);
    let taps = &Intra_Filter_Taps[mode as usize];
    for i2 in 0..h2 {
        for j4 in 0..w4 {
            let mut p = [0i32; 7];
            for (i, v) in p.iter_mut().enumerate().take(5) {
                *v = if i2 == 0 {
                    above[O + (j4 << 2) + i - 1] as i32
                } else if j4 == 0 && i == 0 {
                    left[O + (i2 << 1) - 1] as i32
                } else {
                    dst[((i2 << 1) - 1) * stride + (j4 << 2) + i - 1] as i32
                };
            }
            for i in 5..7 {
                p[i] = if j4 == 0 {
                    left[O + (i2 << 1) + i - 5] as i32
                } else {
                    dst[((i2 << 1) + i - 5) * stride + (j4 << 2) - 1] as i32
                };
            }
            for i1 in 0..2 {
                for j1 in 0..4 {
                    let t = &taps[(i1 << 2) + j1];
                    let pr: i32 = (0..7).map(|i| t[i] as i32 * p[i]).sum();
                    dst[((i2 << 1) + i1) * stride + (j4 << 2) + j1] = clip1(round2signed(pr, 4)) as u8;
                }
            }
        }
    }
}

/// The C structure: one [`pred_pixel_up`] call per sample (the reference the block predictors are
/// tested against).
pub fn predict_intra_ref(
    mode: i32,
    angle_delta: i32,
    have_left: bool,
    have_above: bool,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    dst: &mut [u8],
    stride: usize,
) {
    let (w, h) = (1usize << log2w, 1usize << log2h);
    if mode == DC_PRED {
        let v = dc_value(above, left, have_left, have_above, log2w, log2h) as u8;
        for i in 0..h {
            dst[i * stride..i * stride + w].fill(v);
        }
        return;
    }
    let p_angle = if is_directional(mode) {
        Mode_To_Angle[mode as usize] as i32 + angle_delta * ANGLE_STEP
    } else {
        0
    };
    for i in 0..h {
        for j in 0..w {
            dst[i * stride + j] = pred_pixel(mode, p_angle, i as i32, j as i32, log2w, log2h, above, left) as u8;
        }
    }
}

/// Predicts a whole tx block into `dst` (row stride), edge filter off. `mode` is the effective mode
/// (DC for CfL), `angle_delta` is AngleDeltaY / UV.
pub fn predict_intra(
    mode: i32,
    angle_delta: i32,
    have_left: bool,
    have_above: bool,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    dst: &mut [u8],
    stride: usize,
) {
    if mode == DC_PRED {
        let (w, h) = (1usize << log2w, 1usize << log2h);
        let v = dc_value(above, left, have_left, have_above, log2w, log2h) as u8;
        fill_rows(dst, stride, w, h, |_| v);
        return;
    }
    if is_directional(mode) {
        let p_angle = Mode_To_Angle[mode as usize] as i32 + angle_delta * ANGLE_STEP;
        directional(p_angle, log2w, log2h, above, left, 0, 0, dst, stride);
        return;
    }
    nondirectional(mode, log2w, log2h, above, left, dst, stride);
}

/// Full intra prediction of one tx block (spec 7.11.2): filter intra (`filter_intra_mode` >= 0, luma
/// only), directional with the optional edge filter / upsampling (`edge_filter` =
/// enable_intra_edge_filter; `above` / `left` change), or the other modes.
pub fn predict_intra_ex(
    mode: i32,
    angle_delta: i32,
    filter_intra_mode: i32,
    edge_filter: bool,
    filter_type: i32,
    have_left: bool,
    have_above: bool,
    log2w: i32,
    log2h: i32,
    x: i32,
    y: i32,
    max_x: i32,
    max_y: i32,
    above: &mut Edge,
    left: &mut Edge,
    dst: &mut [u8],
    stride: usize,
) {
    if filter_intra_mode >= 0 {
        predict_filter_intra(filter_intra_mode, log2w, log2h, above, left, dst, stride);
        return;
    }
    if is_directional(mode) {
        let p_angle = Mode_To_Angle[mode as usize] as i32 + angle_delta * ANGLE_STEP;
        let (mut up_a, mut up_l) = (0, 0);
        if edge_filter {
            (up_a, up_l) = edge_prepare(
                p_angle,
                log2w,
                log2h,
                filter_type,
                have_left,
                have_above,
                x,
                y,
                max_x,
                max_y,
                above,
                left,
            );
        }
        directional(p_angle, log2w, log2h, above, left, up_a, up_l, dst, stride);
        return;
    }
    predict_intra(
        mode,
        angle_delta,
        have_left,
        have_above,
        log2w,
        log2h,
        above,
        left,
        dst,
        stride,
    );
}

/// The ref version of [`predict_intra_ex`] (per-pixel), for tests.
pub fn predict_intra_ex_ref(
    mode: i32,
    angle_delta: i32,
    filter_intra_mode: i32,
    edge_filter: bool,
    filter_type: i32,
    have_left: bool,
    have_above: bool,
    log2w: i32,
    log2h: i32,
    x: i32,
    y: i32,
    max_x: i32,
    max_y: i32,
    above: &mut Edge,
    left: &mut Edge,
    dst: &mut [u8],
    stride: usize,
) {
    if filter_intra_mode >= 0 {
        predict_filter_intra(filter_intra_mode, log2w, log2h, above, left, dst, stride);
        return;
    }
    if is_directional(mode) {
        let (w, h) = (1i32 << log2w, 1i32 << log2h);
        let p_angle = Mode_To_Angle[mode as usize] as i32 + angle_delta * ANGLE_STEP;
        let (mut up_a, mut up_l) = (0, 0);
        if edge_filter {
            (up_a, up_l) = edge_prepare(
                p_angle,
                log2w,
                log2h,
                filter_type,
                have_left,
                have_above,
                x,
                y,
                max_x,
                max_y,
                above,
                left,
            );
        }
        for i in 0..h {
            for j in 0..w {
                dst[i as usize * stride + j as usize] =
                    pred_pixel_up(mode, p_angle, i, j, log2w, log2h, above, left, up_a, up_l) as u8;
            }
        }
        return;
    }
    predict_intra_ref(
        mode,
        angle_delta,
        have_left,
        have_above,
        log2w,
        log2h,
        above,
        left,
        dst,
        stride,
    );
}

// ---- whole-block predictors ----

/// One row of a zone-1 style interpolation: d[j] = Round2(e[j] * (32 - shift) + e[j + 1] * shift, 5)
/// for j < d.len() (e has d.len() + 1 samples).
#[inline(always)]
pub(crate) fn interp_row(d: &mut [u8], e: &[u8], shift: i32) {
    #[cfg(target_arch = "aarch64")]
    {
        super::pred_neon::interp_row(d, e, shift);
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        interp_row_scalar(d, e, shift);
    }
}
#[inline(always)]
pub(crate) fn interp_row_scalar(d: &mut [u8], e: &[u8], shift: i32) {
    let e = &e[..d.len() + 1];
    let (a, b) = (32 - shift as u16, shift as u16);
    for (j, p) in d.iter_mut().enumerate() {
        *p = ((e[j] as u16 * a + e[j + 1] as u16 * b + 16) >> 5) as u8;
    }
}

/// Calls `f` with a zeroed scratch buffer of n <= 4096 bytes (small blocks don't pay for 4 KiB).
#[inline(always)]
fn scratch<R>(n: usize, f: impl FnOnce(&mut [u8]) -> R) -> R {
    if n <= 256 {
        f(&mut [0u8; 256][..n])
    } else if n <= 1024 {
        f(&mut [0u8; 1024][..n])
    } else {
        f(&mut [0u8; 4096][..n])
    }
}

/// Row i of the w x h block = [v(i); w], with constant-width stores.
#[inline(always)]
fn fill_rows(dst: &mut [u8], stride: usize, w: usize, h: usize, v: impl Fn(usize) -> u8) {
    #[inline(always)]
    fn go<const W: usize>(dst: &mut [u8], stride: usize, h: usize, v: impl Fn(usize) -> u8) {
        for i in 0..h {
            let d: &mut [u8; W] = (&mut dst[i * stride..i * stride + W]).try_into().unwrap();
            *d = [v(i); W];
        }
    }
    match w {
        4 => go::<4>(dst, stride, h, v),
        8 => go::<8>(dst, stride, h, v),
        16 => go::<16>(dst, stride, h, v),
        32 => go::<32>(dst, stride, h, v),
        _ => go::<64>(dst, stride, h, v),
    }
}
/// Every row of the w x h block = src[..w].
#[inline(always)]
fn copy_rows(dst: &mut [u8], stride: usize, w: usize, h: usize, src: &[u8]) {
    #[inline(always)]
    fn go<const W: usize>(dst: &mut [u8], stride: usize, h: usize, src: &[u8]) {
        let s: [u8; W] = src[..W].try_into().unwrap();
        for i in 0..h {
            let d: &mut [u8; W] = (&mut dst[i * stride..i * stride + W]).try_into().unwrap();
            *d = s;
        }
    }
    match w {
        4 => go::<4>(dst, stride, h, src),
        8 => go::<8>(dst, stride, h, src),
        16 => go::<16>(dst, stride, h, src),
        32 => go::<32>(dst, stride, h, src),
        _ => go::<64>(dst, stride, h, src),
    }
}

/// d[k] = Round2(e[b] * (32 - shift) + e[b + 1] * shift, 5) with b = base + 2k (upsampled edges).
#[inline(always)]
fn interp_row_up(d: &mut [u8], e: &Edge, base: usize, shift: i32) {
    for (k, p) in d.iter_mut().enumerate() {
        let b = base + 2 * k;
        *p = round2(e[b] as i32 * (32 - shift) + e[b + 1] as i32 * shift, 5) as u8;
    }
}

/// Directional prediction of a whole block (spec 7.11.2.4), the same samples as [`pred_pixel_up`]:
/// row by row from AboveRow, column by column (through a transposed scratch block) from LeftCol.
pub fn directional(
    p_angle: i32,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    up_a: i32,
    up_l: i32,
    dst: &mut [u8],
    stride: usize,
) {
    let (w, h) = (1usize << log2w, 1usize << log2h);
    if p_angle == 90 {
        copy_rows(dst, stride, w, h, &above[O..]);
        return;
    }
    if p_angle == 180 {
        fill_rows(dst, stride, w, h, |i| left[O + i]);
        return;
    }
    if p_angle < 90 {
        let dx = Dr_Intra_Derivative[p_angle as usize] as i32;
        let max_base_x = ((w + h - 1) << up_a) as i32;
        let fill = above[(O as i32 + max_base_x) as usize];
        for i in 0..h {
            let idx = (i as i32 + 1) * dx;
            let base = idx >> (6 - up_a);
            let shift = ((idx << up_a) >> 1) & 0x1F;
            let d = &mut dst[i * stride..i * stride + w];
            // base + (j << upA) < maxBaseX
            let n = if base >= max_base_x {
                0
            } else {
                (((max_base_x - base - 1) >> up_a) + 1).min(w as i32) as usize
            };
            if n > 0 {
                if up_a == 0 {
                    interp_row(&mut d[..n], &above[O + base as usize..], shift);
                } else {
                    interp_row_up(&mut d[..n], above, O + base as usize, shift);
                }
            }
            d[n..].fill(fill);
        }
        return;
    }
    if p_angle < 180 {
        let dx = Dr_Intra_Derivative[(180 - p_angle) as usize] as i32;
        let dy = Dr_Intra_Derivative[(p_angle - 90) as usize] as i32;
        // row i takes AboveRow for j >= j0(i): base(j) = base0(i) + (j << upA) >= -(1 << upA), where
        // ((j << 6) - (i + 1) * dx) >> (6 - upA) = base0(i) + (j << upA); j0 grows with i
        let lim = -(1 << up_a);
        let mut j0 = [0usize; 64];
        for (i, v) in j0.iter_mut().enumerate().take(h) {
            let base0 = (-(i as i32 + 1) * dx) >> (6 - up_a);
            *v = if base0 >= lim {
                0
            } else {
                (((lim - base0) + (1 << up_a) - 1) >> up_a) as usize
            }
            .min(w);
        }
        let jmax = j0[h - 1];
        if jmax > 0 {
            // column j < jmax from LeftCol for rows i >= i_j (the first row with j0(i) > j):
            // ((i << 6) - (j + 1) * dy) >> (6 - upL) = (i << upL) + base0(j)
            // with w, h multiples of 8 the scratch goes to dst whole (8x8 transposes): samples left of
            // j0(i) are the ones wanted, the rest is overwritten by the AboveRow part below
            let whole = w.is_multiple_of(8) && h.is_multiple_of(8);
            let jr = if whole { jmax.next_multiple_of(8) } else { jmax };
            scratch(jr * h, |tmp| {
                let mut i_j = 0;
                for j in 0..jmax {
                    while j0[i_j] <= j {
                        i_j += 1;
                    }
                    let k = -(j as i32 + 1) * dy;
                    let base0 = k >> (6 - up_l);
                    let shift = ((k * (1 << up_l)) >> 1) & 0x1F;
                    let b = (O as i32 + base0 + ((i_j as i32) << up_l)) as usize;
                    let t = &mut tmp[j * h + i_j..(j + 1) * h];
                    if up_l == 0 {
                        interp_row(t, &left[b..], shift);
                    } else {
                        interp_row_up(t, left, b, shift);
                    }
                }
                if whole {
                    transpose_into(tmp, h, jr, dst, stride);
                } else {
                    for i in 0..h {
                        let d = &mut dst[i * stride..i * stride + j0[i]];
                        for (j, p) in d.iter_mut().enumerate() {
                            *p = tmp[j * h + i];
                        }
                    }
                }
            });
        }
        for i in 0..h {
            if j0[i] == w {
                continue;
            }
            let k = -(i as i32 + 1) * dx;
            let base0 = k >> (6 - up_a);
            let shift = ((k * (1 << up_a)) >> 1) & 0x1F;
            let b0 = (O as i32 + base0 + ((j0[i] as i32) << up_a)) as usize;
            let d = &mut dst[i * stride + j0[i]..i * stride + w];
            if up_a == 0 {
                interp_row(d, &above[b0..], shift);
            } else {
                interp_row_up(d, above, b0, shift);
            }
        }
        return;
    }
    // pAngle > 180: column j interpolates LeftCol; computed as rows of the transpose
    let dy = Dr_Intra_Derivative[(270 - p_angle) as usize] as i32;
    scratch(w * h, |tmp| {
        for j in 0..w {
            let idx = (j as i32 + 1) * dy;
            let base = idx >> (6 - up_l);
            let shift = ((idx << up_l) >> 1) & 0x1F;
            let t = &mut tmp[j * h..(j + 1) * h];
            if up_l == 0 {
                interp_row(t, &left[O + base as usize..], shift);
            } else {
                interp_row_up(t, left, O + base as usize, shift);
            }
        }
        transpose_into(tmp, h, w, dst, stride);
    });
}

/// dst[i][j] = src[j * h + i] for a w x h block (src holds w rows of h).
#[inline]
fn transpose_into(src: &[u8], h: usize, w: usize, dst: &mut [u8], stride: usize) {
    #[cfg(target_arch = "aarch64")]
    {
        if w.is_multiple_of(8) && h.is_multiple_of(8) {
            super::pred_neon::transpose8_into(src, h, w, dst, stride);
            return;
        }
    }
    for i in 0..h {
        let d = &mut dst[i * stride..i * stride + w];
        for (j, p) in d.iter_mut().enumerate() {
            *p = src[j * h + i];
        }
    }
}

/// SMOOTH*, PAETH: whole block.
pub fn nondirectional(mode: i32, log2w: i32, log2h: i32, above: &Edge, left: &Edge, dst: &mut [u8], stride: usize) {
    #[cfg(target_arch = "aarch64")]
    {
        super::pred_neon::nondirectional(mode, log2w, log2h, above, left, dst, stride);
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        nondirectional_scalar(mode, log2w, log2h, above, left, dst, stride);
    }
}

pub fn nondirectional_scalar(
    mode: i32,
    log2w: i32,
    log2h: i32,
    above: &Edge,
    left: &Edge,
    dst: &mut [u8],
    stride: usize,
) {
    let (w, h) = (1usize << log2w, 1usize << log2h);
    let a = &above[O..O + w];
    let l = &left[O..O + h];
    match mode {
        SMOOTH_PRED => {
            let (wx, wy) = (&sm_weights(log2w)[..w], &sm_weights(log2h)[..h]);
            let (bl, tr) = (l[h - 1] as u32, a[w - 1] as u32);
            for i in 0..h {
                let (wyi, li) = (wy[i] as u32, l[i] as u32);
                let row = (256 - wyi) * bl;
                let d = &mut dst[i * stride..i * stride + w];
                for j in 0..w {
                    let wxj = wx[j] as u32;
                    let s = wyi * a[j] as u32 + row + wxj * li + (256 - wxj) * tr;
                    d[j] = ((s + 256) >> 9) as u8;
                }
            }
        }
        SMOOTH_V_PRED => {
            let wy = &sm_weights(log2h)[..h];
            let bl = l[h - 1] as u32;
            for i in 0..h {
                let wyi = wy[i] as u32;
                let d = &mut dst[i * stride..i * stride + w];
                for j in 0..w {
                    d[j] = ((wyi * a[j] as u32 + (256 - wyi) * bl + 128) >> 8) as u8;
                }
            }
        }
        SMOOTH_H_PRED => {
            let wx = &sm_weights(log2w)[..w];
            let tr = a[w - 1] as u32;
            for i in 0..h {
                let li = l[i] as u32;
                let d = &mut dst[i * stride..i * stride + w];
                for j in 0..w {
                    let wxj = wx[j] as u32;
                    d[j] = ((wxj * li + (256 - wxj) * tr + 128) >> 8) as u8;
                }
            }
        }
        _ => {
            // PAETH
            let tl = above[O - 1] as i16;
            for i in 0..h {
                let li = l[i] as i16;
                let p_top = (li - tl).abs();
                let d = &mut dst[i * stride..i * stride + w];
                for j in 0..w {
                    let aj = a[j] as i16;
                    let p_left = (aj - tl).abs();
                    let p_tl = (aj + li - 2 * tl).abs();
                    d[j] = if p_left <= p_top && p_left <= p_tl {
                        li as u8
                    } else if p_top <= p_tl {
                        aj as u8
                    } else {
                        tl as u8
                    };
                }
            }
        }
    }
}

/// Chroma from luma (spec 7.11.5). `chroma` / `luma` start at sample (0, 0) of their planes;
/// (start_x, start_y) are in chroma samples; the DC prediction must already be in `chroma`.
pub fn cfl_predict(
    chroma: &mut [u8],
    cstride: usize,
    luma: &[u8],
    lstride: usize,
    start_x: i32,
    start_y: i32,
    tx_sz: i32,
    sub_x: i32,
    sub_y: i32,
    max_luma_w: i32,
    max_luma_h: i32,
    alpha: i32,
) {
    let log2w = Tx_Width_Log2[tx_sz as usize] as i32;
    let log2h = Tx_Height_Log2[tx_sz as usize] as i32;
    let (w, h) = (1usize << log2w, 1usize << log2h);
    // the subsampled luma, << 3
    let mut ls = [0i32; 32 * 32];
    let mut sum = 0i32;
    for i in 0..h {
        let luma_y = (((start_y + i as i32) << sub_y).min(max_luma_h - (1 << sub_y))) as usize;
        for j in 0..w {
            let luma_x = (((start_x + j as i32) << sub_x).min(max_luma_w - (1 << sub_x))) as usize;
            let mut t = 0i32;
            for dy in 0..=sub_y as usize {
                let r = &luma[(luma_y + dy) * lstride + luma_x..];
                for &v in &r[..=sub_x as usize] {
                    t += v as i32;
                }
            }
            let v = t << (3 - sub_x - sub_y);
            ls[i * w + j] = v;
            sum += v;
        }
    }
    let avg = round2(sum, log2w + log2h);
    for i in 0..h {
        let row = &mut chroma[(start_y as usize + i) * cstride + start_x as usize..][..w];
        for (j, p) in row.iter_mut().enumerate() {
            let scaled = round2signed(alpha * (ls[i * w + j] - avg), 6);
            *p = clip1(*p as i32 + scaled) as u8;
        }
    }
}
