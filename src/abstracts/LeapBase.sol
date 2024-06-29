// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { BaseHook } from "v4-periphery/BaseHook.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";
import { ERC20 } from "openzeppelin/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LEAPDataTypes } from "../types/DataTypes.sol";
import { LeapFactory } from "../LeapFactory.sol";
import { ILeapEvent } from "../interfaces/ILeapEvent.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { Errors } from "../types/Errors.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { CurrencyLibrary, Currency } from "v4-core/types/Currency.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";

// Sablier contracts
import { ISablierV2LockupLinear } from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import { Broker, LockupLinear } from "@sablier/v2-core/src/types/DataTypes.sol";

// Uniswap contracts
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { ud60x18 } from "@prb/math/src/UD60x18.sol";
import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { BalanceDelta, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import { LeapERC20 } from "../LeapERC20.sol";

/// @title LEAP Base
abstract contract LeapBase is BaseHook, ERC20, ILeapEvent {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for uint128;

    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolSwapTest swapRouter;
    IPoolManager poolManager;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/
    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e sqrt(1) * 2^96
    // This is used as the initial price for the pool
    // as we add equal amounts of token0 and token1 to the pool during setUp
    uint160 constant SQRT_RATIO_1_1 = 79_228_162_514_264_337_593_543_950_336;
    bytes internal constant ZERO_BYTES = bytes("");

    int24 internal _minUsableTick = -887_220;
    int24 internal _maxUsableTick = -_minUsableTick;
    uint160 internal _sqrtMinTick = TickMath.getSqrtPriceAtTick(_minUsableTick);
    uint160 internal _sqrtMaxTick = TickMath.getSqrtPriceAtTick(_maxUsableTick);

    ISablierV2LockupLinear public constant LOCKUP_LINEAR =
        ISablierV2LockupLinear(0xAFb979d9afAd1aD27C5eFf4E27226E3AB9e5dCC9);

    /*//////////////////////////////////////////////////////////////////////////
                                   PUBLIC STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// keeps track of the accTokens during the vesting period
    uint256 accTokenPerShare;
    /// total eth raised as part of campaign
    uint256 public totalRaised;
    /// streamId of the vesting stream once launched
    uint256 public streamId;
    /// leap factory required as fee information is derived from external call to this contract
    address public immutable LEAP_FACTORY;

    // the token launched as part of this launch event
    LEAPDataTypes.LaunchToken public launchToken;
    // timestamps for the relevant phases of the launch event
    LEAPDataTypes.PhaseTimeStamps public phaseTimeStamps;
    // additional required launch parameters
    LEAPDataTypes.LaunchParams public launchParams;
    // tokens owed to the campaign manager
    LEAPDataTypes.OwedDelta public owedDelta;

    // poolKey and poolId are the pool key and pool id for the generated pool
    PoolKey poolKey;
    PoolId poolId;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        IPoolManager _manager,
        address _router, //modifyLiquidityRouter
        LEAPDataTypes.LaunchToken memory _launchToken,
        LEAPDataTypes.PhaseTimeStamps memory _phaseTimeStamps,
        LEAPDataTypes.LaunchParams memory _launchParams,
        address _leapFactory
    )
        BaseHook(_manager)
        // ERC20 token will be minted as receipt token for participating in launc this can be later burnt for redemption
        ERC20(string(abi.encodePacked("RX-", _launchToken.name)), string(abi.encodePacked("RX-", _launchToken.symbol)))
    {
        // set constructor args
        LEAP_FACTORY = _leapFactory;
        phaseTimeStamps = _phaseTimeStamps;
        launchParams = _launchParams;
        poolManager = _manager;

        // check if a new token or a capital raise and set launch token
        // if this a capital raise we also need to transfer the required amount of tokens
        // Set the launch token
        if (launchToken.tokenAddress != address(0)) {
            // This is an existing token, so use the existing token name and symbol
            (launchToken.name, launchToken.symbol) =
                (ERC20(_launchToken.tokenAddress).name(), ERC20(_launchToken.tokenAddress).symbol());
            // As this is now a cap raise, transfer the require amount of tokens into this contract
            IERC20(launchToken.tokenAddress).safeTransferFrom(msg.sender, address(this), launchParams.tokenReserve);
        } else {
            // This will be a new token to launch
            (launchToken.name, launchToken.symbol) = (_launchToken.name, _launchToken.symbol);
        }

        modifyLiquidityRouter = PoolModifyLiquidityTest(_router);
        console2.log("Modify Liquidity Router: %s", address(modifyLiquidityRouter));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Modifier which ensures contract is in a defined phase
    modifier atPhase(LEAPDataTypes.Phase _phase) {
        _atPhase(_phase);
        _;
    }

    /// @dev Bytecode size optimization for the `atPhase` modifier
    /// This works because internal functions are not in-lined in modifiers
    function _atPhase(LEAPDataTypes.Phase _phase) internal view {
        if (currentPhase() != _phase) {
            revert Errors.IncorrectPhase(_phase);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                           UNISWAP HOOK FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        console2.log("Before Initialize");
        return this.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24,
        bytes calldata params
    )
        external
        override
        returns (bytes4)
    {
        // Add the liquidity to the pool
        (uint256 amt0, uint256 amt1) = abi.decode(params, (uint256, uint256));
        if (amt0 > 0 || amt1 > 0) {
            _addLiquidityToPool(amt0, amt1);
        }

        return this.afterInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                USER-FACING FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice intializes a uniswapV4 pool with the provided params and attaches this contract as a hook
    function _initializePool(
        uint256 initialSqrtPriceX96,
        uint24 feeTier,
        int24 tickSpacing,
        bytes memory params
    )
        internal
    {
        // set the pool configuration
        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(launchToken.tokenAddress),
            fee: feeTier,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        poolId = poolKey.toId();

        // initialize the pool with the provided params
        poolManager.initialize(poolKey, uint160(initialSqrtPriceX96), params);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        require(sqrtPriceX96 > 0, "Pool not initialized");
    }

    /// @notice Adds initial liquidity to the pool
    /// @dev This function is calculates and adds liquidity to the pool
    /// @param amount0 The amount of first token to add as liquidity
    /// @param amount1 The amount of second token to add as liquidity
    function _addLiquidityToPool(uint256 amount0, uint256 amount1) internal {
        console2.log("Adding liqudity to pool Id, AMTS: ");

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Calculate liquidity for the given amounts
        uint128 liq =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, _sqrtMinTick, _sqrtMaxTick, amount0, amount1);

        // Approve token1 for use in modifyLiquidityRouter
        IERC20(launchToken.tokenAddress).approve(address(modifyLiquidityRouter), amount1);

        /// @dev we don't need to save position as it is always min - max tick for the tick spacing which is known
        (BalanceDelta delta) = modifyLiquidityRouter.modifyLiquidity{ value: amount0 }(
            poolKey,
            IPoolManager.ModifyLiquidityParams(_minUsableTick, _maxUsableTick, int256(int128(liq)), 0),
            ZERO_BYTES
        );

        // we want to store the amount of tokens owed that were not part of the add liquidity function and send these to
        // user at end
        // delta.amount1 and amount0 will always be negative in this case
        owedDelta.amount0 = int128(int256(amount0)) + delta.amount0();
        owedDelta.amount1 = int128(int256(amount1)) + delta.amount1();
        console2.log("Delta0: %s ", owedDelta.amount0);
        console2.log("Delta1: %s ", owedDelta.amount1);

        console2.log("Liquidity added: %s", liq);
        emit LiquidityAdded(delta.amount0(), delta.amount1());
    }

    /// @notice Removes the LP position after the lock period has been completed
    /// @notice Transfers the LP to the owner of the contract; they are free to do as they please with this position
    function removeLP() external atPhase(LEAPDataTypes.Phase.DEPLETED) {
        // remove all LP from the pool
        console2.log("Removing LP from pool Id");
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint128 liquidityToRemove = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            _sqrtMinTick,
            _sqrtMaxTick,
            uint128(int128(owedDelta.amount0)),
            uint128(int128(owedDelta.amount1))
        );

        (uint256 amt0, uint256 amt1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, _sqrtMinTick, _sqrtMaxTick, liquidityToRemove);

        // add the amounts owed from the add liquidity function
        amt0 += uint256(uint128(owedDelta.amount0));
        amt1 += uint256(uint128(owedDelta.amount1));

        // modify the liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: _minUsableTick,
                tickUpper: _maxUsableTick,
                liquidityDelta: -(liquidityToRemove.toInt256()),
                salt: 0
            }),
            ZERO_BYTES
        );

        // transfer the token amounts to the user
        if (amt0 > 0) {
            _sendNative(amt0, payable(msg.sender));
        }

        if (amt1 > 0) {
            IERC20(launchToken.tokenAddress).safeTransfer(msg.sender, amt1);
        }

        emit LiquidityRemoved(amt0, amt1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SABLIER INTERFACING FUNCTIONS 
    //////////////////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////////////////
                        SABLIER INTERFACING PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Primary function to receive the vested launch tokens from the contract
    /// @dev Burns the user's receipt token in exchange for the vested launch tokens
    /// @param amount The amount of receipt tokens to redeem
    /// @return launchTokenEntitlement The amount of launch tokens the user is entitled to receive
    function redeemStreamedAmount(uint256 amount) external returns (uint256) {
        // Check if there is a streamed amount available for this claim
        uint256 streamedAmountThisClaim = LOCKUP_LINEAR.withdrawableAmountOf(streamId);
        if (streamedAmountThisClaim > 0) {
            // Withdraw all streamed amount from the underlying vesting contract
            LOCKUP_LINEAR.withdrawMax({ streamId: streamId, to: address(this) });
        }

        // Update the total streamed amount to date from the vesting partner
        accTokenPerShare += FullMath.mulDiv(streamedAmountThisClaim, 1e18, totalRaised);
        uint256 launchTokenEntitlement = FullMath.mulDiv(amount, accTokenPerShare, 1e18);

        // Fetch underlying vesting partner data
        uint256 streamedAmount = LOCKUP_LINEAR.getWithdrawnAmount(streamId);
        uint256 totalInStream = LOCKUP_LINEAR.getDepositedAmount(streamId);

        // Calculate the amount of receipt tokens to be burned based on the streamed amount
        uint256 burnAmount = FullMath.mulDiv(amount, streamedAmount, totalInStream);

        // Transfer the required amount of launch tokens to the user
        IERC20(launchToken.tokenAddress).safeTransfer(msg.sender, launchTokenEntitlement);

        // Burn the user's receipt token to prevent double spending
        _burn(msg.sender, burnAmount);

        return launchTokenEntitlement;
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SABLIER INTERFACING INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// Create the sablier vesting stream
    /// @dev the params for this are set at contract creation time
    /// @param vestingAmount is the amount of token to be vested through Sablier
    function _createSablierVestingStream(uint128 vestingAmount) internal virtual returns (uint256 _streamId) {
        // approve the sablier contract to transfer the vesting amount
        IERC20(launchToken.tokenAddress).approve(address(LOCKUP_LINEAR), vestingAmount);

        // Declare the params struct
        LockupLinear.CreateWithDurations memory params;

        // Declare the function parameters
        params.sender = msg.sender; // the sender will be able to cancel the stream
        params.recipient = address(this); // the recipient of the streamed assets
        params.totalAmount = vestingAmount; // total amount of amount inclusive of all fees
        params.asset = IERC20(launchToken.tokenAddress); // the asset to be streamed
        params.cancelable = false; // Whether the stream can be cancelled by the sender
        params.transferable = true; // Whether the stream can be transferred to another address
        params.durations = LockupLinear.Durations({
            cliff: launchParams.streamCliff, // Assets will be unlocked after stream cliff
            total: launchParams.streamTotal // Setting a total duration of stream total
         });
        console2.log("Creating the stream");
        console2.log("Sender: %s", params.sender);
        console2.log("Recipient: %s", params.recipient);
        console2.log("Total Amount: %s", params.totalAmount);
        console2.log("Cancelable: %s", params.cancelable);
        console2.log("Transferable: %s", params.transferable);
        console2.log("Cliff: %s", params.durations.cliff);
        console2.log("Total: %s", params.durations.total);

        // Createh LockupLinear stream using a function that sets the start time to
        // this also transfers the vesting asset to the stream
        _streamId = LOCKUP_LINEAR.createWithDurations(params);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         SABLIER INTERFACING FUNCTIONS VIEWS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Returns the total amount streamed to the recipient, adjusted for the user's allocation
    /// @return the total amonut streamed, in units of the asset's decimals
    function stremedAmountOf() public view returns (uint128) {
        return _streamedAmountOf();
    }

    /// @dev Internal  function to get the total amount streamed from the LOCKUP_LINEAR contract
    /// @return The total amount streamed, in units of the asset's decimals
    function _streamedAmountOf() internal view returns (uint128) {
        return LOCKUP_LINEAR.streamedAmountOf(streamId);
    }

    /// @notice Calculates the total stream amount for a given receipt amount
    /// @param amount The receipt amount to calculate the total stream amount for
    /// @return The total stream amount corresponding to the receipt amount
    function totalStreamAmountForReceiptAmount(uint256 amount) external view returns (uint256) {
        uint256 ts = totalSupply();
        uint256 totalInStream = LOCKUP_LINEAR.getDepositedAmount(streamId);
        return FullMath.mulDiv(amount, totalInStream, ts);
    }

    /// @notice Calculates the streamed amount for a given receipt amount
    /// @dev Adjusts for the user's allocation amount
    /// @param amount The receipt amount to calculate the stream amount for
    /// @return the streamed amount corresponding to the receipt amount
    function streamedAmountForReceiptAmount(uint256 amount) external view returns (uint256) {
        uint256 ts = totalSupply();
        return FullMath.mulDiv(amount, uint256(_streamedAmountOf()), ts);
    }

    /// @notice Calculates the pending redemption amount for a given receipt amount
    /// @param receiptAmount The receipt amount to calculate the pending redemption for
    /// @return _pendingRedemption The pending redemption amount
    function pendingRedemption(uint256 receiptAmount) external view returns (uint256 _pendingRedemption) {
        uint256 streamedAmountThisClaim = LOCKUP_LINEAR.withdrawableAmountOf(streamId);
        uint256 _accTokenPerShare = accTokenPerShare + FullMath.mulDiv(streamedAmountThisClaim, 1e18, totalRaised);
        _pendingRedemption = FullMath.mulDiv(receiptAmount, _accTokenPerShare, 1e18);
    }

    /*//////////////////////////////////////////////////////////////////////////
                           INTERNAL NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Creates the launch token mints the required supply
    /// @dev This function is called only if the launch token does not exist yet. It creates the token and mints
    // the maximum supply. Then transfers the additional tokens to the campaign's treasury
    /// @param _treasury The address of the campaign's treasury where additinal tokens will be sent
    function _createTokenMintSupply(address _treasury) internal {
        // Create new token
        LeapERC20 _launchToken = new LeapERC20(launchParams.tokenMaxSupply, launchToken.name, launchToken.symbol);
        launchToken.tokenAddress = address(_launchToken);

        // Transfer the additional tokens to the campaign's treasury
        IERC20(address(_launchToken)).safeTransfer(_treasury, launchParams.tokenMaxSupply - launchParams.tokenReserve);
    }

    /// @notice Internal function to send a specified amount of Ether to a given address
    /// @dev This function uses the low-level `.call` method to transfer Ether and handles errors appropriately
    /// @param amt the amount of Ether to send, in wei
    /// @param to the address to send the Ether to. This must be a payable address
    function _sendNative(uint256 amt, address payable to) internal {
        (bool sent,) = to.call{ value: amt }("");
        require(sent, "Failed to send Ether");
    }

    /// @notice A function to receive ether. This function is executed on plain ether transfers
    /// @dev The receive function is a callback function triggered when the contract receives ether without data
    /// It is marked `external` and `payable` to allow the contract to receive ether
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////////////////
                           INTERNAL CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The current phase the auction is in
    /// @return The current phase from LEAPDataTypes.Phase
    function currentPhase() public view returns (LEAPDataTypes.Phase) {
        uint256 currentTime = block.timestamp;

        if (phaseTimeStamps.launchEventStart == 0 || currentTime < phaseTimeStamps.launchEventStart) {
            return LEAPDataTypes.Phase.NOT_STARTED;
        }

        if (currentTime < phaseTimeStamps.depositPhaseEnd) {
            return LEAPDataTypes.Phase.PHASE_DEPOSIT;
        }

        if (currentTime < phaseTimeStamps.phaseOneEnd) {
            return LEAPDataTypes.Phase.PHASE_ONE;
        }

        if (currentTime < phaseTimeStamps.phaseTwoEnd) {
            return LEAPDataTypes.Phase.PHASE_TWO;
        }

        if (currentTime < phaseTimeStamps.phaseThreeEnd) {
            return LEAPDataTypes.Phase.PHASE_THREE;
        }

        return LEAPDataTypes.Phase.DEPLETED;
    }
}
