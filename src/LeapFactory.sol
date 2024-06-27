// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

contract LeapFactory {
    address public FEE_RECEIVER;
    uint256 public PROTOCOL_FEE = 0.05 ether;

    constructor(address _feeReceiver, uint256 _protocolFee) {
        FEE_RECEIVER = _feeReceiver;
        PROTOCOL_FEE = _protocolFee;
    }
}
