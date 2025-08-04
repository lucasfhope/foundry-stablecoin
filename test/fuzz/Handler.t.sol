// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }
    
    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) external {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(
        uint256 amountDsc,
        uint256 addressSeed
    ) external {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dscEngine.getAccountInformation(sender);
        
        // 200% overcollateralized
        int256 maxDscToMint = (int256(collateralValueInUSD) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));
        if (amountDsc == 0) {
            return;
        }

        vm.startPrank(sender);
        dscEngine.mintDsc(amountDsc);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 amountCollateral, uint256 collateralSeed) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 userBalance = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        if (userBalance == 0) return;

        (uint256 dscMinted, uint256 collateralValueUsd) = dscEngine.getAccountInformation(msg.sender);

        uint256 maxAmountCollateral;

        if (dscMinted == 0) {
            maxAmountCollateral = userBalance;
        } else {
            // Maintain health factor >= 2: Collateral value must be at least 2x minted DSC
            uint256 requiredCollateralUsd = 2 * dscMinted;

            if (collateralValueUsd <= requiredCollateralUsd) {
                return; // Cannot redeem anything safely
            }

            uint256 redeemableUsd = collateralValueUsd - requiredCollateralUsd;

            uint256 pricePerToken = dscEngine.getUsdValue(address(collateral), 1e18); // USD value of 1 token (1e18 units)
            maxAmountCollateral = (redeemableUsd * 1e18) / pricePerToken;

            // Cap at user's actual balance
            if (maxAmountCollateral > userBalance) {
                maxAmountCollateral = userBalance;
            }
        }

        amountCollateral = bound(amountCollateral, 0, maxAmountCollateral);
        if (amountCollateral == 0) return;

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function burnDsc(uint256 amountDsc) external {
        uint256 userBalance = dsc.balanceOf(msg.sender);
        if (userBalance == 0) return;

        amountDsc = bound(amountDsc, 0, userBalance);
        if (amountDsc == 0) return;

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), amountDsc);
        dscEngine.burnDsc(amountDsc);
        vm.stopPrank();
    }




    ///////////////////////
    // Helper Functions ///
    ///////////////////////
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

}