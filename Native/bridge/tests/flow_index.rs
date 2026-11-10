//! Runs the pure ownership cache tests without opening interfaces or changing system networking.
/// Includes the first-party adapter directly so its internal deterministic cache tests run here.
#[path = "../../../Patches/desktop-flow-index.rs"]
mod flow_index;
