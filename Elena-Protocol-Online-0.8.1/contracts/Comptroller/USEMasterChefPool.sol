// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2; 
import '../@openzeppelin/contracts/access/Ownable.sol';
import '../@openzeppelin/contracts/math/SafeMath.sol';  
import '../@openzeppelin/contracts/token/ERC20/IERC20.sol'; 
import '../@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '../@openzeppelin/contracts/access/AccessControl.sol';
import "../Share/IShareToken.sol";
import "../USE/IUSEStablecoin.sol";
import "../USE/Pools/IUSEPool.sol"; 
import "./ProtocolValue.sol"; 
// MasterChef is the master of rewardToken. He can make rewardToken and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once rewardToken is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract USEMasterChefPool is IUSEPool,AccessControl,ProtocolValue {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of rewardTokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accrewardTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accrewardTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. rewardTokens to distribute per block.
        uint256 lastRewardBlock; // Last block number that rewardTokens distribution occurs.
        uint256 accrewardTokenPerShare; // Accumulated rewardTokens per share, times 1e12. See below.
    }
    uint256 public constant PRECISION = 1e6;
    bytes32 public constant COMMUNITY_MASTER = keccak256("COMMUNITY_MASTER");
    bytes32 public constant COMMUNITY_MASTER_PCV = keccak256("COMMUNITY_MASTER_PCV");
    // The rewardToken TOKEN!
    IShareToken public rewardToken;
    address public swapRouter;
    // Dev address.
    address public communityaddr;
    uint256 public communityRateAmount; 
    // rewardToken tokens created per block.
    uint256 public rewardTokenPerBlock; 
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when rewardToken mining starts.
    uint256 public startBlock;
    uint256 public miningEndBlock;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount,uint256 rewardToken);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount,uint256 rewardToken);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        address _rewardToken,
        address _communityaddr,
        address _swapRouter,
        uint256 _rewardTokenPerBlock,
        uint256 _startBlock,
        uint256 _miningEndBlock
    ) public {
        rewardToken =IShareToken(_rewardToken);
        communityaddr = _communityaddr;
        swapRouter = _swapRouter;
        rewardTokenPerBlock = _rewardTokenPerBlock; 
        startBlock = _startBlock;
        miningEndBlock = _miningEndBlock;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(COMMUNITY_MASTER, _communityaddr);
        grantRole(COMMUNITY_MASTER_PCV, _communityaddr);        
    }

    modifier onlyAdmin(){
         require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender));
         _;
    }

    modifier onlyPCVMaster(){
         require(hasRole(COMMUNITY_MASTER_PCV, msg.sender));
         _;
    }
    
    function collatDollarBalance() external view override returns (uint256){
         return 0;
     }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyAdmin {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =  block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accrewardTokenPerShare: 0
            })
        );
    }

    // Update the given pool's rewardToken allocation point. Can only be called by the owner.
    function set(uint256 _pid,uint256 _allocPoint, bool _withUpdate) public onlyAdmin {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }
 

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256){
        return _to.sub(_from);
    }

    // View function to see pending rewardTokens on frontend.
    function pendingrewardToken(uint256 _pid, address _user)external view returns (uint256){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accrewardTokenPerShare = pool.accrewardTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 rewardTokenReward =
                multiplier.mul(rewardTokenPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accrewardTokenPerShare = accrewardTokenPerShare.add(
                rewardTokenReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accrewardTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 rewardTokenReward = multiplier.mul(rewardTokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        communityRateAmount = communityRateAmount.add(rewardTokenReward.div(5));
        rewardToken.pool_mint(address(this), rewardTokenReward);

        pool.accrewardTokenPerShare = pool.accrewardTokenPerShare.add(
            rewardTokenReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for rewardToken allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        uint256 pending = 0;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            pending = user.amount.mul(pool.accrewardTokenPerShare).div(1e12).sub(user.rewardDebt);
            safeRewardTokenTransfer(msg.sender, pending);
        }
        //save gas for claimReward
        if(_amount > 0){
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accrewardTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount,pending);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accrewardTokenPerShare).div(1e12).sub(user.rewardDebt);

        safeRewardTokenTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accrewardTokenPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount,pending);
    }

    function claimReward(uint256 _pid) public {
        deposit(_pid,0);
    }

    function protocolValueForUSE(address _pair,address _use,uint256 _lpp,uint256 _cp) public onlyPCVMaster{
        require(block.number >= miningEndBlock,"pcv: only start after mining");
        uint256 _useRemain =  _protocolValue(swapRouter,_pair,_use,_lpp,_cp);
        IUSEStablecoin(_use).burn(_useRemain); 
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe rewardToken transfer function, just in case if rounding error causes pool to not have enough rewardTokens.
    function safeRewardTokenTransfer(address _to, uint256 _amount) internal {
        uint256 rewardTokenBal = rewardToken.balanceOf(address(this));
        if (_amount > rewardTokenBal) {
            rewardToken.transfer(_to, rewardTokenBal);
        } else {
            rewardToken.transfer(_to, _amount);
        }
    }

    function communityRate(uint256 _rate) public{
        require(communityRateAmount > 0,"No community rate");
        require(hasRole(COMMUNITY_MASTER, msg.sender),"!role");
        uint256 _community_amount = communityRateAmount.mul(_rate).div(PRECISION);
        communityRateAmount = communityRateAmount.sub(_community_amount);
        rewardToken.pool_mint(msg.sender,_community_amount);   
    }

    function rewardTokenRate(uint256 _rewardTokenPerBlock) public onlyAdmin{ 
         rewardTokenPerBlock = _rewardTokenPerBlock;
    }

    function updateStartBlock(uint256 _startBlock,uint256 _miningEndBlock) public onlyAdmin{ 
         startBlock = _startBlock;
         miningEndBlock = _miningEndBlock;
    }
 
}
