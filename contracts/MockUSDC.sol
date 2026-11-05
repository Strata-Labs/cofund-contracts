// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// USDC-shaped stand-in for the unforked localhost chain: 6 decimals and the
/// masterMinter/configureMinter/mint surface the webapp e2e helper drives via
/// impersonation. Permissions are intentionally open — test chain only.
contract MockUSDC is ERC20 {
    address public constant masterMinter =
        0x0000000000000000000000000000000000000001;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function configureMinter(address, uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 amount) external returns (bool) {
        _mint(to, amount);
        return true;
    }
}
