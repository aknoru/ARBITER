use crate::types::{Order, OrderBook, Side};

impl OrderBook {
    // -----------------------------------------------------------------------
    // Order management (Add / Execute / Cancel / Delete)
    // -----------------------------------------------------------------------

    /// Insert a new limit order into the book.
    pub fn add_limit_order(&mut self, order: Order) {
        let price = order.price as usize;
        if price >= self.bids.len() {
            // Silently drop out-of-range prices (defensive guard).
            return;
        }

        let book = match order.side {
            Side::Buy  => &mut self.bids,
            Side::Sell => &mut self.asks,
        };

        let level = &mut book[price];
        level.total_qty += order.qty as u64;
        level.orders.push_back(order.id);

        self.orders.insert(order.id, order);
    }

    /// Reduce `qty` from a resting order; remove completely if qty reaches 0.
    pub fn execute_order(&mut self, order_id: u32, qty: u32) {
        if let Some(order) = self.orders.get_mut(&order_id) {
            let traded = qty.min(order.qty);
            order.qty -= traded;

            let price = order.price as usize;
            let book = match order.side {
                Side::Buy  => &mut self.bids,
                Side::Sell => &mut self.asks,
            };
            let level = &mut book[price];
            level.total_qty -= traded as u64;

            if order.qty == 0 {
                // Drain ID from the FIFO queue.
                let pos = level.orders.iter().position(|id| *id == order_id);
                if let Some(p) = pos {
                    level.orders.remove(p);
                }
                self.orders.remove(&order_id);
            }
        }
    }

    /// Cancel (reduce) `qty` from a resting order.
    /// Semantically equivalent to execute for this implementation.
    pub fn cancel_order(&mut self, order_id: u32, qty: u32) {
        self.execute_order(order_id, qty);
    }

    /// Delete an order entirely from the book regardless of remaining qty.
    pub fn delete_order(&mut self, order_id: u32) {
        if let Some(order) = self.orders.remove(&order_id) {
            let price = order.price as usize;
            let book = match order.side {
                Side::Buy  => &mut self.bids,
                Side::Sell => &mut self.asks,
            };
            let level = &mut book[price];
            level.total_qty = level.total_qty.saturating_sub(order.qty as u64);
            let pos = level.orders.iter().position(|id| *id == order_id);
            if let Some(p) = pos {
                level.orders.remove(p);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Drain methods — used by batch_matcher to collect & re-insert residuals
    // -----------------------------------------------------------------------

    /// Remove and return all BUY orders from the book.
    /// Iterates price levels price-descending, FIFO within each level.
    /// **The bids side of the book is completely empty after this call.**
    pub fn drain_buys(&mut self) -> Vec<Order> {
        let mut result = Vec::new();
        for price in (0..self.bids.len()).rev() {
            // Collect IDs first so we can release the borrow on self.bids
            // before accessing self.orders.
            let ids: Vec<u32> = self.bids[price].orders.drain(..).collect();
            self.bids[price].total_qty = 0;
            for id in ids {
                if let Some(order) = self.orders.remove(&id) {
                    result.push(order);
                }
            }
        }
        result
    }

    /// Remove and return all SELL orders from the book.
    /// Iterates price levels price-ascending, FIFO within each level.
    /// **The asks side of the book is completely empty after this call.**
    pub fn drain_asks(&mut self) -> Vec<Order> {
        let mut result = Vec::new();
        for price in 0..self.asks.len() {
            let ids: Vec<u32> = self.asks[price].orders.drain(..).collect();
            self.asks[price].total_qty = 0;
            for id in ids {
                if let Some(order) = self.orders.remove(&id) {
                    result.push(order);
                }
            }
        }
        result
    }

    // -----------------------------------------------------------------------
    // Reporting helpers
    // -----------------------------------------------------------------------

    /// Return all resting BUY orders sorted by the canonical arbitration key:
    /// price DESC → timestamp ASC → id ASC.
    pub fn resting_buys_sorted(&self) -> Vec<&Order> {
        let mut orders: Vec<&Order> = self
            .orders
            .values()
            .filter(|o| o.side == Side::Buy)
            .collect();
        orders.sort_by(|a, b| {
            b.price
                .cmp(&a.price)
                .then(a.timestamp.cmp(&b.timestamp))
                .then(a.id.cmp(&b.id))
        });
        orders
    }

    /// Return all resting SELL orders sorted by the canonical arbitration key:
    /// price ASC → timestamp ASC → id ASC.
    pub fn resting_asks_sorted(&self) -> Vec<&Order> {
        let mut orders: Vec<&Order> = self
            .orders
            .values()
            .filter(|o| o.side == Side::Sell)
            .collect();
        orders.sort_by(|a, b| {
            a.price
                .cmp(&b.price)
                .then(a.timestamp.cmp(&b.timestamp))
                .then(a.id.cmp(&b.id))
        });
        orders
    }
}
