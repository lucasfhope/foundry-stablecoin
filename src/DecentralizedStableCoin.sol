//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Lucas Hope
 * @notice This contract implements a stablecoin system with the following specifications:
 * Collateral: Exogenous (ETH & BTC)
 * Minting & Burning: Algorithmic
 * Relative Stability: Pegged to USD
 * @dev This is the contract meant to be governed by DSCEngine.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountLessThanOrEqualToZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__MintToZeroAddress();

    constructor(address initialOwner) ERC20("Decentralized Stable Coin", "DSC") Ownable(initialOwner) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountLessThanOrEqualToZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__MintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountLessThanOrEqualToZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
