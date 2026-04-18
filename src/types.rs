use std::collections::{HashMap, VecDeque};

pub const MAX_PRICE: usize = 200_000;

#[derive(Clone, Copy, Debug)]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Debug)]
pub struct Order {
    pub id: u64,
    pub price: usize,
    pub qty: u64,
    pub side: Side,
}

#[derive(Clone)]
pub struct PriceLevel {
    pub total_qty: u64,
    pub orders: VecDeque<u64>,
}

impl Default for PriceLevel {
    fn default() -> Self {
        Self {
            total_qty: 0,
            orders: VecDeque::new(),
        }
    }
}

pub struct OrderBook {
    pub bids: Vec<PriceLevel>,
    pub asks: Vec<PriceLevel>,
    pub orders: HashMap<u64, Order>,
}

impl OrderBook {
    pub fn new() -> Self {
        let bids = vec![PriceLevel::default(); MAX_PRICE];
        let asks = vec![PriceLevel::default(); MAX_PRICE];

        Self {
            bids,
            asks,
            orders: HashMap::with_capacity(10_000_000),
        }
    }
}
