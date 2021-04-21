// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./USEPool.sol";

contract USEPoolDAI is USEPool {
    address public DAI_address;
    constructor(
        address _use_contract_address,
        address _shares_contract_address,
        address _collateral_address,
        address _creator_address, 
        address _timelock_address,
        address _community_address
    ) 
    USEPool(_use_contract_address, _shares_contract_address, _collateral_address, _creator_address, _timelock_address,_community_address)
    public {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DAI_address = _collateral_address;
    }

    // Returns the price of the pool collateral in USD
    function getCollateralPrice() public view override returns (uint256) {
        if(collateralPricePaused == true){
            return pausedPrice;
        } else { 
            //Only For Dai
            return 1 * PRICE_PRECISION; 
        }
    } 
}
