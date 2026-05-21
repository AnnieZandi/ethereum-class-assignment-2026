import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OrderBook {
    enum OrderType {
        Buy,
        Sell
    }

    struct Order {
        uint256 id;
        address trader;
        OrderType orderType;
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint256 price;
        uint256 remaining;
        bool isOpen;
    }

    event OrderPlaced(
        uint256 indexed id,
        address indexed trader,
        OrderType orderType,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price
    );
    event OrderMatched(uint256 indexed buyOrderId, uint256 indexed sellOrderId, uint256 amount);
    event OrderCanceled(uint256 indexed id);

    error InvalidAmount();
    error InvalidPrice();
    error PriceMismatch();
    error UnauthorizedCancellation();

    IERC20 public tokenA; // PNPToken
    IERC20 public tokenB; // FNBToken

    Order[] public orders;

    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    function placeBuyOrder(uint256 amount, uint256 price) external {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Buyer pays tokenB (quote), wants tokenA (base)
        uint256 cost = amount * price;
        tokenB.transferFrom(msg.sender, address(this), cost);

        uint256 id = orders.length;
        orders.push(
            Order({
                id: id,
                trader: msg.sender,
                orderType: OrderType.Buy,
                tokenIn: address(tokenB),
                tokenOut: address(tokenA),
                amount: amount,
                price: price,
                remaining: amount,
                isOpen: true
            })
        );

        emit OrderPlaced(id, msg.sender, OrderType.Buy, address(tokenB), address(tokenA), amount, price);
    }

    function placeSellOrder(uint256 amount, uint256 price) external {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Seller gives tokenA (base), wants tokenB (quote)
        tokenA.transferFrom(msg.sender, address(this), amount);

        uint256 id = orders.length;
        orders.push(
            Order({
                id: id,
                trader: msg.sender,
                orderType: OrderType.Sell,
                tokenIn: address(tokenA),
                tokenOut: address(tokenB),
                amount: amount,
                price: price,
                remaining: amount,
                isOpen: true
            })
        );

        emit OrderPlaced(id, msg.sender, OrderType.Sell, address(tokenA), address(tokenB), amount, price);
    }

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        if (buyOrder.price != sellOrder.price) revert PriceMismatch();

        uint256 matchAmount = buyOrder.remaining < sellOrder.remaining ? buyOrder.remaining : sellOrder.remaining;

        uint256 cost = matchAmount * buyOrder.price;

        // Send tokenA to buyer
        tokenA.transfer(buyOrder.trader, matchAmount);
        // Send tokenB to seller
        tokenB.transfer(sellOrder.trader, cost);

        buyOrder.remaining -= matchAmount;
        sellOrder.remaining -= matchAmount;

        if (buyOrder.remaining == 0) buyOrder.isOpen = false;
        if (sellOrder.remaining == 0) sellOrder.isOpen = false;

        emit OrderMatched(buyOrderId, sellOrderId, matchAmount);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.trader != msg.sender) revert UnauthorizedCancellation();

        order.isOpen = false;

        // Refund remaining tokens
        if (order.orderType == OrderType.Buy) {
            // Refund remaining tokenB (quote)
            uint256 refund = order.remaining * order.price;
            tokenB.transfer(msg.sender, refund);
        } else {
            // Refund remaining tokenA (base)
            tokenA.transfer(msg.sender, order.remaining);
        }

        order.remaining = 0;
        emit OrderCanceled(orderId);
    }

    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].isOpen;
    }

    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].remaining;
    }
}
