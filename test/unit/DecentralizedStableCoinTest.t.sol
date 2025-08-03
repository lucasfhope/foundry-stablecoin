//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    function setUp() public {
        dsc = new DecentralizedStableCoin(address(this));
    }

    function testMustMintMoreThanZero() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__AmountLessThanOrEqualToZero.selector);
        dsc.mint(address(this), 0);
    }

    function testMustBurnMoreThanZero() public {
        dsc.mint(address(this), 1 ether);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__AmountLessThanOrEqualToZero.selector);
        dsc.burn(0);
    }

    function testBurnMoreThanBalance() public {
        dsc.mint(address(this), 1 ether);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(2 ether);
    }

    function testMintToZeroAddress() public {
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MintToZeroAddress.selector);
        dsc.mint(address(0), 1 ether);
    }
}
