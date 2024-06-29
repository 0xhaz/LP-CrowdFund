// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

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
import { LeapBaseHook } from "../../src/Leap.sol";
import { LeapFactory } from "../../src/LeapFactory.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { LEAPDataTypes } from "../../src/types/DataTypes.sol";

//abi
import { LockupLinear, Lockup } from "@sablier/v2-core/src/types/DataTypes.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

// forge test --match-contract LeapVestingBaseHookTest --fork-url mainnet
