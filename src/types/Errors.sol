// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.19;

import { LEAPDataTypes } from "../types/DataTypes.sol";

/// @title Errors
/// @notice Library containing all custom errors the protocol may revert with.
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                      GENERICS
    //////////////////////////////////////////////////////////////////////////*/

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    // Deposit Errors
    error ERR_NoEthDeposited();
    error ERR_RequiresMinimumAmount();
    error ERR_MaxAllocationAmount();
    error ERR_PhaseEnded();

    // Withdraw Errors
    error ZeroWithdraw();
    error InsufficientAmounts(uint256);
    error IncorrectPhase(LEAPDataTypes.Phase);

    //Phase Errors
    error PhaseNotStarted();

    /*//////////////////////////////////////////////////////////////////////////
                                      NEXT SECTION
    //////////////////////////////////////////////////////////////////////////*/
}
