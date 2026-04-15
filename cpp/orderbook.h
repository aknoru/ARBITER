#pragma once
#include "order.h"
#include <cstdint>
#include <deque>
#include <unordered_map>
#include <vector>

// ============================================================
// Price level: one FIFO queue of order IDs at a single price
// ============================================================

struct PriceLevel {
    uint64_t             total_qty = 0;
    std::deque<uint32_t> orders;   // front = oldest (FIFO priority)
};

// ============================================================
// OrderBook
// ============================================================
//
// Structurally identical to the Rust baseline:
//   bids_   : Vec<PriceLevel>[0..MAX_PRICE]  — price-indexed array
//   asks_   : Vec<PriceLevel>[0..MAX_PRICE]
//   orders_ : HashMap<order_id, Order>        — flat O(1) lookup
//
// The price-indexed array allows:
//   - O(1) insert / cancel at any price
//   - O(1) best-price lookup (scan once at construction; track externally if needed)

class OrderBook {
public:
    OrderBook();  // allocates MAX_PRICE levels per side on the heap

    // ---- Order management ------------------------------------------------
    void add_limit_order(const Order& order);
    void execute_order(uint32_t order_id, uint32_t qty);
    void cancel_order (uint32_t order_id, uint32_t qty); // = partial execute
    void delete_order (uint32_t order_id);               // full delete

    // ---- Drain (used by batch_matcher before every batch) ----------------
    /// Remove and return all BUY orders; bids side becomes empty.
    std::vector<Order> drain_buys();
    /// Remove and return all SELL orders; asks side becomes empty.
    std::vector<Order> drain_asks();

    // ---- Reporting (non-destructive) -------------------------------------
    /// BUY orders sorted: price DESC → timestamp ASC → id ASC.
    std::vector<const Order*> resting_buys_sorted() const;
    /// SELL orders sorted: price ASC → timestamp ASC → id ASC.
    std::vector<const Order*> resting_asks_sorted() const;

    /// Number of live orders currently in the book.
    std::size_t order_count() const { return orders_.size(); }

private:
    std::vector<PriceLevel>             bids_;   // indexed by price (0..MAX_PRICE-1)
    std::vector<PriceLevel>             asks_;
    std::unordered_map<uint32_t, Order> orders_; // order_id -> Order
};
