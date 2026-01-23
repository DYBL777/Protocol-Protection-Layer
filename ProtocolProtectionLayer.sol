// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/*
 * ╔══════════════════════════════════════════════════════════════════════════╗
 * ║                                                                          ║
 * ║                           SEED INSURANCE                                 ║
 * ║                     Eternal Seed Variant 8                               ║
 * ║                          VERSION 3.1                                     ║
 * ║                                                                          ║
 * ╠══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  Licensed under the Business Source License 1.1 (BUSL-1.1)               ║
 * ║                                                                          ║
 * ║  Licensor:            DYBL Foundation                                    ║
 * ║  Licensed Work:       SeedInsurance & Eternal Seed Mechanism             ║
 * ║  Change Date:         May 10, 2029                                       ║
 * ║  Change License:      MIT                                                ║
 * ║                                                                          ║
 * ║  Contact: dybl7@proton.me | Twitter: @DYBL77                             ║
 * ║                                                                          ║
 * ╚══════════════════════════════════════════════════════════════════════════╝
 *
 * @title SeedInsurance V3.1
 * @author DYBL Foundation
 * @notice Eternal Seed with native insurance payout capability for black swan events
 * 
 * @dev Core Mechanism:
 *      - Deposits are split: seedBps% → Aave (insurance reserve), remainder → yield pool
 *      - Seed compounds via Aave yield, creating a "rising floor"
 *      - On verified trigger: seed releases up to maxClaimBps% for pro-rata user claims
 *      - Seed rebuilds from ongoing deposits after claim period ends
 *
 * @dev Security Features:
 *      - Front-run protection via block-anchored snapshots
 *      - Trigger governance: Oracle proposes, multi-sig confirms within time window
 *      - Dormancy mechanism: 90-day inactivity enables user fund recovery
 *      - Cooldown between claims prevents cascade drain attacks
 *
 * @dev V3.1 Changes:
 *      - Added heartbeat() function to reset dormancy timer
 *      - Dynamic MIN_DEPOSIT derived from token decimals (supports any ERC20)
 *
 * @dev Key Invariant:
 *      The seed principal can only exit via:
 *      1. Approved insurance claim (up to maxClaimBps per event)
 *      2. Dormancy withdrawal (after 90 days of protocol inactivity)
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

