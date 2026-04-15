use crate::types::{Order, OrderBook, Side};

// ---------------------------------------------------------------------------
// Trade record
// ---------------------------------------------------------------------------

/// One executed trade, produced by `process_batch`.
#[derive(Debug)]
pub struct Trade {
    pub buy_id:  u32,
    pub sell_id: u32,
    pub price:   u32,
    pub qty:     u32,
}

// ---------------------------------------------------------------------------
// Batch processor
// ---------------------------------------------------------------------------

/// Process one batch of incoming orders against the resting book.
///
/// Algorithm:
///  1. Drain all resting orders from the book (book is empty after this step).
///  2. Merge resting orders with the new batch orders.
///  3. Sort buys  by: price DESC → timestamp ASC → id ASC  (arbitration key).
///  4. Sort sells by: price ASC  → timestamp ASC → id ASC.
///  5. Two-pointer greedy match: execute whenever buy.price >= sell.price.
///     Trade price = sell.price (canonical intra-batch rule from Spec §5.2).
///  6. Reinsert all residual orders (qty > 0 after matching) back into the book.
///
/// Returns the list of trades in execution order.
pub fn process_batch(book: &mut OrderBook, batch: &[Order]) -> Vec<Trade> {
    // --- Step 1+2: drain resting + merge batch --------------------------------
    let mut buys  = book.drain_buys();
    let mut sells = book.drain_asks();

    for o in batch {
        match o.side {
            Side::Buy  => buys.push(o.clone()),
            Side::Sell => sells.push(o.clone()),
        }
    }

    // --- Step 3+4: sort (arbitration key) ------------------------------------
    buys.sort_by(|a, b| {
        b.price
            .cmp(&a.price)
            .then(a.timestamp.cmp(&b.timestamp))
            .then(a.id.cmp(&b.id))
    });

    sells.sort_by(|a, b| {
        a.price
            .cmp(&b.price)
            .then(a.timestamp.cmp(&b.timestamp))
            .then(a.id.cmp(&b.id))
    });

    // --- Step 5: two-pointer match -------------------------------------------
    let mut trades: Vec<Trade> = Vec::new();
    let mut i = 0usize; // index into buys
    let mut j = 0usize; // index into sells

    while i < buys.len() && j < sells.len() {
        // Condition: buy price must be >= sell price to match.
        if buys[i].price < sells[j].price {
            break; // no further match possible (lists are sorted)
        }

        let trade_qty   = buys[i].qty.min(sells[j].qty);
        let trade_price = sells[j].price; // SELL side sets the trade price

        trades.push(Trade {
            buy_id:  buys[i].id,
            sell_id: sells[j].id,
            price:   trade_price,
            qty:     trade_qty,
        });

        buys[i].qty  -= trade_qty;
        sells[j].qty -= trade_qty;

        if buys[i].qty  == 0 { i += 1; }
        if sells[j].qty == 0 { j += 1; }
    }

    // --- Step 6: reinsert residuals ------------------------------------------
    // Orders at index i..len (buys) and j..len (sells) were not fully consumed.
    // Also covers the case where a partially filled order (qty > 0) sits at i or j.
    for k in i..buys.len() {
        if buys[k].qty > 0 {
            book.add_limit_order(buys[k].clone());
        }
    }
    for k in j..sells.len() {
        if sells[k].qty > 0 {
            book.add_limit_order(sells[k].clone());
        }
    }

    trades
}
