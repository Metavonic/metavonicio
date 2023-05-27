// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IVenoStorm.sol";

/**
 * @title  VenoFountain
 * @notice This contract is a vault for user to lock Veno and get Veno as reward
 */
contract VenoFountain is ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    struct Stake {
        uint256 amount;
        uint256 poolId;
        uint256 weightedAmount;
        uint256 stakeTimestamp;
        uint256 unlockTimestamp;
        bool active;
    }

    struct PoolInfo {
        uint256 multiplier;
        uint256 lockPeriod;
        uint256 totalStaked;
        uint256 earlyVaultPenalty; // 600 represent 60% amount as penalty for early withdrawal
    }

    struct UserInfo {
        uint256 weightedAmount;
        uint256 rewardDebt;
        uint256 pendingVaultPenaltyReward; // how much pending vault penalty reward to claim
        uint256 vaultPenaltyDebt; // similar concept like rewardDebt for vault penalty
        Stake[] stakes;
    }

    mapping(address => UserInfo) public userInfo;
    PoolInfo[] public poolInfo;

    // multiplier -> lockPeriod -> poolID (in +1 format)
    mapping(uint256 => mapping(uint256 => uint256)) public activePoolMap;

    uint256 public lastVnoBalance;
    uint256 public lastRewardBlock;
    uint256 public accTokenPerShare;

    uint256 public accVaultPenaltyPerShare; // similar to accTokenPerShare, for keeping track of vault penalty per share
    uint256 public constant MAX_EARLY_VAULT_PENALTY = 1_000;
    uint256 public vaultPenaltyClaimPid; // claimed vault penalty willl be locked in this pid
    bool public isWithdrawEarlyEnabled;
    address public treasury;

    IERC20Upgradeable public vno;

    IVenoStorm public venoStorm;
    IERC20Upgradeable public depositToken;
    uint256 public constant DEPOSIT_TOKEN_ID = 0;

    uint256 public constant PRECISION = 10**18;

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 indexed stakeId,
        uint256 amount,
        uint256 weightedAmount,
        uint256 unlockTimestamp
    );
    event Withdraw(address indexed user, uint256 indexed stakeId, uint256 amount, uint256 weightedAmount);
    event WithdrawEarly(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amount,
        uint256 weightedAmount
    );
    event Upgrade(
        address indexed user,
        uint256 indexed stakeId,
        uint256 indexed newPid,
        uint256 newWeightedAmount,
        uint256 newUnlockTimestamp
    );
    event AddPool(uint256 indexed poolId, uint256 multiplier, uint256 lockPeriod, uint256 earlyVaultPenalty);
    event SetPool(uint256 indexed poolId, uint256 multiplier, uint256 lockPeriod, uint256 earlyVaultPenalty);
    event SetVaultPenaltyClaimPid(uint256 vaultPenaltyClaimPid);
    event ClaimVaultPenalty(address indexed user, uint256 pendingVaultPenaltyReward);
    event SetTreasury(address treasury);
    event SetIsWithdrawEarlyEnabled(bool isWithdrawEarlyEnabled);

    modifier onlyWithdrawEarlyEnabled() {
        require(isWithdrawEarlyEnabled == true, "Withdraw early not enabled");
        _;
    }

    function initialize(
        IVenoStorm _venoStorm,
        IERC20Upgradeable _vno,
        IERC20Upgradeable _depositToken,
        address _treasury
    ) public initializer {
        require(address(_venoStorm) != address(0), "venoStorm addresss zero");
        require(address(_vno) != address(0), "vno address zero");
        require(address(_depositToken) != address(0), "depositToken address zero");
        require(address(_treasury) != address(0), "treasury address zero");

        venoStorm = _venoStorm;
        vno = _vno;
        depositToken = _depositToken;
        treasury = _treasury;

        // Disable at launch until a further date
        isWithdrawEarlyEnabled = false;

        // If pool is not setup, user will get an error in claimVaultPenalty
        vaultPenaltyClaimPid = 3;

        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __ERC20_init("Veno Fountain Boost Token", "VFB");
    }

    function batchWithdraw(uint256[] calldata _stakeIds) external {
        for (uint256 i; i < _stakeIds.length; i++) {
            withdraw(_stakeIds[i]);
        }
    }

    function batchUpgrade(uint256[] calldata _stakeIds, uint256[] calldata _newPids) external {
        require(_stakeIds.length == _newPids.length, "VenoFountain: Array length mismatch");
        for (uint256 i; i < _stakeIds.length; i++) {
            upgrade(_stakeIds[i], _newPids[i]);
        }
    }

    function batchWithdrawEarly(uint256[] calldata _stakeIds) external {
        for (uint256 i; i < _stakeIds.length; i++) {
            withdrawEarly(_stakeIds[i]);
        }
    }

    function getUserInfo(address _user)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            Stake[] memory
        )
    {
        UserInfo memory user = userInfo[_user];
        return (
            user.weightedAmount,
            user.rewardDebt,
            user.pendingVaultPenaltyReward,
            user.vaultPenaltyDebt,
            user.stakes
        );
    }

    /**
     * @dev Just in case there are too many Stakes and jams `getUserInfo`
     */
    function getUserStake(address _user, uint256 _stakeId) external view returns (Stake memory) {
        return userInfo[_user].stakes[_stakeId];
    }

    function pendingVno(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 pendingVnoInFarm = venoStorm.pendingVno(DEPOSIT_TOKEN_ID, address(this));
        uint256 pendingAccTokenPerShare = accTokenPerShare;
        if (totalSupply() != 0) {
            pendingAccTokenPerShare += (PRECISION * pendingVnoInFarm) / totalSupply();
        }
        return (user.weightedAmount * pendingAccTokenPerShare) / PRECISION - user.rewardDebt;
    }

    function pendingVaultPenaltyReward(address _user) external view returns (uint256) {
        UserInfo memory user = userInfo[_user];
        uint256 pendingVaultPenaltyReward = (user.weightedAmount * accVaultPenaltyPerShare) /
            PRECISION -
            user.vaultPenaltyDebt;

        return user.pendingVaultPenaltyReward + pendingVaultPenaltyReward;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function depositVenoStorm() external onlyOwner {
        depositToken.approve(address(venoStorm), 1);
        venoStorm.deposit(DEPOSIT_TOKEN_ID, 1, IVenoVault(address(0)));
    }

    function deposit(uint256 _pid, uint256 _amount) public {
        depositFor(_pid, _amount, msg.sender);
    }

    /**
     * @param _user address to deposit on behalf on. Veno will come from msg.sender instead of user
     */
    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.multiplier > 0, "VenoFountain: Invalid Pool ID");

        _harvest();

        Stake memory stake;
        UserInfo storage user = userInfo[_user];

        if (user.weightedAmount > 0) {
            uint256 pending = (user.weightedAmount * accTokenPerShare) / PRECISION - user.rewardDebt;
            if (pending > 0) {
                // In case of rounding error, contract does not have enough vno
                if (lastVnoBalance < pending) {
                    pending = lastVnoBalance;
                }
                vno.safeTransfer(_user, pending);
                lastVnoBalance = vno.balanceOf(address(this));
            }

            user.pendingVaultPenaltyReward +=
                (user.weightedAmount * accVaultPenaltyPerShare) /
                PRECISION -
                user.vaultPenaltyDebt;
        }

        if (_amount > 0) {
            uint256 weightedAmount = pool.multiplier * _amount;
            stake.amount = _amount;
            stake.poolId = _pid;
            stake.weightedAmount = weightedAmount;
            stake.stakeTimestamp = block.timestamp;
            stake.unlockTimestamp = block.timestamp + pool.lockPeriod;
            stake.active = true;

            pool.totalStaked += _amount;

            vno.safeTransferFrom(msg.sender, address(this), _amount);
            lastVnoBalance = vno.balanceOf(address(this));
            _mint(_user, weightedAmount);

            user.stakes.push(stake);
            user.weightedAmount += weightedAmount;
        }

        user.rewardDebt = (user.weightedAmount * accTokenPerShare) / PRECISION;
        user.vaultPenaltyDebt = (user.weightedAmount * accVaultPenaltyPerShare) / PRECISION;
        emit Deposit(
            _user,
            _pid,
            user.stakes.length - 1,
            _amount,
            stake.weightedAmount,
            stake.unlockTimestamp
        );

        // Update boosted multiplier
        venoStorm.updateBoostedAmount(_user);
    }

    function withdraw(uint256 _stakeId) public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        Stake storage stake = user.stakes[_stakeId];
        PoolInfo storage pool = poolInfo[stake.poolId];
        require(block.timestamp >= stake.unlockTimestamp, "VenoFountain: Stake not Ready for Withdrawal");
        require(stake.active, "VenoFountain: Stake not Active");

        _harvest();

        if (user.weightedAmount > 0) {
            uint256 pending = (user.weightedAmount * accTokenPerShare) / PRECISION - user.rewardDebt;
            if (pending > 0) {
                // In case of rounding error, contract does not have enough vno
                if (lastVnoBalance < pending) {
                    pending = lastVnoBalance;
                }
                vno.safeTransfer(msg.sender, pending);
                lastVnoBalance = vno.balanceOf(address(this));
            }

            user.pendingVaultPenaltyReward +=
                (user.weightedAmount * accVaultPenaltyPerShare) /
                PRECISION -
                user.vaultPenaltyDebt;
        }
        pool.totalStaked -= stake.amount;
        stake.active = false;

        vno.safeTransfer(msg.sender, stake.amount);
        lastVnoBalance = vno.balanceOf(address(this));

        user.weightedAmount -= stake.weightedAmount;
        _burn(msg.sender, stake.weightedAmount);

        user.rewardDebt = (user.weightedAmount * accTokenPerShare) / PRECISION;
        user.vaultPenaltyDebt = (user.weightedAmount * accVaultPenaltyPerShare) / PRECISION;
        emit Withdraw(msg.sender, _stakeId, stake.amount, stake.weightedAmount);

        // Update boosted multiplier
        venoStorm.updateBoostedAmount(msg.sender);
    }

    function withdrawEarly(uint256 _stakeId) public onlyWithdrawEarlyEnabled nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        Stake storage stake = user.stakes[_stakeId];
        PoolInfo storage pool = poolInfo[stake.poolId];
        require(
            block.timestamp < stake.unlockTimestamp,
            "VenoFountain: Stake ready for withdraw without penalty"
        );
        require(stake.active, "VenoFountain: Stake not Active");

        _harvest();

        if (user.weightedAmount > 0) {
            uint256 pending = (user.weightedAmount * accTokenPerShare) / PRECISION - user.rewardDebt;
            if (pending > 0) {
                // In case of rounding error, contract does not have enough vno
                if (lastVnoBalance < pending) {
                    pending = lastVnoBalance;
                }
                vno.safeTransfer(msg.sender, pending);
                lastVnoBalance = vno.balanceOf(address(this));
            }

            user.pendingVaultPenaltyReward +=
                (user.weightedAmount * accVaultPenaltyPerShare) /
                PRECISION -
                user.vaultPenaltyDebt;
        }

        user.weightedAmount -= stake.weightedAmount;
        _burn(msg.sender, stake.weightedAmount);

        // Update vault penalty debt earlier as accVaultPenaltyPerShare will increase below and
        // user might have existing stake that can take a portion of early vault penalty fee
        user.vaultPenaltyDebt = (user.weightedAmount * accVaultPenaltyPerShare) / PRECISION;

        // Calculate out how much to user, treasury and vault staker
        uint256 penaltyAmt = (stake.amount * pool.earlyVaultPenalty) / MAX_EARLY_VAULT_PENALTY;
        uint256 treasuryAmt = penaltyAmt / 2; // 50/50 to treasury and vault
        uint256 vaultStakerAmt = penaltyAmt - treasuryAmt;
        uint256 userAmtAfterPenalty = stake.amount - penaltyAmt;

        // Transfer to user, treasury and vault stakers
        vno.safeTransfer(msg.sender, userAmtAfterPenalty);
        vno.safeTransfer(treasury, treasuryAmt);
        lastVnoBalance = vno.balanceOf(address(this));

        // If totalSupply = 0, user cannot early withdraw - expected for contract to throw div by 0 error
        // Happens when user's stake somehow is the only stake in the system.
        accVaultPenaltyPerShare += (PRECISION * vaultStakerAmt) / totalSupply();

        pool.totalStaked -= stake.amount;
        stake.active = false;

        user.rewardDebt = (user.weightedAmount * accTokenPerShare) / PRECISION;
        emit WithdrawEarly(msg.sender, _stakeId, stake.amount, stake.weightedAmount);

        // Update boosted multiplier
        venoStorm.updateBoostedAmount(msg.sender);
    }

    function upgrade(uint256 _stakeId, uint256 _newPid) public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        Stake storage stake = user.stakes[_stakeId];
        PoolInfo storage oldPool = poolInfo[stake.poolId];
        PoolInfo storage newPool = poolInfo[_newPid];
        require(stake.active, "VenoFountain: Stake not Active");
        require(
            stake.stakeTimestamp + newPool.lockPeriod >= stake.unlockTimestamp,
            "VenoFountain: New Stake must be longer"
        );
        require(newPool.multiplier > stake.weightedAmount / stake.amount, "VenoFountain: Why downgrade");

        _harvest();
        if (user.weightedAmount > 0) {
            uint256 pending = (user.weightedAmount * accTokenPerShare) / PRECISION - user.rewardDebt;
            if (pending > 0) {
                // In case of rounding error, contract does not have enough vno
                if (lastVnoBalance < pending) {
                    pending = lastVnoBalance;
                }
                vno.safeTransfer(msg.sender, pending);
                lastVnoBalance = vno.balanceOf(address(this));
            }

            user.pendingVaultPenaltyReward +=
                (user.weightedAmount * accVaultPenaltyPerShare) /
                PRECISION -
                user.vaultPenaltyDebt;
        }

        stake.poolId = _newPid;
        stake.unlockTimestamp = stake.stakeTimestamp + newPool.lockPeriod;

        uint256 upgradeAmount = newPool.multiplier * stake.amount - stake.weightedAmount;
        user.weightedAmount += upgradeAmount;
        stake.weightedAmount += upgradeAmount;
        _mint(msg.sender, upgradeAmount);

        oldPool.totalStaked -= stake.amount;
        newPool.totalStaked += stake.amount;

        user.rewardDebt = (user.weightedAmount * accTokenPerShare) / PRECISION;
        user.vaultPenaltyDebt = (user.weightedAmount * accVaultPenaltyPerShare) / PRECISION;
        emit Upgrade(msg.sender, _stakeId, _newPid, stake.weightedAmount, stake.unlockTimestamp);

        // Update boosted multiplier
        venoStorm.updateBoostedAmount(msg.sender);
    }

    /**
     * @notice Claim vault penalty accumulated. Vault penalty reward will be locked
     *         into a pid for the user.
     */
    function claimVaultPenalty() public {
        UserInfo storage user = userInfo[msg.sender];

        // Check any pending vault amount and add to user's pendingVaultPenaltyReward
        user.pendingVaultPenaltyReward +=
            (user.weightedAmount * accVaultPenaltyPerShare) /
            PRECISION -
            user.vaultPenaltyDebt;

        // Then update vaultPenaltyDebt
        user.vaultPenaltyDebt = (user.weightedAmount * accVaultPenaltyPerShare) / PRECISION;

        require(user.pendingVaultPenaltyReward > 0, "No vault penalty");

        // Update user pendingVaultPenaltyReward
        uint256 pendingVaultPenaltyReward = user.pendingVaultPenaltyReward;
        user.pendingVaultPenaltyReward = 0;

        // Deposit pendingVaultPenaltyReward from the user into a pid
        // 1. Transfer pendingVaultPenaltyReward to the user
        // 2. Immediately take pendingVaultPenaltyReward from user and deposit into pid
        vno.safeTransfer(msg.sender, pendingVaultPenaltyReward);
        lastVnoBalance = vno.balanceOf(address(this));
        deposit(vaultPenaltyClaimPid, pendingVaultPenaltyReward);

        emit ClaimVaultPenalty(msg.sender, pendingVaultPenaltyReward);
    }

    /**
     * @param _earlyVaultPenalty 600 would mean 60%, 505 would mean 50.5% of staked token as penalty
     */
    function add(
        uint256 _multiplier,
        uint256 _lockPeriod,
        uint256 _earlyVaultPenalty
    ) public onlyOwner {
        require(activePoolMap[_multiplier][_lockPeriod] == 0, "VenoFountain: Duplicate Pool");
        require(_multiplier > 0, "VenoFountain: Multiplier must be > 0");
        require(
            _earlyVaultPenalty <= MAX_EARLY_VAULT_PENALTY,
            "VenoFountain: earlyVaultPenalty is over limit"
        );
        poolInfo.push(
            PoolInfo({
                multiplier: _multiplier,
                lockPeriod: _lockPeriod,
                totalStaked: 0,
                earlyVaultPenalty: _earlyVaultPenalty
            })
        );
        activePoolMap[_multiplier][_lockPeriod] = poolInfo.length;
        emit AddPool(poolInfo.length - 1, _multiplier, _lockPeriod, _earlyVaultPenalty);
    }

    /**
     * @notice Early vault penalty changes will only apply for future early withdrawal
     * @param  _earlyVaultPenalty 600 would mean 60%, 505 would mean 50.5% of staked token as penalty
     */
    function set(
        uint256 _pid,
        uint256 _multiplier,
        uint256 _lockPeriod,
        uint256 _earlyVaultPenalty
    ) public onlyOwner {
        require(activePoolMap[_multiplier][_lockPeriod] == 0, "VenoFountain: Duplicate Pool");
        require(_multiplier > 0, "VenoFountain: Multiplier must be > 0");
        require(
            _earlyVaultPenalty <= MAX_EARLY_VAULT_PENALTY,
            "VenoFountain: earlyVaultPenalty is over limit"
        );
        _harvest();

        PoolInfo storage pool = poolInfo[_pid];
        activePoolMap[pool.multiplier][pool.lockPeriod] = 0;
        pool.multiplier = _multiplier;
        pool.lockPeriod = _lockPeriod;
        pool.earlyVaultPenalty = _earlyVaultPenalty;
        activePoolMap[_multiplier][_lockPeriod] = _pid + 1;

        emit SetPool(_pid, _multiplier, _lockPeriod, _earlyVaultPenalty);
    }

    /**
     * @dev If pid does not exist, this will throw index out of bound error
     */
    function setVaultPenaltyClaimPid(uint256 _vaultPenaltyClaimPid) public onlyOwner {
        require(poolInfo[_vaultPenaltyClaimPid].multiplier > 0, "pid should have multiplier");

        vaultPenaltyClaimPid = _vaultPenaltyClaimPid;
        emit SetVaultPenaltyClaimPid(vaultPenaltyClaimPid);
    }

    function setTreasury(address _treasury) public onlyOwner {
        require(address(_treasury) != address(0), "treasury address(0)");

        treasury = _treasury;
        emit SetTreasury(treasury);
    }

    function setIsWithdrawEarlyEnabled(bool _isWithdrawEarlyEnabled) public onlyOwner {
        isWithdrawEarlyEnabled = _isWithdrawEarlyEnabled;

        emit SetIsWithdrawEarlyEnabled(isWithdrawEarlyEnabled);
    }

    function _harvest() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (totalSupply() == 0) {
            lastRewardBlock = block.number;
            return;
        }

        // Deposit with vault as address 0 as the pool does not lock any reward
        venoStorm.deposit(DEPOSIT_TOKEN_ID, 0, IVenoVault(address(0)));

        uint256 harvestedVno = vno.balanceOf(address(this)) - lastVnoBalance;
        lastVnoBalance = vno.balanceOf(address(this));
        accTokenPerShare += (PRECISION * harvestedVno) / totalSupply();
        lastRewardBlock = block.number;
    }

    /**
     * @dev BOOST Token is currently non-transferable
     */
    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal pure override {
        require(_from == address(0) || _to == address(0), "VenoFountain: Transfer not permitted");
    }

    /**
     * @dev Required by EIP-1822 UUPS
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
