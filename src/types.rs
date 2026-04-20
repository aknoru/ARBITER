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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_price_level_default_is_empty() {
        let level = PriceLevel::default();
        assert_eq!(level.total_qty, 0);
        assert!(level.orders.is_empty());
    }

    #[test]
    fn test_orderbook_new_allocates_all_price_levels() {
        let book = OrderBook::new();
        assert_eq!(book.bids.len(), MAX_PRICE);
        assert_eq!(book.asks.len(), MAX_PRICE);
    }

    #[test]
    fn test_orderbook_new_all_levels_start_empty() {
        let book = OrderBook::new();
        assert!(book.bids.iter().all(|l| l.total_qty == 0 && l.orders.is_empty()));
        assert!(book.asks.iter().all(|l| l.total_qty == 0 && l.orders.is_empty()));
    }

    #[test]
    fn test_orderbook_new_orders_map_is_empty() {
        let book = OrderBook::new();
        assert!(book.orders.is_empty());
    }
}
