#pragma once
#include "order.h"
#include "orderbook.h"
#include <vector>

/// Process one fixed-size (or partial) batch of incoming orders against the
/// resting order book.
///
/// Algorithm (mirrors Rust batch_matcher::process_batch exactly):
///
///  1. Drain all resting BUY and SELL orders from the book.
///     The book is empty after this step.
///  2. Merge drained orders with the new batch orders.
///  3. Sort BUY  side: price DESC → timestamp ASC → id ASC.
///  4. Sort SELL side: price ASC  → timestamp ASC → id ASC.
///  5. Two-pointer greedy match:
///       while buy.price >= sell.price:
///           trade at sell.price, qty = min(buy.qty, sell.qty)
///  6. Reinsert residual orders (qty > 0) back into the book.
///
/// Returns trades in execution order (deterministic).
std::vector<Trade> process_batch(OrderBook& book,
                                 const std::vector<Order>& batch);
