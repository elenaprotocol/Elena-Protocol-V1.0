// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import '../../@openzeppelin/contracts/math/SafeMath.sol'; 
import '../../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
import '../../@openzeppelin/contracts/access/AccessControl.sol'; 
import "../../Common/ContractGuard.sol";
import "../../Common/IERC20Detail.sol";
import "../../Share/IShareToken.sol";
import "../../USE/IUSEStablecoin.sol";
import "../../Oracle/IUniswapPairOracle.sol";
import "./USEPoolAlgo.sol";

abstract contract USEPool is USEPoolAlgo,ContractGuard,AccessControl {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    IERC20Detail public collateral_token;
    address public collateral_address;
    address public owner_address;
    address public community_address;

    address public use_contract_address;
    address public shares_contract_address;
    address public timelock_address;
    IShareToken private SHARE;
    IUSEStablecoin private USE; 

    uint256 public minting_tax_base;
    uint256 public minting_tax_multiplier; 
    uint256 public minting_required_reserve_ratio;
     
    uint256 public redemption_gcr_adj = PRECISION;   // PRECISION/PRECISION = 1
    uint256 public redemption_tax_base;
    uint256 public redemption_tax_multiplier;
    uint256 public redemption_tax_exponent;
    uint256 public redemption_required_reserve_ratio = 800000;

    uint256 public buyback_tax;
    uint256 public recollat_tax;

    uint256 public community_rate_ratio = 15000;
    uint256 public community_rate_in_use;
    uint256 public community_rate_in_share;

    mapping (address => uint256) public redeemSharesBalances;
    mapping (address => uint256) public redeemCollateralBalances;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolShares;
    mapping (address => uint256) public lastRedeemed;

    // Constants for various precisions
    uint256 public constant PRECISION = 1e6;  
    uint256 public constant RESERVE_RATIO_PRECISION = 1e6;    
    uint256 public constant COLLATERAL_RATIO_MAX = 1e6;

    // Number of decimals needed to get to 18
    uint256 public immutable missing_decimals;
    
    // Pool_ceiling is the total units of collateral that a pool contract can hold
    uint256 public pool_ceiling = 10000000000e18;

    // Stores price of the collateral, if price is paused
    uint256 public pausedPrice = 0;

    // Bonus rate on Shares minted during recollateralizeUSE(); 6 decimals of precision, set to 0.5% on genesis
    uint256 public bonus_rate = 5000;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public redemption_delay = 2;

    uint256 public global_use_supply_adj = 1000e18;  //genesis_supply
    // AccessControl Roles
    bytes32 public constant MINT_PAUSER = keccak256("MINT_PAUSER");
    bytes32 public constant REDEEM_PAUSER = keccak256("REDEEM_PAUSER");
    bytes32 public constant BUYBACK_PAUSER = keccak256("BUYBACK_PAUSER");
    bytes32 public constant RECOLLATERALIZE_PAUSER = keccak256("RECOLLATERALIZE_PAUSER");
    bytes32 public constant COLLATERAL_PRICE_PAUSER = keccak256("COLLATERAL_PRICE_PAUSER");
    bytes32 public constant COMMUNITY_RATER = keccak256("COMMUNITY_RATER");
    // AccessControl state variables
    bool public mintPaused = false;
    bool public redeemPaused = false;
    bool public recollateralizePaused = false;
    bool public buyBackPaused = false;
    bool public collateralPricePaused = false;
    

    event UpdateOracleBonus(address indexed user,bool bonus1, bool bonus2);
    /* ========== MODIFIERS ========== */

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == timelock_address || msg.sender == owner_address, "You are not the owner or the governance timelock");
        _;
    }

    modifier notRedeemPaused() {
        require(redeemPaused == false, "Redeeming is paused");
        require(redemptionOpened() == true,"Redeeming is closed");
        _;
    }

    modifier notMintPaused() {
        require(mintPaused == false, "Minting is paused");
        require(mintingOpened() == true,"Minting is closed");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor(
        address _use_contract_address,
        address _shares_contract_address,
        address _collateral_address,
        address _creator_address,
        address _timelock_address,
        address _community_address
    ) public {
        USE = IUSEStablecoin(_use_contract_address);
        SHARE = IShareToken(_shares_contract_address);
        use_contract_address = _use_contract_address;
        shares_contract_address = _shares_contract_address;
        collateral_address = _collateral_address;
        timelock_address = _timelock_address;
        owner_address = _creator_address;
        community_address = _community_address;
        collateral_token = IERC20Detail(_collateral_address); 
        missing_decimals = uint(18).sub(collateral_token.decimals());

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(MINT_PAUSER, timelock_address);
        grantRole(REDEEM_PAUSER, timelock_address);
        grantRole(RECOLLATERALIZE_PAUSER, timelock_address);
        grantRole(BUYBACK_PAUSER, timelock_address);
        grantRole(COLLATERAL_PRICE_PAUSER, timelock_address);
        grantRole(COMMUNITY_RATER, _community_address);
    }

    /* ========== VIEWS ========== */

    // Returns dollar value of collateral held in this USE pool
   
    function collatDollarBalance() public view returns (uint256) {
        uint256 collateral_amount = collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral);
        uint256 collat_usd_price = collateralPricePaused == true ? pausedPrice : getCollateralPrice();
        return collateral_amount.mul(10 ** missing_decimals).mul(collat_usd_price).div(PRICE_PRECISION); 
    }

    // Returns the value of excess collateral held in this USE pool, compared to what is needed to maintain the global collateral ratio
    function availableExcessCollatDV() public view returns (uint256) {      
        uint256 total_supply = USE.totalSupply().sub(global_use_supply_adj);       
        uint256 global_collat_value = USE.globalCollateralValue();
        uint256 global_collateral_ratio = USE.global_collateral_ratio();
        // Handles an overcollateralized contract with CR > 1
        if (global_collateral_ratio > COLLATERAL_RATIO_PRECISION) {
            global_collateral_ratio = COLLATERAL_RATIO_PRECISION; 
        }
        // Calculates collateral needed to back each 1 USE with $1 of collateral at current collat ratio
        uint256 required_collat_dollar_value_d18 = (total_supply.mul(global_collateral_ratio)).div(COLLATERAL_RATIO_PRECISION);
        if (global_collat_value > required_collat_dollar_value_d18) {
           return global_collat_value.sub(required_collat_dollar_value_d18);
        }
        return 0;
    }
   
    /* ========== PUBLIC FUNCTIONS ========== */ 
    function getCollateralPrice() public view virtual returns (uint256);
   
    function getCollateralAmount()   public view  returns (uint256){
        return collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral);
    }

    function requiredReserveRatio() public view returns(uint256){
        uint256 pool_collateral_amount = getCollateralAmount();
        uint256 swap_collateral_amount = USE.swapCollateralAmount();
        require(swap_collateral_amount>0,"swap collateral is empty?");
        return pool_collateral_amount.mul(RESERVE_RATIO_PRECISION).div(swap_collateral_amount);
    }
    
    function mintingOpened() public view returns(bool){ 
        return  (requiredReserveRatio() >= minting_required_reserve_ratio);
    }
    
    function redemptionOpened() public view returns(bool){
        return  (requiredReserveRatio() >= redemption_required_reserve_ratio);
    }
    
    //
    function mintingTax() public view returns(uint256){
        uint256 _dynamicTax =  minting_tax_multiplier.mul(requiredReserveRatio()).div(RESERVE_RATIO_PRECISION); 
        return  minting_tax_base + _dynamicTax;       
    }
    
    
    function dynamicRedemptionTax(uint256 ratio,uint256 multiplier,uint256 exponent) public pure returns(uint256){        
        return multiplier.mul(RESERVE_RATIO_PRECISION**exponent).div(ratio**exponent);
    }
    
    //
    function redemptionTax() public view returns(uint256){
        uint256 _dynamicTax =dynamicRedemptionTax(requiredReserveRatio(),redemption_tax_multiplier,redemption_tax_exponent);
        return  redemption_tax_base + _dynamicTax;       
    } 

    function updateOraclePrice() public { 
        IUniswapPairOracle _useDaiOracle = USE.USEDAIOracle();
        IUniswapPairOracle _useSharesOracle = USE.USESharesOracle();
        bool _bonus1 = _useDaiOracle.update();
        bool _bonus2 = _useSharesOracle.update(); 
        if(_bonus1 || _bonus2){
            emit UpdateOracleBonus(msg.sender,_bonus1,_bonus2);
        }
    }


    // We separate out the 1t1, fractional and algorithmic minting functions for gas efficiency 
    function mint1t1USE(uint256 collateral_amount, uint256 use_out_min) external onlyOneBlock notMintPaused { 
        updateOraclePrice();       
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);

        require(USE.global_collateral_ratio() >= COLLATERAL_RATIO_MAX, "Collateral ratio must be >= 1");
        require(getCollateralAmount().add(collateral_amount) <= pool_ceiling, "[Pool's Closed]: Ceiling reached");
        
        (uint256 use_amount_d18) = calcMint1t1USE(
            getCollateralPrice(),
            collateral_amount_d18
        ); //1 USE for each $1 worth of collateral
        community_rate_in_use  =  community_rate_in_use.add(use_amount_d18.mul(community_rate_ratio).div(PRECISION));
        use_amount_d18 = (use_amount_d18.mul(uint(1e6).sub(mintingTax()))).div(1e6); //remove precision at the end
        require(use_out_min <= use_amount_d18, "Slippage limit reached");

        collateral_token.transferFrom(msg.sender, address(this), collateral_amount);
        USE.pool_mint(msg.sender, use_amount_d18);  
    }

    // Will fail if fully collateralized or fully algorithmic
    // > 0% and < 100% collateral-backed
    function mintFractionalUSE(uint256 collateral_amount, uint256 shares_amount, uint256 use_out_min) external onlyOneBlock notMintPaused {
        updateOraclePrice();
        uint256 share_price = USE.share_price();
        uint256 global_collateral_ratio = USE.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        require(getCollateralAmount().add(collateral_amount) <= pool_ceiling, "Pool ceiling reached, no more USE can be minted with this collateral");

        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        MintFU_Params memory input_params = MintFU_Params(
            share_price,
            getCollateralPrice(),
            shares_amount,
            collateral_amount_d18,
            global_collateral_ratio
        );

        (uint256 mint_amount,uint256 collateral_need_d18, uint256 shares_needed) = calcMintFractionalUSE(input_params);
        community_rate_in_use  =  community_rate_in_use.add(mint_amount.mul(community_rate_ratio).div(PRECISION));
        mint_amount = (mint_amount.mul(uint(1e6).sub(mintingTax()))).div(1e6);
        require(use_out_min <= mint_amount, "Slippage limit reached");
        require(shares_needed <= shares_amount, "Not enough Shares inputted");

        uint256 collateral_need = collateral_need_d18.div(10 ** missing_decimals);
        SHARE.pool_burn_from(msg.sender, shares_needed);
        collateral_token.transferFrom(msg.sender, address(this), collateral_need);
        USE.pool_mint(msg.sender, mint_amount);      
    }

    // Redeem collateral. 100% collateral-backed
    function redeem1t1USE(uint256 use_amount, uint256 COLLATERAL_out_min) external onlyOneBlock notRedeemPaused {
        updateOraclePrice();
        require(USE.global_collateral_ratio() == COLLATERAL_RATIO_MAX, "Collateral ratio must be == 1");

        
        // Need to adjust for decimals of collateral
        uint256 use_amount_precision = use_amount.div(10 ** missing_decimals);
        (uint256 collateral_needed) = calcRedeem1t1USE(
            getCollateralPrice(),
            use_amount_precision
        );
        community_rate_in_use  =  community_rate_in_use.add(use_amount.mul(community_rate_ratio).div(PRECISION));
        collateral_needed = (collateral_needed.mul(uint(1e6).sub(redemptionTax()))).div(1e6);
        require(collateral_needed <= getCollateralAmount(), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_needed, "Slippage limit reached");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_needed);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_needed);
        lastRedeemed[msg.sender] = block.number;
        
        // Move all external functions to the end
        USE.pool_burn_from(msg.sender, use_amount); 
        
        require(redemptionOpened() == true,"Redeem amount too large !");
    }

    // Will fail if fully collateralized or algorithmic
    // Redeem USE for collateral and SHARE. > 0% and < 100% collateral-backed
    function redeemFractionalUSE(uint256 use_amount, uint256 shares_out_min, uint256 COLLATERAL_out_min) external onlyOneBlock notRedeemPaused {
        updateOraclePrice();
        uint256 global_collateral_ratio = USE.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
 
        global_collateral_ratio = global_collateral_ratio.mul(redemption_gcr_adj).div(PRECISION);

        uint256 use_amount_post_tax = (use_amount.mul(uint(1e6).sub(redemptionTax()))).div(PRICE_PRECISION);

        uint256 shares_dollar_value_d18 = use_amount_post_tax.sub(use_amount_post_tax.mul(global_collateral_ratio).div(PRICE_PRECISION));
        uint256 shares_amount = shares_dollar_value_d18.mul(PRICE_PRECISION).div(USE.share_price());

        // Need to adjust for decimals of collateral
        uint256 use_amount_precision = use_amount_post_tax.div(10 ** missing_decimals);
        uint256 collateral_dollar_value = use_amount_precision.mul(global_collateral_ratio).div(PRICE_PRECISION);
        uint256 collateral_amount = collateral_dollar_value.mul(PRICE_PRECISION).div(getCollateralPrice());


        require(collateral_amount <= getCollateralAmount(), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_amount, "Slippage limit reached [collateral]");
        require(shares_out_min <= shares_amount, "Slippage limit reached [Shares]");
        community_rate_in_use  =  community_rate_in_use.add(use_amount.mul(community_rate_ratio).div(PRECISION));

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_amount);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_amount);

        redeemSharesBalances[msg.sender] = redeemSharesBalances[msg.sender].add(shares_amount);
        unclaimedPoolShares = unclaimedPoolShares.add(shares_amount);

        lastRedeemed[msg.sender] = block.number;
        
        // Move all external functions to the end
        USE.pool_burn_from(msg.sender, use_amount);
        SHARE.pool_mint(address(this), shares_amount);
        
        require(redemptionOpened() == true,"Redeem amount too large !");
    }
 
    // After a redemption happens, transfer the newly minted Shares and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out USE/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption() external onlyOneBlock{        
        require((lastRedeemed[msg.sender].add(redemption_delay)) <= block.number, "Must wait for redemption_delay blocks before collecting redemption");
        bool sendShares = false;
        bool sendCollateral = false;
        uint sharesAmount;
        uint CollateralAmount;

        // Use Checks-Effects-Interactions pattern
        if(redeemSharesBalances[msg.sender] > 0){
            sharesAmount = redeemSharesBalances[msg.sender];
            redeemSharesBalances[msg.sender] = 0;
            unclaimedPoolShares = unclaimedPoolShares.sub(sharesAmount);

            sendShares = true;
        }
        
        if(redeemCollateralBalances[msg.sender] > 0){
            CollateralAmount = redeemCollateralBalances[msg.sender];
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral.sub(CollateralAmount);

            sendCollateral = true;
        }

        if(sendShares == true){
            SHARE.transfer(msg.sender, sharesAmount);
        }
        if(sendCollateral == true){
            collateral_token.transfer(msg.sender, CollateralAmount);
        }
    }


    // When the protocol is recollateralizing, we need to give a discount of Shares to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get Shares for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of Shares + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra Shares value from the bonus rate as an arb opportunity
    function recollateralizeUSE(uint256 collateral_amount, uint256 shares_out_min) external onlyOneBlock {
        require(recollateralizePaused == false, "Recollateralize is paused");
        updateOraclePrice();
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        uint256 share_price = USE.share_price();
        uint256 use_total_supply = USE.totalSupply().sub(global_use_supply_adj);
        uint256 global_collateral_ratio = USE.global_collateral_ratio();
        uint256 global_collat_value = USE.globalCollateralValue();

        (uint256 collateral_units, uint256 amount_to_recollat) = calcRecollateralizeUSEInner(
            collateral_amount_d18,
            getCollateralPrice(),
            global_collat_value,
            use_total_supply,
            global_collateral_ratio
        ); 

        uint256 collateral_units_precision = collateral_units.div(10 ** missing_decimals);

        uint256 shares_paid_back = amount_to_recollat.mul(uint(1e6).add(bonus_rate).sub(recollat_tax)).div(share_price);

        require(shares_out_min <= shares_paid_back, "Slippage limit reached");

        community_rate_in_share =  community_rate_in_share.add(shares_paid_back.mul(community_rate_ratio).div(PRECISION));
        collateral_token.transferFrom(msg.sender, address(this), collateral_units_precision);
        SHARE.pool_mint(msg.sender, shares_paid_back);
        
    }

    // Function can be called by an Shares holder to have the protocol buy back Shares with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    function buyBackShares(uint256 shares_amount, uint256 COLLATERAL_out_min) external onlyOneBlock {
        require(buyBackPaused == false, "Buyback is paused");
        updateOraclePrice();
        uint256 share_price = USE.share_price();
    
        BuybackShares_Params memory input_params = BuybackShares_Params(
            availableExcessCollatDV(),
            share_price,
            getCollateralPrice(),
            shares_amount
        );

        (uint256 collateral_equivalent_d18) = (calcBuyBackShares(input_params)).mul(uint(1e6).sub(buyback_tax)).div(1e6);
        uint256 collateral_precision = collateral_equivalent_d18.div(10 ** missing_decimals);

        require(COLLATERAL_out_min <= collateral_precision, "Slippage limit reached");

        community_rate_in_share  =  community_rate_in_share.add(shares_amount.mul(community_rate_ratio).div(PRECISION));
        // Give the sender their desired collateral and burn the Shares
        SHARE.pool_burn_from(msg.sender, shares_amount);
        collateral_token.transfer(msg.sender, collateral_precision);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function toggleMinting() external {
        require(hasRole(MINT_PAUSER, msg.sender));
        mintPaused = !mintPaused;
    }

    function toggleRedeeming() external {
        require(hasRole(REDEEM_PAUSER, msg.sender));
        redeemPaused = !redeemPaused;
    }

    function toggleRecollateralize() external {
        require(hasRole(RECOLLATERALIZE_PAUSER, msg.sender));
        recollateralizePaused = !recollateralizePaused;
    }
    
    function toggleBuyBack() external {
        require(hasRole(BUYBACK_PAUSER, msg.sender));
        buyBackPaused = !buyBackPaused;
    }

    function toggleCollateralPrice(uint256 _new_price) external {
        require(hasRole(COLLATERAL_PRICE_PAUSER, msg.sender));
        // If pausing, set paused price; else if unpausing, clear pausedPrice
        if(collateralPricePaused == false){
            pausedPrice = _new_price;
        } else {
            pausedPrice = 0;
        }
        collateralPricePaused = !collateralPricePaused;
    }
    
    function toggleCommunityInSharesRate(uint256 _rate) external{
        require(community_rate_in_share>0,"No SHARE rate");
        require(hasRole(COMMUNITY_RATER, msg.sender));
        uint256 _amount_rate = community_rate_in_share.mul(_rate).div(PRECISION);
        community_rate_in_share = community_rate_in_share.sub(_amount_rate);
        SHARE.pool_mint(msg.sender,_amount_rate);  
    }

    function toggleCommunityInUSERate(uint256 _rate) external{
        require(community_rate_in_use>0,"No USE rate");
        require(hasRole(COMMUNITY_RATER, msg.sender));
        uint256 _amount_rate_use = community_rate_in_use.mul(_rate).div(PRECISION);        
        community_rate_in_use = community_rate_in_use.sub(_amount_rate_use);

        uint256 _share_price_use = USE.share_price_in_use();
        uint256 _amount_rate = _amount_rate_use.mul(PRICE_PRECISION).div(_share_price_use);
        SHARE.pool_mint(msg.sender,_amount_rate);  
    }

    // Combined into one function due to 24KiB contract memory limit
    function setPoolParameters(uint256 new_ceiling, 
                               uint256 new_bonus_rate, 
                               uint256 new_redemption_delay, 
                               uint256 new_buyback_tax, 
                               uint256 new_recollat_tax,
                               uint256 use_supply_adj) external onlyByOwnerOrGovernance {
        pool_ceiling = new_ceiling;
        bonus_rate = new_bonus_rate;
        redemption_delay = new_redemption_delay; 
        buyback_tax = new_buyback_tax;
        recollat_tax = new_recollat_tax;
        global_use_supply_adj = use_supply_adj;
    }

    
    function setMintingParameters(uint256 _ratioLevel,
                                  uint256 _tax_base,
                                  uint256 _tax_multiplier) external onlyByOwnerOrGovernance{
        minting_required_reserve_ratio = _ratioLevel;
        minting_tax_base = _tax_base;
        minting_tax_multiplier = _tax_multiplier;
    }


    function setRedemptionParameters(uint256 _ratioLevel,
                                     uint256 _tax_base,
                                     uint256 _tax_multiplier,
                                     uint256 _tax_exponent,
                                     uint256 _redeem_gcr_adj) external onlyByOwnerOrGovernance{
        redemption_required_reserve_ratio = _ratioLevel;
        redemption_tax_base = _tax_base;
        redemption_tax_multiplier = _tax_multiplier;
        redemption_tax_exponent = _tax_exponent;
        redemption_gcr_adj = _redeem_gcr_adj;
    }


    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;
    }

    function setOwner(address _owner_address) external onlyByOwnerOrGovernance {
        owner_address = _owner_address;
    }
    
    function setCommunityParameters(address _community_address,uint256 _ratio) external onlyByOwnerOrGovernance {
        community_address = _community_address;
        community_rate_ratio = _ratio;
    } 

    /* ========== EVENTS ========== */

}