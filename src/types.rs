use std::collections::{HashMap, VecDeque};

/// Maximum supported price tick (16-bit; 65535 = 0xFFFF).
/// Reduced from the baseline's 200_000 for BRAM/FPGA feasibility.
pub const MAX_PRICE: usize = 65536; // array size; valid indices 0..=65535

/// Fixed batch size — must match BATCH_SIZE parameter in Verilog and C++.
pub const BATCH_SIZE: usize = 8;

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

/// A single resting or incoming limit order.
///
/// Type changes from the baseline:
///  - `id`    : u64 → u32  (sufficient for session; FPGA-friendly)
///  - `price` : usize → u32 (consistent; cast to usize only for array indexing)
///  - `qty`   : u64 → u32  (fits MAX_QTY = 65535; FPGA-friendly)
///  - `timestamp` : new field u32 — required for price-time priority
#[derive(Clone, Debug)]
pub struct Order {
    pub timestamp: u32,
    pub id:        u32,
    pub side:      Side,
    pub price:     u32,
    pub qty:       u32,
}

// ---------------------------------------------------------------------------
// Order book internals
// ---------------------------------------------------------------------------

/// A single price level: FIFO queue of order IDs + aggregate quantity.
#[derive(Clone)]
pub struct PriceLevel {
    pub total_qty: u64,
    pub orders:    VecDeque<u32>,
}

impl Default for PriceLevel {
    fn default() -> Self {
        Self {
            total_qty: 0,
            orders:    VecDeque::new(),
        }
    }
}

/// The persistent limit order book.
///
/// Structurally identical to the baseline (price-indexed arrays of FIFO queues
/// plus a flat order map), adapted for u32 types throughout.
pub struct OrderBook {
    /// Bid levels, indexed by price (0..MAX_PRICE).
    pub bids:   Vec<PriceLevel>,
    /// Ask levels, indexed by price (0..MAX_PRICE).
    pub asks:   Vec<PriceLevel>,
    /// Flat lookup: order_id → Order (live orders only).
    pub orders: HashMap<u32, Order>,
}

impl OrderBook {
    pub fn new() -> Self {
        Self {
            bids:   vec![PriceLevel::default(); MAX_PRICE],
            asks:   vec![PriceLevel::default(); MAX_PRICE],
            orders: HashMap::new(),
        }
    }
}
