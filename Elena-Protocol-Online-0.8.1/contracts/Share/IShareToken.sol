// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import '../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
interface IShareToken is IERC20 {  
    function pool_mint(address m_address, uint256 m_amount) external; 
    function pool_burn_from(address b_address, uint256 b_amount) external; 
    function burn(uint256 amount) external;
}
