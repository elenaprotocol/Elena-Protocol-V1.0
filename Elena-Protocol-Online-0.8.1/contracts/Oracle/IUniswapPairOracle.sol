// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
 

// Fixed window oracle that recomputes the average price for the entire period once every period
// Note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
interface IUniswapPairOracle { 
    function getPairToken(address token) external view returns(address);
    function containsToken(address token) external view returns(bool);
    function getSwapTokenReserve(address token) external view returns(uint256);
    function update() external returns(bool);
    // Note this will always return 0 before update has been called successfully for the first time.
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}
