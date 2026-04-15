#include "matcher.h"
#include <algorithm>

std::vector<Trade> process_batch(OrderBook& book, const std::vector<Order>& batch) {

    // ----------------------------------------------------------------
    // Step 1 + 2: drain resting orders, then merge with incoming batch
    // ----------------------------------------------------------------
    std::vector<Order> buys  = book.drain_buys();
    std::vector<Order> sells = book.drain_asks();

    for (const auto& o : batch) {
        if (o.side == Side::Buy)  buys.push_back(o);
        else                       sells.push_back(o);
    }

    // ----------------------------------------------------------------
    // Step 3 + 4: sort by canonical arbitration key
    //
    //   BUY  side: price DESC → timestamp ASC → id ASC
    //   SELL side: price ASC  → timestamp ASC → id ASC
    // ----------------------------------------------------------------
    std::sort(buys.begin(), buys.end(),
        [](const Order& a, const Order& b) {
            if (a.price     != b.price)     return a.price     > b.price;
            if (a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
            return a.id < b.id;
        });

    std::sort(sells.begin(), sells.end(),
        [](const Order& a, const Order& b) {
            if (a.price     != b.price)     return a.price     < b.price;
            if (a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
            return a.id < b.id;
        });

    // ----------------------------------------------------------------
    // Step 5: two-pointer greedy match
    //
    //   Invariant: buys[i].price is the best remaining bid;
    //              sells[j].price is the best remaining offer.
    //   Match condition: buy.price >= sell.price.
    //   Trade price: sell.price (canonical rule from Spec §5.2).
    // ----------------------------------------------------------------
    std::vector<Trade> trades;
    std::size_t i = 0, j = 0;

    while (i < buys.size() && j < sells.size()) {
        if (buys[i].price < sells[j].price) break; // no further match possible

        uint32_t trade_qty   = (buys[i].qty < sells[j].qty) ? buys[i].qty : sells[j].qty;
        uint32_t trade_price = sells[j].price;

        trades.push_back({ buys[i].id, sells[j].id, trade_price, trade_qty });

        buys[i].qty  -= trade_qty;
        sells[j].qty -= trade_qty;

        if (buys[i].qty  == 0) ++i;
        if (sells[j].qty == 0) ++j;
    }

    // ----------------------------------------------------------------
    // Step 6: reinsert residuals (all unmatched or partially filled orders)
    // ----------------------------------------------------------------
    // Orders at indices [0..i-1] are fully consumed; [i..end] are residuals.
    // Note: buys[i].qty may be > 0 if it was only partially filled (pointer
    // stopped at it because the next sell is worse). We reinsert it too.
    for (std::size_t k = i; k < buys.size(); ++k) {
        if (buys[k].qty > 0) book.add_limit_order(buys[k]);
    }
    for (std::size_t k = j; k < sells.size(); ++k) {
        if (sells[k].qty > 0) book.add_limit_order(sells[k]);
    }

    return trades;
}
