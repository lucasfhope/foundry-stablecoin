//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "test/mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "test/mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFailedTransferFrom.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    /**
     * @dev Using a mock weth for testing purposes.
     * Price of the mock weth is $2000 USD
     */
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 10000 ether; // 10e18 collateral in eth = 20,000e18 in USD
    uint256 public constant AMOUNT_TO_MINT_BREAK_HEALTH_FACTOR = 10001 ether;
    uint256 public constant AMOUNT_TO_BURN = 5000 ether; // 5e18 collateral in eth = 10,000e18 in USD

    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant COLLATERAL_TO_COVER = 25 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (weth, wbtc, ethUsdPriceFeed, btcUsdPriceFeed,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenAdressesLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAndPriceFeedAddressesLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////
    // Price Tests ////////
    ///////////////////////
    function testGetUsdValue() public {
        uint256 ethAmount = 15 ether; // 15e18 * $2000 = 30,000e18
        uint256 expectedValue = 30000e18;
        uint256 actualValue = engine.getUsdValue(weth, ethAmount);
        assertEq(actualValue, expectedValue);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether; // 100e18 / 2000 = 0.05e18
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ///////////////////////////////
    // Deposit Collateral Tests ///
    ///////////////////////////////
    function testDepositingRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approveInternal(USER, address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsAmountMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsDepositingUnapprovedCollateral() public {
        ERC20Mock mockToken = new ERC20Mock("Mock", "MCK", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(mockToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        ERC20Mock(weth).approveInternal(USER, address(engine), AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 expectedWethDepositAmount = engine.getTokenAmountFromUsd(weth, totalCollateralInUsd);
        uint256 expectedCollateralInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(totalCollateralInUsd, expectedCollateralInUsd);
        assertEq(AMOUNT_COLLATERAL, expectedWethDepositAmount);
    }

    function testRevertsIfTransferFromFailsDuringDeposit() public {
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom(msg.sender);
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        vm.prank(msg.sender);
        mockDsc.transferOwnership(address(mockEngine));

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////
    // Mint DSC Tests /////////////
    ///////////////////////////////
    function testRevertsIfMintingIsAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsAmountMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBrokenDuringMinting() public depositedCollateral {
        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            AMOUNT_TO_MINT_BREAK_HEALTH_FACTOR, engine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.startPrank(USER);
        vm.expectRevert(abi.encodePacked(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));
        engine.mintDsc(AMOUNT_TO_MINT_BREAK_HEALTH_FACTOR);
        vm.stopPrank();
    }

    modifier mintedDsc() {
        vm.startPrank(USER);
        engine.mintDsc(AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanMintAndAccessDsc() public depositedCollateral mintedDsc {
        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, AMOUNT_TO_MINT);
    }

    function testRevertsIfMintFails() public {
        MockFailedMintDSC mockDsc = new MockFailedMintDSC(msg.sender);
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        vm.prank(msg.sender);
        mockDsc.transferOwnership(address(mockEngine));

        ERC20Mock(weth).approveInternal(USER, address(mockEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        vm.prank(USER);
        mockEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
    }

    ///////////////////////////////
    // Burn DSC Tests /////////////
    ///////////////////////////////
    function testRevertsIfBurningIsAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsAmountMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfBurningMoreThanBalance() public {
        uint256 amountToBurn = 1;
        vm.startPrank(USER);
        vm.expectRevert(abi.encodePacked(DSCEngine.DSCEngine__AmountExceedsBalance.selector, amountToBurn, uint256(0)));
        engine.burnDsc(1);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_TO_BURN);
        engine.burnDsc(AMOUNT_TO_BURN);
        vm.stopPrank();
        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, AMOUNT_TO_MINT - AMOUNT_TO_BURN);
    }

    function testburnDscRevertsWhenDscTransferFromReturnsFalse() public {
        // 1) Deploy a DSC that returns false on transferFrom
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom(address(this)); // with transferFrom overridden to return false

        // 2) Deploy an engine that uses normal collaterals but this bad DSC
        address[] memory tokens = new address[](1);
        tokens[0] = weth;
        address[] memory feeds = new address[](1);
        feeds[0] = ethUsdPriceFeed;
 

        DSCEngine eng = new DSCEngine(tokens, feeds, address(mockDsc));
        mockDsc.transferOwnership(address(eng)); // if your DSC is Ownable and engine needs to mint

        // 3) USER deposits collateral and mints some DSC (so _burnDsc can run)
        ERC20Mock(weth).approveInternal(USER, address(eng), AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        eng.depositCollateral(weth, AMOUNT_COLLATERAL);
        eng.mintDsc(AMOUNT_TO_BURN);
        mockDsc.approve(address(eng), AMOUNT_TO_BURN); // normal allowance step
        vm.stopPrank();

        // 4) Expect engine revert because mockDsc.transferFrom returns false
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);

        // 5) This calls _burnDsc internally -> transferFrom(false) -> TransferFailed
        vm.prank(USER);
        eng.burnDsc(AMOUNT_TO_BURN);
    }



    ///////////////////////////////
    // Redeem Collateral Tests ////
    ///////////////////////////////
    function testRevertsIfRedeemingIsAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsAmountMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfRedeemCollateralIsMoreThanDepositedAmount() public depositedCollateral {
        uint256 redeemAmount = AMOUNT_COLLATERAL + 1e18;
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodePacked(DSCEngine.DSCEngine__AmountExceedsBalance.selector, redeemAmount, AMOUNT_COLLATERAL)
        );
        engine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBrokenAfterRedeemingCollateral() public depositedCollateral mintedDsc {
        uint256 expectedHealthFactor = engine.calculateHealthFactor(AMOUNT_TO_MINT, engine.getUsdValue(weth, 0));
        vm.startPrank(USER);
        vm.expectRevert(abi.encodePacked(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralTransferFails() public {
        MockFailedTransfer mockDsc = new MockFailedTransfer(msg.sender);
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        vm.prank(msg.sender);
        mockDsc.transferOwnership(address(mockEngine));

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockEngine), AMOUNT_COLLATERAL);
        mockEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////
    /// Combined Function Tests ///
    ///////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approveInternal(USER, address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        uint256 dscBalance = dsc.balanceOf(USER);
        assertEq(dscBalance, AMOUNT_TO_MINT);
        uint256 wethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(wethBalance, STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralForDscBurnsDscAndRedeemsCollateral() public depositedCollateral mintedDsc {
        uint256 burnAmount = AMOUNT_TO_MINT;
        uint256 initialDscBalance = dsc.balanceOf(USER);
        uint256 initialWethBalance = ERC20Mock(weth).balanceOf(USER);
        vm.startPrank(USER);
        dsc.approve(address(engine), burnAmount);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, burnAmount);
        vm.stopPrank();
        uint256 finalDscBalance = dsc.balanceOf(USER);
        uint256 finalWethBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalDscBalance, initialDscBalance - burnAmount);
        assertEq(finalWethBalance, initialWethBalance + AMOUNT_COLLATERAL);
    }

    ///////////////////////////////
    // Health Factor Tests ////////
    ///////////////////////////////
    function testHealthFactorEnsuresTwoHundredPercentCollateralization() public depositedCollateral mintedDsc {
        // Deposited 10 WETH * $2000 (mock price) = $20,000
        // Minting 10,000 DSC should be health factor of 1
        uint256 expectedHealthFactor = 1 ether;
        vm.startPrank(USER);
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, expectedHealthFactor);
        vm.stopPrank();
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateral mintedDsc {
        int256 newWethPrice = 1500e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(newWethPrice);
        // 10 WETH * $1500 = $15,000
        // 10,000 DSC -->((15000 * 50)/100) / 10000  ---> should be health factor of 0.75
        uint256 expectedHealthFactor = 0.75 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorIsGreaterThanOneWhenNoDscMinted() public depositedCollateral {
        uint256 expectedHealthFactor = type(uint256).max;
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, expectedHealthFactor);
    }

    ///////////////////////////////
    // Liquidation Tests //////////
    ///////////////////////////////
    function testRevertsIfDebtToCoverIsZero() public {
        vm.prank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsAmountMoreThanZero.selector);
        engine.liquidate(weth, USER, 0);
    }

    function testCantLiquidateIfHealthFactorIsOk() public depositedCollateral mintedDsc {
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(AMOUNT_TO_MINT, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);

        vm.expectRevert(abi.encodePacked(DSCEngine.DSCEngine__HealthFactorIsOk.selector, expectedHealthFactor));
        engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }



    // This is a helper function to compute the expected revert payload
    uint256 constant _BPS = 10_000;            // precision
    uint256 constant _LIQ_BONUS_BPS = 1_000;   // 10% bonus

    function _expectedNotImprovedPayload(uint256 debtToCover)
        internal
        view
        returns (bytes memory)
    {
        // Starting HF (as the contract will read it)
        uint256 startHF = engine.getHealthFactor(USER);

        // Current account state (USD collateral, DSC debt)
        (uint256 d0, uint256 c0Usd) = engine.getAccountInformation(USER);

        // Base collateral tokens corresponding to the USD debtToCover
        uint256 baseTokens = engine.getTokenAmountFromUsd(weth, debtToCover);

        // Add liquidation bonus (borrower-paid)
        uint256 bonusTokens = (baseTokens * _LIQ_BONUS_BPS) / _BPS;
        uint256 totalTokens = baseTokens + bonusTokens;

        // Convert seized tokens to USD at current oracle price
        uint256 seizedUsd = engine.getUsdValue(weth, totalTokens);

        // Post-state for HF
        uint256 c1Usd = c0Usd - seizedUsd;
        uint256 d1    = d0 - debtToCover;

        uint256 endHF = engine.calculateHealthFactor(d1, c1Usd);

        // Encode the exact custom error with args (bytes overload)
        return abi.encodeWithSelector(
            DSCEngine.DSCEngine__HealthFactorNotImproved.selector,
            startHF,
            endHF
        );
    }


    function testLiquidationRevertsIfHealthFactorDoesNotImprove_programmatic()
        public
        depositedCollateral
        mintedDsc
    {
        // Make USER liquidatable (HF < 1) by dropping price to $1,000
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1_000e8);
        assertLt(engine.getHealthFactor(USER), 1e18, "pre: HF must be < 1");

        // Prepare LIQUIDATOR with DSC to burn (no extra locals kept alive)
        {
            ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);
            vm.startPrank(LIQUIDATOR);
            ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
            engine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
            dsc.approve(address(engine), type(uint256).max);
            vm.stopPrank();
        } // <- locals inside this block are dropped here

        uint256 debtToCover = 100 ether;                // small amount to ensure HF worsens
        bytes memory expected = _expectedNotImprovedPayload(debtToCover);

        vm.expectRevert(expected);                      // bytes overload: selector + args
        vm.prank(LIQUIDATOR);
        engine.liquidate(weth, USER, debtToCover);
    }


    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 1500e8; // 1 ETH = $1500
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_TO_COVER);
        engine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);
        engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    
    function testLiquidationPaysTheBonus() public liquidated {
        // the `liquidated` modifier calls:
        //   engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        // at a price of $1,500/ETH.
        //
        // So the base collateral seized (in WETH) equals the token amount
        // corresponding to `debtToCover = AMOUNT_TO_MINT` USD:
        uint256 baseTokens = engine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT);

        // If your DSCEngine exposes public constants/getters for the bonus, use them.
        // Otherwise, set what your engine uses (10% bonus -> 1000 bps over 10_000 precision).
        uint256 BONUS_BPS = 1_000;   // 10%
        uint256 BPS       = 10_000;  // precision

        uint256 bonusTokens    = (baseTokens * BONUS_BPS) / BPS;
        uint256 expectedTokens = baseTokens + bonusTokens;

        // After liquidation, the Engine transfers the seized collateral to the LIQUIDATOR.
        uint256 liquidatorWethAfter = ERC20Mock(weth).balanceOf(LIQUIDATOR);

        // Strict equality should pass if price/bonus math matches exactly.
        // If you worry about a 1 wei rounding difference, switch to assertApproxEqAbs(..., 1).
        assertEq(
            liquidatorWethAfter,
            expectedTokens,
            "Liquidator must receive base + bonus collateral"
        );

        assertGt(bonusTokens, 0, "Bonus should be positive");
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, AMOUNT_TO_MINT);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }


    /////////////////////////////////
    //  View & Pure Function Tests //
    /////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, 50);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDscAddress() public {
        address dscAddress = engine.getDscAddress();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    function testLiquidationBonus() public {
        uint256 expectedLiquidationBonus = 10; // 10% bonus
        uint256 actualLiquidationBonus = engine.getLiquidationBonus();
        assertEq(actualLiquidationBonus, expectedLiquidationBonus);
    }

    function testPrecisionAndAdditionalPriceFeedPrecision() public {
        uint256 expectedPrecision = 1e18;
        uint256 actualPrecision = engine.getPrecision();
        assertEq(actualPrecision, expectedPrecision);

        uint256 expectedAdditionalPriceFeedPrecision = 1e10;
        uint256 actualAdditionalPriceFeedPrecision = engine.getAdditionalPriceFeedPrecision();
        assertEq(actualAdditionalPriceFeedPrecision, expectedAdditionalPriceFeedPrecision);
    }

}
