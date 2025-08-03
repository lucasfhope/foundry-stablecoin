// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Lucas Hope
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors     ////
    ///////////////////
    error DSCEngine__TokenAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__NeedsAmountMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOk(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 startingHealthFactor, uint256 endingHealthFactor);
    error DSCEngine__AmountExceedsBalance(uint256 amount, uint256 balance);

    //////////////////////
    // State Variables  //
    //////////////////////
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_PRICE_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1.0 = 100%
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    // Events      ////
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed tokenCollateralAddress, uint256 amountOfCollateral);
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amountOfCollateral
    );

    ///////////////////
    // Modifiers    ///
    ///////////////////
    modifier amountMoreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsAmountMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD price feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @param tokenCollateralAddress The address of the collateral token to deposit
     * @param amountOfCollateral The amount of collateral to deposit
     * @param amountOfDscToMint The amount of the decentralized stablecoin to mint
     * @notice This function deposits collateral and mints DSC in one transaction.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        uint256 amountOfDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountOfCollateral);
        mintDsc(amountOfDscToMint);
    }

    /**
     * @param tokenCollateralAddress The address of the collateral token to deposit
     * @param amountOfCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        public
        amountMoreThanZero(amountOfCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountOfCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // $100 ETh -> $20 DSC
    // redeem all (break)
    //

    /**
     *
     * @param tokenCollateralAddress The address of the collateral token to redeem
     * @param amountOfCollateral The amount of collateral to redeem
     * @param amountOfDscToBurn The amount of the decentralized stablecoin to burn
     * @notice This function burns DSC and redeems collateral in one transaction.
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        uint256 amountOfDscToBurn
    ) external {
        burnDsc(amountOfDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountOfCollateral);
        // redeem collateral already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY - Dont repeat yourself
    // CEI - Checks Effects Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        public
        amountMoreThanZero(amountOfCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountOfCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amountDscToMint The amount of the decentralized stablecoin to mint
     * @notice minting user must have more collateral than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public amountMoreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountOfDscToBurn) public amountMoreThanZero(amountOfDscToBurn) {
        _burnDsc(amountOfDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i dont think this would ever hit
    }

    // $100 ETh backing $50 DSC
    // $20 ETH backing $50 DSc <-- DSC isnt worth $1

    // $75 backing $50 DSC
    // Liquidator takes the $75 backing and burns off the $50 DSC

    // if someone is almost undercollateralized, we will pay you to liquidate them

    /**
     * @param tokenCollateralAddreess The ERC20 address of the collateral token to liquidate from the user
     * @param userToLiquidate The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice you can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice The function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice a known bug would be if the protocol were 100% or less collateralized, then we wouldn;t be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address tokenCollateralAddreess, address userToLiquidate, uint256 debtToCover)
        external
        amountMoreThanZero(debtToCover)
        nonReentrant
    {
        // folllows CEI - Checks, Effects, Interactions
        // need to check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(userToLiquidate);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk(startingUserHealthFactor);
        }
        // We want to burn their DSC debt
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC = ?? ETH
        uint256 tokenAmountFromDebtCovered = _getTokenAmountFromUsd(tokenCollateralAddreess, debtToCover);
        // and give them 10% bonus
        // so giving the liquidator $110 WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep the extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(userToLiquidate, msg.sender, tokenCollateralAddreess, totalCollateralToRedeem);
        _burnDsc(debtToCover, userToLiquidate, msg.sender);
        // We need to burn DSC
        uint256 endingHealthFactor = _healthFactor(userToLiquidate);
        if (endingHealthFactor < startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved(startingUserHealthFactor, endingHealthFactor);
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    

    /////////////////////////////
    // Private Functions ////////
    /////////////////////////////
    /**
     * @dev low-level private functions, do not call unless the function calling it is checking for health factors being broken.
     */
    function _burnDsc(uint256 amountOfDscToBurn, address onBehalfOf, address dscFrom) private {
        if (amountOfDscToBurn > s_dscMinted[onBehalfOf]) {
            revert DSCEngine__AmountExceedsBalance(amountOfDscToBurn, s_dscMinted[onBehalfOf]);
        }
        s_dscMinted[onBehalfOf] -= amountOfDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountOfDscToBurn);
        if (!success) {
            // this conditional is hypothetically unreachable
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountOfDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountOfCollateral)
        private
    {
        if (amountOfCollateral > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert DSCEngine__AmountExceedsBalance(
                amountOfCollateral, s_collateralDeposited[from][tokenCollateralAddress]
            );
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountOfCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountOfCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /////////////////////////////////////////////
    // Private & Internal View Functions ////////
    /////////////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        totalCollateralInUsd = _getAccountCollateralValue(user);
        return (totalDscMinted, totalCollateralInUsd);
    }

    /**
     * Returns how close the user is to liquidation a user is
     * If a user goes below 1, they can be liquidated.
     * A value of 1 means 200% collateralization, which is the minimum
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $150 ETH / 100 DSC = 1.5
        // $150 * 50 = 7500 / 100 = 75, (75/100 DSC minted < 1)

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(healthFactor);
        }
    }

    function _getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Price of ETH (token)
        // $/ETH ETH ??
        // $2000 / 1 ETH, $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_PRICE_FEED_PRECISION);
    }

    function _getAccountCollateralValue(address user) public view returns (uint256 totalCollateralInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralInUsd;
    }

    function _getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // the returned value from chainlink will be 2000 * 1e8 (assuming 1 ETH = $2000)
        return ((uint256(price) * ADDITIONAL_PRICE_FEED_PRECISION) * amount) / PRECISION; // price in 1e8 * 1e10 = 1e18 to multiply with amount that should be in 1e18 (=1eth). then divide by 1e18 to get the value in USD (1e18=1$)
    }

    /////////////////////////////////////////////
    // Public and External View Functions
    /////////////////////////////////////////////
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        return _getTokenAmountFromUsd(token, usdAmountInWei);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralInUsd) {
        return _getAccountCollateralValue(user);
    }

    function getCollateralBalanceOfUser(address user, address token)
        public
        view
        returns (uint256 amountCollateral)
    {
        return s_collateralDeposited[user][token];
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralInUsd)
    {
        (totalDscMinted, totalCollateralInUsd) = _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralTokenBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalPriceFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_PRICE_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDscAddress() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
