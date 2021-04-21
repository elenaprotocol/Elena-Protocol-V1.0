// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import '../@openzeppelin/contracts/math/SafeMath.sol'; 
import '../@openzeppelin/contracts/access/Ownable.sol';
import '../@openzeppelin/contracts/access/AccessControl.sol';
import '../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
import '../@openzeppelin/contracts/token/ERC20/SafeERC20.sol'; 
import "../Common/ITradeMining.sol";
import "../Common/ERC20Custom.sol";
import "../USE/IUSEStablecoin.sol"; 
import "../Oracle/IUniswapPairOracle.sol"; 
import "./Pools/IUSEPool.sol";

contract USEToken is ERC20Custom, AccessControl {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    enum PriceChoice { USE, SHARE }
    
    IUniswapPairOracle public USEDAIOracle;
    IUniswapPairOracle public USESharesOracle;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public owner_address;
    address public creator_address;
    address public timelock_address; // Governance timelock address
    ITradeMining public use_trade_mining; 

    uint256 public constant genesis_supply = 1000e18; //help with establishing the Uniswap pools, as they need liquidity

    // The addresses in this array are added by the oracle and these contracts are able to mint USE
    address[] public use_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public use_pools; 

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102 
    uint256 public share_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of USE at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");
    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyCollateralRatioPauser() {
        require(hasRole(COLLATERAL_RATIO_PAUSER, msg.sender));
        _;
    }

    modifier onlyPools() {
       require(use_pools[msg.sender] == true, "Only USE pools can call this function");
        _;
    } 
    
    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == owner_address || msg.sender == timelock_address , "You are not the owner,  or timelock");
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner_address 
            || msg.sender == timelock_address 
            || use_pools[msg.sender] == true, 
            "You are not the owner, the governance timelock, or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol, 
        address _timelock_address
    ) public {
        name = _name;
        symbol = _symbol;
        creator_address = _msgSender();        
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        owner_address = _msgSender();
        
        timelock_address = _timelock_address;
        _mint(creator_address, genesis_supply);
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(COLLATERAL_RATIO_PAUSER, creator_address);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        share_step = 2500; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // USE system starts off fully collateralized (6 decimals of precision)
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000; // Collateral ratio will adjust according to the $1 price target at genesis
        price_band = 5000; // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis
    }

    
    function _transfer(address sender,address recipient, uint256 amount) internal override {
        super._transfer(sender, recipient, amount);
        if (address(use_trade_mining) != address(0)) {
            use_trade_mining.tradeMining(sender, recipient, msg.sender, amount);
        }
    }

    /* ========== VIEWS ========== */
 

    // Returns X USE = 1 USD
    function use_price() public view returns (uint256) {
        address usd_address = USEDAIOracle.getPairToken(address(this));
        return uint256(USEDAIOracle.consult(usd_address, PRICE_PRECISION));
    }

    // Returns X Share = 1 USE
    function share_price_in_use()  public view returns (uint256) {
        return  uint256(USESharesOracle.consult(address(this), PRICE_PRECISION));
    }

    // Returns X Share = 1 USD
    function share_price()  public view returns (uint256) {
        uint256 _use_price = use_price(); 
        return share_price_in_use().mul(_use_price).div(PRICE_PRECISION);
    }
     
    // Iterate through all USE pools and calculate all value of collateral in all pools globally 
    function globalCollateralValue() public view returns (uint256) {
        uint256 total_collateral_value_d18 = 0; 

        for (uint i = 0; i < use_pools_array.length; i++){ 
            // Exclude null addresses
            if (use_pools_array[i] != address(0)){
                total_collateral_value_d18 = total_collateral_value_d18.add(IUSEPool(use_pools_array[i]).collatDollarBalance());
            }
        }
        return total_collateral_value_d18;
    }
    /* ========== PUBLIC FUNCTIONS ========== */
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public onlyCollateralRatioPauser{
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 share_price_cur = share_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setUSEStep()) 
        
        if (share_price_cur > price_target.add(price_band)) { //decrease collateral ratio
            if(global_collateral_ratio <= share_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(share_step);
            }
        } else if (share_price_cur < price_target.sub(price_band)) { //increase collateral ratio
            if(global_collateral_ratio.add(share_step) >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio.add(share_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion
    }


    function swapCollateralAmount() external view returns(uint256){
        address usd_address = USEDAIOracle.getPairToken(address(this));
        return USEDAIOracle.getSwapTokenReserve(usd_address);
    }
    

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit USETokenBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other USE pools will call to mint new USE 
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit USETokenMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) public onlyByOwnerOrGovernance {
        require(use_pools[pool_address] == false, "address already exists");
        use_pools[pool_address] = true; 
        use_pools_array.push(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) public onlyByOwnerOrGovernance {
        require(use_pools[pool_address] == true, "address doesn't exist already");
        
        // Delete from the mapping
        delete use_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < use_pools_array.length; i++){ 
            if (use_pools_array[i] == pool_address) {
                use_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }
    }

    function setOwner(address _owner_address) external onlyByOwnerOrGovernance {
        owner_address = _owner_address;
    }

    
    function setUSETradeMiningPool(address _use_trade_mining) external onlyByOwnerOrGovernance {
        use_trade_mining = ITradeMining(_use_trade_mining);
    } 

    function setUSEStep(uint256 _new_step) public onlyByOwnerOrGovernance {
        share_step = _new_step;
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerOrGovernance {
        price_target = _new_price_target;
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerOrGovernance {
    	refresh_cooldown = _new_cooldown;
    }


    function setCollateralRatio(uint256 _ratio)  public onlyByOwnerOrGovernance {
        global_collateral_ratio = _ratio;
    } 

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;
    } 

    function setPriceBand(uint256 _price_band) external onlyByOwnerOrGovernance {
        price_band = _price_band;
    }

    // Sets the use_usd(Dai) Uniswap oracle address 
    function setUSEDAIOracle(address _oracle) public onlyByOwnerOrGovernance {
        USEDAIOracle = IUniswapPairOracle(_oracle);  
        require(USEDAIOracle.containsToken(address(this)),"!use");
    }

    // Sets the use_elena Uniswap oracle address 
    function setUSESharesOracle(address _oracle) public onlyByOwnerOrGovernance {
        USESharesOracle = IUniswapPairOracle(_oracle);
        require(USESharesOracle.containsToken(address(this)),"!use");
    }
   

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;
    }

    /* ========== EVENTS ========== */

    // Track USE burned
    event USETokenBurned(address indexed from, address indexed to, uint256 amount);

    // Track USE minted
    event USETokenMinted(address indexed from, address indexed to, uint256 amount);
}
