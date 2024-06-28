// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";

/// @title ILeapEvent
/// @notice Base logic for all Sablier V2  streaming contracts
interface ILeapEvent {
    /// @notice Emitted when the admin claims all protocol revenues accrued for a particular ERC-20 asset
    /// @param admin The address of the contract admin
    /// @param asset The contract address of ERC-20 asset protocol revenues have been claimed for
    /// @param protocolRevenues The amount of protocol revenues claimed, denoted in units of the asset's decimals
    event ClaimProtocolRevenues(address indexed admin, IERC20 indexed asset, uint128 protocolRevenues);

    event EthDeposited(address indexed user, uint256 amount);

    event EthRemoved(address indexed user, uint256 amount, uint256 fee);

    event CampaignFinalized(uint256 streamId, uint256 protocolFee);

    event LiquidityAdded(int128 amount0, int128 amount1);

    event LiquidityRemoved(uint256 amount0, uint256 amount1);
}
