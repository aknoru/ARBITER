use crate::types::{Order, OrderBook, Side};

impl OrderBook {
    pub fn add_limit_order(&mut self, order: Order) {
        if order.price >= self.bids.len() {
            return;
        }

        let book = match order.side {
            Side::Buy => &mut self.bids,
            Side::Sell => &mut self.asks,
        };

        let level = &mut book[order.price];

        level.total_qty += order.qty;
        level.orders.push_back(order.id);

        self.orders.insert(order.id, order);
    }

    pub fn execute_order(&mut self, order_id: u64, qty: u64) {
        if let Some(order) = self.orders.get_mut(&order_id) {
            let traded = qty.min(order.qty);

            order.qty -= traded;

            let book = match order.side {
                Side::Buy => &mut self.bids,
                Side::Sell => &mut self.asks,
            };

            let level = &mut book[order.price];

            level.total_qty -= traded;

            if order.qty == 0 {
                if let Some(pos) = level.orders.iter().position(|id| *id == order_id) {
                    level.orders.remove(pos);
                }

                self.orders.remove(&order_id);
            }
        }
    }

    pub fn cancel_order(&mut self, order_id: u64, qty: u64) {
        if let Some(order) = self.orders.get_mut(&order_id) {
            let cancel = qty.min(order.qty);

            order.qty -= cancel;

            let book = match order.side {
                Side::Buy => &mut self.bids,
                Side::Sell => &mut self.asks,
            };

            let level = &mut book[order.price];

            level.total_qty -= cancel;

            if order.qty == 0 {
                if let Some(pos) = level.orders.iter().position(|id| *id == order_id) {
                    level.orders.remove(pos);
                }

                self.orders.remove(&order_id);
            }
        }
    }

    pub fn delete_order(&mut self, order_id: u64) {
        if let Some(order) = self.orders.remove(&order_id) {
            let book = match order.side {
                Side::Buy => &mut self.bids,
                Side::Sell => &mut self.asks,
            };

            let level = &mut book[order.price];

            level.total_qty -= order.qty;

            if let Some(pos) = level.orders.iter().position(|id| *id == order_id) {
                level.orders.remove(pos);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::types::{Order, OrderBook, Side, MAX_PRICE};

    fn buy(id: u64, price: usize, qty: u64) -> Order {
        Order { id, price, qty, side: Side::Buy }
    }

    fn sell(id: u64, price: usize, qty: u64) -> Order {
        Order { id, price, qty, side: Side::Sell }
    }

    // ── add_limit_order ──────────────────────────────────────────────────────

    #[test]
    fn test_add_buy_order_updates_bids() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        assert_eq!(book.bids[100].total_qty, 50);
        assert_eq!(book.bids[100].orders.len(), 1);
        assert_eq!(book.bids[100].orders[0], 1);
        assert!(book.orders.contains_key(&1));
    }

    #[test]
    fn test_add_sell_order_updates_asks() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(2, 200, 30));
        assert_eq!(book.asks[200].total_qty, 30);
        assert_eq!(book.asks[200].orders.len(), 1);
        assert_eq!(book.asks[200].orders[0], 2);
        assert!(book.orders.contains_key(&2));
    }

