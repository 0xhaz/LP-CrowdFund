// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

/**
 * @title DataTypes.sol
 * @dev All structs used in LEAP Core, most of which organized under namespaces:
 * - `LEAPDataTypes` for structs used in LEAP Core
 * @dev Some structs contain "slot" annotations that are used to indicate the storage layout of the struct
 * - More gas efficient to group small data types together
 * - They fit in a single 32-byte storage slot
 */

/// @notice Namespace for structs used in both {LeapBase}
library LEAPDataTypes {
    /// @notice Enum representing the different statuses of a launchEvent
    /// @custom: value0 NOT_STARTED event has been created but is not yet launched
    /// @custom: value1 PHASE_DEPOSIT event is active for both deposits and withdrawals
    /// @custome: value2 PHASE_ONE event is in withdraw only mode; no more deposits can be made at this time
    /// @custom: value3 PHASE_TWO no more withdrawals can be made and LP lockup period is active
    /// @custome: value4 PHASE_THREE Depleted event; all assets are able to be withdrawn by the correct parties
    /// @custom: value5 DEPLETED depleted event; all assets are able to be withdrawn by the correct parties
    enum Phase {
        NOT_STARTED,
        /// user can make deposits and withdrawals at anytime with 0% fee
        PHASE_DEPOSIT,
        /// users can no longer deposit, but can still withdraw with a fee
        PHASE_ONE,
        /// users can no longer withdraw or deposit pending the token launch time
        PHASE_TWO,
        /// token has been launched event finished but the LP lockup period has started and is ongoing
        PHASE_THREE,
        // launch event finished and the LP lockup period has finished. Manager can withdraw the LP and tokens
        DEPLETED
    }

    /// phase timestamps to keep track of the launch event critical times
    /// fits in a single 32-byte storage slot
    struct PhaseTimeStamps {
        // when the deposit phase starts
        uint32 launchEventStart;
        // no more deposits can be made after this time
        uint32 depositPhaseEnd;
        // no more deposits can be made but users can still withdraw for a fee
        uint32 phaseOneEnd;
        // no more withdrawals can be made nor deposits
        uint32 phaseTwoEnd;
        // the launch event has finished but the LP lockup period has started i.e the owner can launch
        // the token and the LP pool owner can launch in phase 3
        uint32 phaseThreeEnd;
        // the launch event is finished and the LP lockup period has finished
        uint32 depletionTimestamp;
    }

    struct LaunchParams {
        // the maximum amount of launch token that user can purchase
        uint256 maxAllocation;
        // the minimum amount of Native token the user must deposit
        uint256 minAllocation;
        // only used if new token to mint the correct supply ignored for existing tokens
        uint256 tokenMaxSupply;
        // the amount of the launch token to be sold
        uint256 tokenReserve;
        // percentage to LP pool
        uint256 lpPercentage; // 1e18 == 100% of the raise goes to LP
        /// Timelock duration post phase x when issuer can withdraw their LP tokens
        uint256 issuerTimelock;
        /// the amount of time for the underlying sablier stream
        uint40 streamCliff;
        /// the amount of time for the underlying sablier stream
        uint40 streamTotal;
        /// the royalty address which will receive the raised funds
        address campaignTreasury;
    }

    struct LaunchToken {
        // the address of the launch token
        address tokenAddress;
        // the address of the LP token
        string name;
        // the address of the LP token stream
        string symbol;
    }

    struct OwedDelta {
        // amount of token0 owed to the campaign manager
        int128 amount0;
        // amount of token1 owed to the campaign manager
        int128 amount1;
    }
}
