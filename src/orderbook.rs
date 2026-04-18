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