    #[test]
    fn test_add_buy_does_not_touch_asks() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        assert_eq!(book.asks[100].total_qty, 0);
        assert!(book.asks[100].orders.is_empty());
    }

    #[test]
    fn test_add_order_price_at_max_is_ignored() {
        let mut book = OrderBook::new();
        let order = Order { id: 99, price: MAX_PRICE, qty: 10, side: Side::Buy };
        book.add_limit_order(order);
        assert!(!book.orders.contains_key(&99));
    }

    #[test]
    fn test_add_multiple_orders_same_price_accumulates_qty() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        book.add_limit_order(buy(2, 100, 30));
        assert_eq!(book.bids[100].total_qty, 80);
        assert_eq!(book.bids[100].orders.len(), 2);
    }

    #[test]
    fn test_add_orders_fifo_queue_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 10));
        book.add_limit_order(buy(2, 100, 20));
        book.add_limit_order(buy(3, 100, 30));
        let orders = &book.bids[100].orders;
        assert_eq!(orders[0], 1);
        assert_eq!(orders[1], 2);
        assert_eq!(orders[2], 3);
    }

    // ── execute_order ────────────────────────────────────────────────────────

    #[test]
    fn test_execute_partial_reduces_qty() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        book.execute_order(1, 20);
        assert_eq!(book.orders[&1].qty, 30);
        assert_eq!(book.bids[100].total_qty, 30);
        assert_eq!(book.bids[100].orders.len(), 1);
    }

    #[test]
    fn test_execute_full_removes_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        book.execute_order(1, 50);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.bids[100].total_qty, 0);
        assert!(book.bids[100].orders.is_empty());
    }

    #[test]
    fn test_execute_more_than_qty_clamps_and_removes() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        book.execute_order(1, 100);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.bids[100].total_qty, 0);
    }

    #[test]
    fn test_execute_sell_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(1, 150, 80));
        book.execute_order(1, 40);
        assert_eq!(book.orders[&1].qty, 40);
        assert_eq!(book.asks[150].total_qty, 40);
    }

    #[test]
    fn test_execute_nonexistent_order_is_noop() {
        let mut book = OrderBook::new();
        book.execute_order(999, 10); // must not panic
    }

    #[test]
    fn test_execute_removes_from_price_level_queue() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 10));
        book.add_limit_order(buy(2, 100, 20));
        book.execute_order(1, 10);
        let orders = &book.bids[100].orders;
        assert_eq!(orders.len(), 1);
        assert_eq!(orders[0], 2);
        assert_eq!(book.bids[100].total_qty, 20);
    }

    // ── cancel_order ─────────────────────────────────────────────────────────

    #[test]
    fn test_cancel_partial_reduces_qty() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(1, 150, 80));
        book.cancel_order(1, 30);
        assert_eq!(book.orders[&1].qty, 50);
        assert_eq!(book.asks[150].total_qty, 50);
        assert_eq!(book.asks[150].orders.len(), 1);
    }

    #[test]
    fn test_cancel_full_removes_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(1, 150, 80));
        book.cancel_order(1, 80);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.asks[150].total_qty, 0);
        assert!(book.asks[150].orders.is_empty());
    }

    #[test]
    fn test_cancel_more_than_qty_clamps_and_removes() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(1, 150, 80));
        book.cancel_order(1, 200);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.asks[150].total_qty, 0);
    }

    #[test]
    fn test_cancel_buy_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 60));
        book.cancel_order(1, 20);
        assert_eq!(book.orders[&1].qty, 40);
        assert_eq!(book.bids[100].total_qty, 40);
    }

    #[test]
    fn test_cancel_nonexistent_order_is_noop() {
        let mut book = OrderBook::new();
        book.cancel_order(999, 10); // must not panic
    }

    // ── delete_order ─────────────────────────────────────────────────────────

    #[test]
    fn test_delete_buy_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 50));
        book.delete_order(1);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.bids[100].total_qty, 0);
        assert!(book.bids[100].orders.is_empty());
    }

    #[test]
    fn test_delete_sell_order() {
        let mut book = OrderBook::new();
        book.add_limit_order(sell(5, 200, 100));
        book.delete_order(5);
        assert!(!book.orders.contains_key(&5));
        assert_eq!(book.asks[200].total_qty, 0);
        assert!(book.asks[200].orders.is_empty());
    }

    #[test]
    fn test_delete_removes_from_queue_leaves_others() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 10));
        book.add_limit_order(buy(2, 100, 20));
        book.delete_order(1);
        assert_eq!(book.bids[100].orders.len(), 1);
        assert_eq!(book.bids[100].orders[0], 2);
        assert_eq!(book.bids[100].total_qty, 20);
    }

    #[test]
    fn test_delete_nonexistent_order_is_noop() {
        let mut book = OrderBook::new();
        book.delete_order(999); // must not panic
    }

    // ── mixed operations ─────────────────────────────────────────────────────

    #[test]
    fn test_mixed_add_execute_cancel_delete() {
        let mut book = OrderBook::new();
        book.add_limit_order(buy(1, 100, 100));
        book.add_limit_order(buy(2, 100, 50));
        book.execute_order(1, 60);
        book.cancel_order(2, 25);
        book.delete_order(1);
        assert!(!book.orders.contains_key(&1));
        assert_eq!(book.orders[&2].qty, 25);
        assert_eq!(book.bids[100].total_qty, 25);
        assert_eq!(book.bids[100].orders.len(), 1);
    }
}
