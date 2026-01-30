// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/*
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║                                                                          ║
 * ║                    PROTOCOL PROTECTION LAYER (PPL)                       ║
 * ║                         VERSION 2.0                                      ║
 * ║                                                                          ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  Licensed under the Business Source License 1.1 (BUSL-1.1)               ║
 * ║                                                                          ║
 * ║  Licensor:            DYBL Foundation                                    ║
 * ║  Licensed Work:       Protocol Protection Layer                          ║
 * ║  Change Date:         May 10, 2029                                       ║
 * ║  Change License:      MIT                                                ║
 * ║                                                                          ║
 * ║  Contact: dybl7@proton.me | Twitter: @DYBL77                             ║
 * ║                                                                          ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 *
 * @title ProtocolProtectionLayer V2.0
 * @author DYBL Foundation
 * @notice Yield-funded embedded protection. Deposit, earn, withdraw anytime.
 *
 * @dev The Concept:
 *      You came for yield. Protection is included.
 *      
 *      Like train tickets with delay compensation built in.
 *      Like credit cards with purchase protection.
 *      You didn't pay extra. It's just there.
 *
 * @dev How It Works:
 *      1. User deposits USDC (or other token)
 *      2. ALL funds go to Aave, earning yield
 *      3. Yield is split: 80% user / 10% seed / 10% treasury
 *      4. User can withdraw principal ANYTIME
 *      5. If something goes wrong, seed compensates users automatically
 *
 * @dev The Split (configurable, example 80/10/10):
 *      ┌─────────────────────────────────────────┐
 *      │  Yield Generated                        │
 *      │  ├── 80% → User (competitive return)    │
 *      │  ├── 10% → Seed (protection fund)       │
 *      │  └── 10% → Treasury (operations)        │
 *      └─────────────────────────────────────────┘
 *
 * @dev Key Difference from V1:
 *      V1: Seed funded from deposit principal (locked forever)
 *      V2: Seed funded from yield only (principal stays liquid)
 *
 * @dev Security Features:
 *      - Front-run protection via deposit halt during trigger evaluation
 *      - Block-anchored snapshots for compensation eligibility
 *      - Trigger governance: Oracle proposes, multi-sig confirms
 *      - Dormancy mechanism: 90-day inactivity enables full exit
 *      - Cooldown between compensation events prevents drain
 *
 * @custom:security-contact dybl7@proton.me
 */

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";

