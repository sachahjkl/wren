//! The one Rust static library of wren.exe: the libraries below are linked in, and their C functions (`wm_*`, `gt_*`)
//! are exported from this library. See native/Cargo.toml.

pub use wren_media;
#[cfg(feature = "text")]
pub use gt_text;
#[cfg(feature = "a11y")]
pub use gt_a11y;
