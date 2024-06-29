// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

// Foundry libraries
import { Test, console2 } from "forge-std/Test.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

// Our contracts
import { LeapBaseHook } from "../src/Leap.sol";
import { HookMiner } from "./utils/HookMiner.sol";
import { LEAPDataTypes } from "../src/types/DataTypes.sol";

contract LeapBaseHookTest is Test, Deployers {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    LeapBaseHook hook;

    address payable TREASURY = payable(makeAddr("treasury"));

    function setUp() public {
        // Deploy V4 core contracts
        deployFreshManagerAndRouters();

        // test initially with a test token which has not yet been minted
        LEAPDataTypes.LaunchToken memory _launchToken =
            LEAPDataTypes.LaunchToken({ tokenAddress: address(0), name: "TEST", symbol: "TEST" });

        // Set the params for the base hook test
        LEAPDataTypes.PhaseTimeStamps memory _phaseTimeStamps = LEAPDataTypes.PhaseTimeStamps({
            launchEventStart: uint32(block.timestamp),
            depositPhaseEnd: uint32(block.timestamp) + 60, // 1 minute
            phaseOneEnd: uint32(block.timestamp) + 120, // 2 minutes
            phaseTwoEnd: uint32(block.timestamp) + 180, // 3 minutes
            phaseThreeEnd: uint32(block.timestamp) + 240, // 4 minutes
            depletionTimestamp: uint32(block.timestamp) + 300 // 5 minutes
         });

        LEAPDataTypes.LaunchParams memory _launchParams = LEAPDataTypes.LaunchParams({
            maxAllocation: 100 ether,
            minAllocation: 0.1 ether,
            tokenMaxSupply: 1000 ether, // max supply of the token
            tokenReserve: 590 ether, // reserve for the token
            lpPercentage: 0.1 ether, // 10% of the raise goes to LP
            issuerTimelock: 52 weeks, // timelock on the LP tokens that are supplied to the market
            streamCliff: 4 weeks,
            streamTotal: 52 weeks,
            campaignTreasury: TREASURY
        });

        // Deploy the hook contract
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_INITIALIZE_FLAG);

        bytes memory creationCode = type(LeapBaseHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            address(manager), address(modifyLiquidityRouter), _launchToken, _phaseTimeStamps, _launchParams, address(0)
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);

        hook = new LeapBaseHook{ salt: salt }(
            IPoolManager(address(manager)),
            address(modifyLiquidityRouter),
            _launchToken,
            _phaseTimeStamps,
            _launchParams,
            address(0)
        );

        require(address(hook) == hookAddress, "Hook address does not match");
    }

    function test_DepositETH_LaunchStarted() public {
        uint256 depositAmount = 0.25 ether;

        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Balance should have increased");
        assertEq(balReceiptAfter, depositAmount, "Receipt balance should match deposit amount");
        assertEq(depositAmount, hook.totalRaised(), "Total raised should match deposit amount");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt balance should not change");
    }

    function testFail_DepositEth_DuringPhase1() public {
        // increase the timestamp to phase1 where deposits are no longer allowed
        vm.warp(block.timestamp + 61);

        uint256 depositAmount = 0.25 ether;
        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Contract balance should have increased");
        assertEq(balReceiptAfter, depositAmount, "Receipt balance should match deposit amount");
        assertEq(depositAmount, hook.totalRaised(), "Total raised should match deposit amount");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt balance should not change");
    }

    // user can withdraw their deposit during phase1 with 0 fee
    function test_DepositEthWitdraw_DuringDepositPhase() public {
        // deposit into the contract
        uint256 depositAmount = 0.25 ether;

        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Contract balance should have increased");
        assertEq(balReceiptAfter, depositAmount, "Receipt balance should match deposit amount");
        assertEq(depositAmount, hook.totalRaised(), "Total raised should match deposit amount");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt balance should not change");

        // withdraw the deposit
        hook.removeETH(depositAmount);
        uint256 balAfterWithdraw = address(hook).balance;
        assertEq(balAfterWithdraw, balBefore, "Contract balance should match before deposit");
    }

    // user can withdraw their deposit during phase1 with a fee
    function test_DepositEthWithdraw_DuringPhase1() public {
        // deposit into the contract
        uint256 depositAmount = 0.25 ether;

        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Contract balance should have increased");
        assertEq(balReceiptAfter, depositAmount, "Receipt balance should match deposit amount");
        assertEq(depositAmount, hook.totalRaised(), "Total raised should match deposit amount");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt balance should not change");

        // 69 seconds put us into phase 1
        vm.warp(block.timestamp + 69);

        // withdraw the deposit
        hook.removeETH(depositAmount);
        uint256 balAfterWithdraw = address(hook).balance;
        assertEq(balAfterWithdraw, balBefore, "Contract balance should match before deposit");
    }

    function testFail_DepositEthWithdraw_DuringPhase2() public {
        // deposit into the contract
        uint256 depositAmount = 0.25 ether;

        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Contract balance should have increased");
        assertEq(balReceiptAfter, depositAmount, "Receipt balance should match deposit amount");
        assertEq(depositAmount, hook.totalRaised(), "Total raised should match deposit amount");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt balance should not change");

        // 129 seconds put us into phase 2
        vm.warp(block.timestamp + 129);

        // withdraw the deposit
        hook.removeETH(depositAmount);
    }

    function test_finalizeLaunchEvent() public {
        // deposit into the contract
        uint256 depositAmount = 0.25 ether;

        uint256 balBefore = address(hook).balance;

        uint256 balReceiptBefore = IERC20(address(hook)).balanceOf(address(this));

        hook.depositEth{ value: depositAmount }();

        uint256 balAfter = address(hook).balance;
        uint256 balReceiptAfter = IERC20(address(hook)).balanceOf(address(this));

        assertGt(balAfter, balBefore, "Contract balance not updated correctly");
        assertEq(balReceiptAfter, depositAmount, "Deposit amounts not equal");
        assertEq(depositAmount, hook.totalRaised(), "Contract balance not updated correctly");
        assertGt(balReceiptAfter, balReceiptBefore, "Receipt tokens not updated correctly");

        // 229 seconds put us into phase 3
        vm.warp(block.timestamp + 229);

        // finalize the launch event
        console2.log("Before finalizeLaunchEvent");
        hook.finalizeCampaign();
    }
}
