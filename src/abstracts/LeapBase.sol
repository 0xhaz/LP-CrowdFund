// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Test.sol";
import { BaseHook } from "v4-periphery/BaseHook.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LEAPDataTypes } from "../libraries/DataTypes.sol";
import { LeapFactory } from "../LeapFactory.sol";
import { ILeapEvent } from "../interfaces/ILeapEvent.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { Errors } from "../libraries/Errors.sol";
