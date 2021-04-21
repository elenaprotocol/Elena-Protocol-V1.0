// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
import "../Oracle/IUniswapPairOracle.sol"; 
interface IUSEStablecoin {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function owner_address() external returns (address);
    function creator_address() external returns (address);
    function timelock_address() external returns (address); 
    function genesis_supply() external returns (uint256); 
    function refresh_cooldown() external returns (uint256);
    function price_target() external returns (uint256);
    function price_band() external returns (uint256);

    function DEFAULT_ADMIN_ADDRESS() external returns (address);
    function COLLATERAL_RATIO_PAUSER() external returns (bytes32);
    function collateral_ratio_paused() external returns (bool);
    function last_call_time() external returns (uint256);

    function USEDAIOracle() external returns (IUniswapPairOracle);
    function USESharesOracle() external returns (IUniswapPairOracle); 
    
    /* ========== VIEWS ========== */
    function use_pools(address a) external view returns (bool);
    function global_collateral_ratio() external view returns (uint256);
    function use_price() external view returns (uint256);
    function share_price()  external view returns (uint256);
    function share_price_in_use()  external view returns (uint256); 
    function globalCollateralValue() external view returns (uint256);

    /* ========== PUBLIC FUNCTIONS ========== */
    function refreshCollateralRatio() external;
    function swapCollateralAmount() external view returns(uint256);
    
    function pool_mint(address m_address, uint256 m_amount) external;
    function pool_burn_from(address b_address, uint256 b_amount) external;
    function burn(uint256 amount) external;
}