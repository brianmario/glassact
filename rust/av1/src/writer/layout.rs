//! The deterministic tx-block layout of a record (av1g_layout) and the delta-q helpers.
use crate::blockinfo::*;
use crate::tables::*;
use crate::types::{Block, ERR_CAPACITY, ERR_INVALID, FrameParams, Txb};

/// A record's tx-block and coefficient counts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LayoutCounts {
    pub n_txb: u32,
    pub n_coeffs: u64,
}

fn depth(b: &Block) -> i32 {
    (b.tx_depth as i32).min(max_tx_depth(b.bsize as i32))
}

/// av1g_layout's first pass: the counts. Errors: [`ERR_INVALID`] (a bsize >= BLOCK_SIZES or a
/// block starting outside the coded area).
pub fn layout_counts(fp: &FrameParams, blocks: &[Block]) -> Result<LayoutCounts, i32> {
    let (mi_cols, mi_rows) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32));
    let mono = fp.monochrome != 0;
    let (mut n, mut nc) = (0u32, 0u64);
    for k in blocks {
        if k.bsize as i32 >= BLOCK_SIZES || k.mi_row as i32 >= mi_rows || k.mi_col as i32 >= mi_cols {
            return Err(ERR_INVALID);
        }
        for_each_txb(
            k.bsize as i32,
            k.mi_row as i32,
            k.mi_col as i32,
            depth(k),
            mono,
            mi_rows,
            mi_cols,
            |_, tx_sz, _, _, _, _| {
                n += 1;
                nc += tx_coeffs(tx_sz) as u64;
            },
        );
    }
    Ok(LayoutCounts { n_txb: n, n_coeffs: nc })
}

/// av1g_layout: fills `block_txb` (`blocks.len() + 1` entries) and `txb` (positions, sizes,
/// coefficient offsets; tx_type DCT_DCT, eob 0) and returns the counts. Errors: [`ERR_INVALID`] as
/// [`layout_counts`], [`ERR_CAPACITY`] when an array is too small (nothing written).
pub fn layout(fp: &FrameParams, blocks: &[Block], block_txb: &mut [u32], txb: &mut [Txb]) -> Result<LayoutCounts, i32> {
    let counts = layout_counts(fp, blocks)?;
    if block_txb.len() < blocks.len() + 1 || txb.len() < counts.n_txb as usize {
        return Err(ERR_CAPACITY);
    }
    let (mi_cols, mi_rows) = (mi_cols(fp.width as i32), mi_rows(fp.height as i32));
    let mono = fp.monochrome != 0;
    let (mut n, mut nc) = (0usize, 0u64);
    for (b, k) in blocks.iter().enumerate() {
        block_txb[b] = n as u32;
        for_each_txb(
            k.bsize as i32,
            k.mi_row as i32,
            k.mi_col as i32,
            depth(k),
            mono,
            mi_rows,
            mi_cols,
            |plane, tx_sz, x4, y4, _, _| {
                txb[n] = Txb {
                    coeff_off: nc as u32,
                    x4: x4 as u16,
                    y4: y4 as u16,
                    plane: plane as u8,
                    tx_size: tx_sz as u8,
                    tx_type: DCT_DCT as u8,
                    flags: 0,
                    eob: 0,
                    reserved: 0,
                };
                n += 1;
                nc += tx_coeffs(tx_sz) as u64;
            },
        );
    }
    block_txb[blocks.len()] = n as u32;
    Ok(counts)
}

/// av1g_legalize_sb_qindex: maps per-superblock target qindex values onto values the bitstream can
/// code with delta_q_res: the nearest v with v == base_q_idx (mod 2^delta_q_res) and 1 <= v <= 255.
/// Every legal value is reachable from every other one in one SB step, so engines can quantize with
/// the returned values directly. `legal` has `target`'s length.
pub fn legalize_sb_qindex(base_q_idx: i32, delta_q_res: i32, target: &[u8], legal: &mut [u8]) {
    let step = 1 << (delta_q_res & 3);
    for (l, &t) in legal.iter_mut().zip(target) {
        let d = t as i32 - base_q_idx;
        let k = if d >= 0 {
            (d + step / 2) / step
        } else {
            -((-d + step / 2) / step)
        }; // nearest multiple
        let mut v = base_q_idx + k * step;
        while v < 1 {
            v += step;
        }
        while v > 255 {
            v -= step;
        }
        *l = v as u8;
    }
}

/// av1g_apply_sb_qindex: copies a per-SB map (raster over the 64x64 SB grid, sbCols = (MiCols +
/// 15) >> 4) into the blocks' sb_qindex. Errors: [`ERR_INVALID`] when a block's SB is outside the
/// map (nothing written).
pub fn apply_sb_qindex(fp: &FrameParams, blocks: &mut [Block], sb_map: &[u8]) -> Result<(), i32> {
    let sb_cols = ((mi_cols(fp.width as i32) + 15) >> 4) as usize;
    let at = |k: &Block| (k.mi_row as usize >> 4) * sb_cols + (k.mi_col as usize >> 4);
    if blocks.iter().any(|k| at(k) >= sb_map.len()) {
        return Err(ERR_INVALID);
    }
    for k in blocks {
        k.sb_qindex = sb_map[at(k)];
    }
    Ok(())
}
