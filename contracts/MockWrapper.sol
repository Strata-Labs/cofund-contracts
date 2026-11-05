// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MockDeFi.sol";

contract MockWrapper {
    MockDeFi public deFi;
    error InvalidInstructions();

    constructor(address _defi) {
        deFi = MockDeFi(_defi);
    }

    function routerWrapper(string calldata name, bytes calldata instructions) external returns (bool) {
        if (keccak256(bytes(name)) == keccak256(bytes("mint-token"))) {
            (uint256 amount) = abi.decode(instructions, (uint256));
            return deFi.mintToken(amount);
        } else {
            (uint256 amount, address to) = abi.decode(instructions, (uint256, address));
            return deFi.transferToken(amount, to);
        }
        return true;
    }
} 