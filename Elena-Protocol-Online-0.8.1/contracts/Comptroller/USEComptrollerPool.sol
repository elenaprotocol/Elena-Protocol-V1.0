// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2; 

import '../@openzeppelin/contracts/math/SafeMath.sol';  
import '../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
import '../@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '../@openzeppelin/contracts/access/AccessControl.sol';
import "../Share/IShareToken.sol";
import "../USE/IUSEStablecoin.sol";
import "../USE/Pools/IUSEPool.sol"; 
import "./ProtocolValue.sol"; 
contract USEComptrollerPool is IUSEPool,ProtocolValue,AccessControl{ 
    using SafeMath for uint256;
    using SafeERC20 for IERC20; 
   
    address public use;
    address public shares;
    address public router; 
    
    bytes32 public constant USE_SHARES_COMPTROLLER = keccak256("USE_SHARES_COMPTROLLER");
    constructor() public { 
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(USE_SHARES_COMPTROLLER, _msgSender());      
    }

    modifier onlyAuthorized{
        require(hasRole(USE_SHARES_COMPTROLLER, msg.sender));
        _;
    }
    
     function collatDollarBalance() external view override returns (uint256){
         return 0;
     }
    
    function init(address _use,address _shares,address _router)  public onlyAuthorized{
        use = _use;
        shares = _shares;
        router = _router;
    }

    function getUseElenaPair() public view returns(address){
        return _getPair(router,use,shares);      
    }

    function _burnUseAndShares()  internal{
        uint256 _sharesAmount = IERC20(shares).balanceOf(address(this));
        uint256 _useAmount = IERC20(use).balanceOf(address(this));      
        if(_sharesAmount > 0){
            IShareToken(shares).burn(_sharesAmount);
        }
        if(_useAmount > 0){
            IUSEStablecoin(use).burn(_useAmount);
        }
    }

    function addUseElenaPair(uint256 _useAmount,uint256 _sharesAmount) public onlyAuthorized{
        IUSEStablecoin(use).pool_mint(address(this),_useAmount);
        IShareToken(shares).pool_mint(address(this),_sharesAmount);
        _addLiquidity(router,use,shares,_useAmount,_sharesAmount,0,0);
        _burnUseAndShares(); 
    }

    function guardUSEValue(uint256 _lpp) public onlyAuthorized{
        address _pair = getUseElenaPair();       
        _removeLiquidity(router,_pair,use,shares,_lpp);
        _burnUseAndShares(); 
    }

    function protocolValueForUSE(uint256 _lpp,uint256 _cp) public onlyAuthorized{
        address _pair = getUseElenaPair();
        _protocolValue(router,_pair,use,_lpp,_cp);
        _burnUseAndShares(); 
    } 
    
    function protocolValueForElena(uint256 _lpp,uint256 _cp) public onlyAuthorized{
        address _pair = getUseElenaPair();
        _protocolValue(router,_pair,shares,_lpp,_cp);
        _burnUseAndShares(); 
    } 
}
