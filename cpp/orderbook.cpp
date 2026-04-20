#include "orderbook.h"
#include <algorithm>

// ============================================================
// Constructor
// ============================================================

OrderBook::OrderBook()
    : bids_(MAX_PRICE),  // heap-allocated; default PriceLevel{} per slot
      asks_(MAX_PRICE)
{}

// ============================================================
// Order management
// ============================================================

void OrderBook::add_limit_order(const Order& order) {
    if (order.price == 0 || order.price >= MAX_PRICE) return; // guard

    auto& book  = (order.side == Side::Buy) ? bids_ : asks_;
    auto& level = book[order.price];

    level.total_qty += order.qty;
    level.orders.push_back(order.id);   // FIFO: new orders go to the back
    orders_[order.id] = order;
}

void OrderBook::execute_order(uint64_t order_id, uint32_t qty) {
    auto it = orders_.find(order_id);
    if (it == orders_.end()) return;

    Order& order   = it->second;
    uint32_t traded = (qty < order.qty) ? qty : order.qty; // min
    order.qty -= traded;

    auto& book  = (order.side == Side::Buy) ? bids_ : asks_;
    auto& level = book[order.price];
    level.total_qty -= static_cast<uint64_t>(traded);

    if (order.qty == 0) {
        // Remove the ID from the FIFO queue.
        auto& q   = level.orders;
        auto  pos = std::find(q.begin(), q.end(), order_id);
        if (pos != q.end()) q.erase(pos);
        orders_.erase(it);
    }
}

void OrderBook::cancel_order(uint64_t order_id, uint32_t qty) {
    // A cancel is a partial or full quantity reduction — identical to execute.
    execute_order(order_id, qty);
}

void OrderBook::delete_order(uint64_t order_id) {
    auto it = orders_.find(order_id);
    if (it == orders_.end()) return;

    const Order& order = it->second;
    auto& book  = (order.side == Side::Buy) ? bids_ : asks_;
    auto& level = book[order.price];

    // Saturating subtract to avoid underflow on corrupted state.
    if (level.total_qty >= static_cast<uint64_t>(order.qty))
        level.total_qty -= order.qty;
    else
        level.total_qty = 0;

    auto& q   = level.orders;
    auto  pos = std::find(q.begin(), q.end(), order_id);
    if (pos != q.end()) q.erase(pos);

    orders_.erase(it);
}

// ============================================================
// Drain methods (used once per batch by the matcher)
// ============================================================

std::vector<Order> OrderBook::drain_buys() {
    std::vector<Order> result;
    // Iterate price levels from high to low (natural BUY priority order).
    for (int p = static_cast<int>(MAX_PRICE) - 1; p >= 0; --p) {
        auto& level = bids_[p];
        while (!level.orders.empty()) {
            uint64_t id = level.orders.front();
            level.orders.pop_front();
            auto it = orders_.find(id);
            if (it != orders_.end()) {
                result.push_back(it->second);
                orders_.erase(it);
            }
        }
        level.total_qty = 0;
    }
    return result;
}

std::vector<Order> OrderBook::drain_asks() {
    std::vector<Order> result;
    // Iterate price levels from low to high (natural SELL priority order).
    for (uint32_t p = 0; p < MAX_PRICE; ++p) {
        auto& level = asks_[p];
        while (!level.orders.empty()) {
            uint64_t id = level.orders.front();
            level.orders.pop_front();
            auto it = orders_.find(id);
            if (it != orders_.end()) {
                result.push_back(it->second);
                orders_.erase(it);
            }
        }
        level.total_qty = 0;
    }
    return result;
}

// ============================================================
// Reporting helpers (non-destructive)
// ============================================================

std::vector<const Order*> OrderBook::resting_buys_sorted() const {
    std::vector<const Order*> result;
    result.reserve(orders_.size());
    for (const auto& [id, order] : orders_) {
        if (order.side == Side::Buy) result.push_back(&order);
    }
    std::sort(result.begin(), result.end(),
        [](const Order* a, const Order* b) {
            if (a->price     != b->price)     return a->price     > b->price;     // DESC
            if (a->timestamp != b->timestamp) return a->timestamp < b->timestamp; // ASC
            return a->id < b->id;                                                  // ASC
        });
    return result;
}

std::vector<const Order*> OrderBook::resting_asks_sorted() const {
    std::vector<const Order*> result;
    result.reserve(orders_.size());
    for (const auto& [id, order] : orders_) {
        if (order.side == Side::Sell) result.push_back(&order);
    }
    std::sort(result.begin(), result.end(),
        [](const Order* a, const Order* b) {
            if (a->price     != b->price)     return a->price     < b->price;     // ASC
            if (a->timestamp != b->timestamp) return a->timestamp < b->timestamp; // ASC
            return a->id < b->id;                                                  // ASC
        });
    return result;
}
