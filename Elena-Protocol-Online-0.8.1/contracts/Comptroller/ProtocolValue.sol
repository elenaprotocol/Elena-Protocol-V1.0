 //SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2; 

import '../@openzeppelin/contracts/math/SafeMath.sol';  
import '../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
import '../@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "../Uniswap/Interfaces/IUniswapV2Pair.sol";  
import "../Uniswap/Interfaces/IUniswapV2Factory.sol";  
import "../Uniswap/Interfaces/IUniswapV2Router01.sol";  
 
abstract contract ProtocolValue  { 
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    uint256 public constant PERCENT = 1e6;  
    struct PCVInfo{
        //remove 
        uint256 targetTokenRemoved;
        uint256 otherTokenRemoved;
        uint256 liquidityRemoved;
        //swap
        uint256 otherTokenIn;
        uint256 targetTokenOut;
        //add
        uint256 targetTokenAdded;
        uint256 otherTokenAdded;
        uint256 liquidityAdded; 
        //remain
        uint256 targetTokenRemain;       
    }
    event PCVResult(address targetToken,address otherToken,uint256 lpp,uint256 cp,PCVInfo pcv);
    
    function _getPair(address router,address token0,address token1) internal view returns(address){
        address _factory =  IUniswapV2Router01(router).factory();
        return IUniswapV2Factory(_factory).getPair(token0,token1);
    }

    function _checkOrApproveRouter(address _router,address _token,uint256 _amount) internal{
        if(IERC20(_token).allowance(address(this),_router) < _amount){
            IERC20(_token).safeApprove(_router,0);
            IERC20(_token).safeApprove(_router,uint256(-1));
        }        
    }
  
    function _swapToken(address router,address tokenIn,address tokenOut,uint256 amountIn) internal returns (uint256){
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut; 
        uint256 exptime = block.timestamp+60;
        _checkOrApproveRouter(router,tokenIn,amountIn); 
        return IUniswapV2Router01(router).swapExactTokensForTokens(amountIn,0,path,address(this),exptime)[1];
    }


    function _addLiquidity(
        address router,
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal returns (uint amountA, uint amountB, uint liquidity){
         uint256 exptime = block.timestamp+60;
        _checkOrApproveRouter(router,tokenA,amountADesired);
        _checkOrApproveRouter(router,tokenB,amountBDesired);
        return IUniswapV2Router01(router).addLiquidity(tokenA,tokenB,amountADesired,amountBDesired,amountAMin,amountBMin,address(this), exptime);
    }

    function _removeLiquidity(
        address router,
        address pair,
        address tokenA,
        address tokenB,
        uint256 lpp 
    ) internal returns (uint amountA, uint amountB,uint256 liquidity){
        uint256 exptime = block.timestamp+60;
        liquidity = IERC20(pair).balanceOf(address(this)).mul(lpp).div(PERCENT);
        _checkOrApproveRouter(router,pair,liquidity);
        (amountA, amountB) = IUniswapV2Router01(router).removeLiquidity(tokenA,tokenB,liquidity,0,0,address(this),exptime);
    }

    function getOtherToken(address _pair,address _targetToken) public view returns(address){
        address token0 = IUniswapV2Pair(_pair).token0();
        address token1 = IUniswapV2Pair(_pair).token1(); 
        require(token0 == _targetToken || token1 == _targetToken,"!_targetToken");
        return _targetToken == token0 ? token1 : token0;
    } 


    function _protocolValue(address _router,address _pair,address _targetToken,uint256 _lpp,uint256 _cp) internal returns(uint256){
        //only guard _targetToken 
        address otherToken = getOtherToken(_pair,_targetToken); 
        PCVInfo memory pcv =  PCVInfo(0,0,0,0,0,0,0,0,0);
        //removeLiquidity 
        (pcv.targetTokenRemoved,pcv.otherTokenRemoved,pcv.liquidityRemoved) = _removeLiquidity(_router,_pair,_targetToken,otherToken,_lpp);
        //swap _targetToken
        pcv.otherTokenIn = pcv.otherTokenRemoved.mul(_cp).div(PERCENT);
        pcv.targetTokenOut = _swapToken(_router,otherToken,_targetToken,pcv.otherTokenIn);
        
        //addLiquidity
        uint256 otherTokenRemain  = (pcv.otherTokenRemoved).sub((pcv.otherTokenIn));
        uint256 targetTokenAmount = (pcv.targetTokenRemoved).add(pcv.targetTokenOut);        
        (pcv.targetTokenAdded, pcv.otherTokenAdded, pcv.liquidityAdded) = _addLiquidity(_router,
                                                                                        _targetToken,otherToken,
                                                                                        targetTokenAmount,otherTokenRemain,
                                                                                        0,otherTokenRemain);
        pcv.targetTokenRemain = targetTokenAmount.sub(pcv.targetTokenAdded);
        emit PCVResult(_targetToken,otherToken,_lpp,_cp,pcv);
        return pcv.targetTokenRemain;  
    }
  
}