contract SeedInsuranceV3 is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Token used for deposits (e.g., USDC, DAI, WBTC)
    /// @dev Must be compatible with Aave V3 pool
    address public immutable DEPOSIT_TOKEN;

    /// @notice Aave aToken received when supplying DEPOSIT_TOKEN
    /// @dev Used to track seed value including accrued yield
    address public immutable A_TOKEN;

    /// @notice Aave V3 Pool contract for supply/withdraw operations
    address public immutable AAVE_POOL;

    /// @notice Minimum deposit amount to prevent dust attacks
    /// @dev Derived from token decimals: 1 full token (e.g., 1e6 for USDC, 1e18 for DAI)
    uint256 public immutable MIN_DEPOSIT;

    /*//////////////////////////////////////////////////////////////
                         SEED CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Percentage of deposits allocated to insurance seed
    /// @dev Basis points (e.g., 1500 = 15%). Max 5000 (50%)
    uint256 public seedBps;

    /// @notice Maximum percentage of seed claimable per insurance event
    /// @dev Basis points (e.g., 5000 = 50%). Prevents full drain on single event
    uint256 public maxClaimBps;

    /// @notice Minimum time between claim trigger events
    /// @dev Prevents cascade drain attacks via multiple rapid triggers
    uint256 public cooldownPeriod;

    /// @notice Basis points denominator for percentage calculations
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum allowed cooldown period
    /// @dev 7 days provides time for incident assessment
    uint256 public constant MIN_COOLDOWN = 7 days;

    /// @notice Minimum claim window before endClaimPeriod can be called
    /// @dev 30 days ensures users have adequate time to claim
    uint256 public constant MIN_CLAIM_WINDOW = 30 days;

    /*//////////////////////////////////////////////////////////////
                        DORMANCY CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Timestamp of last meaningful protocol activity
    /// @dev Updated by recordActivity modifier on key functions
    uint256 public lastActivityTimestamp;

    /// @notice Time without activity before dormancy can be activated
    /// @dev 90 days balances safety with reasonable inactivity period
    uint256 public constant DORMANCY_THRESHOLD = 90 days;

    /// @notice Whether dormancy mode has been activated
    /// @dev Once true, deposits are disabled and withdrawals enabled
    bool public dormancyActivated;

    /// @notice Tracks users who have completed dormancy withdrawal
    /// @dev Prevents double-withdrawal during dormancy
    mapping(address => bool) public hasDormancyWithdrawn;

    /*//////////////////////////////////////////////////////////////
                       TRIGGER GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address authorized to propose claim triggers
    /// @dev Intended for Chainlink Automation or similar oracle service
    address public triggerOracle;

    /// @notice Address authorized to confirm proposed triggers
    /// @dev Intended for multi-sig (e.g., Gnosis Safe 3-of-5)
    address public triggerMultisig;

    /// @notice Trigger ID awaiting multi-sig confirmation
    /// @dev bytes32(0) when no trigger is pending
    bytes32 public pendingTriggerId;

    /// @notice Timestamp when current trigger was proposed
    /// @dev Used to enforce confirmation window and minimum delay
    uint256 public triggerProposedAt;

    /// @notice Maximum time for multi-sig to confirm after proposal
    /// @dev Trigger expires if not confirmed within 24 hours
    uint256 public constant TRIGGER_CONFIRMATION_WINDOW = 24 hours;

    /// @notice Minimum delay between proposal and confirmation
    /// @dev 1 hour buffer allows cancellation if oracle is compromised
    uint256 public constant TRIGGER_MIN_DELAY = 1 hours;

    /*//////////////////////////////////////////////////////////////
                           CLAIM STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Registered trigger IDs that can initiate claims
    /// @dev Triggers must be pre-registered by owner
    mapping(bytes32 => bool) public validTriggers;

    /// @notice Timestamp of most recent claim trigger
    /// @dev Used to enforce cooldown period
    uint256 public lastClaimTimestamp;

    /// @notice Whether a claim event is currently active
    /// @dev When true, deposits blocked and users can claim
    bool public claimActive;

    /// @notice Incrementing ID for each claim event
    /// @dev Used as key for claim-specific mappings
    uint256 public currentClaimId;

    /*//////////////////////////////////////////////////////////////
                         BALANCE TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice Cumulative deposit balance per user
    /// @dev Used for pro-rata claim calculations. Never decreases in normal operation
    mapping(address => uint256) public userBalances;

    /// @notice Sum of all user balances
    /// @dev Denominator for pro-rata calculations
    uint256 public totalUserBalances;

    /// @notice Block number of each user's most recent deposit
    /// @dev Front-run protection: must be < trigger block to claim
    mapping(address => uint256) public lastDepositBlock;

    /// @notice Block number when each claim was triggered
    /// @dev Anchor for front-run protection comparison
    mapping(uint256 => uint256) public claimTriggerBlock;

    /// @notice Snapshot of totalUserBalances at each claim trigger
    /// @dev Locked at trigger time to prevent manipulation
    mapping(uint256 => uint256) public totalSnapshotBalances;

    /// @notice Total tokens available for each claim event
    /// @dev Calculated as seedValue * maxClaimBps / BPS_DENOMINATOR
    mapping(uint256 => uint256) public claimPoolAmounts;

    /// @notice Running total of tokens claimed per event
    /// @dev Used to calculate unclaimed remainder for return to seed
    mapping(uint256 => uint256) public claimedAmounts;

    /// @notice Tracks whether user has claimed for specific event
    /// @dev Prevents double-claiming within same event
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Cumulative principal deposited to Aave seed
    /// @dev Does not include accrued yield
    uint256 public totalSeeded;

    /// @notice Cumulative tokens received in yield pool
    /// @dev Portion of deposits not sent to seed
    uint256 public totalYieldReceived;

    /// @notice Cumulative tokens distributed from yield pool
    /// @dev For operational costs, rewards, etc.
    uint256 public totalYieldDistributed;

    /// @notice Cumulative tokens paid via insurance claims
    /// @dev Across all claim events
    uint256 public totalClaimsPaid;

    /// @notice Cumulative tokens withdrawn via dormancy
    /// @dev Only populated if dormancy activates
    uint256 public totalDormancyWithdrawn;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when user deposits tokens
    /// @param user Depositor address
    /// @param amount Total deposit amount
    /// @param toSeed Portion allocated to insurance seed
    /// @param toYield Portion allocated to yield pool
    event Deposited(address indexed user, uint256 amount, uint256 toSeed, uint256 toYield);

    /// @notice Emitted when tokens are supplied to Aave seed
    /// @param amount Tokens supplied this transaction
    /// @param totalSeeded Cumulative seed principal after supply
    event Seeded(uint256 amount, uint256 totalSeeded);

    /// @notice Emitted when new trigger is registered
    /// @param triggerId Unique identifier for the trigger
    /// @param description Human-readable trigger description
    event TriggerAdded(bytes32 indexed triggerId, string description);

    /// @notice Emitted when trigger is deregistered
    /// @param triggerId Trigger being removed
    event TriggerRemoved(bytes32 indexed triggerId);

    /// @notice Emitted when oracle proposes a trigger
    /// @param triggerId Proposed trigger ID
    /// @param oracle Address that proposed (triggerOracle)
    /// @param proposedAt Block timestamp of proposal
    event TriggerProposed(bytes32 indexed triggerId, address indexed oracle, uint256 proposedAt);

    /// @notice Emitted when multi-sig confirms trigger
    /// @param triggerId Confirmed trigger ID
    /// @param multisig Address that confirmed (triggerMultisig)
    event TriggerConfirmed(bytes32 indexed triggerId, address indexed multisig);

    /// @notice Emitted when pending trigger is cancelled
    /// @param triggerId Cancelled trigger ID
    event TriggerCancelled(bytes32 indexed triggerId);

    /// @notice Emitted when claim event is triggered
    /// @param claimId Unique ID for this claim event
    /// @param triggerId Trigger that initiated the claim
    /// @param claimableAmount Total tokens available for claims
    /// @param triggerBlock Block number at trigger time
    event ClaimTriggered(uint256 indexed claimId, bytes32 triggerId, uint256 claimableAmount, uint256 triggerBlock);

    /// @notice Emitted when user claims their insurance payout
    /// @param claimId Claim event ID
    /// @param user Claimant address
    /// @param amount Tokens paid to user
    event ClaimPayout(uint256 indexed claimId, address indexed user, uint256 amount);

    /// @notice Emitted when claim period ends
    /// @param claimId Claim event ID
    /// @param totalPaid Total tokens claimed by users
    /// @param unclaimed Tokens returned to seed
    event ClaimPeriodEnded(uint256 indexed claimId, uint256 totalPaid, uint256 unclaimed);

    /// @notice Emitted when yield is distributed
    /// @param to Recipient address
    /// @param amount Tokens distributed
    event YieldDistributed(address indexed to, uint256 amount);

    /// @notice Emitted when configuration is updated
    /// @param seedBps New seed percentage
    /// @param maxClaimBps New max claim percentage
    /// @param cooldownPeriod New cooldown period
    event ConfigUpdated(uint256 seedBps, uint256 maxClaimBps, uint256 cooldownPeriod);

    /// @notice Emitted when trigger governance addresses updated
    /// @param oracle New oracle address
    /// @param multisig New multi-sig address
    event GovernanceUpdated(address indexed oracle, address indexed multisig);

    /// @notice Emitted when dormancy mode activates
    /// @param timestamp Activation time
    /// @param totalAssets Total tokens available for withdrawal
    event DormancyActivated(uint256 timestamp, uint256 totalAssets);

    /// @notice Emitted when user withdraws via dormancy
    /// @param user Withdrawer address
    /// @param amount Tokens withdrawn
    event DormancyWithdrawal(address indexed user, uint256 amount);

    /// @notice Emitted when activity timestamp updates
    /// @param timestamp New activity timestamp
    event ActivityRecorded(uint256 timestamp);

    /// @notice Emitted when heartbeat is called
    /// @param timestamp Heartbeat timestamp
    event Heartbeat(uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when address parameter is zero
    error InvalidAddress();

    /// @notice Thrown when amount parameter is zero
    error InvalidAmount();

    /// @notice Thrown when deposit is below MIN_DEPOSIT
    error DepositTooSmall();

    /// @notice Thrown when operation blocked due to active claim
    error ClaimInProgress();

    /// @notice Thrown when claim operation attempted with no active claim
    error NoActiveClaim();

    /// @notice Thrown when user attempts to claim twice for same event
    error AlreadyClaimed();

    /// @notice Thrown when user has no balance to claim against
    error NoBalance();

    /// @notice Thrown when calculated share rounds to zero
    error ShareTooSmall();

    /// @notice Thrown when trigger ID is invalid or unregistered
    error InvalidTrigger();

    /// @notice Thrown when adding trigger that already exists
    error TriggerExists();

    /// @notice Thrown when removing trigger that doesn't exist
    error TriggerNotFound();

    /// @notice Thrown when cooldown period hasn't elapsed
    error CooldownNotElapsed();

    /// @notice Thrown when claim window hasn't elapsed
    error ClaimWindowNotElapsed();

    /// @notice Thrown when seed has no value to claim against
    error NoSeedToClaim();

    /// @notice Thrown when yield distribution exceeds available balance
    error InsufficientYield();

    /// @notice Thrown when attempting to recover protected aToken
    error CannotTouchSeed();

    /// @notice Thrown when user deposited at or after trigger block
    error DepositedAfterTrigger();

    /// @notice Thrown when config parameter out of allowed range
    error ConfigOutOfRange();

    /// @notice Thrown when non-oracle calls oracle-only function
    error NotOracle();

    /// @notice Thrown when non-multisig calls multisig-only function
    error NotMultisig();

    /// @notice Thrown when confirming with no pending trigger
    error NoPendingTrigger();

    /// @notice Thrown when trigger confirmation window has passed
    error TriggerExpired();

    /// @notice Thrown when confirming before minimum delay
    error TriggerTooEarly();

    /// @notice Thrown when dormancy action attempted but not dormant
    error NotDormant();

    /// @notice Thrown when dormancy withdrawal attempted before activation
    error DormancyNotActivated();

    /// @notice Thrown when user attempts second dormancy withdrawal
    error AlreadyDormancyWithdrawn();

    /// @notice Thrown when deposit attempted after dormancy activation
    error ProtocolStillActive();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function to triggerOracle address
    modifier onlyOracle() {
        if (msg.sender != triggerOracle) revert NotOracle();
        _;
    }

    /// @notice Restricts function to triggerMultisig address
    modifier onlyMultisig() {
        if (msg.sender != triggerMultisig) revert NotMultisig();
        _;
    }

    /// @notice Updates lastActivityTimestamp to current block
    /// @dev Applied to functions that represent meaningful protocol activity
    modifier recordActivity() {
        lastActivityTimestamp = block.timestamp;
        emit ActivityRecorded(block.timestamp);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys SeedInsurance V3.1 contract
    /// @param _depositToken ERC20 token for deposits (e.g., USDC, DAI, WBTC)
    /// @param _aToken Corresponding Aave aToken (e.g., aUSDC)
    /// @param _aavePool Aave V3 Pool contract address
    /// @param _seedBps Percentage of deposits to seed (basis points, max 5000)
    /// @param _maxClaimBps Maximum claimable per event (basis points, max 5000)
    /// @param _cooldownPeriod Minimum seconds between claim events
    /// @param _triggerOracle Address authorized to propose triggers
    /// @param _triggerMultisig Address authorized to confirm triggers
    /// @dev All addresses must be non-zero. Config values must be within ranges.
    ///      MIN_DEPOSIT is automatically derived from token decimals.
    constructor(
        address _depositToken,
        address _aToken,
        address _aavePool,
        uint256 _seedBps,
        uint256 _maxClaimBps,
        uint256 _cooldownPeriod,
        address _triggerOracle,
        address _triggerMultisig
    ) Ownable(msg.sender) {
        if (_depositToken == address(0)) revert InvalidAddress();
        if (_aToken == address(0)) revert InvalidAddress();
        if (_aavePool == address(0)) revert InvalidAddress();
        if (_triggerOracle == address(0)) revert InvalidAddress();
        if (_triggerMultisig == address(0)) revert InvalidAddress();
        if (_seedBps == 0 || _seedBps > 5000) revert ConfigOutOfRange();
        if (_maxClaimBps == 0 || _maxClaimBps > 5000) revert ConfigOutOfRange();
        if (_cooldownPeriod < MIN_COOLDOWN) revert ConfigOutOfRange();

        DEPOSIT_TOKEN = _depositToken;
        A_TOKEN = _aToken;
        AAVE_POOL = _aavePool;
        seedBps = _seedBps;
        maxClaimBps = _maxClaimBps;
        cooldownPeriod = _cooldownPeriod;
        triggerOracle = _triggerOracle;
        triggerMultisig = _triggerMultisig;
        
        // Derive MIN_DEPOSIT from token decimals (1 full token)
        uint8 decimals = IERC20Metadata(_depositToken).decimals();
        MIN_DEPOSIT = 10 ** decimals;
        
        lastActivityTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN: TRIGGERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers a new valid claim trigger
    /// @param triggerId Unique identifier (e.g., keccak256("AAVE_EXPLOIT"))
    /// @param description Human-readable description for documentation
    /// @dev Only owner. Trigger must not already exist.
    function addTrigger(bytes32 triggerId, string calldata description) external onlyOwner {
        if (triggerId == bytes32(0)) revert InvalidTrigger();
        if (validTriggers[triggerId]) revert TriggerExists();
        
        validTriggers[triggerId] = true;
        emit TriggerAdded(triggerId, description);
    }

    /// @notice Deregisters an existing claim trigger
    /// @param triggerId Trigger to remove
    /// @dev Only owner. Trigger must exist. Does not affect pending triggers.
    function removeTrigger(bytes32 triggerId) external onlyOwner {
        if (!validTriggers[triggerId]) revert TriggerNotFound();
        
        validTriggers[triggerId] = false;
        emit TriggerRemoved(triggerId);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN: CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates seed configuration parameters
    /// @param _seedBps New seed percentage (1-5000 basis points)
    /// @param _maxClaimBps New max claim percentage (1-5000 basis points)
    /// @param _cooldownPeriod New cooldown period (minimum 7 days)
    /// @dev Only owner. Should be behind timelock in production deployment.
    function updateConfig(
        uint256 _seedBps,
        uint256 _maxClaimBps,
        uint256 _cooldownPeriod
    ) external onlyOwner {
        if (_seedBps == 0 || _seedBps > 5000) revert ConfigOutOfRange();
        if (_maxClaimBps == 0 || _maxClaimBps > 5000) revert ConfigOutOfRange();
        if (_cooldownPeriod < MIN_COOLDOWN) revert ConfigOutOfRange();
        
        seedBps = _seedBps;
        maxClaimBps = _maxClaimBps;
        cooldownPeriod = _cooldownPeriod;
        
        emit ConfigUpdated(_seedBps, _maxClaimBps, _cooldownPeriod);
    }

    /// @notice Updates trigger governance addresses
    /// @param _triggerOracle New oracle address (e.g., Chainlink Automation)
    /// @param _triggerMultisig New multi-sig address
    /// @dev Only owner. Both addresses must be non-zero.
    function updateGovernance(
        address _triggerOracle,
        address _triggerMultisig
    ) external onlyOwner {
        if (_triggerOracle == address(0)) revert InvalidAddress();
        if (_triggerMultisig == address(0)) revert InvalidAddress();
        
        triggerOracle = _triggerOracle;
        triggerMultisig = _triggerMultisig;
        
        emit GovernanceUpdated(_triggerOracle, _triggerMultisig);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN: PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses deposit functionality
    /// @dev Only owner. Use if Aave or yield source shows issues.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses deposit functionality
    /// @dev Only owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN: HEARTBEAT
    //////////////////////////////////////////////////////////////*/

    /// @notice Resets dormancy timer without any state changes
    /// @dev Only owner. Call periodically (e.g., every 60 days) if protocol
    ///      is healthy but has low deposit activity to prevent unintended dormancy.
    function heartbeat() external onlyOwner {
        lastActivityTimestamp = block.timestamp;
        emit Heartbeat(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          CORE: DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits tokens, splitting between seed and yield pool
    /// @param amount Amount of DEPOSIT_TOKEN to deposit
    /// @dev Caller must approve this contract first.
    ///      Blocked when: paused, claim active, or dormancy activated.
    ///      Records block number for front-run protection.
    function deposit(uint256 amount) external nonReentrant whenNotPaused recordActivity {
        if (amount < MIN_DEPOSIT) revert DepositTooSmall();
        if (claimActive) revert ClaimInProgress();
        if (dormancyActivated) revert ProtocolStillActive();
        
        IERC20(DEPOSIT_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        
        uint256 seedAmount = (amount * seedBps) / BPS_DENOMINATOR;
        uint256 yieldAmount = amount - seedAmount;
        
        userBalances[msg.sender] += amount;
        totalUserBalances += amount;
        lastDepositBlock[msg.sender] = block.number;
        
        if (seedAmount > 0) {
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, seedAmount);
            
            try IPool(AAVE_POOL).supply(DEPOSIT_TOKEN, seedAmount, address(this), 0) {
                totalSeeded += seedAmount;
                emit Seeded(seedAmount, totalSeeded);
            } catch {
                // Aave supply failed, redirect to yield pool
                yieldAmount += seedAmount;
            }
            
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, 0);
        }
        
        totalYieldReceived += yieldAmount;
        
        emit Deposited(msg.sender, amount, seedAmount, yieldAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    TRIGGER GOVERNANCE: PROPOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a claim trigger for multi-sig confirmation
    /// @param triggerId Registered trigger ID that was detected
    /// @dev Only triggerOracle (e.g., Chainlink Automation).
    ///      Creates pending trigger that multi-sig must confirm within 24h.
    ///      Cannot propose if: claim active, cooldown not elapsed, or trigger invalid.
    function proposeTrigger(bytes32 triggerId) external onlyOracle {
        if (!validTriggers[triggerId]) revert InvalidTrigger();
        if (claimActive) revert ClaimInProgress();
        if (block.timestamp < lastClaimTimestamp + cooldownPeriod) revert CooldownNotElapsed();
        
        pendingTriggerId = triggerId;
        triggerProposedAt = block.timestamp;
        
        emit TriggerProposed(triggerId, msg.sender, block.timestamp);
    }

    /// @notice Confirms pending trigger and initiates claim event
    /// @dev Only triggerMultisig.
    ///      Must be called between TRIGGER_MIN_DELAY and TRIGGER_CONFIRMATION_WINDOW.
    ///      Executes the claim trigger on success.
    function confirmTrigger() external onlyMultisig nonReentrant recordActivity {
        if (pendingTriggerId == bytes32(0)) revert NoPendingTrigger();
        if (block.timestamp < triggerProposedAt + TRIGGER_MIN_DELAY) revert TriggerTooEarly();
        if (block.timestamp > triggerProposedAt + TRIGGER_CONFIRMATION_WINDOW) revert TriggerExpired();
        
        bytes32 triggerId = pendingTriggerId;
        pendingTriggerId = bytes32(0);
        triggerProposedAt = 0;
        
        emit TriggerConfirmed(triggerId, msg.sender);
        
        _executeTrigger(triggerId);
    }

    /// @notice Cancels a pending trigger
    /// @dev Callable by owner or triggerMultisig.
    ///      Use if oracle proposed incorrect trigger or situation resolved.
    function cancelTrigger() external {
        if (msg.sender != owner() && msg.sender != triggerMultisig) revert NotMultisig();
        if (pendingTriggerId == bytes32(0)) revert NoPendingTrigger();
        
        bytes32 triggerId = pendingTriggerId;
        pendingTriggerId = bytes32(0);
        triggerProposedAt = 0;
        
        emit TriggerCancelled(triggerId);
    }

    /// @notice Internal function to execute trigger and initiate claim
    /// @param triggerId The trigger being executed
    /// @dev Withdraws maxClaimBps% from Aave, sets up claim state
    function _executeTrigger(bytes32 triggerId) internal {
        uint256 seedValue = IERC20(A_TOKEN).balanceOf(address(this));
        if (seedValue == 0) revert NoSeedToClaim();
        
        uint256 claimableAmount = (seedValue * maxClaimBps) / BPS_DENOMINATOR;
        
        IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, claimableAmount, address(this));
        
        currentClaimId++;
        claimActive = true;
        lastClaimTimestamp = block.timestamp;
        
        totalSnapshotBalances[currentClaimId] = totalUserBalances;
        claimPoolAmounts[currentClaimId] = claimableAmount;
        claimTriggerBlock[currentClaimId] = block.number;
        
        emit ClaimTriggered(currentClaimId, triggerId, claimableAmount, block.number);
    }

    /// @notice Emergency trigger bypass for initial deployment
    /// @param triggerId Registered trigger ID to execute
    /// @dev Only owner. Use before oracle/multisig are operational.
    ///      Should be disabled or timelocked in production.
    function emergencyTrigger(bytes32 triggerId) external onlyOwner nonReentrant recordActivity {
        if (!validTriggers[triggerId]) revert InvalidTrigger();
        if (claimActive) revert ClaimInProgress();
        if (block.timestamp < lastClaimTimestamp + cooldownPeriod) revert CooldownNotElapsed();
        
        _executeTrigger(triggerId);
    }

    /*//////////////////////////////////////////////////////////////
                        CORE: USER CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claims pro-rata share of insurance payout
    /// @dev User must have deposited before trigger block.
    ///      Can only claim once per claim event.
    ///      Share calculated as: claimPool * userBalance / totalSnapshot
    function claimPayout() external nonReentrant recordActivity {
        if (!claimActive) revert NoActiveClaim();
        if (hasClaimed[currentClaimId][msg.sender]) revert AlreadyClaimed();
        if (lastDepositBlock[msg.sender] >= claimTriggerBlock[currentClaimId]) {
            revert DepositedAfterTrigger();
        }
        
        uint256 userBalance = userBalances[msg.sender];
        if (userBalance == 0) revert NoBalance();
        
        uint256 totalSnapshot = totalSnapshotBalances[currentClaimId];
        uint256 claimPool = claimPoolAmounts[currentClaimId];
        
        uint256 userShare = (claimPool * userBalance) / totalSnapshot;
        if (userShare == 0) revert ShareTooSmall();
        
        hasClaimed[currentClaimId][msg.sender] = true;
        claimedAmounts[currentClaimId] += userShare;
        totalClaimsPaid += userShare;
        
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, userShare);
        
        emit ClaimPayout(currentClaimId, msg.sender, userShare);
    }

    /// @notice Calculates claimable amount for a user
    /// @param user Address to check
    /// @return amount Tokens claimable (0 if ineligible)
    /// @dev Returns 0 if: no active claim, already claimed, deposited after trigger, or no balance
    function getClaimableAmount(address user) external view returns (uint256 amount) {
        if (!claimActive) return 0;
        if (hasClaimed[currentClaimId][user]) return 0;
        if (lastDepositBlock[user] >= claimTriggerBlock[currentClaimId]) return 0;
        
        uint256 userBalance = userBalances[user];
        if (userBalance == 0) return 0;
        
        uint256 totalSnapshot = totalSnapshotBalances[currentClaimId];
        uint256 claimPool = claimPoolAmounts[currentClaimId];
        
        return (claimPool * userBalance) / totalSnapshot;
    }

    /*//////////////////////////////////////////////////////////////
                      ADMIN: END CLAIM PERIOD
    //////////////////////////////////////////////////////////////*/

    /// @notice Ends active claim period and returns unclaimed to seed
    /// @dev Only owner. Must wait MIN_CLAIM_WINDOW (30 days) after trigger.
    ///      Unclaimed tokens are re-supplied to Aave seed.
    function endClaimPeriod() external onlyOwner recordActivity {
        if (!claimActive) revert NoActiveClaim();
        if (block.timestamp < lastClaimTimestamp + MIN_CLAIM_WINDOW) {
            revert ClaimWindowNotElapsed();
        }
        
        uint256 claimPool = claimPoolAmounts[currentClaimId];
        uint256 claimed = claimedAmounts[currentClaimId];
        uint256 unclaimed = claimPool - claimed;
        
        if (unclaimed > 0) {
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, unclaimed);
            IPool(AAVE_POOL).supply(DEPOSIT_TOKEN, unclaimed, address(this), 0);
            IERC20(DEPOSIT_TOKEN).forceApprove(AAVE_POOL, 0);
        }
        
        claimActive = false;
        
        emit ClaimPeriodEnded(currentClaimId, claimed, unclaimed);
    }

    /*//////////////////////////////////////////////////////////////
                       YIELD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Distributes tokens from yield pool
    /// @param to Recipient address
    /// @param amount Tokens to distribute
    /// @dev Only owner. Cannot distribute during active claim.
    ///      Only distributes from yield pool (contract balance), not seed.
    function distributeYield(address to, uint256 amount) external onlyOwner nonReentrant recordActivity {
        if (to == address(0)) revert InvalidAddress();
        if (claimActive) revert ClaimInProgress();
        
        uint256 available = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        if (amount > available) revert InsufficientYield();
        
        totalYieldDistributed += amount;
        IERC20(DEPOSIT_TOKEN).safeTransfer(to, amount);
        
        emit YieldDistributed(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         DORMANCY MECHANISM
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if protocol is dormant (inactive 90+ days)
    /// @return bool True if no activity for DORMANCY_THRESHOLD
    function isDormant() public view returns (bool) {
        return block.timestamp > lastActivityTimestamp + DORMANCY_THRESHOLD;
    }

    /// @notice Activates dormancy mode, enabling user withdrawals
    /// @dev Callable by anyone if isDormant() returns true.
    ///      Withdraws all funds from Aave to enable full distribution.
    ///      Irreversible - deposits blocked after activation.
    function activateDormancy() external {
        if (!isDormant()) revert NotDormant();
        if (dormancyActivated) return; // Already activated, no-op
        
        dormancyActivated = true;
        
        uint256 seedValue = IERC20(A_TOKEN).balanceOf(address(this));
        if (seedValue > 0) {
            IPool(AAVE_POOL).withdraw(DEPOSIT_TOKEN, type(uint256).max, address(this));
        }
        
        uint256 totalAssets = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        
        emit DormancyActivated(block.timestamp, totalAssets);
    }

    /// @notice Withdraws pro-rata share during dormancy
    /// @dev Only after dormancy activated. One withdrawal per user.
    ///      Share calculated against remaining assets and balances.
    ///      Zeroes user balance to prevent double-withdrawal.
    function dormancyWithdraw() external nonReentrant {
        if (!dormancyActivated) revert DormancyNotActivated();
        if (hasDormancyWithdrawn[msg.sender]) revert AlreadyDormancyWithdrawn();
        
        uint256 userBalance = userBalances[msg.sender];
        if (userBalance == 0) revert NoBalance();
        
        uint256 totalAssets = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        uint256 userShare = (totalAssets * userBalance) / totalUserBalances;
        
        if (userShare == 0) revert ShareTooSmall();
        
        hasDormancyWithdrawn[msg.sender] = true;
        totalDormancyWithdrawn += userShare;
        
        totalUserBalances -= userBalance;
        userBalances[msg.sender] = 0;
        
        IERC20(DEPOSIT_TOKEN).safeTransfer(msg.sender, userShare);
        
        emit DormancyWithdrawal(msg.sender, userShare);
    }

    /// @notice Calculates user's dormancy withdrawal amount
    /// @param user Address to check
    /// @return amount Tokens withdrawable (0 if ineligible)
    function getDormancyAmount(address user) external view returns (uint256) {
        if (!dormancyActivated) return 0;
        if (hasDormancyWithdrawn[user]) return 0;
        
        uint256 userBalance = userBalances[user];
        if (userBalance == 0) return 0;
        
        uint256 totalAssets = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        return (totalAssets * userBalance) / totalUserBalances;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns comprehensive seed and protocol status
    /// @return seedPrincipal Cumulative tokens supplied to Aave
    /// @return seedValue Current aToken balance (principal + yield)
    /// @return seedYield Accrued yield (seedValue - seedPrincipal)
    /// @return yieldPoolBalance Tokens in yield pool (contract balance)
    /// @return isClaimActive Whether claim event is in progress
    /// @return currentClaim Current claim event ID
    /// @return cooldownRemaining Seconds until next trigger allowed
    /// @return claimWindowRemaining Seconds until claim can be ended
    /// @return dormancyCountdown Seconds until dormancy can activate
    /// @return isDormancyActive Whether dormancy has been activated
    function getSeedStatus() external view returns (
        uint256 seedPrincipal,
        uint256 seedValue,
        uint256 seedYield,
        uint256 yieldPoolBalance,
        bool isClaimActive,
        uint256 currentClaim,
        uint256 cooldownRemaining,
        uint256 claimWindowRemaining,
        uint256 dormancyCountdown,
        bool isDormancyActive
    ) {
        seedPrincipal = totalSeeded;
        seedValue = IERC20(A_TOKEN).balanceOf(address(this));
        seedYield = seedValue > totalSeeded ? seedValue - totalSeeded : 0;
        yieldPoolBalance = IERC20(DEPOSIT_TOKEN).balanceOf(address(this));
        isClaimActive = claimActive;
        currentClaim = currentClaimId;
        isDormancyActive = dormancyActivated;
        
        if (block.timestamp < lastClaimTimestamp + cooldownPeriod) {
            cooldownRemaining = (lastClaimTimestamp + cooldownPeriod) - block.timestamp;
        }
        
        if (claimActive && block.timestamp < lastClaimTimestamp + MIN_CLAIM_WINDOW) {
            claimWindowRemaining = (lastClaimTimestamp + MIN_CLAIM_WINDOW) - block.timestamp;
        }
        
        if (!dormancyActivated && block.timestamp < lastActivityTimestamp + DORMANCY_THRESHOLD) {
            dormancyCountdown = (lastActivityTimestamp + DORMANCY_THRESHOLD) - block.timestamp;
        }
    }

    /// @notice Returns trigger governance status
    /// @return oracle Current trigger oracle address
    /// @return multisig Current trigger multi-sig address
    /// @return pendingTrigger Pending trigger ID (bytes32(0) if none)
    /// @return proposedAt Timestamp of pending trigger proposal
    /// @return confirmableAfter Earliest confirmation timestamp
    /// @return expiresAt Latest confirmation timestamp
    function getTriggerStatus() external view returns (
        address oracle,
        address multisig,
        bytes32 pendingTrigger,
        uint256 proposedAt,
        uint256 confirmableAfter,
        uint256 expiresAt
    ) {
        oracle = triggerOracle;
        multisig = triggerMultisig;
        pendingTrigger = pendingTriggerId;
        proposedAt = triggerProposedAt;
        
        if (pendingTriggerId != bytes32(0)) {
            confirmableAfter = triggerProposedAt + TRIGGER_MIN_DELAY;
            expiresAt = triggerProposedAt + TRIGGER_CONFIRMATION_WINDOW;
        }
    }

    /// @notice Returns current seed value including yield
    /// @return uint256 Current aToken balance
    function getSeedValue() external view returns (uint256) {
        return IERC20(A_TOKEN).balanceOf(address(this));
    }

    /// @notice Returns accrued seed yield
    /// @return uint256 Yield amount (0 if no yield accrued)
    function getSeedYield() external view returns (uint256) {
        uint256 current = IERC20(A_TOKEN).balanceOf(address(this));
        return current > totalSeeded ? current - totalSeeded : 0;
    }

    /// @notice Checks if trigger ID is registered
    /// @param triggerId Trigger to check
    /// @return bool True if trigger is valid
    function isTriggerValid(bytes32 triggerId) external view returns (bool) {
        return validTriggers[triggerId];
    }

    /// @notice Returns user's cumulative deposit balance
    /// @param user Address to check
    /// @return uint256 User's balance
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

    /// @notice Returns block of user's most recent deposit
    /// @param user Address to check
    /// @return uint256 Block number
    function getUserLastDepositBlock(address user) external view returns (uint256) {
        return lastDepositBlock[user];
    }

    /// @notice Returns statistics for a specific claim event
    /// @param claimId Claim event ID to query
    /// @return triggerBlock Block when claim was triggered
    /// @return totalSnapshot Total balances at trigger time
    /// @return poolAmount Tokens available for claims
    /// @return claimedAmount Tokens claimed so far
    function getClaimStats(uint256 claimId) external view returns (
        uint256 triggerBlock,
        uint256 totalSnapshot,
        uint256 poolAmount,
        uint256 claimedAmount
    ) {
        return (
            claimTriggerBlock[claimId],
            totalSnapshotBalances[claimId],
            claimPoolAmounts[claimId],
            claimedAmounts[claimId]
        );
    }

    /*//////////////////////////////////////////////////////////////
                       EMERGENCY RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Recovers accidentally sent tokens
    /// @param token Token address to recover
    /// @param amount Amount to recover
    /// @param to Recipient address
    /// @dev Only owner. Cannot recover A_TOKEN (seed is protected).
    function recoverToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == A_TOKEN) revert CannotTouchSeed();
        if (to == address(0)) revert InvalidAddress();
        
        IERC20(token).safeTransfer(to, amount);
    }
}