contract ProtocolProtectionLayerV2 is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable DEPOSIT_TOKEN;
    address public immutable A_TOKEN;
    address public immutable AAVE_POOL;
    uint256 public immutable MIN_DEPOSIT;

    /*//////////////////////////////////////////////////////////////
                         YIELD SPLIT CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice User's share of yield in basis points (e.g., 8000 = 80%)
    uint256 public userYieldBps;

    /// @notice Seed's share of yield in basis points (e.g., 1000 = 10%)
    uint256 public seedYieldBps;

    /// @notice Treasury's share of yield in basis points (e.g., 1000 = 10%)
    uint256 public treasuryYieldBps;

    uint256 public constant BPS_DENOMINATOR = 10000;

    /*//////////////////////////////////////////////////////////////
                         PROTECTION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum percentage of seed claimable per compensation event
    uint256 public maxCompensationBps;

    /// @notice Minimum time between compensation events
    uint256 public cooldownPeriod;

    uint256 public constant MIN_COOLDOWN = 7 days;
    uint256 public constant MIN_COMPENSATION_WINDOW = 30 days;

    /*//////////////////////////////////////////////////////////////
                         DORMANCY CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 public lastActivityTimestamp;
    uint256 public constant DORMANCY_THRESHOLD = 90 days;
    bool public dormancyActivated;

    /*//////////////////////////////////////////////////////////////
                       TRIGGER GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    address public triggerOracle;
    address public triggerMultisig;

    bytes32 public pendingTriggerId;
    uint256 public triggerProposedAt;

    uint256 public constant TRIGGER_CONFIRMATION_WINDOW = 24 hours;
    uint256 public constant TRIGGER_MIN_DELAY = 1 hours;
    uint256 public constant DEPOSIT_HALT_BUFFER = 1 minutes;

    uint256 public depositsDisabledUntil;

    mapping(bytes32 => bool) public validTriggers;

    /*//////////////////////////////////////////////////////////////
                       COMPENSATION STATE
    //////////////////////////////////////////////////////////////*/

    uint256 public lastCompensationTimestamp;
    bool public compensationActive;
    uint256 public currentCompensationId;

    mapping(uint256 => uint256) public compensationTriggerBlock;
    mapping(uint256 => uint256) public compensationPoolAmounts;
    mapping(uint256 => uint256) public totalSnapshotBalances;
    mapping(uint256 => uint256) public compensatedAmounts;
    mapping(uint256 => mapping(address => bool)) public hasCompensated;

    /*//////////////////////////////////////////////////////////////
                         BALANCE TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice User's deposited principal
    mapping(address => uint256) public userPrincipal;

    /// @notice User's yield already claimed
    mapping(address => uint256) public userYieldClaimed;

    /// @notice Block of user's last deposit (for front-run protection)
    mapping(address => uint256) public lastDepositBlock;

    /// @notice Total principal deposited by all users
    uint256 public totalPrincipal;

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Protection seed balance (stays in Aave)
    uint256 public seedBalance;

    /// @notice Treasury balance available for withdrawal
    uint256 public treasuryBalance;

    /// @notice Total user yield distributed (for pro-rata calculation)
    uint256 public totalUserYieldDistributed;

    /// @notice Total yield sent to seed
    uint256 public totalSeedYieldReceived;

    /// @notice Total yield sent to treasury
    uint256 public totalTreasuryYieldReceived;

    /// @notice Total compensation paid out
    uint256 public totalCompensationPaid;

    /*//////////////////////////////////////////////////////////////
                         DORMANCY TRACKING
    //////////////////////////////////////////////////////////////*/

    mapping(address => bool) public hasDormancyWithdrawn;
    uint256 public totalDormancyWithdrawn;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event YieldHarvested(uint256 totalYield, uint256 toUsers, uint256 toSeed, uint256 toTreasury);
    event YieldClaimed(address indexed user, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    event TriggerAdded(bytes32 indexed triggerId, string description);
    event TriggerRemoved(bytes32 indexed triggerId);
    event TriggerProposed(bytes32 indexed triggerId, address indexed oracle, uint256 proposedAt);
    event TriggerConfirmed(bytes32 indexed triggerId, address indexed multisig);
    event TriggerCancelled(bytes32 indexed triggerId);
    event DepositsHalted(uint256 until);
    event DepositHaltCleared();

    event CompensationTriggered(uint256 indexed compensationId, bytes32 triggerId, uint256 amount, uint256 triggerBlock);
    event CompensationPaid(uint256 indexed compensationId, address indexed user, uint256 amount);
    event CompensationPeriodEnded(uint256 indexed compensationId, uint256 totalPaid, uint256 returnedToSeed);

    event ConfigUpdated(uint256 userBps, uint256 seedBps, uint256 treasuryBps, uint256 maxCompBps, uint256 cooldown);
    event GovernanceUpdated(address indexed oracle, address indexed multisig);

    event DormancyActivated(uint256 timestamp, uint256 totalAssets);
    event DormancyWithdrawal(address indexed user, uint256 amount);
    event Heartbeat(uint256 timestamp);
    event ActivityRecorded(uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAddress();
    error InvalidAmount();
    error DepositTooSmall();
    error InsufficientBalance();
    error InsufficientYield();
    error CompensationInProgress();
    error NoActiveCompensation();
    error AlreadyCompensated();
    error NoBalance();
    error ShareTooSmall();
    error InvalidTrigger();
    error TriggerExists();
    error TriggerNotFound();
    error CooldownNotElapsed();
    error CompensationWindowNotElapsed();
    error NoSeedToCompensate();
    error DepositedAfterTrigger();
    error ConfigOutOfRange();
    error NotOracle();
    error NotMultisig();
    error NoPendingTrigger();
    error TriggerExpired();
    error TriggerTooEarly();
    error NotDormant();
    error DormancyNotActivated();
    error AlreadyDormancyWithdrawn();
    error ProtocolDormant();
    error DepositsTemporarilyHalted();
    error NoETHAccepted();
    error SplitMustEqual100();
    error InsufficientAaveLiquidity();
    error InsufficientContractBalance();
    error NoYieldToHarvest();
    error ExceedsDormancyTxCap();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOracle() {
        if (msg.sender != triggerOracle) revert NotOracle();
        _;
    }

    modifier onlyMultisig() {
        if (msg.sender != triggerMultisig) revert NotMultisig();
        _;
    }

    modifier recordActivity() {
        lastActivityTimestamp = block.timestamp;
        emit ActivityRecorded(block.timestamp);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy PPL V2
    /// @param _depositToken Token for deposits (e.g., USDC)
    /// @param _aToken Corresponding Aave aToken
    /// @param _aavePool Aave V3 Pool address
    /// @param _triggerOracle Address that can propose triggers
    /// @param _triggerMultisig Address that confirms triggers
    constructor(
        address _depositToken,
        address _aToken,
        address _aavePool,
        address _triggerOracle,
        address _triggerMultisig
    ) Ownable(msg.sender) {
        if (_depositToken == address(0)) revert InvalidAddress();
        if (_aToken == address(0)) revert InvalidAddress();
        if (_aavePool == address(0)) revert InvalidAddress();
        if (_triggerOracle == address(0)) revert InvalidAddress();
        if (_triggerMultisig == address(0)) revert InvalidAddress();

        DEPOSIT_TOKEN = _depositToken;
        A_TOKEN = _aToken;
        AAVE_POOL = _aavePool;
        triggerOracle = _triggerOracle;
        triggerMultisig = _triggerMultisig;

        // Default split: 80/10/10
        userYieldBps = 8000;
        seedYieldBps = 1000;
        treasuryYieldBps = 1000;

        // Default protection config
        maxCompensationBps = 5000; // 50% of seed per event
        cooldownPeriod = 7 days;

        // Derive MIN_DEPOSIT from token decimals
        uint8 decimals = IERC20Metadata(_depositToken).decimals();
        MIN_DEPOSIT = 10 ** decimals;

        lastActivityTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                          ETH REJECTION
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        revert NoETHAccepted();
    }

    fallback() external payable {
        revert NoETHAccepted();
    }

    /*//////////////////////////////////////////////////////////////
                          CORE: DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens to earn yield with embedded protection
    /// @param amount Amount to deposit
    /// @dev All funds go to Aave. User can withdraw anytime.
    function deposit(uint256 amount) external nonReentrant whenNotPaused recordActivity {
        if (amount < MIN_DEPOSIT) revert DepositTooSmall();
        if (dormancyActivated) revert ProtocolDormant();
        if (compensationActive) revert CompensationInProgress();
        if (block.timestamp < depositsDisabledUntil) revert DepositsTemporarilyHalted();

        // Harvest any pending yield first
        _harvestYield();

        // Transfer from user
        IERC20(DEPOSIT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // Supply ALL to Aave
        IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, amount);
        IPool(AAVE_POOL).supply(DEPOSIT_TOKEN, amount, address(this), 0);
        IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, 0);

        // Track user principal
        userPrincipal[msg.sender] += amount;
        totalPrincipal += amount;
        lastDepositBlock[msg.sender] = block.number;

        emit Deposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          CORE: WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw principal anytime
    /// @param amount Amount to withdraw
    /// @dev User can withdraw their principal whenever they want
    function withdraw(uint256 amount) external nonReentrant recordActivity {
        if (amount == 0) revert InvalidAmount();
        if (dormancyActivated) revert ProtocolDormant();
        if (compensationActive) revert CompensationInProgress();
        
        uint256 principal = userPrincipal[msg.sender];
        if (amount > principal) revert InsufficientBalance();

        // Harvest yield first
        _harvestYield();

        // Update state
        userPrincipal[msg.sender] -= amount;
        totalPrincipal -= amount;

        // Withdraw from Aave
        uint256 balanceBefore = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, amount, address(this));
        uint256 received = IERC20(DEPOSIT_TOKEN).balanceOf(address(this)) - balanceBefore;
        
        // Check we got enough
        if (received < amount) revert InsufficientAaveLiquidity();
        
        // Transfer to user
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, received);

        emit Withdrawn(msg.sender, received);
    }

    /*//////////////////////////////////////////////////////////////
                          YIELD MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Harvest and distribute yield (callable by anyone)
    /// @dev Reverts if no yield to harvest (prevents spam)
    function harvestYield() external nonReentrant recordActivity {
        uint256 aTokenBalance = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 allocated = totalPrincipal + seedBalance + treasuryBalance;
        if (aTokenBalance <= allocated) revert NoYieldToHarvest();
        
        _harvestYield();
    }

    /// @notice Internal yield harvesting
    function _harvestYield() internal {
        uint256 aTokenBalance = IERC20(A_TOKEN).balanceOf(address(this));
        
        // What we should have: principal + seed + treasury
        uint256 allocated = totalPrincipal + seedBalance + treasuryBalance;
        
        // If aToken balance > allocated, we have yield
        if (aTokenBalance <= allocated) return;
        
        uint256 totalYield = aTokenBalance - allocated;
        if (totalYield == 0) return;

        // Split yield according to config
        uint256 toUsers = (totalYield * userYieldBps) / BPS_DENOMINATOR;
        uint256 toSeed = (totalYield * seedYieldBps) / BPS_DENOMINATOR;
        uint256 toTreasury = totalYield - toUsers - toSeed; // Remainder

        // Track user yield (distributed pro-rata when claimed)
        totalUserYieldDistributed += toUsers;

        // Add to seed
        seedBalance += toSeed;
        totalSeedYieldReceived += toSeed;

        // Add to treasury
        treasuryBalance += toTreasury;
        totalTreasuryYieldReceived += toTreasury;

        emit YieldHarvested(totalYield, toUsers, toSeed, toTreasury);
    }

    /// @notice Claim accumulated yield
    function claimYield() external nonReentrant recordActivity {
        _harvestYield();
        
        uint256 claimable = getClaimableYield(msg.sender);
        if (claimable == 0) revert InsufficientYield();

        // Track claimed amount
        userYieldClaimed[msg.sender] += claimable;

        // Withdraw from Aave
        uint256 balanceBefore = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, claimable, address(this));
        uint256 received = IERC20(DEPOSIT_TOKEN).balanceOf(address(this)) - balanceBefore;
        
        // Check we got enough
        if (received < claimable) revert InsufficientAaveLiquidity();
        
        // Transfer to user
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, received);

        emit YieldClaimed(msg.sender, received);
    }

    /// @notice Get user's claimable yield
    function getClaimableYield(address user) public view returns (uint256) {
        if (totalPrincipal == 0) return 0;
        if (userPrincipal[user] == 0) return 0;
        
        // User's share of total distributed yield
        uint256 userShare = (totalUserYieldDistributed * userPrincipal[user]) / totalPrincipal;
        
        // Subtract what they've already claimed
        uint256 claimed = userYieldClaimed[user];
        
        return userShare > claimed ? userShare - claimed : 0;
    }

    /*//////////////////////////////////////////////////////////////
                       TREASURY WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw from treasury
    /// @param amount Amount to withdraw
    /// @param to Recipient address
    /// @dev In production, this function should be called via a timelock/multisig contract.
    function withdrawTreasury(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount > treasuryBalance) revert InsufficientBalance();
        if (compensationActive) revert CompensationInProgress();

        treasuryBalance -= amount;

        IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, amount, to);

        emit TreasuryWithdrawn(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         TRIGGER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addTrigger(bytes32 triggerId, string calldata description) external onlyOwner {
        if (triggerId == bytes32(0)) revert InvalidTrigger();
        if (validTriggers[triggerId]) revert TriggerExists();
        
        validTriggers[triggerId] = true;
        emit TriggerAdded(triggerId, description);
    }

    function removeTrigger(bytes32 triggerId) external onlyOwner {
        if (!validTriggers[triggerId]) revert TriggerNotFound();
        
        validTriggers[triggerId] = false;
        emit TriggerRemoved(triggerId);
    }

    /*//////////////////////////////////////////////////////////////
                       TRIGGER GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function proposeTrigger(bytes32 triggerId) external onlyOracle {
        if (!validTriggers[triggerId]) revert InvalidTrigger();
        if (compensationActive) revert CompensationInProgress();
        if (block.timestamp < lastCompensationTimestamp + cooldownPeriod) revert CooldownNotElapsed();
        
        pendingTriggerId = triggerId;
        triggerProposedAt = block.timestamp;
        depositsDisabledUntil = block.timestamp + TRIGGER_CONFIRMATION_WINDOW + DEPOSIT_HALT_BUFFER;
        
        emit TriggerProposed(triggerId, msg.sender, block.timestamp);
        emit DepositsHalted(depositsDisabledUntil);
    }

    function confirmTrigger() external onlyMultisig nonReentrant recordActivity {
        if (pendingTriggerId == bytes32(0)) revert NoPendingTrigger();
        if (block.timestamp < triggerProposedAt + TRIGGER_MIN_DELAY) revert TriggerTooEarly();
        if (block.timestamp > triggerProposedAt + TRIGGER_CONFIRMATION_WINDOW) revert TriggerExpired();
        
        bytes32 triggerId = pendingTriggerId;
        pendingTriggerId = bytes32(0);
        triggerProposedAt = 0;
        
        emit TriggerConfirmed(triggerId, msg.sender);
        
        _executeCompensation(triggerId);
    }

    function cancelTrigger() external {
        if (msg.sender != owner() && msg.sender != triggerMultisig) revert NotMultisig();
        if (pendingTriggerId == bytes32(0)) revert NoPendingTrigger();
        
        bytes32 triggerId = pendingTriggerId;
        pendingTriggerId = bytes32(0);
        triggerProposedAt = 0;
        depositsDisabledUntil = 0;
        
        emit TriggerCancelled(triggerId);
        emit DepositHaltCleared();
    }

    function _executeCompensation(bytes32 triggerId) internal {
        // Harvest any pending yield first
        _harvestYield();
        
        if (seedBalance == 0) revert NoSeedToCompensate();
        
        // Calculate compensation amount (up to maxCompensationBps of seed)
        uint256 compensationAmount = (seedBalance * maxCompensationBps) / BPS_DENOMINATOR;
        
        // Deduct from seed
        seedBalance -= compensationAmount;
        
        // Withdraw from Aave to contract for distribution
        uint256 balanceBefore = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, compensationAmount, address(this));
        uint256 received = IERC20(DEPOSIT_TOKEN).balanceOf(address(this)) - balanceBefore;
        
        // Check we got at least 95% (allow small slippage)
        uint256 minExpected = (compensationAmount * 95) / 100;
        if (received < minExpected) revert InsufficientAaveLiquidity();
        
        // Set up compensation state (use actual received amount)
        currentCompensationId++;
        compensationActive = true;
        lastCompensationTimestamp = block.timestamp;
        
        compensationTriggerBlock[currentCompensationId] = block.number;
        compensationPoolAmounts[currentCompensationId] = received;
        totalSnapshotBalances[currentCompensationId] = totalPrincipal;
        
        emit CompensationTriggered(currentCompensationId, triggerId, received, block.number);
    }

    /// @notice Emergency trigger for owner (testing/initial deployment)
    /// @dev Should be disabled or timelocked in production deployment.
    function emergencyTrigger(bytes32 triggerId) external onlyOwner nonReentrant recordActivity {
        if (!validTriggers[triggerId]) revert InvalidTrigger();
        if (compensationActive) revert CompensationInProgress();
        if (block.timestamp < lastCompensationTimestamp + cooldownPeriod) revert CooldownNotElapsed();
        
        _executeCompensation(triggerId);
    }

    /*//////////////////////////////////////////////////////////////
                       COMPENSATION CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim compensation payout
    function claimCompensation() external nonReentrant recordActivity {
        if (!compensationActive) revert NoActiveCompensation();
        if (hasCompensated[currentCompensationId][msg.sender]) revert AlreadyCompensated();
        if (lastDepositBlock[msg.sender] >= compensationTriggerBlock[currentCompensationId]) {
            revert DepositedAfterTrigger();
        }
        
        uint256 principal = userPrincipal[msg.sender];
        if (principal == 0) revert NoBalance();
        
        uint256 totalSnapshot = totalSnapshotBalances[currentCompensationId];
        uint256 pool = compensationPoolAmounts[currentCompensationId];
        
        uint256 userShare = (pool * principal) / totalSnapshot;
        if (userShare == 0) revert ShareTooSmall();
        
        // Check contract has enough balance
        if (IERC20(DEPOSIT_TOKEN).balanceOf(address(this)) < userShare) {
            revert InsufficientContractBalance();
        }
        
        hasCompensated[currentCompensationId][msg.sender] = true;
        compensatedAmounts[currentCompensationId] += userShare;
        totalCompensationPaid += userShare;
        
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, userShare);
        
        emit CompensationPaid(currentCompensationId, msg.sender, userShare);
    }

    /// @notice Get user's claimable compensation
    function getClaimableCompensation(address user) external view returns (uint256) {
        if (!compensationActive) return 0;
        if (hasCompensated[currentCompensationId][user]) return 0;
        if (lastDepositBlock[user] >= compensationTriggerBlock[currentCompensationId]) return 0;
        
        uint256 principal = userPrincipal[user];
        if (principal == 0) return 0;
        
        uint256 totalSnapshot = totalSnapshotBalances[currentCompensationId];
        uint256 pool = compensationPoolAmounts[currentCompensationId];
        
        return (pool * principal) / totalSnapshot;
    }

    /// @notice End compensation period, return unclaimed to seed
    function endCompensationPeriod() external onlyOwner recordActivity {
        if (!compensationActive) revert NoActiveCompensation();
        if (block.timestamp < lastCompensationTimestamp + MIN_COMPENSATION_WINDOW) {
            revert CompensationWindowNotElapsed();
        }
        
        uint256 pool = compensationPoolAmounts[currentCompensationId];
        uint256 paid = compensatedAmounts[currentCompensationId];
        uint256 unclaimed = pool - paid;
        
        // Return unclaimed to seed (re-supply to Aave)
        if (unclaimed > 0) {
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, unclaimed);
            IPool(AAVE_POOL).supply(DEPOSIT_TOKEN, unclaimed, address(this), 0);
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, 0);
            seedBalance += unclaimed;
        }
        
        compensationActive = false;
        
        emit CompensationPeriodEnded(currentCompensationId, paid, unclaimed);
    }

    /*//////////////////////////////////////////////////////////////
                         DORMANCY MECHANISM
    //////////////////////////////////////////////////////////////*/

    function isDormant() public view returns (bool) {
        return block.timestamp > lastActivityTimestamp + DORMANCY_THRESHOLD;
    }

    function activateDormancy() external {
        if (!isDormant()) revert NotDormant();
        if (dormancyActivated) return;
        
        dormancyActivated = true;
        
        // Withdraw everything from Aave
        uint256 aBalance = IERC20(A_TOKEN).balanceOf(address(this));
        if (aBalance > 0) {
            IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, aBalance, address(this));
        }
        
        uint256 totalAssets = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        
        // Check we got at least 95% (allow small slippage in extreme conditions)
        uint256 minExpected = (aBalance * 95) / 100;
        if (totalAssets < minExpected) revert InsufficientAaveLiquidity();
        
        emit DormancyActivated(block.timestamp, totalAssets);
    }

    function dormancyWithdraw() external nonReentrant {
        if (!dormancyActivated) revert DormancyNotActivated();
        if (hasDormancyWithdrawn[msg.sender]) revert AlreadyDormancyWithdrawn();
        
        uint256 principal = userPrincipal[msg.sender];
        if (principal == 0) revert NoBalance();
        
        uint256 totalAssets = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        uint256 userShare = (totalAssets * principal) / totalPrincipal;
        
        if (userShare == 0) revert ShareTooSmall();
        
        // Cap at 10% of total assets per tx (prevents whale griefing)
        uint256 maxPerTx = totalAssets / 10;
        if (userShare > maxPerTx) revert ExceedsDormancyTxCap();
        
        hasDormancyWithdrawn[msg.sender] = true;
        totalDormancyWithdrawn += userShare;
        
        totalPrincipal -= principal;
        userPrincipal[msg.sender] = 0;
        
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, userShare);
        
        emit DormancyWithdrawal(msg.sender, userShare);
    }

    function heartbeat() external onlyOwner {
        lastActivityTimestamp = block.timestamp;
        emit Heartbeat(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN: CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Update yield split (must total 100%)
    /// @dev In production, this function should be called via a timelock/multisig contract.
    function updateYieldSplit(
        uint256 _userBps,
        uint256 _seedBps,
        uint256 _treasuryBps
    ) external onlyOwner {
        if (_userBps + _seedBps + _treasuryBps != BPS_DENOMINATOR) revert SplitMustEqual100();
        
        userYieldBps = _userBps;
        seedYieldBps = _seedBps;
        treasuryYieldBps = _treasuryBps;
        
        emit ConfigUpdated(_userBps, _seedBps, _treasuryBps, maxCompensationBps, cooldownPeriod);
    }

    /// @notice Update protection parameters
    /// @dev In production, this function should be called via a timelock/multisig contract.
    function updateProtectionConfig(
        uint256 _maxCompensationBps,
        uint256 _cooldownPeriod
    ) external onlyOwner {
        if (_maxCompensationBps == 0 || _maxCompensationBps > 5000) revert ConfigOutOfRange();
        if (_cooldownPeriod < MIN_COOLDOWN) revert ConfigOutOfRange();
        
        maxCompensationBps = _maxCompensationBps;
        cooldownPeriod = _cooldownPeriod;
        
        emit ConfigUpdated(userYieldBps, seedYieldBps, treasuryYieldBps, _maxCompensationBps, _cooldownPeriod);
    }

    /// @notice Update trigger governance addresses
    /// @dev In production, this function should be called via a timelock/multisig contract.
    function updateGovernance(address _oracle, address _multisig) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        if (_multisig == address(0)) revert InvalidAddress();
        
        triggerOracle = _oracle;
        triggerMultisig = _multisig;
        
        emit GovernanceUpdated(_oracle, _multisig);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get protocol status
    function getStatus() external view returns (
        uint256 _totalPrincipal,
        uint256 _seedBalance,
        uint256 _treasuryBalance,
        uint256 _aTokenBalance,
        uint256 _pendingYield,
        bool _compensationActive,
        bool _dormant
    ) {
        _totalPrincipal = totalPrincipal;
        _seedBalance = seedBalance;
        _treasuryBalance = treasuryBalance;
        _aTokenBalance = IERC20(A_TOKEN).balanceOf(address(this));
        
        uint256 allocated = totalPrincipal + seedBalance + treasuryBalance;
        _pendingYield = _aTokenBalance > allocated ? _aTokenBalance - allocated : 0;
        
        _compensationActive = compensationActive;
        _dormant = dormancyActivated;
    }

    /// @notice Get user position
    function getUserPosition(address user) external view returns (
        uint256 principal,
        uint256 claimableYield,
        uint256 claimableCompensation,
        uint256 depositBlock
    ) {
        principal = userPrincipal[user];
        claimableYield = getClaimableYield(user);
        depositBlock = lastDepositBlock[user];
        
        if (compensationActive && 
            !hasCompensated[currentCompensationId][user] &&
            lastDepositBlock[user] < compensationTriggerBlock[currentCompensationId] &&
            principal > 0) {
            uint256 totalSnapshot = totalSnapshotBalances[currentCompensationId];
            uint256 pool = compensationPoolAmounts[currentCompensationId];
            claimableCompensation = (pool * principal) / totalSnapshot;
        }
    }

    /// @notice Get yield split configuration
    function getYieldSplit() external view returns (
        uint256 userBps,
        uint256 seedBps,
        uint256 treasuryBps
    ) {
        return (userYieldBps, seedYieldBps, treasuryYieldBps);
    }

    /// @notice Get dormancy countdown in seconds
    function getDormancyCountdown() external view returns (uint256) {
        if (dormancyActivated) return 0;
        uint256 dormancyTime = lastActivityTimestamp + DORMANCY_THRESHOLD;
        if (block.timestamp >= dormancyTime) return 0;
        return dormancyTime - block.timestamp;
    }
}
