// SPDX-License-Identifier: MIT

// have our invariant aka properties
// what are invariants?

// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <-- evergreen invariant

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract Invariants is StdInvariant, Test{
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (weth, wbtc,,,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreCollateralThanDsc() external view {
        // get the value of all of the collateral in the protocol
        // and compare it to the total debt (DSC)

        uint256 totalDscSupply = dsc.totalSupply();
        uint256 totalWeth = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtc = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 totalCollateralValue = dscEngine.getUsdValue(weth, totalWeth) +
            dscEngine.getUsdValue(wbtc, totalWbtc);

        assert(totalCollateralValue >= totalDscSupply);
    }
}