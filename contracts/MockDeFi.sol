// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MockToken.sol";

contract MockDeFi {
    MockToken public token;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function mintToken(uint256 amount) external returns (bool) {
        token.mint(msg.sender, amount);
        return true;
    }

    function transferToken(uint256 amount, address to) external returns (bool) {
        token.transferFrom(msg.sender, to, amount);
        return true;
    }
} 