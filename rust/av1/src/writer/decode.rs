//! The decoder's tile walk ([`crate::decoder`]): the parser's walk with the spec's symbol decoder,
//! reconstructing each block as it's parsed (prediction, the dequantized levels' inverse
//! transform) into the tile's planes, keeping no record.
use super::NoHook;
use super::Res;
use super::sink::DecSink;
#[cfg(test)]
pub(crate) use super::walk::ELIDED;
pub(crate) use super::walk::{Frame, TileBufs, TileState};
use super::walk::{ParseRec, Rec, walk_tile};

/// One thread's tile decoding state: the walk's (CDFs, contexts, scratch). Reused.
#[derive(Default)]
pub(crate) struct TileDecoder {
    st: Box<TileState>,
    pr: ParseRec,
}

impl TileDecoder {
    /// Sizes the walk's contexts for frames of `mi_cols` x `mi_rows`.
    pub fn setup(&mut self, mi_cols: i32, mi_rows: i32) {
        self.st.setup(mi_cols, mi_rows);
    }

    /// Decodes tile (tr, tc) of frame `f` from its payload `data` into `bufs` (sized for it here,
    /// its planes keeping the samples [`Frame::elide`] relies on).
    pub fn decode(&mut self, f: &Frame, bufs: &mut TileBufs, data: &[u8], tr: usize, tc: usize) -> Res<()> {
        bufs.setup(f, tr, tc, true);
        self.pr.decode = true;
        self.pr.n_blocks = 0;
        walk_tile::<DecSink, NoHook>(
            &mut self.st,
            DecSink::new(data),
            f,
            bufs,
            None,
            &mut (),
            None,
            &mut Rec::Parse(&mut self.pr),
            tr,
            tc,
        )?;
        Ok(())
    }
}
