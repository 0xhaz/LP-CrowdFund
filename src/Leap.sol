// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { Errors } from "./types/Errors.sol";
import { LEAPDataTypes } from "./types/DataTypes.sol";
import { LeapFactory } from "./LeapFactory.sol";
import { LeapBase } from "./abstracts/LeapBase.sol";

contract LeapBaseHook is LeapBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Emits a {TransferAdmin} event
    /// @param _manager The address of the pool manager
    /// @param _launchToken The parameters of the launch token
    /// @param _phaseTimeStamps The timestamps of the launch event phases
    /// @param _launchParams The parameters of the launch event
    /// @param _leapFactory The address of the LeapFactory contract
    constructor(
        IPoolManager _manager,
        address _rouer, // modifyLiquidityRouter
        LEAPDataTypes.LaunchToken memory _launchToken,
        LEAPDataTypes.PhaseTimeStamps memory _phaseTimeStamps,
        LEAPDataTypes.LaunchParams memory _launchParams,
        address _leapFactory
    )
        LeapBase(_manager, _rouer, _launchToken, _phaseTimeStamps, _launchParams, _leapFactory)
    { }

    /*//////////////////////////////////////////////////////////////////////////
                           USER-FACING NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice deposit ETH into the launch event and mints the user receipt tokens
    /// @notice only possible during PHASE_DEPOSIT
    /// @notice this is the primary entry point of funds into the system
    function depositEth() external payable atPhase(LEAPDataTypes.Phase.PHASE_DEPOSIT) {
        // perform required checks to make sure deposit is valid
        if (msg.value == 0) revert Errors.ERR_NoEthDeposited();
        if (msg.value < launchParams.minAllocation) revert Errors.ERR_RequiresMinimumAmount();
        if (msg.value > launchParams.maxAllocation) revert Errors.ERR_MaxAllocationAmount();

        // increase the amount of total native raised
        totalRaised += msg.value;
        // mint the amount of shares to the sender in proportion to the amount of native deposited
        _mint(msg.sender, msg.value);

        // emit the event to show that the eth was deposited
        emit EthDeposited(msg.sender, msg.value);
    }

    /// @notice withdraws the amount of ETH from the launch event and burns the users receipt token
    /// @notice only possible during PHASE_DEPOSIT and PHASE_ONE (but with a fee)
    /// @param amountToRemove the amount of ETH to remove from the launch event
    function removeETH(uint256 amountToRemove) external payable {
        LEAPDataTypes.Phase cp = currentPhase();

        if (cp != LEAPDataTypes.Phase.PHASE_DEPOSIT && cp != LEAPDataTypes.Phase.PHASE_ONE) {
            revert Errors.IncorrectPhase(cp);
        }

        // check that the user has enough shares to remove the desired amount
        if (amountToRemove == 0) revert Errors.ZeroWithdraw();
        if (amountToRemove > balanceOf(msg.sender)) revert Errors.InsufficientAmounts(amountToRemove);

        // send the eth back to the user who requested the withdrawal
        // this will include the withdrawal fee if it is required
        uint256 fee;

        // during phase one there is a fee to remove the eth
        if (cp == LEAPDataTypes.Phase.PHASE_ONE) {
            fee = FullMath.mulDiv(amountToRemove, 0.1 ether, 1 ether);
            console2.log("Phase One fee", fee);

            // send the fee to the campaign treasury as marketing compensation
            (bool sentFee,) = payable(address(launchParams.campaignTreasury)).call{ value: fee }("");
            require(sentFee, "Failed to send fee to campaign treasury");
        }

        // update the total raised amount
        totalRaised -= amountToRemove;

        // burn the receipt tokens from the user
        _burn(msg.sender, amountToRemove);

        // return the eth to the user minus any fee incurred during stage 2
        _sendNative(amountToRemove - fee, payable(msg.sender));

        // emit an event to show that the eth was removed
        emit EthRemoved(msg.sender, amountToRemove, fee);
    }

    /// @notice finalizes the leap campaign event
    /// @notice launches the univ4 pool for the asset
    /// @notice applies protocol fees
    /// @notice sends the tokens to vesting campaign and distributes excess tokens to campaign manager
    /// @notice only callable during PHASE_THREE or DEPLETED
    /// @notice can be called by anyone as permissionless function
    function finalizeCampaign() external {
        // Retrieve the current phase
        LEAPDataTypes.Phase cp = currentPhase();

        // Ensure the function can only be called during PHASE_THREE or DEPLETED
        if (cp != LEAPDataTypes.Phase.PHASE_THREE && cp != LEAPDataTypes.Phase.DEPLETED) {
            revert Errors.IncorrectPhase(cp);
        }

        // Create the launch token if it doesn't exist and mint the max supply to the campaign treasury
        if (launchToken.tokenAddress == address(0)) {
            _createTokenMintSupply(launchParams.campaignTreasury);
        }

        uint256 LeapFee = 0.05 ether;
        uint256 protocolFeeAmount = FullMath.mulDiv(totalRaised, LeapFee, 1e18);
        uint256 totalRaisedMinusFee = totalRaised - protocolFeeAmount;

        uint256 token1VestingAmount = launchParams.tokenReserve;
        uint256 lpAmountToken0;
        uint256 lpAmountToken1;

        // Create uniV4 LP Pool if LP Percentage is greater than 0
        if (launchParams.lpPercentage > 0) {
            lpAmountToken0 = FullMath.mulDiv(launchParams.lpPercentage, totalRaisedMinusFee, 1e18);
            lpAmountToken1 = FullMath.mulDiv(launchParams.lpPercentage, launchParams.tokenReserve, 1e18);

            // Adjust the vesting amount by subtracting the LP amount
            token1VestingAmount -= lpAmountToken1;

            // Initialize the pool with the calculated sqrt price
            uint256 sqrtPriceX96 = FullMath.mulDiv(launchParams.tokenReserve, SQRT_RATIO_1_1, totalRaised);
            _initializePool(sqrtPriceX96, 3000, 60, abi.encode(lpAmountToken0, lpAmountToken1));
        }

        // Create sablier vesting stream if there are tokens to vest
        if (token1VestingAmount > 0) {
            streamId = _createSablierVestingStream(uint128(token1VestingAmount));
            console2.log("Stream ID", streamId);
        }

        // Handle protocol fee distribution and treasury transfer
        _sendNative(protocolFeeAmount, payable(msg.sender));
        _sendNative(totalRaisedMinusFee - lpAmountToken0, payable(launchParams.campaignTreasury));

        // Emit the event to show that the campaign has been finalized
        emit CampaignFinalized(streamId, protocolFeeAmount);
    }
}
