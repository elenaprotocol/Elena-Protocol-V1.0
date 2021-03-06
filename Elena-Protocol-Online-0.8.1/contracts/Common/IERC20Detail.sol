 // SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
import '../@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IERC20Detail is IERC20 {
    function decimals() external view returns (uint8);
}
